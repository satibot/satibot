---
name: zig-compilation-errors
description: Rules to prevent common Zig compilation errors and ensure clean builds
---

# Zig Compilation Error Prevention Rules

## 1. Type Casting Rules

### @intCast Usage

- **DO**: Always use `@as` with explicit type when using `@intCast`
- **DON'T**: Use `@intCast` alone without specifying the result type

```zig
// WRONG - Causes compilation error
const value = @intCast(some_expression);

// CORRECT - Explicit type provided
const value = @as(u64, @intCast(some_expression));
```

**Why**: Zig 0.15.0 requires explicit type information for `@intCast` to ensure type safety.

### Type Casting for Time Values

- **DO**: Use explicit cast for time values
- **DON'T**: Rely on implicit casting for time values

```zig
// WRONG - i128 cannot be cast to i64 implicitly
.timestamp = std.time.nanoTimestamp(),

// CORRECT - Explicit cast
.timestamp = @intCast(u64, std.time.nanoTimestamp()),
```

### Common Type Cast Patterns

```zig
// Integer to integer
const u32_value = @as(u32, @intCast(i64_value));

// Float to integer
const int_value = @as(i32, @intCast(float_value));

// Size calculations
const size_bytes = @as(usize, @intCast(count * item_size));
```

## 2. Unused Parameter Handling

### Function Parameters

- **DO**: Use underscore prefix (`_`) for unused parameters
- **DON'T**: Leave parameters unused without marking

```zig
// ❌ WRONG - Compilation error
fn handleData(allocator: std.mem.Allocator, data: []const u8) void {
    // allocator is unused - error!
    std.debug.print("{s}\n", .{data});
}

// ✅ CORRECT - Mark unused with underscore
fn handleData(_allocator: std.mem.Allocator, data: []const u8) void {
    // _allocator is intentionally unused
    std.debug.print("{s}\n", .{data});
}

// ✅ ALSO CORRECT - Actually use the parameter
fn handleData(allocator: std.mem.Allocator, data: []const u8) void {
    const owned = allocator.dupe(u8, data);
    defer allocator.free(owned);
    std.debug.print("{s}\n", .{owned});
}
```

### Callback Function Patterns

```zig
// When implementing interfaces with unused parameters
pub const Handler = struct {
    fn callback(_ctx: *Context, _event: Event) void {
        // Both parameters unused but required by interface
    }
};
```

## 3. Memory Management Rules

### Deinit Pattern

- **DO**: Always free heap-allocated fields before calling `deinit()`
- **DON'T**: Forget to free owned allocations

```zig
pub fn deinit(self: *Container) void {
    // ✅ Free all owned allocations first
    for (self.items.items) |item| {
        self.allocator.free(item.name);
        self.allocator.free(item.data);
    }
    
    // Then deinit the container
    self.items.deinit(self.allocator);
}
```

## 4. Thread Safety Rules

### Mutex Usage

- **DO**: Always use `defer` with mutex unlock
- **DON'T**: Forget to unlock mutexes

```zig
// ✅ CORRECT - defer ensures unlock
self.mutex.lock();
defer self.mutex.unlock();

// Critical section here
```

### Condition Variables

- **DO**: Always wait with mutex locked
- **DON'T**: Wait without proper locking

```zig
// ✅ CORRECT
self.mutex.lock();
while (self.queue.items.len == 0) {
    self.condition.wait(&self.mutex);
}
self.mutex.unlock();
```

## 5. Error Handling Rules

### Error Returns

- **DO**: Handle or propagate errors with `try` or `catch`
- **DON'T**: Ignore errors

```zig
// ❌ WRONG - Error ignored
const result = someFunction();

// ✅ CORRECT - Handle error
const result = someFunction() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return;
};

// ✅ ALSO CORRECT - Propagate with try
const result = try someFunction();
```

## 6. Compilation Checklist

Before committing code, verify:

1. [ ] All `@intCast` calls use `@as` with explicit type
2. [ ] All unused parameters are prefixed with `_`
3. [ ] All mutexes are unlocked (prefer `defer`)
4. [ ] All allocations are freed before `deinit()`
5. [ ] All errors are handled or propagated
6. [ ] No unused variables or imports
7. [ ] ArrayList uses `initCapacity()` instead of `init()`
8. [ ] ArrayList `deinit()` and `append()` include allocator parameter
9. [ ] Signal handling uses `std.posix.sigemptyset()`
10. [ ] Division operations use `@divTrunc`, `@divFloor`, or `@divExact`
11. [ ] Time values are explicitly cast when needed
12. [ ] Atomic values use `.load()` and `.store()` methods
13. [ ] Structs used across modules are marked `pub`
14. [ ] External API structs include all required fields
15. [ ] Function pointers use global context pattern if needed
16. [ ] JSON API uses correct path (`std.json.Stringify.valueAlloc`)
17. [ ] Const qualifier issues handled with `@constCast` when necessary
18. [ ] Agent.run() return type handled correctly (void, not string)
19. [ ] Struct methods are properly indented inside the struct
20. [ ] Event loop integration uses separate threads for polling
21. [ ] No duplicate function names in the same scope
22. [ ] All struct methods are marked `pub` if used externally

## 7. Common Error Messages and Solutions

### "must have a known result type"

```zig
// Error: @intCast must have a known result type
// Solution: Add @as(Type, @intCast(...))
```

### "unused function parameter"

```zig
// Error: unused function parameter
// Solution: Prefix with underscore or use the parameter
```

### "type mismatch" with threads

```zig
// Error: type mismatch
// Solution: Ensure thread function signatures match exactly
```

### "has no member named 'init'"

```zig
// Error: struct 'ArrayList' has no member named 'init'
// Solution: Use initCapacity() instead
const list = std.ArrayList(T).initCapacity(allocator, 0) catch unreachable;
```

### "member function expected X argument(s), found Y"

```zig
// Error: member function expected 2 argument(s), found 1
// Solution: Pass allocator to ArrayList methods
list.append(allocator, item);
list.deinit(allocator);
```

### "has no member named 'empty_sigset'"

```zig
// Error: root source file struct 'posix' has no member named 'empty_sigset'
// Solution: Use sigemptyset() function
.mask = std.posix.sigemptyset(),
```

### "division with 'i128' and 'comptime_int'"

```zig
// Error: division with signed integers must use @divTrunc, @divFloor, or @divExact
// Solution: Use explicit division function
const result = @divTrunc(a, b);
```

### "expected type 'i64', found 'atomic.Value(i64)'"

```zig
// Error: expected type 'i64', found 'atomic.Value(i64)'
// Solution: Use .load() to read atomic values
return self.offset.load(.seq_cst);
```

### "no field named 'X' in struct"

```zig
// Error: no field named 'message_id' in struct
// Solution: Add missing required fields from external API
message: ?struct {
    message_id: i64,  // Add missing field
    chat: struct { ... },
    // ...
}
```

### "'X' is not marked 'pub'"

```zig
// Error: 'Task' is not marked 'pub'
// Solution: Make structs public for cross-module usage
pub const Task = struct { ... };
pub const Event = struct { ... };
```

### "'X' not accessible from inner function"

```zig
// Error: 'ctx' not accessible from inner function
// Solution: Function pointers cannot capture context
var global_context: ?*Context = null;

fn createHandler(ctx: *Context) Handler {
    global_context = ctx;
    return globalHandler;
}
```

### "root source file struct 'json' has no member named 'stringifyAlloc'"

```zig
// Error: root source file struct 'json' has no member named 'stringifyAlloc'
// Solution: Use correct JSON API path
std.json.Stringify.valueAlloc(allocator, value, .{});
```

### "expected type '*Type', found '*const Type'"

```zig
// Error: expected type '*http.Client', found '*const http.Client'
// Solution: Use @constCast for APIs requiring mutability
@constCast(client).post(url, headers, body);
```

### "no field or member function named 'X' in struct"

```zig
// Error: no field or member function named 'run' in 'TelegramBot'
try bot.run();

// Common causes:
// 1. Method defined outside struct (wrong indentation)
// 2. Method not marked pub (private)
// 3. Typo in method name

// Solution: Ensure proper struct indentation
pub const MyStruct = struct {
    // Methods must be indented inside the struct
    pub fn run(self: *MyStruct) !void {
        // method body
    }
};
```

### Event Loop Integration Pattern

When integrating polling with an event loop:

```zig
// WRONG: Event loop runs without polling
pub fn run(self: *Bot) !void {
    self.event_loop.run(); // Blocks forever, no polling
}

// CORRECT: Separate threads for event loop and polling
pub fn run(self: *Bot) !void {
    // Start event loop in background thread
    const event_loop_thread = try std.Thread.spawn(.{}, EventLoop.run, .{&self.event_loop});
    defer event_loop_thread.join();
    
    // Main thread handles polling
    while (!shutdown_requested.load(.seq_cst)) {
        self.tick() catch {};
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}
```

### Duplicate Function Names

```zig
// Error: duplicate struct member name 'run'
pub const MyStruct = struct {
    pub fn run(self: *MyStruct) !void { ... }
};

pub fn run(allocator: Allocator, config: Config) !void { ... } // Duplicate!

// Solution: Use different names
pub const MyStruct = struct {
    pub fn run(self: *MyStruct) !void { ... } // Instance method
};

pub fn runMyService(allocator: Allocator, config: Config) !void { ... } // Module function
```

## 9. Zig 0.15.0 API Changes

### ArrayList Initialization

- **DO**: Use `initCapacity()` instead of `init()`
- **DON'T**: Use old `init()` method

```zig
// ❌ WRONG - init() no longer exists
const list = std.ArrayList(T).init(allocator);

// ✅ CORRECT - Use initCapacity with initial capacity
const list = std.ArrayList(T).initCapacity(allocator, 0) catch unreachable;
```

### ArrayList.deinit() Requires Allocator

- **DO**: Pass allocator to `deinit()`
- **DON'T**: Call `deinit()` without parameters

```zig
// ❌ WRONG - Missing allocator parameter
list.deinit();

// ✅ CORRECT - Pass allocator
list.deinit(allocator);
```

### ArrayList.append() Requires Allocator

- **DO**: Pass allocator to `append()`
- **DON'T**: Call `append()` with only the item

```zig
// ❌ WRONG - Missing allocator parameter
list.append(item);

// ✅ CORRECT - Pass allocator
list.append(allocator, item);
```

### Signal Handling Changes

- **DO**: Use `std.posix.sigemptyset()` function
- **DON'T**: Use `std.posix.empty_sigset` constant

```zig
// ❌ WRONG - empty_sigset no longer exists
.mask = std.posix.empty_sigset,

// ✅ CORRECT - Use sigemptyset() function
.mask = std.posix.sigemptyset(),
```

### Division Operations

- **DO**: Use explicit division functions
- **DON'T**: Use `/` operator for signed integers

```zig
// ❌ WRONG - Division with signed integers requires explicit function
const result = a / b;

// ✅ CORRECT - Use appropriate division function
const result = @divTrunc(a, b);  // Truncate toward zero
const result = @divFloor(a, b);  // Round down
const result = @divExact(a, b);  // Must divide evenly
```

## 11. Migration Guide: Zig 0.14.x to 0.15.0

### Required Changes

1. **ArrayList Updates**

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

2. **Type Casting**

   ```zig
   // Old
   const value = @intCast(expression);
   
   // New
   const value = @as(Type, @intCast(expression));
   ```

3. **Signal Handling**

   ```zig
   // Old
   .mask = std.posix.empty_sigset,
   
   // New
   .mask = std.posix.sigemptyset(),
   ```

4. **Division**

   ```zig
   // Old
   const result = a / b;
   
   // New
   const result = @divTrunc(a, b);  // or @divFloor/@divExact
   ```

### Common Pitfalls

- Forgetting to pass allocator to ArrayList methods
- Using old signal handling constants
- Implicit time value casting
- Unused parameters without underscore prefix

### Testing Your Migration

1. Compile with `-Dwarn-error` to treat warnings as errors
2. Run all tests to ensure functionality
3. Check for memory leaks with valgrind if available
4. Test thread safety if using concurrent code

## 13. Advanced Error Patterns

### Atomic Operations

Atomic values require explicit load/store operations:

```zig
// Wrong: Direct access
return self.atomic_value;

// Correct: Use load()
return self.atomic_value.load(.seq_cst);

// For updates
self.atomic_value.store(new_value, .seq_cst);
self.atomic_value.fetchAdd(1, .seq_cst);
```

### Cross-Module Type Visibility

Types used across modules must be public:

```zig
// In event_loop.zig
pub const Task = struct { ... };
pub const Event = struct { ... };

// In other files
fn handler(task: event_loop.Task) void { ... }
```

### Function Pointer Context Capture

Zig function pointers cannot capture context like closures:

```zig
// This doesn't work - ctx is not accessible
fn createHandler(ctx: *Context) Handler {
    return struct {
        fn handler() void {
            use(ctx); // Error!
        }
    }.handler;
}

// Solution: Use global state
var global_ctx: ?*Context = null;
fn createHandler(ctx: *Context) Handler {
    global_ctx = ctx;
    return globalHandler;
}
```

### External API Integration

When integrating with external APIs (like Telegram):

1. **Include all required fields** - Check API documentation
2. **Match exact field names** - Case-sensitive
3. **Handle optional fields** - Use `?` for nullable fields

```zig
// Telegram message example
message: ?struct {
    message_id: i64,        // Required field
    chat: struct {          // Required nested struct
        id: i64,
    },
    text: ?[]const u8,      // Optional field
    voice: ?struct { ... } = null,  // Optional with default
}
```

### Agent Pattern Usage

The Agent pattern uses message buffers, not direct returns:

```zig
// Wrong: Expecting return value
const response = agent.run(prompt);

// Correct: Check messages after run
agent.run(prompt) catch {};
const messages = agent.ctx.get_messages();
const last_msg = messages[messages.len - 1];
if (last_msg.content) |response| {
    // Use response
}
```

## 14. Debugging Compilation Errors

### Reading Error Messages Effectively

1. **Note the error type** - "expected", "found", "unused", etc.
2. **Identify the location** - File and line number
3. **Understand the context** - What the compiler expects vs what you provided
4. **Check similar patterns** - Look at working code for examples

### Common Debugging Steps

1. **Compile frequently** - Catch errors early
2. **Use `zig build-exe`** - Quick compilation checks
3. **Enable all warnings** - `zig build -Dwarn-error`
4. **Check imports** - Ensure all modules are correctly imported

### IDE Integration

Configure your IDE for Zig:

- Syntax highlighting
- Error detection
- Auto-completion
- Build integration

## 15. Migration and Version Compatibility

### Keeping Up with Zig Changes

1. **Read release notes** - API changes are documented
2. **Update incrementally** - Don't jump multiple versions
3. **Test thoroughly** - Ensure functionality after updates
4. **Update documentation** - Keep rules current

### Version-Specific Patterns

Some patterns are version-dependent:

```zig
// Zig 0.14.x
const list = std.ArrayList(T).init(allocator);

// Zig 0.15.x
const list = std.ArrayList(T).initCapacity(allocator, 0) catch unreachable;
```

Always check your Zig version when encountering errors.

## 17. Debugging Struct Member Issues

### Common Symptoms

1. **"no field or member function named"** - Method not found
2. **"duplicate struct member name"** - Name collision
3. **Method not accessible** - Visibility issues

### Debugging Steps

1. **Check struct indentation**

   ```zig
   // Use consistent indentation (4 spaces recommended)
   pub const MyStruct = struct {
       field: Type,
       
       pub fn method(self: *MyStruct) void {
           // Must be indented at same level as fields
       }
   };
   ```

2. **Verify method signatures**

   ```zig
   // Instance method needs self parameter
   pub fn instanceMethod(self: *MyStruct) void { ... }
   
   // Static method doesn't need self
   pub fn staticMethod() void { ... }
   ```

3. **Check visibility**

   ```zig
   // Private (only accessible within same file)
   fn privateMethod(self: *MyStruct) void { ... }
   
   // Public (accessible from other files)
   pub fn publicMethod(self: *MyStruct) void { ... }
   ```

4. **Use IDE features**
   - Syntax highlighting shows struct boundaries
   - Go-to-definition reveals actual location
   - Error indicators mark structural issues

### Prevention Strategies

1. **Consistent indentation** - Use the same indent for all struct members
2. **Clear naming** - Distinguish between instance and module functions
3. **Explicit visibility** - Always mark pub if used externally
4. **Regular compilation** - Catch errors early in development

## 18. Best Practices

### Code Style

- Use explicit types for all casts
- Mark intentionally unused parameters
- Use `defer` for cleanup
- Handle all errors explicitly

### Testing

- Test with `zig build-exe` to catch compilation errors
- Use `zig fmt` for consistent formatting
- Enable all warnings: `zig build -Dwarn-error`

### Documentation

- Document why parameters are unused with comments
- Explain type cast choices when non-obvious
- Add examples for complex thread operations
