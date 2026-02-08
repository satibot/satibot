const std = @import("std");
const Config = @import("config.zig").Config;
const AsyncTelegramBot = @import("agent/async_telegram_bot.zig").AsyncTelegramBot;
const TelegramEventLoop = @import("agent/telegram_event_loop.zig").TelegramEventLoop;

/// Send a message to Telegram chat
fn sendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    const http = @import("http.zig");
    
    var client = try http.Client.initWithSettings(allocator, .{
        .request_timeout_ms = 10000,
        .keep_alive = true,
    });
    defer client.deinit();

    const encoded_text = try std.Uri.Component.escape(text);
    defer allocator.free(encoded_text);

    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
    defer allocator.free(chat_id_str);

    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage?chat_id={s}&text={s}", .{ bot_token, chat_id_str, encoded_text });
    defer allocator.free(url);

    const response = try client.get(url, &.{});
    defer @constCast(&response).deinit();

    if (response.status_code != 200) {
        std.debug.print("Failed to send message: status {d}, body: {s}\n", .{ response.status_code, response.body });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Load configuration
    var config = Config.load(allocator) catch |err| {
        std.debug.print("Failed to load config: {any}\n", .{err});
        return err;
    };
    defer config.deinit(allocator);

    // Initialize Telegram event loop
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Telegram configuration not found\n", .{});
        return error.TelegramNotConfigured;
    };

    var event_loop = try TelegramEventLoop.init(
        allocator,
        config,
        tg_config.botToken,
        sendMessage,
    );
    defer event_loop.deinit();

    // Initialize async telegram bot
    var bot = try AsyncTelegramBot.init(allocator, config, &event_loop);
    defer bot.deinit();

    // Add some example cron jobs
    try event_loop.addCronJob("daily_report", "Daily Report", "Generate daily analytics report", .{
        .kind = .every,
        .every_ms = 24 * 60 * 60 * 1000, // 24 hours
    });

    try event_loop.addCronJob("hourly_check", "Hourly Check", "Check system status", .{
        .kind = .every,
        .every_ms = 60 * 60 * 1000, // 1 hour
    });

    // Start the event loop in a separate thread
    const event_loop_thread = try std.Thread.spawn(.{}, TelegramEventLoop.run, .{&event_loop});
    defer event_loop_thread.join();

    // Start the Telegram bot polling
    try bot.run();
}
