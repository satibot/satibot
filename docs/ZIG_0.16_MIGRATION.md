# Zig 0.16 Migration Guide

This document summarizes the breaking changes encountered when migrating the Satibot codebase from Zig 0.14/0.15 to Zig 0.16, along with the fixes applied.

## Build System

### Executable Linking

| Old API | Replacement |
|---|---|
| `exe.linkLibC()` | `exe.root_module.link_libc = true` |
| `exe.linkSystemLibrary("sqlite3")` | `exe.root_module.linkSystemLibrary("sqlite3", .{})` |

## Standard Library API Changes

### Removed APIs

| Old API | Replacement | Notes |
|---|---|---|
| `std.fs.cwd()` | C stdio (`std.c.fopen`, `std.c.fread`) or direct paths | File system iteration APIs removed |
| `std.fs.openFileAbsolute()` | C stdio wrappers | Use `fopen`/`fread`/`fclose` |
| `std.fs.File.stdin()` | `extern "c" var stdin` + `fgets` | Standard input reading |
| `std.fs.makeDirAbsolute()` | `std.c.mkdir()` | Directory creation |
| `std.process.argsAlloc()` / `argsFree()` | `init.args.toSlice(allocator)` | Entry point argument parsing |
| `std.process.getEnvVarOwned()` | `std.c.getenv()` + `std.mem.span()` | Environment variable reading |
| `std.process.Child.run()` | Stub/disable | Process spawning API changed significantly |
| `std.crypto.random.bytes()` | `std.Random.DefaultPrng` | Non-cryptographic random generation |
| `std.time.timestamp()` | C `time()` via `extern "c" fn time(...)` | Wall clock timestamps |
| `std.time.milliTimestamp()` | `gettimeofday()` wrapper | Millisecond precision timestamps |
| `std.time.nanoTimestamp()` | `gettimeofday()` wrapper | Nanosecond precision timestamps |
| `std.posix.nanosleep()` | Custom `extern "c" fn nanosleep(...)` | Sleep functionality |
| `std.posix.timespec` | Custom `extern struct timespec` | Time specification struct |
| `std.posix.timeval` | Custom `extern struct timeval` | Time value struct |
| `std.posix.gettimeofday()` | `std.c.gettimeofday()` | High-resolution time |
| `std.posix.getenv()` | `std.c.getenv()` + `std.mem.span()` | Environment variable reading |
| `std.posix.setenv()` / `unsetenv()` | `extern "c" fn setenv/unsetenv` declarations | Environment variable setting in tests |
| `std.Thread.Mutex` | `std.atomic.Mutex` | Synchronization primitive (use `.unlocked`) |
| `std.Thread.Condition` | Busy-wait loop with `sleepMs` | Signaling primitive |
| `std.Thread.sleep()` | `std.c.nanosleep()` or custom wrapper | Thread sleep |
| `std.net.Stream` | Removed - network APIs changed | HTTP/TLS stack affected |
| `std.ArrayList.writer()` | Removed - use manual buffer management | JSON serialization affected |
| `std.ArrayListUnmanaged.init()` | `.empty` initialization pattern | Empty initialization |
| `std.PriorityQueue.init()` | `.initContext()` | Priority queue creation |
| `std.PriorityQueue.add()` | `.push()` | Priority queue insertion |
| `std.PriorityQueue.remove()` | `.pop()` | Priority queue removal |
| `std.cstr.toCstr()` | `allocator.dupeZ()` | String conversion |
| `std.heap.PageAlloc` | `std.heap.DebugAllocator(.{})` | Page allocator API |
| `pub fn main() !void` | `pub fn main(init: std.process.Init.Minimal) !void` | Entry point signature |

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
fn handleSignal(sig: c_int) void

// After
fn handleSignal(sig: std.posix.SIG) void
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
`std.Thread.Mutex` replaced with `std.atomic.Mutex`:

```zig
// Before
.task_mutex = .{},

// After
.task_mutex = .unlocked,
```

## APIs That Still Work

The following APIs were not affected by Zig 0.16 changes and continue to work:
- `std.fs.path.join()` - path construction
- `std.fs.deleteFileAbsolute()` - file deletion
- `std.json.parseFromSlice()` - JSON parsing

## Dependency Fixes

### TLS Package (`zig-pkg/tls-...`)
- `std.crypto.Certificate.Bundle` initialization changed from `.{}` to `.empty`
- `bundle.rescan()` now requires additional `io` and `now` parameters
- Temporarily disabled certificate rescanning to unblock build

### HTTP Library (`libs/http`)
- TLS certificate loading stubbed out (returns empty bundle)
- `std.net.Stream` no longer available - network stack requires significant rework

### Provider Libraries (`libs/providers`)
- `std.posix.getenv()` → `std.c.getenv()` applied across Anthropic, Minimax, OpenRouter, and OpenRouter Sync providers

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

### Time Helper Pattern
```zig
fn getCurrentTimeMs() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000);
}
```

### Stdin Reading Pattern
```zig
extern "c" var stdin: *anyopaque;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;

var read_buf: [4096:0]u8 = undefined;
const ptr = fgets(&read_buf, @intCast(read_buf.len), stdin);
if (ptr == null) return; // EOF
var n: usize = 0;
while (n < read_buf.len and read_buf[n] != 0) n += 1;
const input = std.mem.trim(u8, read_buf[0..n], " \t\r\n");
```

### Condition Variable Replacement
`std.Thread.Condition` removed; use busy-wait with mutex unlock/relock:

```zig
// Before
self.task_condition.wait(&self.task_mutex);

// After
self.task_mutex.unlock();
sleepMs(1);
mutexLock(&self.task_mutex);
```

## Remaining Work

The following areas still need attention for full Zig 0.16 compatibility:
1. Network Stack - `std.net.Stream` removal requires reimplementing HTTP/TLS networking (TLS currently returns empty bundle)
2. Process Spawning - `std.process.Child.run()` is stubbed out; needs full reimplementation
3. File System Iteration - `std.fs.cwd().openDir()` with iteration is disabled; skill/rule listing and file walking stubbed out
4. TLS Certificate Loading - `Bundle.rescan()` requires `io` and `now` parameters from new I/O model

## Testing

After applying fixes, verify with:
```bash
zig build
```

Individual targets:
```bash
zig build console # Async console app
zig build console-sync # Sync console app
zig build telegram # Telegram bot
zig build agent # Interactive agent CLI
```
