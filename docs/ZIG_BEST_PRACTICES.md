# Zig Best Practices

This document consolidates best practices for Zig programming, covering code style, memory management, error handling, and common patterns.

## Table of Contents

1. [Code Style and Structure](#code-style-and-structure)
2. [Memory Management](#memory-management)
3. [Error Handling](#error-handling)
4. [Common Patterns](#common-patterns)
5. [Async and Event Loop Patterns](#async-and-event-loop-patterns)
6. [Testing Guidelines](#testing-guidelines)
7. [Safety Conventions](#safety-conventions)
8. [Development Tools](#development-tools)

## Code Style and Structure

### Naming Conventions

- `camelCase` for functions and methods
- `snake_case` for variables and parameters  
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

### File Structure

Organize files in this order:

1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports ordered: `std` -> `builtin` -> project modules
4. `const log = std.log.scoped(.module_name);`

```zig
//! Module description explaining purpose and usage

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const project_module = @import("project_module.zig");

const log = std.log.scoped(.module_name);
```

### Function Organization

Order methods as:

1. `init` functions
2. `deinit` functions  
3. Public API
4. Private helpers

### Struct Initialization

Prefer explicit type annotation with anonymous literals:

```zig
// ✅ Good
const foo: Type = .{ .field = value };

// ❌ Avoid
const foo = Type{ .field = value };
```

### Documentation

- Use `///` for public API documentation
- Use `//` for implementation notes
- Always explain *why*, not just *what*

```zig
/// Calculates the factorial of n using iterative approach.
/// Returns error.Overflow if the result exceeds u64 bounds.
pub fn factorial(n: u32) !u64 {
    // Implementation uses iterative approach to avoid stack overflow
    // that would occur with recursive implementation for large n
    var result: u64 = 1;
    for (1..n + 1) |i| {
        result = try std.math.mul(u64, result, @as(u64, i));
    }
    return result;
}
```

## Memory Management

### Core Principles

1. Never store pointers to stack-local variables in structs that outlive the function
2. Ensure handler contexts have valid pointer references for async operations
3. Always verify pointer lifetime when passing to threads or callbacks
4. Free owned fields before deiniting containers

### Container Patterns (Zig 0.15.2+)

Prefer `std.ArrayListUnmanaged(T)` over `std.ArrayList(T)`:

```zig
// ✅ Correct
var list: std.ArrayListUnmanaged(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

// ❌ Wrong - causes compilation errors
var list = std.ArrayList(u32).init(allocator); // Error: no member named 'init'
```

### HashMap Patterns

```zig
// Unmanaged (preferred for consistency)
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);

// Managed (acceptable)
var map: std.StringHashMap(u32) = std.StringHashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", 42);
```

### Context Pattern Best Practices

When creating context objects for async/callback patterns:

```zig
// ✅ GOOD - Context owns resources
pub const Context = struct {
    allocator: std.mem.Allocator,
    client: HttpClient, // Owned, not a pointer
    
    pub fn init(allocator: std.mem.Allocator) !Context {
        return Context{
            .allocator = allocator,
            .client = try HttpClient.init(allocator),
        };
    }
};

// ✅ GOOD - Context points to owner's fields
pub const Context = struct {
    owner: *OwnerStruct,
    
    pub fn init(owner: *OwnerStruct) Context {
        return Context{ .owner = owner };
    }
};
```

### Freeing Owned Fields

When a struct has a `deinit` method, always iterate over remaining items and free heap-allocated fields **before** calling `container.deinit()`:

```zig
pub fn deinit(self: *Self) void {
    // Free owned fields first
    for (self.message_queue.items) |msg| {
        self.allocator.free(msg.text);
        self.allocator.free(msg.session_id);
    }
    // Then deinit the container
    self.message_queue.deinit(self.allocator);
}
```

## Error Handling

### Never Use `catch unreachable` for Recoverable Errors

Only use `catch unreachable` for truly impossible conditions:

```zig
// ❌ WRONG - initCapacity can fail!
.task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch unreachable,

// ✅ CORRECT - Handle the error
.task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch return error.OutOfMemory,

// ✅ ALSO CORRECT - Use try if in a function that can return errors
.task_queue = try std.ArrayList(Task).initCapacity(allocator, 0),
```

### Acceptable Uses of `catch unreachable`

```zig
// ✅ ACCEPTABLE - Timer should never fail on supported platforms
timer = std.time.Timer.start() catch unreachable;

// ✅ ACCEPTABLE - Math operations that shouldn't overflow in known contexts
const result = a * b catch unreachable; // If we've proven a and b are small enough
```

### Memory Allocation Error Handling

Always handle allocation failures:

```zig
// ❌ WRONG
const items = allocator.alloc(Item, count) catch unreachable;

// ✅ CORRECT
const items = allocator.alloc(Item, count) catch {
    std.debug.print("Failed to allocate {d} items\n", .{count});
    return error.OutOfMemory;
};

// ✅ ALSO CORRECT - Propagate the error
const items = try allocator.alloc(Item, count);
```

### Error Logging

Always log errors when catching them:

```zig
result = dangerous_operation() catch |err| {
    log.err("Operation failed: {}", .{err});
    return err;
};
```

## Common Patterns

### I/O Patterns

Use buffered writers for performance:

```zig
// stdout/stderr Writer
var buf: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buf);
defer writer.flush() catch {};
try writer.print("hello {s}\n", .{"world"});

// Allocating writer (dynamic buffer)
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = writer.toOwnedSlice();  // Get result
```

### JSON Writing

```zig
// Use std.json.Stringify with a buffered writer
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);  // Serialize any struct/value directly
```

### Debug Print Optimization

Combine multiple print statements into single multiline strings:

```zig
// ✅ GOOD - Single multiline string
fn usage() !void {
    const help_text =
        \\🐸 satibot - AI Chatbot Framework
        \\
        \\USAGE:
        \\  satibot <command> [options] [args...]
        \\  satibot help <command>    Show detailed help for a command
        \\
        \\COMMANDS:
        \\  help          Show this help message
        \\  agent         Run AI agent in interactive or single message mode
        \\  console       Run console-based interactive bot
        \\
        \\For more information, visit: https://github.com/satibot/satibot
    ;

    std.debug.print("{s}\n", .{help_text});
}

// ❌ AVOID - Multiple print calls
fn usage() !void {
    std.debug.print("🐸 satibot - AI Chatbot Framework\n\n", .{});
    std.debug.print("USAGE:\n", .{});
    // ... many more calls
}
```

### Build System Patterns

```zig
// build.zig executable/test
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Pre-calculated Constants

Replace arithmetic expressions with pre-calculated constants in memory allocations:

```zig
// ✅ GOOD - Pre-calculated with comment
const buffer_size = 1048576; // 1024 * 1024
var buffer = try allocator.alloc(u8, buffer_size);

// ❌ AVOID - Runtime calculation
var buffer = try allocator.alloc(u8, 1024 * 1024);
```

## Async and Event Loop Patterns

### Handler Context Management

Ensure handler contexts maintain valid pointer references:

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

### Task Data Ownership

Task data must be owned by the event loop or explicitly transferred:

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
```

### Thread-Safe Context Access

Context accessed from multiple threads must be thread-safe:

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

## Testing Guidelines

### Test Organization

- Write tests inline in the same file as the code
- Register tests in src/main.zig test block
- Test both happy path and error paths

### Testing Error Paths

Use failing allocators to test error handling:

```zig
test "handles allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 }, // Fail first allocation
    );
    
    const result = MyStruct.init(failing_allocator.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}
```

### Testing Concurrent Patterns

Test with realistic concurrency:

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

### Use Sanitizers

Enable sanitizers for catching memory issues:

```bash
zig build test -fsanitize=thread
```

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

### Assertions

Add assertions that catch real bugs, not trivially true statements:

- **Good**: bounds checks, null checks before dereference, state machine transitions
- **Avoid**: asserting something immediately after setting it, checking internal function arguments

### Function Size

- Soft limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions  
- Push pure computation to helper functions

### Comments

Explain *why* the code exists, not *what* it does. Document non-obvious thresholds, timing values, protocol details.

## Development Tools

### Using zigdoc

Always use `zigdoc` to discover APIs for the Zig standard library and third-party dependencies:

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

### Debug Allocator

Use Zig's debug allocator during development:

- The pattern `0xaaaaaaaaaaaaaaaa` indicates freed memory access
- Enable with: `zig build-exe myprog.zig --debug`

### Common Memory Corruption Patterns

- `0xaaaaaaaaaaaaaaaa` = Accessing freed memory
- `0xdeadbeefdeadbeef` = Uninitialized memory
- Segfault on allocation = Heap corruption

## Code Review Checklist

### Memory Management

- [ ] No pointers to stack variables in returned structs
- [ ] Context objects have clear ownership
- [ ] Thread-shared data has proper lifetime
- [ ] Initialization order respects dependencies
- [ ] Callbacks capture valid context
- [ ] Memory is freed in matching deinit patterns
- [ ] Preferred `std.ArrayListUnmanaged(T)` over managed `ArrayList`

### Error Handling

- [ ] No `catch unreachable` for operations that can fail
- [ ] Memory allocations are properly handled
- [ ] Container initialization with error handling
- [ ] Error paths are tested
- [ ] Errors are logged when caught

### Code Style

- [ ] Naming conventions followed
- [ ] File structure organized correctly
- [ ] Functions ordered properly
- [ ] Documentation explains why, not just what
- [ ] Comments added for complex logic

### Safety

- [ ] Assertions catch real bugs
- [ ] Functions under 70 lines where possible
- [ ] Thread safety considered for shared data
- [ ] Pointer lifetimes verified

## Functional Programming Preference

Avoid Object-Oriented Programming (OOP) patterns where state is hidden within objects. Instead:

- **Favor Pure Functions**: Use functions that take data as input and return new or modified data as output
- **Avoid "Instances"**: Minimize the use of long-lived stateful objects. Only use "init" patterns for resource management
- **Separate Data and Logic**: Keep data structures simple and process them with external, stateless functions
- **Separate IO from Logic**: Isolate Input/Output operations from core logic. Core logic should be pure and testable
- **Stateless Handlers**: Design task and event handlers to be stateless transformations of input data

## Additional Resources

- [Zig Documentation](https://ziglang.org/documentation/)
- [Zig Standard Library](https://ziglang.org/documentation/master/std/)
- [TigerStyle Guide](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Zig Community](https://github.com/ziglang/zig/wiki/Community)
