const std = @import("std");
const telegram_handlers = @import("telegram_handlers.zig");
const http = @import("../http.zig");
const Config = @import("../config.zig").Config;

test "SessionCache: init and deinit" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(usize, 0), cache.sessions.count());
    try std.testing.expectEqual(@as(usize, 0), cache.last_used.count());
}

test "SessionCache: getOrCreateSession creates new session" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    const session_id = "test-session-123";
    const history = try cache.getOrCreateSession(session_id);

    // Session should be created
    try std.testing.expect(cache.sessions.contains(session_id));
    try std.testing.expect(cache.last_used.contains(session_id));
    _ = history;
}

test "SessionCache: getOrCreateSession returns existing session" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    const session_id = "test-session-456";

    // Create first session
    const history1 = try cache.getOrCreateSession(session_id);

    // Get existing session
    const history2 = try cache.getOrCreateSession(session_id);

    // Should be the same pointer
    try std.testing.expect(history1 == history2);

    // Count should still be 1
    try std.testing.expectEqual(@as(usize, 1), cache.sessions.count());
}

test "SessionCache: cleanup removes idle sessions" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    // Set short idle time for testing (1 second)
    cache.max_idle_time_ms = 1000;

    // Create a session
    _ = try cache.getOrCreateSession("idle-session");

    // Wait a bit
    std.Thread.sleep(std.time.ns_per_s * 2);

    // Run cleanup
    cache.cleanup();

    // Session should be removed
    try std.testing.expect(!cache.sessions.contains("idle-session"));
    try std.testing.expect(!cache.last_used.contains("idle-session"));
}

test "SessionCache: cleanup keeps active sessions" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    // Set short idle time for testing (1 second)
    cache.max_idle_time_ms = 1000;

    // Create sessions
    _ = try cache.getOrCreateSession("active-session");
    _ = try cache.getOrCreateSession("idle-session");

    // Touch active session to update last_used
    if (cache.last_used.getPtr("active-session")) |time_ptr| {
        time_ptr.* = std.time.timestamp();
    }

    // Wait a bit
    std.Thread.sleep(std.time.ns_per_s * 2);

    // Run cleanup
    cache.cleanup();

    // Active session should remain
    try std.testing.expect(cache.sessions.contains("active-session"));
    // Idle session should be removed
    try std.testing.expect(!cache.sessions.contains("idle-session"));
}

test "SessionCache: memory - multiple session creation and cleanup" {
    const allocator = std.testing.allocator;
    var cache = telegram_handlers.SessionCache.init(allocator);
    defer cache.deinit();

    // Create many sessions
    for (0..50) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "session_{d}", .{i});
        defer allocator.free(session_id);
        _ = try cache.getOrCreateSession(session_id);
    }

    // Verify all sessions created
    try std.testing.expectEqual(@as(usize, 50), cache.sessions.count());

    // Run cleanup (nothing should be removed since we just created them)
    cache.cleanup();
    try std.testing.expectEqual(@as(usize, 50), cache.sessions.count());
}

test "TelegramContext: init and deinit" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    // Create a minimal HTTP client for testing
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();
    var client = http.Client.init(temp_allocator);
    defer client.deinit();

    var ctx = telegram_handlers.TelegramContext.init(allocator, config, &client);
    defer ctx.deinit();

    // Verify initial state
    try std.testing.expectEqual(allocator, ctx.allocator);
    try std.testing.expectEqual(config, ctx.config);
    try std.testing.expect(ctx.session_cache == null);
}

test "TelegramContext: initSessionCache creates cache" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();
    var client = http.Client.init(temp_allocator);
    defer client.deinit();

    var ctx = telegram_handlers.TelegramContext.init(allocator, config, &client);
    defer ctx.deinit();

    // Initially no cache
    try std.testing.expect(ctx.session_cache == null);

    // Initialize session cache
    ctx.initSessionCache();

    // Cache should now exist
    try std.testing.expect(ctx.session_cache != null);
}

test "TelegramContext: deinit cleans up session cache" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();
    var client = http.Client.init(temp_allocator);
    defer client.deinit();

    // Create context and add sessions
    {
        var ctx = telegram_handlers.TelegramContext.init(allocator, config, &client);

        // Initialize and use session cache
        ctx.initSessionCache();
        if (ctx.session_cache) |*cache| {
            _ = try cache.getOrCreateSession("test-session-1");
            _ = try cache.getOrCreateSession("test-session-2");
        }

        // Deinit should clean up everything
        ctx.deinit();
    }

    // If we reach here without memory leaks, test passes
    try std.testing.expect(true);
}

test "TelegramTaskData: struct fields" {
    const task_data: telegram_handlers.TelegramTaskData = .{
        .chat_id = 123456789,
        .message_id = 987654321,
        .text = "Hello, world!",
        .voice_duration = null,
        .update_id = 111111,
    };

    try std.testing.expectEqual(@as(i64, 123456789), task_data.chat_id);
    try std.testing.expectEqual(@as(i64, 987654321), task_data.message_id);
    try std.testing.expectEqualStrings("Hello, world!", task_data.text);
    try std.testing.expect(task_data.voice_duration == null);
    try std.testing.expectEqual(@as(i64, 111111), task_data.update_id);
}

test "TelegramTaskData: with voice duration" {
    const task_data: telegram_handlers.TelegramTaskData = .{
        .chat_id = 123456789,
        .message_id = 987654321,
        .text = "Voice message",
        .voice_duration = 30,
        .update_id = 222222,
    };

    try std.testing.expect(task_data.voice_duration != null);
    try std.testing.expectEqual(@as(i32, 30), task_data.voice_duration.?);
}

test "TelegramEventData: struct fields" {
    const event_data: telegram_handlers.TelegramEventData = .{
        .type = "custom",
        .data = "some payload",
    };

    try std.testing.expectEqualStrings("custom", event_data.type);
    try std.testing.expect(event_data.data != null);
    try std.testing.expectEqualStrings("some payload", event_data.data.?);
}

test "TelegramEventData: with null data" {
    const event_data: telegram_handlers.TelegramEventData = .{
        .type = "shutdown",
        .data = null,
    };

    try std.testing.expectEqualStrings("shutdown", event_data.type);
    try std.testing.expect(event_data.data == null);
}
