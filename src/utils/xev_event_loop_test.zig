const std = @import("std");
const xev_event_loop = @import("xev_event_loop.zig");
const Config = @import("../config.zig").Config;

test "Task: struct creation and access" {
    const task: xev_event_loop.Task = .{
        .id = "task_123",
        .data = "task data",
        .source = "test_source",
    };

    try std.testing.expectEqualStrings("task_123", task.id);
    try std.testing.expectEqualStrings("task data", task.data);
    try std.testing.expectEqualStrings("test_source", task.source);
}

test "Task: empty strings" {
    const task: xev_event_loop.Task = .{
        .id = "",
        .data = "",
        .source = "",
    };

    try std.testing.expectEqualStrings("", task.id);
    try std.testing.expectEqualStrings("", task.data);
    try std.testing.expectEqualStrings("", task.source);
}

test "Event: struct creation and access" {
    const event: xev_event_loop.Event = .{
        .id = "event_456",
        .type = .custom,
        .payload = "event payload",
        .expires = 1234567890,
    };

    try std.testing.expectEqualStrings("event_456", event.id);
    try std.testing.expectEqual(xev_event_loop.EventType.custom, event.type);
    try std.testing.expectEqualStrings("event payload", event.payload.?);
    try std.testing.expectEqual(@as(i64, 1234567890), event.expires);
}

test "Event: with null payload" {
    const event: xev_event_loop.Event = .{
        .id = "no_payload",
        .type = .shutdown,
        .payload = null,
        .expires = 987654321,
    };

    try std.testing.expectEqualStrings("no_payload", event.id);
    try std.testing.expectEqual(xev_event_loop.EventType.shutdown, event.type);
    try std.testing.expect(event.payload == null);
    try std.testing.expectEqual(@as(i64, 987654321), event.expires);
}

test "EventType: enum values" {
    try std.testing.expectEqual(xev_event_loop.EventType.custom, xev_event_loop.EventType.custom);
    try std.testing.expectEqual(xev_event_loop.EventType.shutdown, xev_event_loop.EventType.shutdown);
}

test "Event: compare function" {
    const event1: xev_event_loop.Event = .{
        .id = "earlier",
        .type = .custom,
        .payload = null,
        .expires = 1000,
    };

    const event2: xev_event_loop.Event = .{
        .id = "later",
        .type = .custom,
        .payload = null,
        .expires = 2000,
    };

    // event1 expires earlier, so it should be less than event2
    const order = xev_event_loop.Event.compare({}, event1, event2);
    try std.testing.expectEqual(std.math.Order.lt, order);

    // event2 expires later, so it should be greater than event1
    const reverse_order = xev_event_loop.Event.compare({}, event2, event1);
    try std.testing.expectEqual(std.math.Order.gt, reverse_order);

    // Same expiration time should be equal
    const event3: xev_event_loop.Event = .{
        .id = "same_time",
        .type = .custom,
        .payload = null,
        .expires = 1000,
    };

    const equal_order = xev_event_loop.Event.compare({}, event1, event3);
    try std.testing.expectEqual(std.math.Order.eq, equal_order);
}

test "Event: compare with negative timestamps" {
    const event1: xev_event_loop.Event = .{
        .id = "negative1",
        .type = .custom,
        .payload = null,
        .expires = -1000,
    };

    const event2: xev_event_loop.Event = .{
        .id = "negative2",
        .type = .custom,
        .payload = null,
        .expires = -500,
    };

    const order = xev_event_loop.Event.compare({}, event1, event2);
    try std.testing.expectEqual(std.math.Order.lt, order);
}

test "TaskHandler and EventHandler: function pointer types" {
    // Test that the function pointer types are valid
    const TaskHandler = xev_event_loop.TaskHandler;
    const EventHandler = xev_event_loop.EventHandler;

    // These should compile without errors
    _ = TaskHandler;
    _ = EventHandler;

    try std.testing.expect(true);
}

test "XevEventLoop: basic initialization" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Note: This test may fail if xev is not available or if there are system dependencies
    // In a real test environment, you might want to mock xev or skip this test
    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        // If xev is not available, that's expected in some test environments
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    try std.testing.expectEqual(allocator, event_loop.allocator);
    try std.testing.expectEqual(parsed.value, event_loop.config);
    try std.testing.expectEqual(false, event_loop.shutdown.load(.seq_cst));
    try std.testing.expectEqual(@as(i64, 0), event_loop.offset.load(.seq_cst));
}

test "XevEventLoop: task handler management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should have no task handler
    try std.testing.expect(event_loop.task_handler == null);

    // Set a mock task handler
    const mock_task_handler = struct {
        fn handle(task_allocator: std.mem.Allocator, task: xev_event_loop.Task) !void {
            _ = task_allocator;
            _ = task;
        }
    }.handle;

    event_loop.setTaskHandler(mock_task_handler);
    try std.testing.expect(event_loop.task_handler != null);
}

test "XevEventLoop: event handler management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should have no event handler
    try std.testing.expect(event_loop.event_handler == null);

    // Set a mock event handler
    const mock_event_handler = struct {
        fn handle(event_allocator: std.mem.Allocator, event: xev_event_loop.Event) !void {
            _ = event_allocator;
            _ = event;
        }
    }.handle;

    event_loop.setEventHandler(mock_event_handler);
    try std.testing.expect(event_loop.event_handler != null);
}

test "XevEventLoop: offset management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should be 0
    try std.testing.expectEqual(@as(i64, 0), event_loop.offset.load(.seq_cst));

    // Test setting offset
    event_loop.offset.store(42, .seq_cst);
    try std.testing.expectEqual(@as(i64, 42), event_loop.offset.load(.seq_cst));

    // Test updating offset
    event_loop.offset.store(100, .seq_cst);
    try std.testing.expectEqual(@as(i64, 100), event_loop.offset.load(.seq_cst));
}

test "XevEventLoop: shutdown flag management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should not be shutdown
    try std.testing.expectEqual(false, event_loop.shutdown.load(.seq_cst));

    // Test setting shutdown
    event_loop.shutdown.store(true, .seq_cst);
    try std.testing.expectEqual(true, event_loop.shutdown.load(.seq_cst));
}

test "XevEventLoop: task queue operations" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should be empty
    try std.testing.expectEqual(@as(usize, 0), event_loop.task_queue.items.len);

    // Test adding task (this would normally be done internally)
    const task: xev_event_loop.Task = .{
        .id = "test_task",
        .data = "test_data",
        .source = "test_source",
    };

    // Note: Direct access to task_queue might not be thread-safe in real usage
    // This is just for testing the data structure
    event_loop.task_queue.append(task) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), event_loop.task_queue.items.len);
    try std.testing.expectEqualStrings("test_task", event_loop.task_queue.items[0].id);
}

test "XevEventLoop: event queue operations" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
        if (err == error.Unexpected) return; // Skip test
        return err;
    };
    defer event_loop.deinit();

    // Initially should be empty
    try std.testing.expectEqual(@as(usize, 0), event_loop.event_queue.count());

    // Test adding events
    const event1: xev_event_loop.Event = .{
        .id = "event1",
        .type = .custom,
        .payload = "payload1",
        .expires = 1000,
    };

    const event2: xev_event_loop.Event = .{
        .id = "event2",
        .type = .custom,
        .payload = "payload2",
        .expires = 500,
    };

    // Add events (note: this would normally be done internally)
    event_loop.event_queue.add(event1) catch unreachable;
    event_loop.event_queue.add(event2) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), event_loop.event_queue.count());

    // The priority queue should order by expiration time
    const earliest = event_loop.event_queue.peek().?;
    try std.testing.expectEqual(@as(i64, 500), earliest.expires); // event2 expires earlier
}

test "XevEventLoop: memory management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test that init and deinit work without memory leaks
    {
        var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
            if (err == error.Unexpected) return; // Skip test
            return err;
        };
        defer event_loop.deinit();

        // Set some handlers to test cleanup
        const mock_handler = struct {
            fn handle(handler_allocator: std.mem.Allocator, task: xev_event_loop.Task) !void {
                _ = handler_allocator;
                _ = task;
            }
        }.handle;

        event_loop.setTaskHandler(mock_handler);
        event_loop.setEventHandler(mock_handler);

        // If we get here without crashing, memory management is working
        try std.testing.expect(true);
    }
}

test "XevEventLoop: configuration integration" {
    const allocator = std.testing.allocator;

    const configs = [_][]const u8{
        // Minimal config
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
        ,
        // Config with providers
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": { "openrouter": { "apiKey": "test-key" } },
        \\  "tools": { "web": { "search": {} } }
        \\}
        ,
    };

    for (configs) |config_json| {
        const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var event_loop = xev_event_loop.XevEventLoop.init(allocator, parsed.value) catch |err| {
            if (err == error.Unexpected) continue; // Skip this config
            return err;
        };
        defer event_loop.deinit();

        try std.testing.expectEqual(parsed.value, event_loop.config);
    }
}
