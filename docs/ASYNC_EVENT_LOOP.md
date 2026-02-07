# Async Event Loop Architecture

This document describes the async event loop implementation for efficiently handling multiple ChatIDs and cron jobs in SatiBot.

## Overview

The async event loop replaces the synchronous polling approach with a more efficient async/await pattern, enabling:

- Concurrent processing of messages from multiple chats
- Efficient cron job scheduling without blocking
- Better resource utilization and scalability
- Non-blocking I/O operations

## Architecture

### Core Components

1. **AsyncEventLoop** (`src/agent/event_loop.zig`)
   - Main event loop with priority queue for timed events
   - Message queue for immediate processing
   - Cron job management
   - Active chat tracking

2. **AsyncGateway** (`src/agent/async_gateway.zig`)
   - Integrates the event loop with bot services
   - Handles provider-specific message polling
   - Manages graceful shutdown

3. **Event Types**
   - `message`: Chat messages from any platform
   - `cron_job`: Scheduled tasks
   - `heartbeat`: System health checks
   - `shutdown`: Graceful termination

## Key Features

### 1. Priority-Based Event Scheduling

Events are scheduled using a priority queue based on their execution time:

```zig
const Event = struct {
    type: EventType,
    expires: u64,
    frame: anyframe,
    // ... event-specific data
};
```

### 2. Async Message Processing

Messages are processed concurrently without blocking:

```zig
fn processChatMessage(self: *AsyncEventLoop, chat_id: i64, text: []const u8, session_id: []const u8) void {
    self.waitForTime(100); // Simulate processing
    
    var agent = Agent.init(self.allocator, self.config, session_id);
    defer agent.deinit();
    
    agent.run(text) catch |err| {
        std.debug.print("Error processing message: {any}\n", .{err});
    };
}
```

### 3. Efficient Cron Job Management

Cron jobs are scheduled and executed asynchronously:

```zig
fn processCronJob(self: *AsyncEventLoop, job: CronJobEvent) void {
    // Process job
    agent.run(job.message) catch {};
    
    // Schedule next run if recurring
    if (job.schedule.kind == .every) {
        _ = async self.scheduleCronExecution(job.id, next_delay);
    }
}
```

## Usage Examples

### Basic Event Loop

```zig
var event_loop = try AsyncEventLoop.init(allocator, config);
defer event_loop.deinit();

// Add a cron job
try event_loop.addCronJob(
    "daily_report",
    "Daily Report",
    "Generate daily analytics",
    .{ .kind = .every, .every_ms = 24 * 60 * 60 * 1000 }
);

// Add a chat message
try event_loop.addChatMessage(123456, "Hello, bot!");

// Run the event loop
try event_loop.run();
```

### Multi-Platform Gateway

```zig
var gateway = try AsyncGateway.init(allocator, config);
defer gateway.deinit();

// Automatically handles:
// - Telegram polling
// - Discord webhooks
// - WhatsApp messages
// - All cron jobs

try gateway.run();
```

## Performance Benefits

1. **Concurrent Processing**: Multiple chats handled simultaneously
2. **Non-Blocking I/O**: Network operations don't block the entire system
3. **Efficient Scheduling**: Priority queue ensures timely execution
4. **Resource Optimization**: No busy-waiting or excessive polling

## Comparison with Synchronous Approach

| Aspect            | Synchronous       | Async Event Loop |
|-------------------|-------------------|------------------|
| Message Handling  | One at a time     | Concurrent       |
| Cron Execution    | Blocks main loop  | Non-blocking     |
| Resource Usage    | Higher CPU usage  | Optimized        |
| Scalability       | Limited           | High             |
| Latency           | Variable          | Low and predictable |

## Implementation Details

### Event Queue

The event loop uses a min-heap priority queue:

```zig
var event_queue: std.PriorityQueue(Event, void, Event.compare) = undefined;
```

Events are ordered by their `expires` timestamp, ensuring the next due event is always processed first.

### Message Queue

Immediate messages use a simple FIFO queue:

```zig
var message_queue: std.ArrayList(ChatMessage) = undefined;
```

This ensures messages are processed in arrival order without delay.

### Async/Await Pattern

The implementation uses Zig's async/await for non-blocking operations:

```zig
fn waitForTime(self: *AsyncEventLoop, delay_ms: u64) void {
    suspend {
        self.scheduleEvent(.message, delay_ms, @frame()) catch unreachable;
    }
}
```

## Migration Guide

To migrate from the synchronous gateway:

1. Replace `Gateway` with `AsyncGateway`
2. Update message handlers to work with the event loop
3. Convert cron jobs to use the async scheduler
4. Test with the provided demo

## Testing

Run the async event loop demo:

```bash
zig run examples/async_event_loop_demo.zig
```

This simulates multiple concurrent chats and demonstrates the event loop's efficiency.

## Future Enhancements

1. **Load Balancing**: Distribute load across multiple event loop instances
2. **Persistent Queue**: Survive restarts with message persistence
3. **Metrics Collection**: Built-in performance monitoring
4. **Dynamic Scaling**: Auto-scale based on load
5. **Event Replay**: Replay events for debugging

## Best Practices

1. Keep async functions short and non-blocking
2. Use proper error handling in async contexts
3. Avoid long-running operations in the event loop
4. Implement proper shutdown handling
5. Monitor event queue depth for performance tuning

## Troubleshooting

### High Memory Usage

- Check for leaked frames in the event queue
- Ensure proper cleanup of allocated strings
- Monitor cron job count

### Poor Performance

- Profile the `waitForTime` delays
- Check for blocking operations in async functions
- Monitor CPU usage during high load

### Messages Not Processing

- Verify the message queue is being serviced
- Check for deadlock in async operations
- Ensure proper event scheduling
