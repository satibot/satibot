const std = @import("std");

/// Main entry point for the synchronous Telegram bot
/// This is a simplified version that processes messages one at a time
pub fn main() !void {
    // Initialize general purpose allocator for memory management
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple config loading (standalone to avoid module conflicts)
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const config_path = try std.fs.path.join(allocator, &.{ home, ".bots", "config.json" });
    defer allocator.free(config_path);

    const config_file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        const error_msg =
            \\Error: Could not open config file at {s}: {any}
            \\Please create ~/.bots/config.json with your configuration.
        ;
        std.debug.print(error_msg, .{ config_path, err });
        return err;
    };
    defer config_file.close();

    const config_content = try config_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(config_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_content, .{});
    defer parsed.deinit();

    // Extract config values
    const model = parsed.value.object.get("agents").?.object.get("defaults").?.object.get("model").?.string;
    const telegram_token_opt = parsed.value.object.get("tools").?.object.get("telegram");

    const telegram_token = if (telegram_token_opt) |tg| tg.object.get("botToken").?.string else null;

    // Check if telegram configuration is available
    if (telegram_token == null) {
        const error_msg =
            \\Error: telegram configuration is required but not found in ~/.bots/config.json
            \\Please add the following to your config:
            \\  "tools": {{
            \\    "telegram": {{
            \\      "botToken": "your-bot-token"
            \\    }}
            \\  }}
        ;
        std.debug.print(error_msg, .{});
        return error.TelegramConfigNotFound;
    }

    // Display startup information
    const startup_msg =
        \\🐸 Synchronous Telegram Bot (build: {s})
        \\Model: {s}
        \\Processing: Sequential (one message at a time)
        \\Press Ctrl+C to stop.
        \\
    ;
    std.debug.print(startup_msg, .{ @import("build_options").build_time_str, model });

    // Run the synchronous telegram bot (simple echo version for now)
    try runSimpleBot(allocator, telegram_token.?);
}

fn runSimpleBot(allocator: std.mem.Allocator, bot_token: []const u8) !void {
    _ = allocator; // Mark as used
    var offset: i64 = 0;

    const bot_msg =
        \\Bot started successfully!
        \\Bot Token: {s}
        \\Polling for messages...
    ;
    std.debug.print(bot_msg, .{bot_token});

    while (true) {
        // Simple polling logic would go here
        std.debug.print("Polling... (offset: {d})\n", .{offset});
        std.Thread.sleep(std.time.ns_per_s * 5);
        offset += 1;
    }
}
