# Zig 0.16 Migration Guide

This document summarizes the breaking changes encountered when migrating the Satibot codebase from Zig 0.14/0.15 to Zig 0.16, along with the fixes applied.

## Build System

## Standard Library API Changes

### Removed APIs

| Old API | Replacement | Notes |
|---|---|---|
| `std.fs.cwd()` | C stdio (`std.c.fopen`, `std.c.fread`) or direct paths | File system iteration APIs removed |
| `std.fs.openFileAbsolute()` | C stdio wrappers | Use `fopen`/`fread`/`fclose` |
| `std.fs.File.stdin()` | `extern "c" var stdin` + `fgets` | Standard input reading |
| `std.fs.makeDirAbsolute()` | `std.c.mkdir()` | Directory creation |
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
| `std.Thread.Mutex` | `std.atomic.Mutex` | Synchronization primitive |
| `std.Thread.Condition` | Custom condition variable or busy-wait | Signaling primitive |
| `std.Thread.sleep()` | `std.c.nanosleep()` or custom wrapper | Thread sleep |
| `std.net.Stream` | Removed - network APIs changed | HTTP/TLS stack affected |
| `std.ArrayList.writer()` | Removed - use manual buffer management | JSON serialization affected |
| `std.ArrayListUnmanaged.init()` | `.empty` initialization pattern | Empty initialization |
| `std.PriorityQueue.init()` | `.initContext()` | Priority queue creation |
| `std.PriorityQueue.add()` | `.push()` | Priority queue insertion |
| `std.PriorityQueue.remove()` | `.pop()` | Priority queue removal |
| `std.cstr.toCstr()` | Removed - use manual null-termination | String conversion |

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

## Dependency Fixes

### TLS Package (`zig-pkg/tls-...`)
- `std.crypto.Certificate.Bundle` initialization changed from `.{}` to `.empty`
- `bundle.rescan()` now requires additional `io` and `now` parameters
- Temporarily disabled certificate rescanning to unblock build

### HTTP Library (`libs/http`)
- TLS certificate loading stubbed out (returns empty bundle)
- `std.net.Stream` no longer available - network stack requires significant rework

### Minimax Music (`libs/minimax-music`)
- `ArrayList.writer()` removed - JSON buffer building needs manual implementation

### Provider Libraries (`libs/providers`)
- `ArrayList.writer()` removed across Anthropic, Minimax, and OpenRouter providers
- `std.Thread.sleep()` removed - replaced with custom nanosleep wrapper
- `std.c.getenv()` return type fixes applied consistently

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
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, fp);
        if (n == 0) break;
        try buf.appendSlice(temp[0..n]);
    }
    return buf.toOwnedSlice();
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

### Sleep Helper Pattern
```zig
extern "c" fn nanosleep(req: *const timespec, rem: *timespec) c_int;

pub const timespec = extern struct {
    tv_sec: std.os.time_t,
    tv_nsec: std.os.suseconds_t,
};
```

## Remaining Work

The following areas still need attention for full Zig 0.16 compatibility:
1. Network Stack - `std.net.Stream` removal requires reimplementing HTTP/TLS networking
2. JSON Serialization - `ArrayList.writer()` removal requires manual buffer management across providers
3. Process Spawning - `std.process.Child.run()` API changed significantly; currently stubbed out
4. Build Scripts - Dependency `build.zig` files (e.g., `zap`) may need `getEnvVarOwned` fixes
5. TLS Certificate Loading - `Bundle.rescan()` requires `io` and `now` parameters from new I/O model

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
