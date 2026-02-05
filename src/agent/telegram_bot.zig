const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const Client = @import("../http.zig").Client;

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Error: Telegram bot token not configured in config.json\n", .{});
        return;
    };

    var client = Client.init(allocator);
    defer client.deinit();

    var offset: i64 = 0;

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=30", .{ tg_config.botToken, offset });
        defer allocator.free(url);

        var response = client.get(url, &[_]std.http.Header{}) catch |err| {
            if (err == error.HttpConnectionClosing or err == error.ReadFailed or err == error.ConnectionResetByPeer) {
                // Connection was closed, just wait a bit and retry
                std.Thread.sleep(std.time.ns_per_s * 1);
                continue;
            }
            std.debug.print("Error getting updates: {any}\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
            continue;
        };
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("Telegram API error: {d}\n", .{@intFromEnum(response.status)});
            std.Thread.sleep(std.time.ns_per_s * 5);
            continue;
        }

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

                    var agent = Agent.init(allocator, config, session_id);
                    defer agent.deinit();

                    // We wrap the agent run to capture errors
                    agent.run(text) catch |err| {
                        std.debug.print("Error running agent: {any}\n", .{err});
                        const error_msg = if (err == error.NetworkRetryFailed)
                            try std.fmt.allocPrint(allocator, "⚠️ Connection failed after multiple retries.\n\nThe OpenRouter model '{s}' is currently overloaded or unstable. Please try again in a moment or switch to a different model in config.json.", .{config.agents.defaults.model})
                        else
                            try std.fmt.allocPrint(allocator, "⚠️ Error: {any}\n\nThis often happens with free models if the connection is unstable. Please try again.", .{err});
                        defer allocator.free(error_msg);
                        try send_telegram_message(allocator, &client, tg_config.botToken, chat_id_str, error_msg);
                    };

                    // The agent.run calls tools, but it doesn't automatically send the FINAL response back to telegram.
                    // We need to send the last assistant message back.
                    const messages = agent.ctx.get_messages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                            try send_telegram_message(allocator, &client, tg_config.botToken, chat_id_str, last_msg.content.?);
                        }
                    }

                    // Always try to index even if we fail to send message
                    agent.index_conversation() catch {};
                }
            }
        }
    }
}

fn send_telegram_message(allocator: std.mem.Allocator, client: *Client, token: []const u8, chat_id: []const u8, text: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id,
        .text = text,
    }, .{});
    defer allocator.free(body);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = client.post(url, headers, body) catch |err| blk: {
        if (err == error.HttpConnectionClosing or err == error.ReadFailed or err == error.ConnectionResetByPeer) {
            // Retry once for connection issues
            break :blk try client.post(url, headers, body);
        }
        return err;
    };
    defer response.deinit();

    if (response.status != .ok) {
        std.debug.print("Error sending response to Telegram: {d}\n", .{@intFromEnum(response.status)});
    }
}
