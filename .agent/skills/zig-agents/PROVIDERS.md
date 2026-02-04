# LLM Provider Implementation

## Overview

This guide covers patterns for implementing LLM provider integrations in Zig,
including OpenAI-compatible APIs, authentication, and response handling.

## Provider Interface

### Common Types

```zig
pub const ToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments: []const u8,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
};

pub const ChatResponse = struct {
    content: ?[]const u8,
    tool_calls: ?[]ToolCall,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChatResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.function_name);
                self.allocator.free(call.arguments);
            }
            self.allocator.free(calls);
        }
    }
};
```

### Provider Protocol

```zig
pub const Provider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) Provider {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = "https://api.openai.com/v1",
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Provider) void {
        self.client.deinit();
    }

    pub fn chatStream(
        self: *Provider,
        messages: []const Message,
        model: []const u8,
        on_chunk: *const fn ([]const u8) void,
    ) !ChatResponse {
        // Implementation
    }
};
```

## OpenAI-Compatible Implementation

### Request Building

```zig
fn buildRequest(
    self: *Provider,
    messages: []const Message,
    model: []const u8,
    tools: ?[]const Tool,
) ![]const u8 {
    const Request = struct {
        model: []const u8,
        messages: []const RequestMessage,
        stream: bool = true,
        tools: ?[]const ToolSpec = null,
    };

    const RequestMessage = struct {
        role: []const u8,
        content: ?[]const u8,
        tool_call_id: ?[]const u8 = null,
        tool_calls: ?[]const RequestToolCall = null,
    };

    const RequestToolCall = struct {
        id: []const u8,
        type: []const u8 = "function",
        function: struct {
            name: []const u8,
            arguments: []const u8,
        },
    };

    const ToolSpec = struct {
        type: []const u8 = "function",
        function: struct {
            name: []const u8,
            description: []const u8,
            parameters: std.json.Value,
        },
    };

    // Convert messages to request format
    var req_messages = try self.allocator.alloc(RequestMessage, messages.len);
    defer self.allocator.free(req_messages);

    for (messages, 0..) |msg, i| {
        req_messages[i] = .{
            .role = msg.role,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls = if (msg.tool_calls) |tcs| blk: {
                var rtcs = try self.allocator.alloc(RequestToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    rtcs[j] = .{
                        .id = tc.id,
                        .function = .{
                            .name = tc.function_name,
                            .arguments = tc.arguments,
                        },
                    };
                }
                break :blk rtcs;
            } else null,
        };
    }

    // Build tool specs if provided
    var tool_specs: ?[]ToolSpec = null;
    if (tools) |ts| {
        tool_specs = try self.allocator.alloc(ToolSpec, ts.len);
        for (ts, 0..) |t, i| {
            const params = std.json.parseFromSlice(std.json.Value, self.allocator, t.parameters, .{}) catch .null;
            tool_specs.?[i] = .{
                .function = .{
                    .name = t.name,
                    .description = t.description,
                    .parameters = params,
                },
            };
        }
    }

    const request = Request{
        .model = model,
        .messages = req_messages,
        .tools = tool_specs,
    };

    var out = std.io.Writer.Allocating.init(self.allocator);
    try std.json.Stringify.value(request, .{}, &out.writer);
    return out.toOwnedSlice();
}
```

### Authentication Headers

```zig
fn getAuthHeaders(self: *Provider) [2]std.http.Header {
    return .{
        .{ .name = "Authorization", .value = blk: {
            var buf: [256]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "Bearer {s}", .{self.api_key}) catch self.api_key;
        } },
        .{ .name = "Content-Type", .value = "application/json" },
    };
}
```

## OpenRouter Provider

OpenRouter is an API aggregator that provides access to multiple LLM providers.

```zig
pub const OpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    client: std.http.Client,
    
    const BASE_URL = "https://openrouter.ai/api/v1/chat/completions";

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) OpenRouterProvider {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *OpenRouterProvider) void {
        self.client.deinit();
    }

    pub fn chatStream(
        self: *OpenRouterProvider,
        messages: []const Message,
        model: []const u8,
        on_chunk: *const fn ([]const u8) void,
    ) !ChatResponse {
        const body = try self.buildRequest(messages, model, null);
        defer self.allocator.free(body);

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch return error.BufferTooSmall;

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "HTTP-Referer", .value = "https://github.com/your-project" },
            .{ .name = "X-Title", .value = "YourAgentName" },
        };

        const uri = try std.Uri.parse(BASE_URL);
        var req = try self.client.request(.POST, uri, .{ .extra_headers = headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var body_buf: [8192]u8 = undefined;
        var bw = try req.sendBody(&body_buf);
        try bw.writer.writeAll(body);
        try bw.end();

        var redirect_buf: [4096]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);

        if (res.status != .ok) {
            return error.ApiError;
        }

        var handler = StreamHandler.init(self.allocator, on_chunk);
        defer handler.deinit();

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

        return handler.getResult();
    }
};
```

## Anthropic Claude Provider

Claude has a slightly different API format.

```zig
pub const ClaudeProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    client: std.http.Client,
    
    const BASE_URL = "https://api.anthropic.com/v1/messages";

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) ClaudeProvider {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    fn buildClaudeRequest(
        self: *ClaudeProvider,
        messages: []const Message,
        model: []const u8,
    ) ![]const u8 {
        // Claude uses a different format:
        // - System message is separate from messages array
        // - No "tool_calls" in messages, uses "tool_use" content blocks
        
        const ClaudeRequest = struct {
            model: []const u8,
            max_tokens: u32 = 4096,
            messages: []const ClaudeMessage,
            system: ?[]const u8 = null,
            stream: bool = true,
            tools: ?[]const ClaudeTool = null,
        };

        const ClaudeMessage = struct {
            role: []const u8,
            content: []const u8,
        };

        const ClaudeTool = struct {
            name: []const u8,
            description: []const u8,
            input_schema: std.json.Value,
        };

        // Extract system message
        var system_msg: ?[]const u8 = null;
        var user_messages = std.ArrayListUnmanaged(ClaudeMessage){};
        defer user_messages.deinit(self.allocator);

        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                system_msg = msg.content;
            } else {
                try user_messages.append(self.allocator, .{
                    .role = msg.role,
                    .content = msg.content orelse "",
                });
            }
        }

        const request = ClaudeRequest{
            .model = model,
            .messages = user_messages.items,
            .system = system_msg,
        };

        var out = std.io.Writer.Allocating.init(self.allocator);
        try std.json.Stringify.value(request, .{}, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn chatStream(
        self: *ClaudeProvider,
        messages: []const Message,
        model: []const u8,
        on_chunk: *const fn ([]const u8) void,
    ) !ChatResponse {
        const body = try self.buildClaudeRequest(messages, model);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        };

        // ... streaming implementation similar to OpenRouter
    }
};
```

## Provider Factory Pattern

```zig
pub const ProviderType = enum {
    openai,
    openrouter,
    anthropic,
    ollama,
};

pub fn createProvider(
    allocator: std.mem.Allocator,
    provider_type: ProviderType,
    api_key: []const u8,
) !*Provider {
    return switch (provider_type) {
        .openai => try OpenAIProvider.create(allocator, api_key),
        .openrouter => try OpenRouterProvider.create(allocator, api_key),
        .anthropic => try ClaudeProvider.create(allocator, api_key),
        .ollama => try OllamaProvider.create(allocator, null),
    };
}
```

## Error Handling

### Rate Limiting

```zig
const ApiError = error{
    RateLimited,
    InvalidApiKey,
    ModelNotFound,
    InsufficientCredits,
    ServerError,
};

fn handleHttpError(status: std.http.Status, body: []const u8) ApiError!void {
    switch (status) {
        .too_many_requests => return error.RateLimited,
        .unauthorized => return error.InvalidApiKey,
        .not_found => return error.ModelNotFound,
        .payment_required => return error.InsufficientCredits,
        else => if (@intFromEnum(status) >= 500) return error.ServerError,
    }
}
```

### Retry Logic

```zig
fn chatWithRetry(
    self: *Provider,
    messages: []const Message,
    model: []const u8,
    max_retries: u32,
) !ChatResponse {
    var last_error: anyerror = undefined;
    
    for (0..max_retries) |attempt| {
        const response = self.chat(messages, model) catch |err| {
            last_error = err;
            
            // Only retry on transient errors
            switch (err) {
                error.RateLimited, error.ServerError => {
                    const delay = std.time.ns_per_s * std.math.pow(u64, 2, attempt);
                    std.time.sleep(delay);
                    continue;
                },
                else => return err,
            }
        };
        return response;
    }
    
    return last_error;
}
```

## Configuration

### Provider Config Structure

```zig
pub const ProviderConfig = struct {
    type: ProviderType,
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    default_model: []const u8,
    max_tokens: u32 = 4096,
    temperature: f32 = 0.7,
};

pub const Config = struct {
    providers: struct {
        openai: ?ProviderConfig = null,
        openrouter: ?ProviderConfig = null,
        anthropic: ?ProviderConfig = null,
    },
    active_provider: ProviderType = .openrouter,
};
```

### Environment Variable Loading

```zig
fn loadApiKey(provider: ProviderType) ?[]const u8 {
    return switch (provider) {
        .openai => std.posix.getenv("OPENAI_API_KEY"),
        .openrouter => std.posix.getenv("OPENROUTER_API_KEY"),
        .anthropic => std.posix.getenv("ANTHROPIC_API_KEY"),
        .ollama => null,  // Ollama doesn't need an API key
    };
}
```
