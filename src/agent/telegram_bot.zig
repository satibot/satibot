const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Error: Telegram bot token not configured in config.json\n", .{});
        return;
    };

    var offset: i64 = 0;
    var client = try http.Client.initWithSettings(allocator, .{
        .request_timeout_ms = 60000, // 60 seconds
        .keep_alive = true,
    });
    defer client.deinit();

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=30", .{ tg_config.botToken, offset });
        defer allocator.free(url);

        const response = client.get(url, &.{}) catch |err| {
            std.debug.print("Error getting updates: {any}\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
            continue;
        };
        defer @constCast(&response).deinit();

        const UpdateResponse = struct {
            ok: bool,
            result: []struct {
                update_id: i64,
                message: ?struct {
                    chat: struct {
                        id: i64,
                    },
                    text: ?[]const u8 = null,
                } = null,
            },
        };

        const parsed = std.json.parseFromSlice(UpdateResponse, allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("Error parsing updates: {any}\n", .{err});
            continue;
        };
        defer parsed.deinit();

        for (parsed.value.result) |update| {
            offset = update.update_id + 1;

            if (update.message) |msg| {
                if (msg.text) |text| {
                    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{msg.chat.id});
                    defer allocator.free(chat_id_str);

                    std.debug.print("Received message from {s}: {s}\n", .{ chat_id_str, text });

                    // Create session ID based on chat ID
                    const session_id = try std.fmt.allocPrint(allocator, "tg_{d}", .{msg.chat.id});
                    defer allocator.free(session_id);

                    // Handle /new command
                    var actual_text = text;
                    if (std.mem.startsWith(u8, text, "/new")) {
                        const home = std.posix.getenv("HOME") orelse "/tmp";
                        const session_path = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions", try std.fmt.allocPrint(allocator, "{s}.json", .{session_id}) });
                        defer allocator.free(session_path);
                        std.fs.deleteFileAbsolute(session_path) catch {};

                        if (text.len <= 4) {
                            try send_telegram_message(&client, tg_config.botToken, chat_id_str, "🆕 Session cleared! Send me a new message.");
                            continue;
                        }
                        actual_text = std.mem.trimLeft(u8, text[4..], " ");
                    }

                    var agent = Agent.init(allocator, config, session_id);
                    defer agent.deinit();

                    agent.run(actual_text) catch |err| {
                        std.debug.print("Error running agent: {any}\n", .{err});
                        const error_msg = try std.fmt.allocPrint(allocator, "⚠️ Error: {any}\n\nPlease try again.", .{err});
                        defer allocator.free(error_msg);
                        try send_telegram_message(&client, tg_config.botToken, chat_id_str, error_msg);
                    };

                    const messages = agent.ctx.get_messages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                            try send_telegram_message(&client, tg_config.botToken, chat_id_str, last_msg.content.?);
                        }
                    }

                    agent.index_conversation() catch {};
                }
            }
        }
    }
}

fn send_telegram_message(client: *http.Client, token: []const u8, chat_id: []const u8, text: []const u8) !void {
    const url = try std.fmt.allocPrint(client.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
    defer client.allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(client.allocator, .{
        .chat_id = chat_id,
        .text = text,
    }, .{});
    defer client.allocator.free(body);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const response = client.post(url, headers, body) catch |err| {
        std.debug.print("Error sending message to Telegram: {any}\n", .{err});
        return;
    };
    defer @constCast(&response).deinit();
}
