# Tool Implementation Patterns

## Overview

Tools are the core mechanism that enable agents to interact with the environment.
This guide covers advanced patterns for implementing robust, composable tools.

## Tool Categories

### 1. File System Tools

```zig
const FileTools = struct {
    pub fn list_files(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct { path: []const u8 = "." };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var dir = try std.fs.cwd().openDir(parsed.value.path, .{ .iterate = true });
        defer dir.close();

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(ctx.allocator);

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const kind = switch (entry.kind) {
                .file => "file",
                .directory => "dir",
                else => "other",
            };
            try std.fmt.format(result.writer(ctx.allocator), "{s} ({s})\n", .{ entry.name, kind });
        }

        return result.toOwnedSlice(ctx.allocator);
    }

    pub fn read_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct { path: []const u8 };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const file = try std.fs.cwd().openFile(parsed.value.path, .{});
        defer file.close();

        // Limit file size to prevent OOM
        const max_size = 10 * 1024 * 1024; // 10MB
        return file.readToEndAlloc(ctx.allocator, max_size);
    }

    pub fn write_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct { path: []const u8, content: []const u8 };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const file = try std.fs.cwd().createFile(parsed.value.path, .{});
        defer file.close();

        try file.writeAll(parsed.value.content);
        return try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{
            parsed.value.content.len,
            parsed.value.path,
        });
    }
};
```

### 2. Command Execution Tools

```zig
const CommandTools = struct {
    pub fn run_command(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct {
            command: []const u8,
            args: []const []const u8 = &[_][]const u8{},
            timeout_ms: u32 = 30000,
        };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Build argv
        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(ctx.allocator);
        
        try argv.append(ctx.allocator, parsed.value.command);
        for (parsed.value.args) |arg| {
            try argv.append(ctx.allocator, arg);
        }

        var child = std.process.Child.init(argv.items, ctx.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Collect output
        const stdout = try child.stdout.?.reader().readAllAlloc(ctx.allocator, 1024 * 1024);
        errdefer ctx.allocator.free(stdout);
        
        const stderr = try child.stderr.?.reader().readAllAlloc(ctx.allocator, 1024 * 1024);
        defer ctx.allocator.free(stderr);

        const term = try child.wait();

        if (term.Exited != 0) {
            defer ctx.allocator.free(stdout);
            return try std.fmt.allocPrint(ctx.allocator, "Command failed (exit {d}):\n{s}", .{
                term.Exited,
                stderr,
            });
        }

        return stdout;
    }
};
```

### 3. HTTP Tools

```zig
const HttpTools = struct {
    pub fn http_get(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct { url: []const u8 };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var client = std.http.Client{ .allocator = ctx.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(parsed.value.url);
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        var redirect_buf: [4096]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);

        if (res.status != .ok) {
            return try std.fmt.allocPrint(ctx.allocator, "HTTP error: {d}", .{
                @intFromEnum(res.status),
            });
        }

        var response_buf: [4096]u8 = undefined;
        var reader = res.reader(&response_buf);
        return try reader.allocRemaining(ctx.allocator, .limited(1024 * 1024));
    }

    pub fn http_post(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const Args = struct {
            url: []const u8,
            body: []const u8,
            content_type: []const u8 = "application/json",
        };
        const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var client = std.http.Client{ .allocator = ctx.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(parsed.value.url);
        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = parsed.value.content_type },
        };

        var req = try client.request(.POST, uri, .{ .extra_headers = headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = parsed.value.body.len };
        
        var body_buf: [1024]u8 = undefined;
        var bw = try req.sendBody(&body_buf);
        try bw.writer.writeAll(parsed.value.body);
        try bw.end();

        var redirect_buf: [4096]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);

        var response_buf: [4096]u8 = undefined;
        var reader = res.reader(&response_buf);
        return try reader.allocRemaining(ctx.allocator, .limited(1024 * 1024));
    }
};
```

## Composable Tool Patterns

### Tool Middleware

Wrap tools to add logging, timing, or validation:

```zig
fn withLogging(
    comptime tool_fn: fn (ToolContext, []const u8) anyerror![]const u8,
) fn (ToolContext, []const u8) anyerror![]const u8 {
    return struct {
        fn wrapper(ctx: ToolContext, arguments: []const u8) anyerror![]const u8 {
            const log = std.log.scoped(.tools);
            const start = std.time.milliTimestamp();
            
            const result = tool_fn(ctx, arguments) catch |err| {
                log.err("Tool failed: {any}", .{err});
                return err;
            };
            
            const elapsed = std.time.milliTimestamp() - start;
            log.info("Tool completed in {d}ms", .{elapsed});
            
            return result;
        }
    }.wrapper;
}

// Usage
const logged_read_file = withLogging(FileTools.read_file);
```

### Tool Validation

Validate arguments before execution:

```zig
fn validatePath(path: []const u8) !void {
    // Prevent path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return error.PathTraversalNotAllowed;
    }
    // Only allow relative paths
    if (std.fs.path.isAbsolute(path)) {
        return error.AbsolutePathNotAllowed;
    }
}

pub fn safe_read_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const Args = struct { path: []const u8 };
    const parsed = try std.json.parseFromSlice(Args, ctx.allocator, arguments, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try validatePath(parsed.value.path);
    
    // ... rest of implementation
}
```

## Tool Registration Patterns

### Declarative Registration

```zig
const tool_definitions = [_]Tool{
    .{
        .name = "list_files",
        .description = "List files in a directory",
        .parameters = 
            \\{"type":"object","properties":{"path":{"type":"string","default":"."}}}
        ,
        .execute = FileTools.list_files,
    },
    .{
        .name = "read_file",
        .description = "Read contents of a file",
        .parameters = 
            \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
        .execute = FileTools.read_file,
    },
    // ... more tools
};

fn registerAllTools(registry: *ToolRegistry) !void {
    for (tool_definitions) |tool| {
        try registry.register(tool);
    }
}
```

### Dynamic Tool Loading

```zig
fn loadToolsFromConfig(allocator: std.mem.Allocator, config_path: []const u8) ![]Tool {
    const file = try std.fs.cwd().openFile(config_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse tool configurations and create tools dynamically
    // This is useful for plugin-like tool systems
    // ...
}
```

## Error Handling Best Practices

### User-Friendly Error Messages

```zig
pub fn robust_tool(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const result = innerOperation(ctx, arguments) catch |err| {
        const message = switch (err) {
            error.FileNotFound => "File not found. Check the path and try again.",
            error.AccessDenied => "Permission denied. Cannot access this resource.",
            error.OutOfMemory => "Operation too large. Try with a smaller input.",
            else => try std.fmt.allocPrint(ctx.allocator, "Unexpected error: {any}", .{err}),
        };
        return try ctx.allocator.dupe(u8, message);
    };
    return result;
}
```

### Structured Error Responses

```zig
const ToolResult = struct {
    success: bool,
    data: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
};

fn formatResult(allocator: std.mem.Allocator, result: ToolResult) ![]const u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(result, .{}, &out.writer);
    return out.toOwnedSlice();
}
```
