const std = @import("std");
const testing = std.testing;
const AsyncGateway = @import("async_gateway.zig").AsyncGateway;
const Config = @import("../config.zig").Config;

/// Mock configuration for testing
fn createTestConfig() Config {
    return Config{
        .agents = .{
            .defaults = .{
                .model = "test-model",
                .embeddingModel = "test-embedding",
            },
        },
        .providers = .{
            .anthropic = .{ .apiKey = "test-anthropic-key" },
            .openrouter = .{ .apiKey = "test-openrouter-key" },
            .groq = .{ .apiKey = "test-groq-key" },
        },
        .tools = .{
            .web = .{ .search = .{ .apiKey = "test-search-key" } },
            .telegram = .{
                .botToken = "test-bot-token",
                .chatId = "test-chat-id",
            },
        },
    };
}

// Test AsyncGateway initialization
test "AsyncGateway.init" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Verify gateway was initialized
    try testing.expect(gateway.telegram_bot != null);
    try testing.expectEqual(@as(usize, 0), gateway.event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 0), gateway.event_loop.cron_jobs.count());
}

// Test AsyncGateway initialization without Telegram
test "AsyncGateway.initWithoutTelegram" {
    const allocator = testing.allocator;
    var config = createTestConfig();
    config.tools.telegram = null;

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Verify telegram bot is not initialized
    try testing.expect(gateway.telegram_bot == null);
}

// Test command handling
test "AsyncGateway.handleCommand" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Test /help command (should not error)
    try gateway.handleCommand(12345, "/help");

    // Test /status command (should not error)
    try gateway.handleCommand(12345, "/status");

    // Test /new command (should add as regular message)
    try gateway.handleCommand(12345, "/new test message");

    // Verify message was added to event loop
    try testing.expectEqual(@as(usize, 1), gateway.event_loop.message_queue.items.len);
    const msg = gateway.event_loop.message_queue.items[0];
    try testing.expectEqual(@as(i64, 12345), msg.chat_id);
    try testing.expectEqualStrings("test message", msg.text);

    // Cleanup
    allocator.free(msg.text);
    allocator.free(msg.session_id);
}

// Test voice message handling simulation
test "AsyncGateway.handleVoiceMessage" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // This test simulates the async voice message handling
    // In a real test, we would mock the HTTP client and Groq provider

    // The function should not crash when called
    gateway.handleVoiceMessage(gateway.telegram_bot.?, 12345, "test-file-id", "test-token");
}

// Test cron job loading
test "AsyncGateway.loadCronJobs" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Load cron jobs (will not find file, should not error)
    try gateway.loadCronJobs();

    // Should start with empty cron jobs
    try testing.expectEqual(@as(usize, 0), gateway.event_loop.cron_jobs.count());
}

// Test Telegram polling simulation
test "AsyncGateway.telegramPoller" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Start the telegram poller (it will run until shutdown)
    const frame = async gateway.telegramPoller(gateway.telegram_bot.?);

    // Let it run briefly
    std.Thread.sleep(std.time.ns_per_ms * 10);

    // Request shutdown
    gateway.event_loop.shutdown.store(true, .seq_cst);

    // Wait for poller to finish
    nosuspend await frame;
}

// Test message processing flow
test "AsyncGateway.messageFlow" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Simulate receiving a regular message
    try gateway.event_loop.addChatMessage(12345, "Hello, bot!");

    // Verify message is in queue
    try testing.expectEqual(@as(usize, 1), gateway.event_loop.message_queue.items.len);

    // Simulate command message
    try gateway.handleCommand(67890, "/help");

    // Commands should not be added to the queue (handled directly)
    try testing.expectEqual(@as(usize, 1), gateway.event_loop.message_queue.items.len);
}

// Test error handling in pollTelegramUpdates
test "AsyncGateway.pollTelegramUpdatesErrors" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Test with invalid token (should handle error gracefully)
    gateway.pollTelegramUpdates(gateway.telegram_bot.?, "invalid-token") catch |err| {
        // Should handle network errors gracefully
        try testing.expect(err == error.HttpConnectionClosing or
            err == error.ConnectionResetByPeer or
            err == error.ReadFailed);
    };
}

// Test concurrent operations
test "AsyncGateway.concurrentOperations" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;

    // Spawn threads adding messages and commands concurrently
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn task(gw: *AsyncGateway, thread_id: usize) void {
                const chat_id = @as(i64, @intCast(1000 + thread_id));

                // Add regular message
                gw.event_loop.addChatMessage(chat_id, "Test message") catch return;

                // Handle command
                gw.handleCommand(chat_id, "/status") catch return;
            }
        }.task, .{ &gateway, i });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all messages were added (commands not added)
    try testing.expectEqual(@as(usize, num_threads), gateway.event_loop.message_queue.items.len);

    // Cleanup
    for (gateway.event_loop.message_queue.items) |msg| {
        allocator.free(msg.text);
        allocator.free(msg.session_id);
    }
}

// Test shutdown procedure
test "AsyncGateway.shutdown" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Add some activity
    try gateway.event_loop.addChatMessage(12345, "Test message");
    try gateway.event_loop.addCronJob("test", "Test", "Message", .{ .kind = .every, .every_ms = 60000 });

    // Request shutdown
    gateway.shutdown();

    // Verify shutdown flag is set
    try testing.expectEqual(true, gateway.event_loop.shutdown.load(.seq_cst));
}

// Integration test with mock services
test "AsyncGateway.integration" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();

    // Simulate various operations
    try gateway.handleCommand(12345, "/help");
    try gateway.event_loop.addChatMessage(12345, "Regular message");
    try gateway.event_loop.addChatMessage(67890, "Another message");

    try gateway.event_loop.addCronJob("integration_cron", "Integration Test", "Test cron message", .{ .kind = .every, .every_ms = 300000 });

    // Verify state
    try testing.expectEqual(@as(usize, 2), gateway.event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 1), gateway.event_loop.cron_jobs.count());
    try testing.expectEqual(@as(usize, 2), gateway.event_loop.active_chats.items.len);

    // Cleanup
    for (gateway.event_loop.message_queue.items) |msg| {
        allocator.free(msg.text);
        allocator.free(msg.session_id);
    }
}
