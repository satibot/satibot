# Functional Design Guide

## Overview

satibot uses a pure functional approach for message processing, moving away from traditional Object-Oriented Programming (OOP) patterns. This design choice was made to improve predictability, testability, and memory efficiency.

## Core Principles

### 1. Pure Functions

All message processing is done through pure functions that:

- Take input data (messages, config, session_id)
- Return output data (response, updated history)
- Have no side effects
- Always return the same output for the same input

```zig
// Pure function - no state mutation
pub fn processMessage(
    allocator: std.mem.Allocator,
    config: Config,
    session_id: []const u8,
    user_message: []const u8,
) !struct { 
    history: SessionHistory, 
    response: ?[]const u8, 
    error_msg: ?[]const u8 
} {
    // Pure processing logic
}
```

### 2. Immutable Data Structures

Session history is treated as immutable:

- New messages create new history structures
- Old history is never modified in place
- Memory is managed explicitly with clear ownership

### 3. Separation of Data and Logic

- **Data**: Message structures, session history, configuration
- **Logic**: Pure functions that transform data
- **IO**: Isolated at the edges (HTTP, file system)

## Session Cache

### Purpose

The session cache provides performance optimization while maintaining functional purity:

- Holds session history in memory for fast access
- Automatically cleans up inactive sessions
- Prevents repeated disk I/O for active conversations

### Implementation

```zig
const SessionCache = struct {
    sessions: std.StringHashMap(SessionHistory),
    last_used: std.StringHashMap(i64),
    max_idle_time_ms: u64 = 30 * 60 * 1000, // 30 minutes
    
    pub fn getOrCreateSession(self: *SessionCache, session_id: []const u8) !*SessionHistory {
        // Returns existing or creates new session
        // Updates last_used timestamp
    }
    
    pub fn cleanup(self: *SessionCache) void {
        // Removes sessions idle beyond max_idle_time_ms
        // Scheduled to run every 30 minutes
    }
};
```

### Lifecycle

1. **Creation**: New session created when first message arrives
2. **Access**: Retrieved from cache for subsequent messages
3. **Update**: Last used timestamp updated on each access
4. **Cleanup**: Removed after 30 minutes of inactivity
5. **Persistence**: Saved to disk before cleanup

## Benefits

### 1. Predictable Behavior

- No hidden state mutations
- Easy to reason about code flow
- Consistent behavior across runs

### 2. Memory Safety

- Explicit memory management
- No use-after-free bugs
- Automatic cleanup prevents leaks

### 3. Testability

- Pure functions are easy to unit test
- No need for complex mocks or fixtures
- Deterministic test results

### 4. Performance

- Session cache reduces disk I/O
- No agent object creation overhead
- Efficient memory usage with cleanup

## Migration from OOP

### Before (OOP Approach)

```zig
// Agent object with mutable state
const Agent = struct {
    ctx: Context,
    registry: ToolRegistry,
    session_id: []const u8,
    
    pub fn run(self: *Agent, message: []const u8) !void {
        // Mutates internal state
    }
};

// Agent pool manages object lifecycle
const AgentPool = struct {
    agents: std.StringHashMap(AgentPoolEntry),
    // ...
};
```

### After (Functional Approach)

```zig
// Pure data structures
pub const Message = struct {
    role: []const u8,
    content: ?[]const u8,
    // ...
};

pub const SessionHistory = struct {
    messages: std.ArrayList(Message),
    // ...
};

// Pure function transforms data
pub fn processMessage(...) !struct {...} {
    // No mutation, returns new state
}
```

## Best Practices

### 1. Keep Functions Pure

- Avoid global variables
- Don't modify input parameters
- Return new data instead of mutating

### 2. Manage Memory Explicitly

- Always free allocated memory
- Use `defer` for cleanup
- Follow ownership rules

### 3. Isolate Side Effects

- Keep IO at the edges
- Use pure functions for business logic
- Document any impure functions

### 4. Use the Session Cache Wisely

- Don't rely on it for persistence
- Assume sessions can disappear
- Save important data to disk

## Example: Processing a Message

```zig
// 1. Load session history (pure data)
var history = loadSessionHistory(allocator, session_id) catch SessionHistory.init(allocator);
defer history.deinit();

// 2. Process message (pure function)
const result = processMessage(allocator, config, session_id, user_message) catch {
    // Handle error
};

// 3. Save updated history (side effect)
saveSessionHistory(&result.history, session_id) catch {};

// 4. Send response (side effect)
if (result.response) |response| {
    sendMessage(response);
}
```

## Conclusion

The functional approach provides:

- **Simplicity**: Easier to understand and maintain
- **Reliability**: Fewer bugs from state mutations
- **Performance**: Efficient memory usage with caching
- **Flexibility**: Easy to test and modify

This design aligns with Zig's philosophy of explicit memory management and clear ownership, making the codebase more robust and maintainable.
