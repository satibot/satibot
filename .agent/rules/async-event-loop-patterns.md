# Async Event Loop and Handler Rules

## 1. Handler Context Management

### Rule: Handler contexts must maintain valid pointer references

When creating handlers for async event loops, ensure the context has a lifetime that exceeds the handler execution.

```zig
// ❌ WRONG - Context points to stack variable
pub fn init() !EventLoop {
    var client = HttpClient.init();
    var context = Context.init(&client); // client is on stack!
    
    var loop = EventLoop.init();
    loop.setHandler(context.handler);
    return loop; // context now holds invalid pointer!
}

// ✅ CORRECT - Context points to owned resource
pub fn init(allocator: std.mem.Allocator) !EventLoop {
    var loop = EventLoop.init();
    
    // Create struct that owns resources
    var bot = Bot.init(allocator, client) catch |err| {
        loop.deinit();
        return err;
    };
    
    // Context points to fields in owning struct
    bot.context = Context.init(&bot.client);
    loop.setHandler(bot.context.handler);
    
    return loop;
}
```

## 2. Task Data Ownership

### Rule: Task data must be owned by the event loop or explicitly transferred

When adding tasks to an event loop, the data must outlive the task processing.

```zig
// ✅ CORRECT - Event loop owns task data
pub fn addTask(self: *EventLoop, data: []const u8) !void {
    // Duplicate the data so it's owned by the queue
    const owned_data = try self.allocator.dupe(u8, data);
    const task = Task{
        .data = owned_data,
        // ... other fields
    };
    try self.task_queue.append(task);
}

// ✅ CORRECT - Transfer ownership with clear contract
pub fn addTaskWithOwnership(self: *EventLoop, data: []const u8) !void {
    // Caller transfers ownership to event loop
    const task = Task{
        .data = data, // Now owned by event loop
    };
    try self.task_queue.append(task);
}
```

## 3. Global Handler Pattern

### Rule: Global handlers must use atomic references or be immutable

If using global handlers (as in the Telegram bot), ensure the global reference remains valid.

```zig
// ⚠️  CAUTION - Global mutable state
var global_context: ?*Context = null;

pub fn setGlobalContext(ctx: *Context) void {
    global_context = ctx; // Must ensure ctx outlives all uses!
}

// ✅ BETTER - Use atomic reference counting
var global_context: std.atomic.Value(?*Context) = std.atomic.Value(?*Context).init(null);

pub fn setGlobalContext(ctx: *Context) void {
    _ = global_context.store(ctx, .seq_cst);
}

pub fn getGlobalContext() ?*Context {
    return global_context.load(.seq_cst);
}
```

## 4. Thread-Safe Context Access

### Rule: Context accessed from multiple threads must be thread-safe

When handlers run on worker threads, ensure concurrent access is safe.

```zig
// ✅ GOOD - Thread-safe context design
pub const ThreadSafeContext = struct {
    mutex: std.Thread.Mutex,
    client: HttpClient,
    
    pub fn sendMessage(self: *ThreadSafeContext, msg: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client.send(msg);
    }
};
```

## 5. Handler Lifecycle

### Rule: Handlers must not access resources after deinit

Ensure all handler execution completes before cleaning up resources.

```zig
// ✅ CORRECT shutdown sequence
pub fn deinit(self: *EventLoop) void {
    // 1. Signal shutdown
    self.shutdown.store(true, .seq_cst);
    
    // 2. Wake all waiting threads
    self.condition.broadcast();
    
    // 3. Wait for all tasks to complete
    for (self.worker_threads.items) |thread| {
        thread.join();
    }
    
    // 4. Now safe to clean up resources
    self.client.deinit();
}
```

## 6. Error Handling in Handlers

### Rule: Handlers must gracefully handle resource failures

Never crash the event loop due to handler errors.

```zig
// ✅ GOOD - Error handling in handlers
fn handleTask(self: *EventLoop, task: Task) void {
    self.processTask(task) catch |err| {
        log.err("Task failed: {any}", .{err});
        // Continue processing other tasks
    };
}
```

## 7. Testing Async Patterns

### Rule: Test with realistic concurrency

- Use multiple worker threads in tests
- Test rapid task submission
- Verify cleanup under load

```zig
test "event loop concurrent access" {
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    
    // Submit tasks from multiple threads
    const num_threads = 10;
    var threads: [num_threads]std.Thread = undefined;
    
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, submitTasks, .{&loop, i});
    }
    
    for (threads) |thread| {
        thread.join();
    }
    
    // Verify all tasks processed
    try std.testing.expectEqual(@as(usize, 1000), loop.processed_count);
}
```

## 8. Common Pitfalls

### Pitfalls to avoid

1. **Stack pointers in handlers** - Always use heap or struct fields
2. **Use-after-free in callbacks** - Ensure callback data outlives registration
3. **Data races on shared context** - Use proper synchronization
4. **Resource leaks on errors** - Clean up even when handlers fail
5. **Blocking in event loop** - Never block the main event loop thread
