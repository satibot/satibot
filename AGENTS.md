# AGENTS.md

## Task Workflow

### Validate After Every Code Change

After each code change, always run these commands to confirm the project still passes build and lint checks:

```bash
zig build test
ziglint
```

Do not skip these checks.

### Log Your Work

Whenever you finish a task or change codes, always log your work using the l-log bash command:

```bash
l-log add ./logs/chat.csv "<Task Name>" --tags="<tags>" --problem="<problem>" --solution="<solution>" --action="<action>" --files="<files>" --tech-stack="<tech>" --created-by-agent="<agent-name>"
```

Note: `--last-commit-short-sha` is optional and will be auto-populated by the CLI if not provided.

**Before run:**

- Install the l-log CLI if not already installed: `bun add -g llm-lean-log-cli`
- If need, run CLI help command: `l-log -h` for more information
- Log path: `./logs/chat.csv`

### Write Comments

Write comments in the code to explain why the code needs to do that.
Check if you need to update docs, README.md, etc.

### When Catch Error

When catching an error, always log the error message.

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library and any third-party dependencies.

Examples:

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Common Zig Patterns

These patterns reflect current Zig APIs and may differ from older documentation.

**ArrayList:**

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (unmanaged):**

```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**HashMap/StringHashMap (managed):**

```zig
var map: std.StringHashMap(u32) = std.StringHashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", 42);
```

**stdout/stderr Writer:**

```zig
var buf: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buf);
defer writer.flush() catch {};
try writer.print("hello {s}\n", .{"world"});
```

**build.zig executable/test:**

```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**

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

**Allocating writer (dynamic buffer):**

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = writer.toOwnedSlice();  // Get result
```

## Memory Management

### Free Owned Fields Before Deiniting Containers

When a struct has a `deinit` method that destroys a container (ArrayList, HashMap, etc.), always iterate over remaining items and free any heap-allocated fields **before** calling `container.deinit()`.

**Why:** If items are added to a queue with `allocator.dupe()` / `allocPrint()` and consumed elsewhere (e.g. an event loop pops and frees them), items that are still in the container at shutdown will leak because `deinit()` only releases the container's backing memory, not the contents.

**Rule:** For every container that holds structs with owned allocations:

1. In `deinit`, loop over all remaining items and free each owned field.
2. Then call `container.deinit()`.

```zig
// Example: free owned fields before deiniting the queue
for (self.message_queue.items) |msg| {
    self.allocator.free(msg.text);
    self.allocator.free(msg.session_id);
}
self.message_queue.deinit(self.allocator);
```

### Memory Safety Principles

- Never store pointers to stack-local variables in structs that outlive the function
- Ensure handler contexts have valid pointer references for async operations
- Always verify pointer lifetime when passing to threads or callbacks
- Never use `catch unreachable` for operations that can fail
- Replace arithmetic expressions with pre-calculated constants in memory allocations (e.g., use `1048576` instead of `1024 * 1024`)

## Prefer Functional Programming over OOP

Avoid Object-Oriented Programming (OOP) patterns where state is hidden within objects. Instead:

- **Favor Pure Functions**: Use functions that take data as input and return new or modified data as output.
- **Avoid "Instances"**: Minimize the use of long-lived stateful objects. Only use "init" patterns for resource management (e.g., allocators, network connections).
- **Separate Data and Logic**: Keep data structures simple and process them with external, stateless functions.
- **Separate IO from Logic**: Isolate Input/Output operations (network, disk) from core logic. Core logic should be pure and testable without mocks.
- **Stateless Handlers**: Design task and event handlers to be stateless transformations of input data.

## Optimize Debug Print Statements

When writing help text, usage information, or multi-line output, prefer using a single string literal with multiline syntax over multiple `std.debug.print` calls.

**Good:**

```zig
fn usage() !void {
    const help_text =
        \\🐸 sati - AI Chatbot Framework
        \\
        \\USAGE:
        \\  sati <command> [options> [args...]
        \\
        \\For more information, visit: https://github.com/satibot/satibot
    ;

    std.debug.print("{s}\n", .{help_text});
}
```

**Avoid:**

```zig
fn usage() !void {
    std.debug.print("🐸 sati - AI Chatbot Framework\n\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("  sati <command> [options> [args...]\n", .{});
    // ... more calls
}

## Zig Code Style

**Naming:**

- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:

```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**

1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/main.zig test block

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**

- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Function size:**

- Soft limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**

- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details
