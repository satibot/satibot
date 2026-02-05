const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Error: Telegram bot token not configured in config.json\n", .{});
        return;
    };

    var offset: i64 = 0;

    // Use a slightly larger timeout for curl than the long-polling timeout
    // Telegram timeout is 30s, so using 40s for curl ensures we don't cut it off too early
    while (true) {
        const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=30", .{ tg_config.botToken, offset });
        defer allocator.free(url);

        const response_body = curlRequest(allocator, url, "GET", null) catch |err| {
            // Connection was closed or failed, just wait a bit and retry
            std.debug.print("Error getting updates (curl): {any}\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
            continue;
        };
        defer allocator.free(response_body);

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

        const parsed = std.json.parseFromSlice(UpdateResponse, allocator, response_body, .{ .ignore_unknown_fields = true }) catch |err| {
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
                        try send_telegram_message(allocator, tg_config.botToken, chat_id_str, error_msg);
                    };

                    // The agent.run calls tools, but it doesn't automatically send the FINAL response back to telegram.
                    // We need to send the last assistant message back.
                    const messages = agent.ctx.get_messages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                            try send_telegram_message(allocator, tg_config.botToken, chat_id_str, last_msg.content.?);
                        }
                    }

                    // Always try to index even if we fail to send message
                    agent.index_conversation() catch {};
                }
            }
        }
    }
}

fn send_telegram_message(allocator: std.mem.Allocator, token: []const u8, chat_id: []const u8, text: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id,
        .text = text,
    }, .{});
    defer allocator.free(body);

    const response_body = curlRequest(allocator, url, "POST", body) catch |err| {
        std.debug.print("Error sending message to Telegram: {any}\n", .{err});
        return;
    };
    defer allocator.free(response_body);

    // We could check the response body for "ok": true, but for now just logging it on error is enough
    // std.debug.print("Telegram Send Response: {s}\n", .{response_body});
}

fn curlRequest(allocator: std.mem.Allocator, url: []const u8, method: []const u8, body: ?[]const u8) ![]u8 {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &[_][]const u8{ "curl", "-s", "-X", method, url });

    if (body) |b| {
        try argv.appendSlice(allocator, &[_][]const u8{ "-H", "Content-Type: application/json" });
        try argv.appendSlice(allocator, &[_][]const u8{ "-d", b });
    }

    // Add timeout to prevent hanging forever
    try argv.appendSlice(allocator, &[_][]const u8{ "-m", "40" });

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch |err| {
        return err;
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CurlFailed;
    }

    return result.stdout;
}
