# Migration Guide: Async/Await to Thread-Based Event Loop

This guide helps migrate from the async/await-based event loop (Zig < 0.15.0) to the thread-based event loop (Zig ≥ 0.15.0).

## Overview

Zig 0.15.0 removed async/await support, requiring a complete rewrite of the event loop architecture. This guide covers the changes needed to update your code.

## Key Changes

### 1. Event Loop Initialization

**Before (Async/Await):**

```zig
var event_loop = AsyncEventLoop.init(allocator, config);
defer event_loop.deinit();
```

**After (Thread-Based):**

```zig
var event_loop = try AsyncEventLoop.init(allocator, config);
defer event_loop.deinit();
```

### 2. Adding Tasks/Events

**Before:**

```zig
// Add chat message
try event_loop.addChatMessage(chat_id, text, session_id);

// Schedule event
_ = async event_loop.scheduleEvent(.reminder, delay, @frame());
```

**After:**

```zig
// Add task
try event_loop.addTask(session_id, text, "telegram");

// Schedule event
try event_loop.scheduleEvent(.reminder, expires, payload);
```

### 3. Handler Functions

**Before:**

```zig
fn processChatMessage(self: *AsyncEventLoop, chat_id: i64, text: []const u8, session_id: []const u8) void {
    // Process message
}
```

**After:**

```zig
fn handleTask(allocator: std.mem.Allocator, task: Task) !void {
    // Parse task data
    // Process message
    // Clean up allocated memory
    allocator.free(task.id);
    allocator.free(task.data);
    allocator.free(task.source);
}
```

### 4. Platform Integration

**Before:**

```zig
// Platform-specific code in event loop
if (std.mem.eql(u8, task.source, "telegram")) {
    // Telegram-specific handling
}
```

**After:**

```zig
// Separate handlers for each platform
const telegram_handler = createTelegramTaskHandler(&telegram_context);
event_loop.setTaskHandler(telegram_handler);
```

## Step-by-Step Migration

### Step 1: Update Event Loop Usage

1. Change all `AsyncEventLoop.init()` calls to `try AsyncEventLoop.init()`
2. Replace `addChatMessage()` with `addTask()`
3. Update task data format to include source information

### Step 2: Create Platform Handlers

1. Create a handler file (e.g., `telegram_handlers.zig`)
2. Define a context struct for platform-specific data
3. Implement handler functions with the new signature
4. Create factory functions for handlers

Example handler structure:

```zig
pub const PlatformContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    client: *const HttpClient,
};

pub fn createPlatformTaskHandler(ctx: *PlatformContext) TaskHandler {
    return struct {
        fn handler(allocator: std.mem.Allocator, task: Task) !void {
            // Handle platform-specific task
        }
    }.handler;
}
```

### Step 3: Update Memory Management

1. Always free task data in handlers
2. Use the provided allocator parameter
3. Check for unused parameters

### Step 4: Fix Compilation Errors

Common fixes needed:

1. **Type Casting:**

   ```zig
   // Old
   const value = @intCast(expression);
   
   // New
   const value = @as(u64, @intCast(expression));
   ```

2. **ArrayList:**

   ```zig
   // Old
   var list = std.ArrayList(T).init(allocator);
   list.append(item);
   list.deinit();
   
   // New
   var list = std.ArrayList(T).initCapacity(allocator, 0) catch unreachable;
   list.append(allocator, item);
   list.deinit(allocator);
   ```

3. **Signal Handling:**

   ```zig
   // Old
   .mask = std.posix.empty_sigset,
   
   // New
   .mask = std.posix.sigemptyset(),
   ```

4. **Division:**

   ```zig
   // Old
   const result = a / b;
   
   // New
   const result = @divTrunc(a, b);
   ```

### Step 5: Test Thoroughly

1. Test concurrent message processing
2. Verify memory is properly freed
3. Check for race conditions
4. Ensure graceful shutdown works

## Common Pitfalls

### 1. Memory Leaks

Always free task data in handlers:

```zig
fn handler(allocator: std.mem.Allocator, task: Task) !void {
    defer {
        allocator.free(task.id);
        allocator.free(task.data);
        allocator.free(task.source);
    }
    // Process task...
}
```

### 2. Thread Safety

- Don't share mutable state between threads without synchronization
- Use mutexes for shared data access
- Keep handlers stateless or use thread-local data

### 3. Error Handling

- Handle errors gracefully in handlers
- Don't let one failed task crash the event loop
- Log errors for debugging

## Performance Considerations

### Thread Pool Size

The event loop creates threads based on CPU count. You can customize this if needed:

```zig
// In event_loop.zig
const num_workers = @max(1, std.Thread.getCpuCount() catch 1);
```

### Task Granularity

- Keep tasks small and focused
- Avoid long-running operations in handlers
- Consider breaking large tasks into smaller ones

### Memory Usage

- Monitor task queue depth
- Implement backpressure if queue grows too large
- Consider task batching for efficiency

## Testing Strategies

### Unit Tests

Test handlers in isolation:

```zig
test "Telegram handler processes message" {
    const allocator = std.testing.allocator;
    var ctx = TelegramContext.init(allocator, test_config, &test_client);
    
    const handler = createTelegramTaskHandler(&ctx);
    const task = Task{
        .id = try allocator.dupe(u8, "test_id"),
        .data = try allocator.dupe(u8, "test:message"),
        .source = try allocator.dupe(u8, "telegram"),
        .timestamp = 0,
    };
    defer allocator.free(task.id);
    defer allocator.free(task.data);
    defer allocator.free(task.source);
    
    try handler(allocator, task);
}
```

### Integration Tests

Test the full event loop:

```zig
test "Event loop processes multiple tasks concurrently" {
    var event_loop = try AsyncEventLoop.init(test_allocator, test_config);
    defer event_loop.deinit();
    
    // Add multiple tasks
    for (0..10) |i| {
        try event_loop.addTask(
            try std.fmt.allocPrint(test_allocator, "task_{d}", .{i}),
            "test data",
            "test"
        );
    }
    
    // Run for a short time
    const timer = try std.time.Timer.start();
    while (timer.read() < 100 * std.time.ns_per_ms) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    
    // Verify all tasks were processed
}
```

## Migration Checklist

- [ ] Update event loop initialization
- [ ] Replace async calls with task queue
- [ ] Create platform-specific handlers
- [ ] Update all type casts
- [ ] Fix ArrayList usage
- [ ] Update signal handling
- [ ] Fix division operations
- [ ] Add proper memory cleanup
- [ ] Test concurrent processing
- [ ] Verify graceful shutdown
- [ ] Update documentation
- [ ] Run full test suite

## Resources

- [Thread-Based Event Loop Documentation](THREAD_BASED_EVENT_LOOP.md)
- [Zig 0.15.0 Release Notes](https://ziglang.org/download/0.15.0/release-notes.html)
- [Zig Standard Library Documentation](https://ziglang.org/documentation/0.15.0/std/)

## Getting Help

If you encounter issues during migration:

1. Check the compilation error rules in `.agent/rules/zig-compilation-errors.md`
2. Review the test files for examples
3. Ask for help in the Zig Discord or GitHub discussions
4. Create an issue with details about the problem
