# Thread-Based Event Loop Architecture

This document describes the thread-based event loop implementation for efficiently handling multiple concurrent tasks in SatiBot, compatible with Zig 0.15.0.

## Overview

The thread-based event loop replaces the async/await pattern (removed in Zig 0.15.0) with a multi-threaded approach using `std.Thread`, `std.Thread.Mutex`, and `std.Thread.Condition`. This enables:

- Concurrent processing of tasks using a thread pool
- Efficient event scheduling without blocking
- Better resource utilization through parallel execution
- Generic architecture supporting any task/event source

## Architecture

### Core Components

1. **AsyncEventLoop** (`src/agent/event_loop.zig`)
   - Generic event loop with thread pool for task processing
   - Priority queue for scheduled events
   - Thread-safe task queue with mutex and condition variable
   - Atomic shutdown flag for graceful termination
   - Generic offset tracking for polling APIs

2. **Platform Handlers** (e.g., `src/chat_apps/telegram/telegram_handlers.zig`)
   - Platform-specific task and event handlers
   - Encapsulates platform logic in reusable modules
   - Clean separation between generic event loop and platform code

3. **Event Types**
   - `Task`: Immediate processing items with ID, data, source, and timestamp
   - `Event`: Scheduled items with type, expiration time, and optional payload

## Key Features

### 1. Thread Pool for Concurrent Processing

Tasks are processed by a pool of worker threads:

```zig
pub const AsyncEventLoop = struct {
    task_queue: std.ArrayList(Task),
    task_mutex: std.Thread.Mutex,
    task_condition: std.Thread.Condition,
    worker_threads: std.ArrayList(std.Thread),
    // ...
};
```

### 2. Thread-Safe Operations

All operations are protected by mutexes:

```zig
pub fn addTask(self: *AsyncEventLoop, id: []const u8, data: []const u8, source: []const u8) !void {
    const task = Task{
        .id = try self.allocator.dupe(u8, id),
        .data = try self.allocator.dupe(u8, data),
        .source = try self.allocator.dupe(u8, source),
        .timestamp = @intCast(std.time.nanoTimestamp()),
    };
    
    self.task_mutex.lock();
    defer self.task_mutex.unlock();
    
    try self.task_queue.append(self.allocator, task);
    self.task_condition.signal();
}
```

### 3. Generic Handler System

Handlers are function pointers that can be customized:

```zig
pub const TaskHandler = *const fn (allocator: std.mem.Allocator, task: Task) anyerror!void;
pub const EventHandler = *const fn (allocator: std.mem.Allocator, event: Event) anyerror!void;
```

## Usage Examples

### Basic Event Loop

```zig
var event_loop = try AsyncEventLoop.init(allocator, config);
defer event_loop.deinit();

// Set up handlers
event_loop.setTaskHandler(myTaskHandler);
event_loop.setEventHandler(myEventHandler);

// Add a task
try event_loop.addTask("task_1", "Hello, world!", "test");

// Schedule an event
try event_loop.scheduleEvent(
    .reminder,
    std.time.nanoTimestamp() + (5 * std.time.ns_per_s),
    "Don't forget!"
);

// Run the event loop
try event_loop.run();
```

### Telegram Bot Integration

```zig
// Initialize Telegram bot with event loop
var bot = try TelegramBot.init(allocator, config);
defer bot.deinit();

// The bot automatically:
// - Sets up Telegram-specific handlers
// - Manages offset tracking for polling
// - Processes messages concurrently

// Run the bot
try bot.run();
```

### Custom Handler Example

```zig
fn myTaskHandler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
    std.debug.print("Processing task {s} from {s}: {s}\n", 
        .{ task.id, task.source, task.data });
    
    // Process the task...
    
    // Clean up
    allocator.free(task.id);
    allocator.free(task.data);
    allocator.free(task.source);
}
```

## Performance Benefits

1. **Parallel Processing**: Multiple tasks handled simultaneously on different cores
2. **Non-Blocking Operations**: Thread synchronization prevents blocking
3. **Efficient Scheduling**: Priority queue ensures timely event execution
4. **Resource Optimization**: No busy-waiting, threads sleep when idle

## Comparison with Async/Await (Zig < 0.15.0)

| Aspect              | Async/Await (Old) | Thread-Based (New) |
|---------------------|-------------------|--------------------|
| Concurrency Model   | Coroutines        | OS Threads         |
| Memory Usage        | Lower per task    | Higher per thread  |
| CPU Utilization     | Single core       | Multi-core         |
| Complexity          | Frame management  | Mutex/Condition    |
| Zig Version         | < 0.15.0          | ≥ 0.15.0           |
| Debugging           | Harder            | Easier             |

## Implementation Details

### Thread Pool Management

The event loop creates worker threads based on CPU count:

```zig
const num_workers = @max(1, std.Thread.getCpuCount() catch 1);
for (0..num_workers) |_| {
    const worker = std.Thread.spawn(.{}, workerFn, .{self}) catch continue;
    self.worker_threads.append(self.allocator, worker) catch continue;
}
```

### Event Scheduling

Events use a priority queue ordered by expiration time:

```zig
var event_queue: std.PriorityQueue(Event, void, Event.compare) = undefined;

// Schedule event
try self.event_queue.add(event);

// Process next due event
const next_event = self.event_queue.peek();
if (next_event) |event| {
    const now = std.time.nanoTimestamp();
    if (now < event.expires) {
        const delay_ms = @as(u64, @intCast(@divTrunc(event.expires - now, std.time.ns_per_ms)));
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
    }
}
```

### Graceful Shutdown

Atomic flags ensure clean shutdown:

```zig
pub fn deinit(self: *AsyncEventLoop) void {
    self.shutdown.store(true, .seq_cst);
    self.task_condition.broadcast();
    
    // Wait for all threads
    for (self.worker_threads.items) |thread| {
        thread.join();
    }
    
    // Clean up remaining tasks
    self.task_mutex.lock();
    for (self.task_queue.items) |task| {
        self.allocator.free(task.id);
        self.allocator.free(task.data);
        self.allocator.free(task.source);
    }
    self.task_queue.deinit(self.allocator);
    self.task_mutex.unlock();
}
```

## Migration Guide

To migrate from async/await to thread-based:

1. **Update Event Loop Initialization**

   ```zig
   // Old
   var event_loop = AsyncEventLoop.init(allocator, config);
   
   // New
   var event_loop = try AsyncEventLoop.init(allocator, config);
   ```

2. **Replace Async Calls with Task Queue**

   ```zig
   // Old
   async event_loop.processMessage(chat_id, text);
   
   // New
   try event_loop.addTask(session_id, text, "telegram");
   ```

3. **Update Handler Functions**

   ```zig
   // Old
   fn processMessage(self: *Self, chat_id: i64, text: []const u8) void {
   
   // New
   fn handleMessage(allocator: std.mem.Allocator, task: Task) !void {
   ```

4. **Handle Memory Management**
   - Always free task data in handlers
   - Use proper allocator parameter
   - Check for unused parameters

## Platform Integration

### Telegram Handler Example

```zig
pub const TelegramContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    client: *const http.Client,
};

pub fn createTelegramTaskHandler(ctx: *TelegramContext) TaskHandler {
    return struct {
        fn handler(allocator: std.mem.Allocator, task: Task) !void {
            // Parse Telegram-specific data
            const tg_data = parseTelegramData(task);
            
            // Process with agent
            const response = try processWithAgent(tg_data);
            
            // Send response
            try sendTelegramMessage(ctx.client, tg_data.chat_id, response);
        }
    }.handler;
}
```

## Best Practices

1. **Thread Safety**
   - Always lock mutexes before accessing shared data
   - Use `defer` to unlock mutexes
   - Minimize time spent in critical sections

2. **Memory Management**
   - Free all allocations in task handlers
   - Use the provided allocator
   - Watch for memory leaks in long-running loops

3. **Error Handling**
   - Handle errors gracefully in handlers
   - Log errors but don't crash the event loop
   - Implement retry logic where appropriate

4. **Performance**
   - Keep tasks short and non-blocking
   - Use appropriate number of threads
   - Monitor queue depths

## Testing

Run the thread-based event loop:

```bash
zig build run-satibot
```

This will start the bot with the new thread-based event loop.

## Troubleshooting

### High Memory Usage

- Check for unfreed task data
- Ensure handlers clean up allocations
- Monitor task queue depth

### Poor Performance

- Profile thread contention
- Check for mutex deadlocks
- Optimize handler functions

### Messages Not Processing

- Verify handlers are set correctly
- Check for thread pool exhaustion
- Ensure tasks are being added

### Build Errors

- Check Zig 0.15.0 compatibility
- Verify all `@intCast` calls use `@as`
- Ensure ArrayList methods include allocator parameter

## Future Enhancements

1. **Dynamic Thread Pool**: Adjust thread count based on load
2. **Work Stealing**: Balance load across threads
3. **Priority Tasks**: Different priority levels for tasks
4. **Metrics**: Built-in performance monitoring
5. **Circuit Breakers**: Prevent cascade failures
