# Async Event Loop - Detailed Documentation

## Overview

The Async Event Loop is a high-performance, non-blocking event system designed to efficiently handle multiple concurrent operations in SatiBot. It uses Zig's async/await primitives with priority queues to manage timed events and message processing.

## Architecture

### Core Components

```mermaid
graph TB
    subgraph "AsyncEventLoop"
        EQ[Event Queue<br/>Priority Queue]
        MQ[Message Queue<br/>FIFO]
        CJ[Cron Jobs<br/>HashMap]
        AC[Active Chats<br/>ArrayList]
        SF[Shutdown Flag<br/>Atomic Bool]
    end
    
    subgraph "Event Types"
        MSG[Message Event]
        CRON[Cron Event]
        HB[Heartbeat Event]
        SD[Shutdown Event]
    end
    
    subgraph "External Inputs"
        TG[Telegram Messages]
        DIS[Discord Messages]
        WA[WhatsApp Messages]
        CRON_IN[Cron Triggers]
    end
    
    TG --> MQ
    DIS --> MQ
    WA --> MQ
    CRON_IN --> CJ
    
    MQ --> MSG
    CJ --> CRON
    
    MSG --> EQ
    CRON --> EQ
    HB --> EQ
    SD --> EQ
    
    EQ --> EventLoopRunner
```

## Event Flow

### Message Processing Flow

```mermaid
sequenceDiagram
    participant Platform as Telegram/Discord/WhatsApp
    participant Gateway as AsyncGateway
    participant EL as AsyncEventLoop
    participant MQ as MessageQueue
    participant Agent as Agent Instance
    
    Platform->>Gateway: Incoming Message
    Gateway->>EL: addChatMessage(chat_id, text)
    EL->>MQ: Enqueue message
    
    loop Event Loop
        EL->>MQ: Dequeue message
        MQ->>EL: Return ChatMessage
        EL->>EL: processChatMessage async
        Note over EL: Suspend frame
        
        EL->>Agent: Agent.init()
        EL->>Agent: agent.run(message)
        Agent->>EL: Response
        EL->>Platform: Send response
    end
```

### Cron Job Execution Flow

```mermaid
sequenceDiagram
    participant User as User/Config
    participant EL as AsyncEventLoop
    participant EQ as EventQueue
    participant Cron as CronJob
    participant Agent as Agent Instance
    
    User->>EL: addCronJob()
    EL->>Cron: Create job with next_run
    EL->>EQ: Schedule cron execution
    
    loop Event Loop
        EQ->>EL: Pop expired event
        EL->>EL: processCronJob async
        Note over EL: Suspend frame
        
        EL->>Agent: Agent.init()
        EL->>Agent: agent.run(cron_message)
        Agent->>EL: Result
        
        alt Recurring Job
            EL->>Cron: Calculate next_run
            EL->>EQ: Schedule next execution
        else One-time Job
            EL->>Cron: Disable job
        end
    end
```

## Data Structures

### Event Structure

```zig
const Event = struct {
    type: EventType,        // Message, Cron, Heartbeat, Shutdown
    expires: u64,          // Execution timestamp (nanoseconds)
    frame: anyframe,       // Suspended execution frame
    chat_id: ?i64,         // Associated chat ID
    message: ?[]const u8,  // Message content
    cron_id: ?[]const u8,  // Cron job ID
};
```

### Priority Queue Operations

```mermaid
graph LR
    subgraph "Priority Queue (Min-Heap)"
        A[Event 1<br/>expires: 1000]
        B[Event 2<br/>expires: 2000]
        C[Event 3<br/>expires: 3000]
        D[Event 4<br/>expires: 4000]
    end
    
    E[New Event<br/>expires: 1500] --> PQ
    
    subgraph "After Insertion"
        A2[Event 1<br/>expires: 1000]
        E2[New Event<br/>expires: 1500]
        B2[Event 2<br/>expires: 2000]
        C2[Event 3<br/>expires: 3000]
        D2[Event 4<br/>expires: 4000]
    end
    
    PQ -.->|Reheapify| AfterInsertion
```

## Key Algorithms

### Event Loop Main Algorithm

```mermaid
flowchart TD
    Start([Start]) --> Init{Shutdown?}
    Init -->|No| CheckMsg{Messages in Queue?}
    CheckMsg -->|Yes| ProcessMsg[Process Message Async]
    CheckMsg -->|No| CheckEvent{Events in Queue?}
    
    ProcessMsg --> Init
    
    CheckEvent -->|Yes| GetEvent[Get Next Event]
    CheckEvent -->|No| Sleep[Sleep 10ms]
    
    GetEvent --> CalcDelay{Now < expires?}
    CalcDelay -->|Yes| Wait[Sleep until expires]
    CalcDelay -->|No| Resume[Resume Frame]
    
    Wait --> Resume
    Resume --> Init
    Sleep --> Init
    
    Init -->|Yes| Cleanup[Cleanup & Shutdown]
    Cleanup --> End([End])
```

### Async/Await Pattern

```mermaid
graph TB
    subgraph "Function A"
        A1[Line 1]
        A2[waitForTime100]
        A3[Line 3]
    end
    
    subgraph "Event Loop"
        EL1[Schedule Event]
        EL2[Suspend Frame]
        EL3[...other work...]
        EL4[Resume after 100ms]
    end
    
    A2 --> EL1
    EL1 --> EL2
    EL2 --> EL3
    EL3 --> EL4
    EL4 --> A3
```

## Thread Safety

### Mutex Protection

```mermaid
graph TB
    subgraph "Thread 1"
        T1[Add Message]
        T1 --> M1[Lock message_mutex]
        M1 --> Q1[Enqueue]
        Q1 --> U1[Unlock]
    end
    
    subgraph "Thread 2"
        T2[Process Messages]
        T2 --> M2[Lock message_mutex]
        M2 --> Q2[Dequeue]
        Q2 --> U2[Unlock]
    end
    
    M1 -->|Blocked| M2
    M2 -->|Blocked| M1
```

### Atomic Operations

- **Shutdown Flag**: Uses `std.atomic.Value(bool)` for lock-free shutdown signaling
- **Active Chat Tracking**: Protected by mutex to prevent race conditions
- **Cron Job Updates**: Protected by mutex during modifications

## Performance Characteristics

### Time Complexity

| Operation | Complexity | Description |
|----------|------------|-------------|
| Add Event | O(log n) | Priority queue insertion |
| Pop Event | O(log n) | Priority queue removal |
| Add Message | O(1) | ArrayList append |
| Process Message | O(1) | ArrayList remove first |
| Cron Lookup | O(1) | HashMap lookup |

### Memory Usage

```mermaid
pie title Memory Allocation Breakdown
    "Event Queue" : 25
    "Message Queue" : 20
    "Cron Jobs" : 30
    "Active Chats" : 10
    "Agent Sessions" : 15
```

## Usage Examples

### Basic Setup

```zig
var event_loop = try AsyncEventLoop.init(allocator, config);
defer event_loop.deinit();

// Add a recurring cron job
try event_loop.addCronJob(
    "daily_report",
    "Daily Report",
    "Generate analytics",
    .{ .kind = .every, .every_ms = 24 * 60 * 60 * 1000 }
);

// Process messages
try event_loop.addChatMessage(123456, "Hello, bot!");

// Run the loop
try event_loop.run();
```

### Advanced Configuration

```zig
// Multiple cron jobs with different schedules
try event_loop.addCronJob(
    "hourly_health",
    "Health Check",
    "Check system status",
    .{ .kind = .every, .every_ms = 60 * 60 * 1000 }
);

try event_loop.addCronJob(
    "friday_report",
    "Weekly Report",
    "Generate Friday report",
    .{ 
        .kind = .at,
        .at_ms = calculateNextFriday()
    }
);

// Simulate high message load
for (0..1000) |i| {
    const chat_id = @as(i64, @intCast(i % 100));
    const message = try std.fmt.allocPrint(allocator, "Message {}", .{i});
    try event_loop.addChatMessage(chat_id, message);
}
```

## Integration Points

### Gateway Integration

```mermaid
graph LR
    subgraph "Platforms"
        TG[Telegram]
        DC[Discord]
        WA[WhatsApp]
    end
    
    subgraph "Gateway Layer"
        TG_G[Telegram Handler]
        DC_G[Discord Handler]
        WA_G[WhatsApp Handler]
    end
    
    subgraph "Event Loop"
        EL[AsyncEventLoop]
        AGENT[Agent Pool]
    end
    
    TG --> TG_G
    DC --> DC_G
    WA --> WA_G
    
    TG_G --> EL
    DC_G --> EL
    WA_G --> EL
    
    EL --> AGENT
```

### Provider Integration

The event loop is provider-agnostic and works with:

- **Anthropic**: Claude models
- **OpenRouter**: Multiple model access
- **Groq**: Fast inference & transcription
- **Custom Providers**: Extensible architecture

## Monitoring & Debugging

### Event Loop Metrics

```zig
// Track performance
const metrics = struct {
    var messages_processed: u64 = 0;
    var cron_jobs_run: u64 = 0;
    var avg_event_latency: u64 = 0;
    var queue_depth: u64 = 0;
};
```

### Debug Logging

```mermaid
sequenceDiagram
    participant EL as EventLoop
    participant Log as Debug Log
    participant User as Developer
    
    EL->>Log: [EventLoop] Started
    EL->>Log: [Chat 123] Processing: "Hello"
    EL->>Log: [Cron daily] Running job
    EL->>Log: [Chat 123] Response: "Hi there!"
    EL->>Log: [EventLoop] Shutdown requested
    
    User->>Log: grep "Chat 123" debug.log
    Log->>User: Show chat history
```

## Best Practices

### 1. Error Handling

- Always handle errors in async functions
- Use `catch` blocks in void functions
- Log errors for debugging

### 2. Resource Management

- Free allocated strings promptly
- Use `defer` for cleanup
- Monitor queue depths

### 3. Performance Tips

- Batch similar operations
- Avoid long-running tasks in event loop
- Use separate threads for I/O-bound operations

### 4. Scaling Considerations

- Consider multiple event loop instances
- Implement load balancing
- Use persistent queues for reliability

## Troubleshooting

### Common Issues

1. **Memory Leaks**

   - Check for unfreed strings
   - Verify cron job cleanup
   - Monitor agent session cleanup

2. **Deadlocks**

   - Ensure mutex unlock order
   - Avoid nested locks
   - Use timeout mechanisms

3. **Performance Issues**

   - Profile event latency
   - Check queue depths
   - Optimize cron job frequency

## Future Enhancements

### Planned Features

1. **Persistent Event Storage**
   - Survive restarts
   - Event replay capability
   - Disaster recovery

2. **Distributed Event Loop**
   - Multiple instances
   - Event broadcasting
   - Load distribution

3. **Advanced Scheduling**
   - Cron expression support
   - Timezone awareness
   - Dependency chains

4. **Metrics & Monitoring**
   - Built-in metrics collection
   - Prometheus integration
   - Performance dashboards

## Conclusion

The Async Event Loop provides a robust foundation for high-concurrency operations in SatiBot. Its async/await-based design ensures efficient resource utilization while maintaining clean, readable code. The priority queue system guarantees timely execution of scheduled tasks, while the message queue enables immediate processing of incoming requests.

This architecture scales effectively from a single chat to thousands of concurrent conversations, making it suitable for both development and production deployments.
