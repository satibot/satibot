# Zig 0.16 Migration Guide

This document summarizes the breaking changes encountered when migrating the Satibot codebase from Zig 0.14/0.15 to Zig 0.16, along with the fixes applied.

## Build System

### Executable Linking

| Old API | Replacement |
|---|---|
| `exe.linkLibC()` | `exe.root_module.link_libc = true` |
| `exe.linkSystemLibrary("sqlite3")` | `exe.root_module.linkSystemLibrary("sqlite3", .{})` |

## Language Changes

### Entry Points (Juicy Main)

The main function signature has changed to accept an `std.process.Init` parameter. The full `Init` provides an allocator, `io`, arena, and `environ_map`:

```zig
// Before
pub fn main() !void

// After - full Init
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena;
    const environ_map = init.environ_map;
    // ...
}

// After - Minimal variant (only args and environ)
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(allocator);
}
```

### `@Type` Builtin Replaced

`@Type` is deprecated and replaced with individual type-creating builtins:

| Old | Replacement |
|---|---|
| `@Type(.{ .int = ... })` | `@Int(.unsigned, 10)` |
| `@Type(.{ .enum_literal })` | `@EnumLiteral()` |
| `@Type(.{ .pointer = ... })` | `@Pointer(...)` |
| `@Type(.{ .array = ... })` | `@Array(...)` |
| `@Type(.{ .struct = ... })` | `@Struct(...)` |
| `@Type(.{ .tuple = ... })` | `@Tuple(...)` |
| `@Type(.{ .union = ... })` | `@Union(...)` |
| `@Type(.{ .error_set = ... })` | `@ErrorSet(...)` |

## Standard Library API Changes

### Removed APIs

| Old API | Replacement | Notes |
|---|---|---|
| `std.fs.cwd()` | `std.c.fopen` / `std.c.fread` / `std.c.fclose` | File system iteration APIs removed |
| `std.fs.openFileAbsolute()` | `std.c.fopen` + `std.c.fread` | File reading via C stdio |
| `std.fs.File.stdin()` | `std.posix.read(0, &buf)` | Standard input reading (fd 0) |
| `std.fs.makeDirAbsolute()` | `std.c.mkdir(path_z.ptr, 0o755)` | Directory creation |
| `std.process.argsAlloc()` / `argsFree()` | `init.args.toSlice(allocator)` | Entry point argument parsing |
| `std.process.getEnvVarOwned()` | `std.c.getenv()` + `std.mem.span()` | Environment variable reading |
| `std.process.Child.init(args, allocator)` | `std.process.spawn(io, .{ .argv = args })` | Process spawning requires `Io` handle |
| `child.spawnAndWait()` | `child.wait(io)` | Wait for child process |
| `Child.Term.Exited` | `Child.Term.exited` | Enum tags are lowercase |
| `std.crypto.random.bytes()` | `io.random()` or `std.Random.DefaultPrng` | Non-cryptographic random generation |
| `std.time.timestamp()` | `std.c.gettimeofday()` + `tv.sec` | Wall clock timestamps |
| `std.time.milliTimestamp()` | `std.c.gettimeofday()` + calculation | Millisecond precision timestamps |
| `std.time.nanoTimestamp()` | `std.c.gettimeofday()` + calculation | Nanosecond precision timestamps |
| `std.Thread.sleep(nanos)` | `std.c.nanosleep(&req, &rem)` | Thread sleep |
| `std.posix.nanosleep()` | `std.c.nanosleep()` | Sleep functionality (still available under `std.c`) |
| `std.posix.timespec` | `std.c.timespec` | Time specification struct (still available under `std.c`) |
| `std.posix.timeval` | `std.c.timeval` | Time value struct (still available under `std.c`) |
| `std.posix.gettimeofday()` | `std.c.gettimeofday()` | High-resolution time (still available under `std.c`) |
| `std.posix.getenv()` | `std.c.getenv()` + `std.mem.span()` | Environment variable reading |
| `std.posix.setenv()` / `unsetenv()` | `extern "c" fn setenv/unsetenv` declarations | Environment variable setting in tests |
| `std.Thread.Mutex` | `std.Io.Mutex` | Synchronization primitive |
| `std.Thread.Condition` | `std.Io.Condition` | Signaling primitive |
| `std.Thread.ResetEvent` | `std.Io.Event` | Event primitive |
| `std.Thread.WaitGroup` | `std.Io.Group` | Task grouping primitive |
| `std.Thread.Pool` | `std.Io.async` / `std.Io.Group.async` | Thread pool removed |
| `std.Thread.sleep()` | `std.Io.sleep(io, duration)` or `std.c.nanosleep` | Thread sleep |
| `std.net.Stream` | Removed - network APIs changed | HTTP/TLS stack affected |
| `std.ArrayList.writer()` | Removed - use manual buffer management | JSON serialization affected |
| `std.ArrayList(T).init(allocator)` | `var list: std.ArrayList(T) = .empty;` | Empty initialization |
| `list.deinit()` | `list.deinit(allocator)` | Deinit now requires allocator |
| `list.appendSlice(slice)` | `list.appendSlice(allocator, slice)` | Append now requires allocator |
| `list.toOwnedSlice()` | `list.toOwnedSlice(allocator)` | toOwnedSlice now requires allocator |
| `std.PriorityQueue.init()` | `.initContext()` | Priority queue creation |
| `std.PriorityQueue.add()` | `.push()` | Priority queue insertion |
| `std.PriorityQueue.remove()` | `.pop()` | Priority queue removal |
| `std.cstr.toCstr()` | `allocator.dupeZ()` | String conversion |
| `std.heap.PageAlloc` | `std.heap.DebugAllocator(.{})` | Page allocator API |
| `pub fn main() !void` | `pub fn main(init: std.process.Init.Minimal) !void` | Entry point signature |
| `std.io` namespace | `std.Io` | I/O namespace renamed (PascalCase) |
| `std.io.fixedBufferStream` (read) | `var reader: std.Io.Reader = .fixed(data);` | Fixed buffer reader |
| `std.io.fixedBufferStream` (write) | `var writer: std.Io.Writer = .fixed(buffer);` | Fixed buffer writer |
| `std.Io.GenericReader` | `std.Io.Reader` | Generic reader removed |
| `std.Io.AnyReader` | `std.Io.Reader` | AnyReader removed |
| `{D}` duration format | `{f}` with `std.Io.Duration` | Duration format specifier |

### Type Mismatch Fixes

#### `std.c.getenv()` Return Type
`std.c.getenv()` returns `?[*:0]u8` (nullable null-terminated C string), not `?[]const u8`.

```zig
// Before
const val = std.c.getenv("KEY");

// After
const c_val = std.c.getenv("KEY");
const val: ?[]const u8 = if (c_val) |v| std.mem.span(v) else null;
```

#### Signal Handlers
Signal handler parameter type changed:

```zig
// Before
fn handleSignal(sig: i32) callconv(.c) void

// After
fn handleSignal(sig: std.posix.SIG) callconv(.c) void
```

#### Entry Point Signature
Main function signature changed for argument access:

```zig
// Before
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
}

// After
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(allocator);
}
```

#### Page Allocator
`std.heap.PageAlloc` replaced with `std.heap.DebugAllocator`:

```zig
// Before
var gpa = std.heap.PageAlloc.init(.{});
defer gpa.deinit();

// After
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
```

#### Mutex Initialization
`std.Thread.Mutex` replaced with `std.Io.Mutex`:

```zig
// Before
var mutex = std.Thread.Mutex.init();

// After
var mutex = std.Io.Mutex.init();
```

Note: `std.Io.Mutex` must be used when coordinating with `std.Io` based concurrency. Mixing `std.atomic.Mutex` with `std.Io` primitives is incorrect.

#### Process Spawning

```zig
// Before
var child = std.process.Child.init(argv, allocator);
child.stdout_behavior = .Inherit;
const term = try child.spawnAndWait();

// After
const io = std.Io.Threaded.global_single_threaded.io();
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdout = .inherit,
    .stderr = .inherit,
});
const term = try child.wait(io);

switch (term) {
    .exited => |code| { ... },  // lowercase!
    else => {},
}
```

#### `std.Io` Duration

```zig
// Before
std.Io.sleep(io, .{ .seconds = 5 }, .real) catch {};

// After
std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .real) catch {};
```

Note: `std.Io.Duration.fromMillis` and `std.Io.Duration.fromNanos` are also available.

#### Entry Point Argument Type

```zig
// Before
fn runAgent(allocator: std.mem.Allocator, args: [][:0]u8) !void

// After
fn runAgent(allocator: std.mem.Allocator, args: []const [:0]const u8) !void
```

#### Duration Formatting

```zig
// Before
writer.print("Duration: {D}", .{ns});

// After
writer.print("Duration: {f}", .{std.Io.Duration{ .nanoseconds = ns }});
```

#### Environment Variable Error Renames

| Old | New |
|---|---|
| `error.EnvironmentVariableNotFound` | `error.EnvironmentVariableMissing` |
| `error.CwdNotFound` | `error.CurrentPathMissing` |
| `error.FileTooBig` | `error.StreamTooLong` |

#### `std.Io` Reader/Writer Patterns

```zig
// Before - FixedBufferStream
var fbs = std.io.fixedBufferStream(data);
const reader = fbs.reader();

// After
var reader: std.Io.Reader = .fixed(data);

// Before - FixedBufferStream (write)
var fbs = std.io.fixedBufferStream(buffer);
const writer = fbs.writer();

// After
var writer: std.Io.Writer = .fixed(buffer);
```

## APIs That Still Work

The following APIs were not affected by Zig 0.16 changes and continue to work:
- `std.fs.path.join()` - path construction
- `std.fs.deleteFileAbsolute()` - file deletion
- `std.json.parseFromSlice()` - JSON parsing
- `std.c.fopen()` / `std.c.fread()` / `std.c.fwrite()` / `std.c.fclose()` - C stdio

## Dependency Fixes

### TLS Package (`zig-pkg/tls-...`)
- `std.crypto.Certificate.Bundle` initialization changed from `.{}` to `.empty`
- `bundle.rescan()` now requires additional `io` and `now` parameters
- Temporarily disabled certificate rescanning to unblock build

### HTTP Library (`libs/http`)
- TLS certificate loading stubbed out (returns empty bundle)
- `std.net.Stream` no longer available - network stack requires significant rework

### Provider Libraries (`libs/providers`)
- `std.posix.getenv()` -> `std.c.getenv()` applied across Anthropic, Minimax, OpenRouter, and OpenRouter Sync providers

## C Interop Patterns

### File I/O Wrapper Pattern
```zig
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fp = std.c.fopen(path_z.ptr, "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, fp);
        if (n == 0) break;
        try buf.appendSlice(allocator, temp[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}
```

Note: The canonical Zig 0.16 approach is `std.Io.Dir.cwd().readFileAlloc(io, file_name, allocator, .limited(max_size))`. The C interop pattern above is a workaround when `std.Io` migration is not yet complete.

### Time Helper Pattern
```zig
fn getCurrentTimeMs() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}
```

Note: In Zig 0.16, `std.c.timeval` fields are `sec` and `usec` (no `tv_` prefix). The canonical approach is `std.Io.Timestamp.now(io)`.

### Stdin Reading Pattern
```zig
var buf: [1024:0]u8 = undefined;
var n: usize = 0;
while (n < buf.len - 1) {
    var byte: [1]u8 = undefined;
    const rd = std.posix.read(0, &byte) catch |err| {
        std.debug.print("Error reading stdin: {any}\n", .{err});
        break;
    };
    if (rd == 0) break; // EOF
    if (byte[0] == '\n') break;
    buf[n] = byte[0];
    n += 1;
}
buf[n] = 0;
const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
```

### Condition Variable Replacement
`std.Thread.Condition` removed; use `std.Io.Condition` for I/O based concurrency, or a busy-wait as a workaround:

```zig
// Before
self.task_condition.wait(&self.task_mutex);

// After (workaround)
self.task_mutex.unlock();
sleepMs(1);
mutexLock(&self.task_mutex);

// After (canonical with std.Io)
var cond = std.Io.Condition.init();
// ... use with std.Io.Mutex
```

## Remaining Work

The following areas still need attention for full Zig 0.16 compatibility:
1. Network Stack - `std.net.Stream` removal requires reimplementing HTTP/TLS networking (TLS currently returns empty bundle)
2. File System Iteration - `std.fs.cwd().openDir()` with iteration is disabled; skill/rule listing and file walking stubbed out
3. TLS Certificate Loading - `Bundle.rescan()` requires `io` and `now` parameters from new I/O model
4. Full `std.Io` Migration - Many APIs in the codebase still use C interop workarounds instead of the canonical `std.Io` interfaces (`std.Io.Dir`, `std.Io.Reader`, `std.Io.Writer`, etc.)

## Testing

After applying fixes, verify with:
```bash
zig build
```

Individual targets:
```bash
zig build console      # Async console app
zig build console-sync # Sync console app
zig build telegram     # Telegram bot
zig build agent        # Interactive agent CLI
```
