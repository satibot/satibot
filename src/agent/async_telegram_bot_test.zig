const std = @import("std");
const testing = std.testing;
const AsyncTelegramBot = @import("async_telegram_bot.zig").AsyncTelegramBot;
const TelegramEventLoop = @import("telegram_event_loop.zig").TelegramEventLoop;
const Config = @import("../../config.zig").Config;

// Mock message sender for testing
fn mockSendMessage(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    _ = allocator;
    _ = bot_token;
    _ = chat_id;
    _ = text;
    // In a real test, you would capture these messages for verification
}

test "AsyncTelegramBot initialization" {
    const allocator = testing.allocator;
    
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{
            .telegram = .{
                .botToken = "test_token",
            },
        },
    };

    var event_loop = try TelegramEventLoop.init(
        allocator,
        config,
        "test_token",
        mockSendMessage,
    );
    defer event_loop.deinit();

    var bot = try AsyncTelegramBot.init(allocator, config, &event_loop);
    defer bot.deinit();

    try testing.expect(bot.offset == 0);
}

test "TelegramEventLoop add and process message" {
    const allocator = testing.allocator;
    
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{},
    };

    var event_loop = try TelegramEventLoop.init(
        allocator,
        config,
        "test_token",
        mockSendMessage,
    );
    defer event_loop.deinit();

    // Add a test message
    try event_loop.addChatMessage(12345, "Hello, world!");

    // Check that message was added to queue
    event_loop.message_mutex.lock();
    defer event_loop.message_mutex.unlock();
    
    try testing.expect(event_loop.message_queue.items.len == 1);
    try testing.expectEqual(@as(i64, 12345), event_loop.message_queue.items[0].chat_id);
    try testing.expectEqualStrings("Hello, world!", event_loop.message_queue.items[0].text);
}

test "TelegramEventLoop cron job management" {
    const allocator = testing.allocator;
    
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{},
    };

    var event_loop = try TelegramEventLoop.init(
        allocator,
        config,
        "test_token",
        mockSendMessage,
    );
    defer event_loop.deinit();

    // Add a cron job
    try event_loop.addCronJob("test_job", "Test Job", "Run test", .{
        .kind = .every,
        .every_ms = 60000, // 1 minute
    });

    // Check that cron job was added
    event_loop.cron_mutex.lock();
    defer event_loop.cron_mutex.unlock();
    
    const job = event_loop.cron_jobs.get("test_job");
    try testing.expect(job != null);
    try testing.expectEqualStrings("Test Job", job.?.name);
    try testing.expectEqualStrings("Run test", job.?.message);
}
