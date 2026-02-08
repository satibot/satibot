const std = @import("std");
const satibot = @import("root.zig");
const ThreadedTelegramBot = @import("agent/threaded_telegram_bot.zig").ThreadedTelegramBot;
const ThreadedTelegramEventLoop = @import("agent/threaded_telegram_event_loop.zig").ThreadedTelegramEventLoop;

/// Send a message to Telegram chat
fn sendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    var client = try satibot.http.Client.initWithSettings(allocator, .{
        .request_timeout_ms = 10000,
        .keep_alive = true,
    });
    defer client.deinit();

    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
    defer allocator.free(chat_id_str);

    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage?chat_id={s}&text={s}", .{ bot_token, chat_id_str, text });
    defer allocator.free(url);

    const response = try client.get(url, &.{});
    defer @constCast(&response).deinit();

    if (response.status != .ok) {
        std.debug.print("Failed to send message: status {any}, body: {s}\n", .{ response.status, response.body });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Initialize Telegram event loop
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Telegram configuration not found\n", .{});
        return error.TelegramNotConfigured;
    };

    var event_loop = try ThreadedTelegramEventLoop.init(
        allocator,
        config,
        tg_config.botToken,
        sendMessage,
    );
    defer event_loop.deinit();

    // Initialize threaded telegram bot
    var bot = try ThreadedTelegramBot.init(allocator, config, &event_loop);
    defer bot.deinit();

    // Add some example cron jobs
    const DailySchedule = struct {
        kind: enum { at, every },
        at_ms: ?i64 = null,
        every_ms: ?i64 = null,
    };

    try event_loop.addCronJob("daily_report", "Daily Report", "Generate daily analytics report", DailySchedule{
        .kind = .every,
        .every_ms = 24 * 60 * 60 * 1000, // 24 hours
    });

    try event_loop.addCronJob("hourly_check", "Hourly Check", "Check system status", DailySchedule{
        .kind = .every,
        .every_ms = 60 * 60 * 1000, // 1 hour
    });

    // Start the event loop in a separate thread
    const event_loop_thread = try std.Thread.spawn(.{}, ThreadedTelegramEventLoop.run, .{&event_loop});
    defer event_loop_thread.join();

    // Start the Telegram bot polling
    try bot.run();
}
