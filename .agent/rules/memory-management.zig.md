# Memory Management Rules for Zig

## 1. Pointer Lifetime Management

### Rule: Never store pointers to stack-local variables in structs that outlive the function

- **Problem**: Use-after-free when accessing freed stack memory
- **Solution**: Ensure pointers point to memory with equal or longer lifetime than the struct

```zig
// ❌ WRONG - pointer to stack variable
pub fn init(allocator: std.mem.Allocator) !MyStruct {
    var client = HttpClient.init(allocator);
    return MyStruct {
        .client_ptr = &client, // client lives on stack!
    };
}

// ✅ CORRECT - pointer to struct field
pub fn init(allocator: std.mem.Allocator) !MyStruct {
    var client = HttpClient.init(allocator);
    var result = MyStruct {
        .client = client,
        .client_ptr = undefined,
    };
    result.client_ptr = &result.client; // Points to struct field
    return result;
}
```

## 2. Context Pattern Best Practices

### Rule: When creating context objects for async/callback patterns, ensure proper ownership

- Context should either:
  - Own its resources directly
  - Store pointers to fields in the owning struct
  - Use arena allocators for tied lifetime

```zig
// ✅ GOOD - Context owns resources
pub const Context = struct {
    allocator: std.mem.Allocator,
    client: HttpClient, // Owned, not a pointer
    
    pub fn init(allocator: std.mem.Allocator) !Context {
        return Context {
            .allocator = allocator,
            .client = try HttpClient.init(allocator),
        };
    }
};

// ✅ GOOD - Context points to owner's fields
pub const Context = struct {
    owner: *OwnerStruct,
    
    pub fn init(owner: *OwnerStruct) Context {
        return Context { .owner = owner };
    }
};
```

## 3. Async/Thread Safety Rules

### Rule: Verify pointer validity before passing to threads

- Any pointer accessed from another thread must outlive the thread
- Use atomic references or ownership transfer patterns

```zig
// ❌ DANGEROUS - Stack data in thread
pub fn spawnWorker() !void {
    var data = Data{ .value = 42 };
    _ = try std.Thread.spawn(.{}, worker, .{&data}); // data on stack!
}

// ✅ SAFE - Heap-allocated or owned data
pub fn spawnWorker(allocator: std.mem.Allocator) !void {
    const data = try allocator.create(Data);
    data.* = .{ .value = 42 };
    _ = try std.Thread.spawn(.{}, worker, .{data});
}

fn worker(data: *Data) void {
    // Process data...
    // Remember to free when done!
}
```

## 4. Initialization Order

### Rule: Initialize structs in dependency order

- Create the full struct first
- Then set up pointers between fields
- This prevents dangling pointers to temporaries

```zig
// ✅ CORRECT initialization order
pub fn init(allocator: std.mem.Allocator) !ComplexStruct {
    var result = ComplexStruct {
        .field1 = try Field1.init(),
        .field2 = undefined,
        .context = undefined,
    };
    
    // Now set up pointers after struct exists
    result.field2 = try Field2.init(&result.field1);
    result.context = Context.init(&result.field1, &result.field2);
    
    return result;
}
```

## 5. Debugging Memory Issues

### Rule: Use Zig's debug allocator during development

- The pattern `0xaaaaaaaaaaaaaaaa` indicates freed memory access
- Enable with: `zig build-exe myprog.zig --debug`

### Common memory corruption patterns

- `0xaaaaaaaaaaaaaaaa` = Accessing freed memory
- `0xdeadbeefdeadbeef` = Uninitialized memory
- Segfault on allocation = Heap corruption

## 6. Callback and Handler Patterns

### Rule: Capture context correctly in callbacks

- Use captured values, not pointers to temporaries
- Consider using indices or IDs instead of pointers when possible

```zig
// ❌ WRONG - Capturing stack pointer
fn setupHandlers() void {
    var config = Config{ .value = 42 };
    setHandler(&config); // config dies when function returns!
}

// ✅ CORRECT - Capture by value or use owned memory
fn setupHandlers(allocator: std.mem.Allocator) !void {
    const config = try allocator.create(Config);
    config.* = .{ .value = 42 };
    setHandler(config);
}
```

## 7. Testing Guidelines

### Rule: Test with actual workloads

- Unit tests might not catch thread-safety issues
- Test with concurrent access patterns
- Use sanitizers: `zig build test -fsanitize=thread`

## 8. Code Review Checklist

Before approving code that manages pointers:

- [ ] No pointers to stack variables in returned structs
- [ ] Context objects have clear ownership
- [ ] Thread-shared data has proper lifetime
- [ ] Initialization order respects dependencies
- [ ] Callbacks capture valid context
- [ ] Memory is freed in matching deinit patterns
