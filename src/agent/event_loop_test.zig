const std = @import("std");
const testing = std.testing;
const AsyncEventLoop = @import("event_loop.zig").AsyncEventLoop;
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
        .providers = .{},
        .tools = .{},
    };
}

test "AsyncEventLoop.init" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Verify initial state
    try testing.expectEqual(@as(usize, 0), event_loop.event_queue.count());
    try testing.expectEqual(@as(usize, 0), event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 0), event_loop.cron_jobs.count());
    try testing.expectEqual(@as(usize, 0), event_loop.active_chats.items.len);
    try testing.expectEqual(false, event_loop.shutdown.load(.seq_cst));
}

// Test adding chat messages
test "AsyncEventLoop.addChatMessage" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Add first message
    try event_loop.addChatMessage(12345, "Hello World");

    // Verify message was added
    try testing.expectEqual(@as(usize, 1), event_loop.message_queue.items.len);
    const msg = event_loop.message_queue.items[0];
    try testing.expectEqual(@as(i64, 12345), msg.chat_id);
    try testing.expectEqualStrings("Hello World", msg.text);
    try testing.expectEqualStrings("tg_12345", msg.session_id);

    // Verify chat was tracked
    try testing.expectEqual(@as(usize, 1), event_loop.active_chats.items.len);
    try testing.expectEqual(@as(i64, 12345), event_loop.active_chats.items[0]);

    // Add second message to same chat (should not duplicate in active_chats)
    try event_loop.addChatMessage(12345, "Second message");
    try testing.expectEqual(@as(usize, 2), event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 1), event_loop.active_chats.items.len);

    // Add message to different chat
    try event_loop.addChatMessage(67890, "Different chat");
    try testing.expectEqual(@as(usize, 2), event_loop.active_chats.items.len);

    // Cleanup
    allocator.free(msg.text);
    allocator.free(msg.session_id);
}

// Test adding cron jobs
test "AsyncEventLoop.addCronJob" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Add recurring cron job
    try event_loop.addCronJob("test_job_1", "Test Job 1", "Test message 1", .{ .kind = .every, .every_ms = 60000 });

    // Verify job was added
    try testing.expectEqual(@as(usize, 1), event_loop.cron_jobs.count());
    const job = event_loop.cron_jobs.get("test_job_1").?;
    try testing.expectEqualStrings("test_job_1", job.id);
    try testing.expectEqualStrings("Test Job 1", job.name);
    try testing.expectEqualStrings("Test message 1", job.message);
    try testing.expectEqual(@as(u64, 60000), job.schedule.every_ms.?);
    try testing.expect(job.enabled);

    // Add one-time cron job
    const future_time = std.time.milliTimestamp() + 300000; // 5 minutes from now
    try event_loop.addCronJob("test_job_2", "Test Job 2", "Test message 2", .{ .kind = .at, .at_ms = future_time });

    try testing.expectEqual(@as(usize, 2), event_loop.cron_jobs.count());
    const job2 = event_loop.cron_jobs.get("test_job_2").?;
    try testing.expectEqual(@as(i64, future_time), job2.schedule.at_ms.?);
}

// Test event scheduling
test "AsyncEventLoop.scheduleEvent" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Schedule an event
    const TestEvent = struct {
        executed: bool = false,

        fn testTask(loop: *AsyncEventLoop, self: *@This()) void {
            _ = loop;
            self.executed = true;
        }
    };

    var test_event = TestEvent{};
    TestEvent.testTask(&event_loop, &test_event);

    // Test that we can add events to the queue
    // Note: In a real scenario, the frame would come from an async function
    // For testing purposes, we'll verify the queue operations directly
    try testing.expectEqual(@as(usize, 0), event_loop.event_queue.count());

    // The event scheduling requires a real async frame, which is complex to test
    // in a unit test context. We'll test the integration in the async gateway tests.
}

// Test cron job scheduling
test "AsyncEventLoop.scheduleCronExecution" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Add a cron job first
    try event_loop.addCronJob("test_cron", "Test Cron", "Cron message", .{ .kind = .every, .every_ms = 60000 });

    // Test that the cron job was added
    try testing.expectEqual(@as(usize, 1), event_loop.cron_jobs.count());
    const job = event_loop.cron_jobs.get("test_cron").?;
    try testing.expectEqualStrings("test_cron", job.id);

    // The actual scheduling requires async context
    // We verify the cron job exists and is properly configured
}

// Test nanoTime function
test "nanoTime" {
    const start_time = @import("event_loop.zig").nanoTime();
    std.Thread.sleep(std.time.ns_per_ms);
    const end_time = @import("event_loop.zig").nanoTime();

    // nanoTime should be monotonic and increasing
    try testing.expect(end_time > start_time);
    try testing.expect(end_time - start_time >= std.time.ns_per_ms);
}

// Test message processing simulation
test "AsyncEventLoop.messageProcessing" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Add multiple messages
    const messages = [_]struct { id: i64, text: []const u8 }{
        .{ .id = 1001, .text = "Message 1" },
        .{ .id = 1002, .text = "Message 2" },
        .{ .id = 1003, .text = "Message 3" },
    };

    for (messages) |msg| {
        try event_loop.addChatMessage(msg.id, msg.text);
    }

    // Verify all messages were added
    try testing.expectEqual(@as(usize, 3), event_loop.message_queue.items.len);

    // Verify FIFO order
    try testing.expectEqual(@as(i64, 1001), event_loop.message_queue.items[0].chat_id);
    try testing.expectEqual(@as(i64, 1002), event_loop.message_queue.items[1].chat_id);
    try testing.expectEqual(@as(i64, 1003), event_loop.message_queue.items[2].chat_id);

    // Cleanup
    for (event_loop.message_queue.items) |msg| {
        allocator.free(msg.text);
        allocator.free(msg.session_id);
    }
}

// Test cron job next run calculation
test "AsyncEventLoop.cronNextRun" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    const now = std.time.milliTimestamp();

    // Test recurring job
    try event_loop.addCronJob("recurring", "Recurring Job", "Message", .{ .kind = .every, .every_ms = 300000 } // 5 minutes
    );

    const job = event_loop.cron_jobs.get("recurring").?;
    try testing.expect(job.next_run > now);
    try testing.expect(job.next_run < now + 300000 + 1000); // Allow 1s tolerance

    // Test one-time job
    const future_time = now + 600000; // 10 minutes from now
    try event_loop.addCronJob("onetime", "One-time Job", "Message", .{ .kind = .at, .at_ms = future_time });

    const job2 = event_loop.cron_jobs.get("onetime").?;
    try testing.expectEqual(@as(u64, @intCast(future_time)), job2.next_run);
}

// Test shutdown functionality
test "AsyncEventLoop.shutdown" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Initially not shutdown
    try testing.expectEqual(false, event_loop.shutdown.load(.seq_cst));

    // Request shutdown
    event_loop.shutdown();
    try testing.expectEqual(true, event_loop.shutdown.load(.seq_cst));
}

// Test concurrent message addition
test "AsyncEventLoop.concurrentMessages" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    const num_threads = 10;
    const messages_per_thread = 100;

    // Spawn multiple threads adding messages concurrently
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn task(el: *AsyncEventLoop, thread_id: usize) void {
                for (0..messages_per_thread) |j| {
                    const chat_id = @as(i64, @intCast(thread_id * 1000 + j));
                    const message = std.fmt.allocPrint(el.allocator, "Message {d} from thread {d}", .{ j, thread_id }) catch return;
                    defer el.allocator.free(message);
                    el.addChatMessage(chat_id, message) catch return;
                }
            }
        }.task, .{ &event_loop, i });
    }

    // Wait for all threads to complete
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all messages were added
    try testing.expectEqual(@as(usize, num_threads * messages_per_thread), event_loop.message_queue.items.len);

    // Verify all unique chats were tracked
    try testing.expectEqual(@as(usize, num_threads * messages_per_thread), event_loop.active_chats.items.len);

    // Cleanup
    for (event_loop.message_queue.items) |msg| {
        allocator.free(msg.text);
        allocator.free(msg.session_id);
    }
}

// Test error handling
test "AsyncEventLoop.errorHandling" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Test adding message with empty text (should still work)
    try event_loop.addChatMessage(12345, "");

    // Test adding cron job with empty message (should still work)
    try event_loop.addCronJob("empty_job", "Empty Job", "", .{ .kind = .every, .every_ms = 60000 });

    // Verify they were added
    try testing.expectEqual(@as(usize, 1), event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 1), event_loop.cron_jobs.count());
}

// Integration test with mock agent
test "AsyncEventLoop.integration" {
    const allocator = testing.allocator;
    const config = createTestConfig();

    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    // Add a mix of messages and cron jobs
    try event_loop.addChatMessage(12345, "Test message 1");
    try event_loop.addChatMessage(67890, "Test message 2");

    try event_loop.addCronJob("integration_test", "Integration Test", "Test cron message", .{ .kind = .every, .every_ms = 60000 });

    // Verify state
    try testing.expectEqual(@as(usize, 2), event_loop.message_queue.items.len);
    try testing.expectEqual(@as(usize, 1), event_loop.cron_jobs.count());
    try testing.expectEqual(@as(usize, 2), event_loop.active_chats.items.len);

    // Test that the event loop can be initialized and cleaned up without errors
    // Full async testing would require a test runtime that supports async/await
}
