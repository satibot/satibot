# Error Handling Rules for Zig

## 1. Never Use `catch unreachable` for Recoverable Errors

### Rule: Avoid `catch unreachable` except for truly impossible conditions
- **Problem**: Using `catch unreachable` for operations that can fail causes panics
- **Solution**: Always handle errors properly or propagate them

```zig
// ❌ WRONG - initCapacity can fail!
.task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch unreachable,

// ✅ CORRECT - Handle the error
.task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch return error.OutOfMemory,

// ✅ ALSO CORRECT - Use try if in a function that can return errors
.task_queue = try std.ArrayList(Task).initCapacity(allocator, 0),
```

## 2. When is `catch unreachable` Acceptable?

Only use `catch unreachable` for conditions that should truly be impossible:

```zig
// ✅ ACCEPTABLE - Timer should never fail on supported platforms
timer = std.time.Timer.start() catch unreachable;

// ✅ ACCEPTABLE - Math operations that shouldn't overflow in known contexts
const result = a * b catch unreachable; // If we've proven a and b are small enough

// ❌ NOT ACCEPTABLE - Memory allocations
const memory = allocator.alloc(u8, size) catch unreachable; // Can fail!
```

## 3. Memory Allocation Patterns

### Rule: Always handle allocation failures
Even with ample memory, allocations can fail due to fragmentation or limits.

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

## 4. Container Initialization

### Rule: Initialize containers with proper error handling

```zig
// ❌ WRONG - ArrayList initCapacity can fail
pub const MyStruct = struct {
    list: std.ArrayList(Item),
    
    pub fn init(allocator: std.mem.Allocator) MyStruct {
        return .{
            .list = std.ArrayList(Item).initCapacity(allocator, 10) catch unreachable,
        };
    }
};

// ✅ CORRECT - Handle the error
pub const MyStruct = struct {
    list: std.ArrayList(Item),
    
    pub fn init(allocator: std.mem.Allocator) !MyStruct {
        return .{
            .list = std.ArrayList(Item).initCapacity(allocator, 10) catch return error.OutOfMemory,
        };
    }
};

// ✅ ALSO CORRECT - Use init() and let it grow as needed
pub const MyStruct = struct {
    list: std.ArrayList(Item),
    
    pub fn init(allocator: std.mem.Allocator) MyStruct {
        return .{
            .list = std.ArrayList(Item).init(allocator),
        };
    }
};
```

## 5. Error Propagation Best Practices

### Rule: Make functions fallible when they can fail

```zig
// ❌ WRONG - Hiding errors with unreachable
pub fn createManager(allocator: std.mem.Allocator) Manager {
    return Manager{
        .workers = std.ArrayList(Worker).initCapacity(allocator, 10) catch unreachable,
    };
}

// ✅ CORRECT - Propagate errors
pub fn createManager(allocator: std.mem.Allocator) !Manager {
    return Manager{
        .workers = try std.ArrayList(Worker).initCapacity(allocator, 10),
    };
}
```

## 6. Debugging vs Production Code

### Rule: Use assertions for debugging, error handling for production

```zig
// ✅ GOOD - Use debug assertions for impossible conditions
std.debug.assert(condition_that_should_always_be_true);

// ❌ WRONG - Use unreachable for conditions that might occur
result = dangerous_operation() catch unreachable;

// ✅ CORRECT - Handle potential failures
result = dangerous_operation() catch {
    // Log the error and handle gracefully
    return error.OperationFailed;
};
```

## 7. Common Operations That Can Fail

Be careful with these common operations:
- Memory allocations (`alloc`, `allocAligned`, `create`, `dupe`)
- Container initialization with capacity (`initCapacity`)
- File I/O operations
- Network operations
- Thread spawning
- System calls

## 8. Code Review Checklist

Before approving code with `catch unreachable`:
- [ ] Is this condition truly impossible?
- [ ] Could it fail under memory pressure?
- [ ] Could it fail on different platforms?
- [ ] Is there a better way to handle this error?
- [ ] Should the function be made fallible instead?

## 9. Testing Error Paths

### Rule: Test error handling paths
Don't just test the happy path - ensure errors are handled correctly:

```zig
test "handles allocation failure" {
    // Use a failing allocator to test error paths
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 }, // Fail first allocation
    );
    
    const result = MyStruct.init(failing_allocator.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}
```

## 10. Alternatives to `catch unreachable`

Instead of `catch unreachable`, consider:
- Return an error
- Use a default value
- Log and continue
- Panic with a helpful message
- Use an optional type

```zig
// Instead of this:
value = risky_operation() catch unreachable;

// Use one of these:
value = risky_operation() catch |err| {
    std.log.err("Operation failed: {}", .{err});
    return err;
};

value = risky_operation() catch default_value;

value = risky_operation() catch null;

value = risky_operation() catch {
    std.debug.panic("This should never happen: context", .{});
};
```
