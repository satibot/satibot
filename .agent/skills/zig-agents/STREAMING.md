# Streaming Response Handling

## Overview

LLM APIs typically support streaming responses via Server-Sent Events (SSE).
This guide covers patterns for handling streaming in Zig agents.

## SSE Format

Server-Sent Events format:
```
data: {"id":"chatcmpl-xxx","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"chatcmpl-xxx","choices":[{"delta":{"content":" world"}}]}

data: [DONE]
```

## Basic Streaming Implementation

### Stream Handler

```zig
const StreamHandler = struct {
    allocator: std.mem.Allocator,
    line_buffer: std.ArrayListUnmanaged(u8),
    content_buffer: std.ArrayListUnmanaged(u8),
    tool_calls: std.ArrayListUnmanaged(ToolCall),
    on_chunk: *const fn ([]const u8) void,

    pub fn init(allocator: std.mem.Allocator, on_chunk: *const fn ([]const u8) void) StreamHandler {
        return .{
            .allocator = allocator,
            .line_buffer = .{},
            .content_buffer = .{},
            .tool_calls = .{},
            .on_chunk = on_chunk,
        };
    }

    pub fn deinit(self: *StreamHandler) void {
        self.line_buffer.deinit(self.allocator);
        self.content_buffer.deinit(self.allocator);
        for (self.tool_calls.items) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.function_name);
            self.allocator.free(tc.arguments);
        }
        self.tool_calls.deinit(self.allocator);
    }

    pub fn processChunk(self: *StreamHandler, chunk: []const u8) !void {
        try self.line_buffer.appendSlice(self.allocator, chunk);

        // Process complete lines
        while (std.mem.indexOf(u8, self.line_buffer.items, "\n")) |newline_idx| {
            const line = self.line_buffer.items[0..newline_idx];
            
            // Remove processed line from buffer
            const remaining = self.line_buffer.items[newline_idx + 1 ..];
            std.mem.copyForwards(u8, self.line_buffer.items, remaining);
            self.line_buffer.shrinkRetainingCapacity(remaining.len);

            try self.processLine(line);
        }
    }

    fn processLine(self: *StreamHandler, line: []const u8) !void {
        // Skip empty lines
        if (line.len == 0) return;

        // Parse SSE data line
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..];
            
            // Check for end signal
            if (std.mem.eql(u8, data, "[DONE]")) return;

            try self.processJsonChunk(data);
        }
    }

    fn processJsonChunk(self: *StreamHandler, json_data: []const u8) !void {
        const Chunk = struct {
            choices: []struct {
                delta: struct {
                    content: ?[]const u8 = null,
                    tool_calls: ?[]struct {
                        index: usize,
                        id: ?[]const u8 = null,
                        function: ?struct {
                            name: ?[]const u8 = null,
                            arguments: ?[]const u8 = null,
                        } = null,
                    } = null,
                },
                finish_reason: ?[]const u8 = null,
            },
        };

        const parsed = std.json.parseFromSlice(Chunk, self.allocator, json_data, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        for (parsed.value.choices) |choice| {
            // Handle content delta
            if (choice.delta.content) |content| {
                self.on_chunk(content);
                try self.content_buffer.appendSlice(self.allocator, content);
            }

            // Handle tool calls
            if (choice.delta.tool_calls) |tool_calls| {
                for (tool_calls) |tc| {
                    try self.accumulateToolCall(tc);
                }
            }
        }
    }

    fn accumulateToolCall(self: *StreamHandler, tc: anytype) !void {
        // Tool calls come in fragments; accumulate them
        const idx = tc.index;
        
        // Ensure we have a slot for this tool call
        while (self.tool_calls.items.len <= idx) {
            try self.tool_calls.append(self.allocator, .{
                .id = "",
                .function_name = "",
                .arguments = "",
            });
        }

        var existing = &self.tool_calls.items[idx];

        // Update ID if present
        if (tc.id) |id| {
            if (existing.id.len > 0) self.allocator.free(existing.id);
            existing.id = try self.allocator.dupe(u8, id);
        }

        // Update function name if present
        if (tc.function) |func| {
            if (func.name) |name| {
                if (existing.function_name.len > 0) self.allocator.free(existing.function_name);
                existing.function_name = try self.allocator.dupe(u8, name);
            }
            
            // Append to arguments (they come in chunks)
            if (func.arguments) |args| {
                var new_args = try self.allocator.alloc(u8, existing.arguments.len + args.len);
                @memcpy(new_args[0..existing.arguments.len], existing.arguments);
                @memcpy(new_args[existing.arguments.len..], args);
                if (existing.arguments.len > 0) self.allocator.free(existing.arguments);
                existing.arguments = new_args;
            }
        }
    }

    pub fn getResult(self: *StreamHandler) !ChatResponse {
        return .{
            .content = if (self.content_buffer.items.len > 0)
                try self.content_buffer.toOwnedSlice(self.allocator)
            else
                null,
            .tool_calls = if (self.tool_calls.items.len > 0)
                try self.tool_calls.toOwnedSlice(self.allocator)
            else
                null,
            .allocator = self.allocator,
        };
    }
};
```

## HTTP Streaming Client

### Reading Chunked Responses

```zig
pub fn streamRequest(
    self: *Client,
    uri: std.Uri,
    body: []const u8,
    headers: []const std.http.Header,
    handler: *StreamHandler,
) !void {
    var req = try self.client.request(.POST, uri, .{
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };

    var body_buf: [4096]u8 = undefined;
    var bw = try req.sendBody(&body_buf);
    try bw.writer.writeAll(body);
    try bw.end();

    var redirect_buf: [4096]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.status != .ok) {
        return error.HttpError;
    }

    // Read streaming response
    var read_buf: [8192]u8 = undefined;
    var reader = res.reader(&read_buf);

    while (true) {
        const chunk = reader.read() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (chunk.len == 0) break;
        try handler.processChunk(chunk);
    }
}
```

## Real-time Output

### Terminal Streaming

```zig
fn printChunk(chunk: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(chunk) catch {};
}

// Usage in agent
var handler = StreamHandler.init(allocator, printChunk);
defer handler.deinit();

try client.streamRequest(uri, request_body, headers, &handler);

var response = try handler.getResult();
defer response.deinit();
```

### Buffered Output

```zig
const BufferedPrinter = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    
    pub fn print(self: *BufferedPrinter, chunk: []const u8) void {
        self.buffer.appendSlice(self.allocator, chunk) catch {};
    }
    
    pub fn flush(self: *BufferedPrinter) void {
        const stdout = std.io.getStdOut().writer();
        stdout.writeAll(self.buffer.items) catch {};
        self.buffer.clearRetainingCapacity();
    }
};
```

## Error Recovery in Streams

### Handling Partial JSON

```zig
fn processJsonChunk(self: *StreamHandler, json_data: []const u8) !void {
    // JSON might be malformed or incomplete
    const parsed = std.json.parseFromSlice(Chunk, self.allocator, json_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        // Log error but continue - don't fail the whole stream
        std.log.warn("Failed to parse chunk: {any}", .{err});
        return;
    };
    defer parsed.deinit();
    // ...
}
```

### Reconnection Strategy

```zig
fn streamWithRetry(
    self: *Client,
    max_retries: u32,
    handler: *StreamHandler,
) !void {
    var retries: u32 = 0;
    
    while (retries < max_retries) : (retries += 1) {
        self.streamRequest(uri, body, headers, handler) catch |err| {
            std.log.warn("Stream failed (attempt {d}): {any}", .{ retries + 1, err });
            
            if (retries + 1 < max_retries) {
                std.time.sleep(std.time.ns_per_s * (1 << retries)); // Exponential backoff
                continue;
            }
            return err;
        };
        return; // Success
    }
}
```

## Tool Call Streaming

Tool calls are streamed in fragments:

```json
// First chunk
{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"read_file"}}]}}]}

// Second chunk  
{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}

// Third chunk
{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"file.txt\"}"}}]}}]}
```

The `StreamHandler.accumulateToolCall` method handles this by:
1. Creating tool call slots on first appearance
2. Appending argument fragments as they arrive
3. Building complete tool calls by stream end

## Performance Considerations

### Buffer Sizing

```zig
// Small buffers for line processing
var line_buffer: [1024]u8 = undefined;

// Larger buffers for content accumulation
var content_buffer = std.ArrayListUnmanaged(u8){};
content_buffer.ensureTotalCapacity(allocator, 4096) catch {};
```

### Memory Reuse

```zig
// Reuse handler across multiple requests
var handler = StreamHandler.init(allocator, printChunk);

for (requests) |req| {
    handler.reset();  // Clear buffers, keep capacity
    try client.streamRequest(req, &handler);
    try processResult(handler.getResult());
}

handler.deinit();
```
