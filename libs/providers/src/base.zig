/// Base types and structures for LLM provider interactions.
/// Defines common message formats, tool call structures, and response types
/// used across all LLM provider implementations (Anthropic, OpenRouter, Groq).
const std = @import("std");
const core = @import("core");
const Config = core.config.Config;
const openrouter = @import("openrouter.zig");
const OpenRouterError = openrouter.OpenRouterError;

/// Callback function for streaming response chunks.
/// Takes a context pointer and the chunk content.
pub const ChunkCallback = *const fn (ctx: ?*anyopaque, chunk: []const u8) void;

/// Message in a conversation with an LLM.
/// Can represent messages from user, assistant, system, or tool results.
pub const LlmMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};

/// Tool call requested by an LLM assistant.
/// Contains the function name and JSON arguments to execute.
pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

/// Definition of a tool that can be called by an LLM assistant.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON schema
};

/// Response from an LLM chat completion.
/// Contains either text content, tool calls, or both.
pub const LlmResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    allocator: std.mem.Allocator,

    /// Free all allocated memory in the response.
    pub fn deinit(self: *LlmResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            self.allocator.free(calls);
        }
        self.content = undefined;
        self.tool_calls = undefined;
        self.allocator = undefined;
        self.* = undefined;
    }
};

/// Response from an embedding API containing vector representations of text.
pub const EmbeddingResponse = struct {
    embeddings: [][]const f32,
    allocator: std.mem.Allocator,

    /// Free all embedding vectors and the array itself.
    pub fn deinit(self: *EmbeddingResponse) void {
        for (self.embeddings) |e| {
            self.allocator.free(e);
        }
        self.allocator.free(self.embeddings);
        self.embeddings = undefined;
        self.allocator = undefined;
        self.* = undefined;
    }
};

/// Request to generate embeddings for a list of text inputs.
pub const EmbeddingRequest = struct {
    input: []const []const u8,
    model: []const u8,
};

test "LlmResponse: deinit" {
    const allocator = std.testing.allocator;
    var resp: LlmResponse = .{
        .content = try allocator.dupe(u8, "hello"),
        .tool_calls = null,
        .allocator = allocator,
    };
    resp.deinit();
}

test "EmbeddingResponse: deinit" {
    const allocator = std.testing.allocator;
    var embeddings = try allocator.alloc([]const f32, 1);
    const row = try allocator.alloc(f32, 2);
    row[0] = 1.0;
    row[1] = 0.0;
    embeddings[0] = row;

    var resp: EmbeddingResponse = .{
        .embeddings = embeddings,
        .allocator = allocator,
    };
    resp.deinit();
}

test "LlmMessage: creation" {
    const msg: LlmMessage = .{
        .role = "user",
        .content = "hello",
    };

    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("hello", msg.content.?);
    try std.testing.expect(msg.tool_call_id == null);
    try std.testing.expect(msg.tool_calls == null);
}

test "LlmMessage: with tool calls" {
    const tool_calls = &[_]ToolCall{
        .{ .id = "call_1", .function = .{ .name = "test_func", .arguments = "{\"arg\": \"value\"}" } },
    };

    const msg: LlmMessage = .{
        .role = "assistant",
        .content = "I'll call a tool",
        .tool_calls = tool_calls,
    };

    try std.testing.expectEqualStrings("assistant", msg.role);
    try std.testing.expectEqualStrings("I'll call a tool", msg.content.?);
    try std.testing.expect(msg.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), msg.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", msg.tool_calls.?[0].id);
}

test "LlmMessage: tool result message" {
    const msg: LlmMessage = .{
        .role = "tool",
        .content = "Tool output",
        .tool_call_id = "call_123",
    };

    try std.testing.expectEqualStrings("tool", msg.role);
    try std.testing.expectEqualStrings("Tool output", msg.content.?);
    try std.testing.expectEqualStrings("call_123", msg.tool_call_id.?);
    try std.testing.expect(msg.tool_calls == null);
}

/// Common interface for all LLM providers.
/// Provides a unified way to interact with different providers (Anthropic, OpenRouter, etc.).
pub const ProviderInterface = struct {
    /// Context for provider operations
    ctx: *anyopaque,

    /// Function pointer to get the API key for the provider
    getApiKey: *const fn (ctx: *anyopaque, config: Config) ?[]const u8,

    /// Function pointer to initialize the provider
    initProvider: *const fn (allocator: std.mem.Allocator, api_key: []const u8) anyerror!*anyopaque,

    /// Function pointer to deinitialize the provider
    deinitProvider: *const fn (provider: *anyopaque) void,

    /// Function pointer to call chatStream
    chatStream: *const fn (
        provider: *anyopaque,
        messages: []const LlmMessage,
        model: []const u8,
        tools: []const ToolDefinition,
        chunk_callback: ChunkCallback,
        callback_ctx: ?*anyopaque,
    ) anyerror!LlmResponse,

    /// Function pointer to get the provider name
    getProviderName: *const fn () []const u8,
};

/// Helper function to execute a chat completion with retry logic.
/// This encapsulates the common retry pattern used across all providers.
pub fn executeWithRetry(
    provider_interface: ProviderInterface,
    allocator: std.mem.Allocator,
    config: Config,
    messages: []const LlmMessage,
    model: []const u8,
    tools: []const ToolDefinition,
    chunk_callback: ChunkCallback,
    callback_ctx: ?*anyopaque,
) !LlmResponse {
    const api_key = provider_interface.getApiKey(provider_interface.ctx, config) orelse {
        std.debug.print("Error: API key not set for {s}\n", .{provider_interface.getProviderName()});
        return error.NoApiKey;
    };

    const provider = try provider_interface.initProvider(allocator, api_key);
    defer provider_interface.deinitProvider(provider);

    std.debug.print("AI ({s}): ", .{provider_interface.getProviderName()});

    var retry_count: usize = 0;
    const max_retries = 3;

    while (retry_count < max_retries) : (retry_count += 1) {
        // Calculate exponential backoff: 2s, 4s, 8s
        const backoff_seconds = std.math.shl(u64, 1, retry_count + 1);

        const response = provider_interface.chatStream(
            provider,
            messages,
            model,
            tools,
            chunk_callback,
            callback_ctx,
        ) catch |err| {
            // Handle specific OpenRouter errors
            if (OpenRouterError == @TypeOf(err)) {
                switch (err) {
                    OpenRouterError.ServiceUnavailable => {
                        std.debug.print("\n⚠️ Service unavailable (Model: {s}). Retrying in {d}s... ({d}/{d})\n", .{ model, backoff_seconds, retry_count + 1, max_retries });
                        std.Thread.sleep(std.time.ns_per_s * backoff_seconds);
                        continue;
                    },
                    OpenRouterError.ModelNotSupported => {
                        std.debug.print("\n❌ Error: Model doesn't support tools. Please use a model that supports function calling.\n", .{});
                        return err;
                    },
                    OpenRouterError.RateLimitExceeded => {
                        std.debug.print("\n❌ Error: Rate limit exceeded (Model: {s}). Not retrying to avoid further limits.\n", .{model});
                        return err;
                    },
                    OpenRouterError.ApiRequestFailed => {
                        std.debug.print("\n❌ Error: API request failed (Model: {s}). Retrying in {d}s... ({d}/{d})\n", .{ model, backoff_seconds, retry_count + 1, max_retries });
                        std.Thread.sleep(std.time.ns_per_s * backoff_seconds);
                        continue;
                    },
                }
            }

            // Retry on network errors or temporary service issues
            if (err == error.ReadFailed or err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) {
                std.debug.print("\n❌ Network error: {any} (Model: {s}). Retrying in {d}s... ({d}/{d})\n", .{ err, model, backoff_seconds, retry_count + 1, max_retries });
                std.Thread.sleep(std.time.ns_per_s * backoff_seconds);
                continue;
            }
            return err;
        };

        return response;
    }

    std.debug.print("\n❌ Failed after {d} retries. The service may be experiencing high load or temporary issues. Please try again later.\n", .{max_retries});
    return error.NetworkRetryFailed;
}

// --- Unit Tests ---

test "ToolCall: struct fields" {
    const call: ToolCall = .{
        .id = "call_abc",
        .function = .{
            .name = "my_function",
            .arguments = "{\"key\": \"value\"}",
        },
    };

    try std.testing.expectEqualStrings("call_abc", call.id);
    try std.testing.expectEqualStrings("my_function", call.function.name);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", call.function.arguments);
}

test "LlmResponse: creation with content only" {
    const allocator = std.testing.allocator;
    var resp: LlmResponse = .{
        .content = try allocator.dupe(u8, "Hello world"),
        .tool_calls = null,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("Hello world", resp.content.?);
    try std.testing.expect(resp.tool_calls == null);
}

test "LlmResponse: creation with tool calls only" {
    const allocator = std.testing.allocator;

    const calls = try allocator.alloc(ToolCall, 2);
    calls[0] = .{
        .id = try allocator.dupe(u8, "call_1"),
        .function = .{
            .name = try allocator.dupe(u8, "func1"),
            .arguments = try allocator.dupe(u8, "{}"),
        },
    };
    calls[1] = .{
        .id = try allocator.dupe(u8, "call_2"),
        .function = .{
            .name = try allocator.dupe(u8, "func2"),
            .arguments = try allocator.dupe(u8, "{\"a\": 1}"),
        },
    };

    var resp: LlmResponse = .{
        .content = null,
        .tool_calls = calls,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expect(resp.content == null);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), resp.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", resp.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("call_2", resp.tool_calls.?[1].id);
}

test "LlmResponse: creation with both content and tool calls" {
    const allocator = std.testing.allocator;

    const calls = try allocator.alloc(ToolCall, 1);
    calls[0] = .{
        .id = try allocator.dupe(u8, "call_1"),
        .function = .{
            .name = try allocator.dupe(u8, "func1"),
            .arguments = try allocator.dupe(u8, "{}"),
        },
    };

    var resp: LlmResponse = .{
        .content = try allocator.dupe(u8, "I'll call the function"),
        .tool_calls = calls,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("I'll call the function", resp.content.?);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), resp.tool_calls.?.len);
}

test "EmbeddingResponse: multiple embeddings" {
    const allocator = std.testing.allocator;
    var embeddings = try allocator.alloc([]const f32, 3);

    for (0..3) |i| {
        const row = try allocator.alloc(f32, 4);
        for (0..4) |j| {
            row[j] = @floatFromInt(i * 4 + j);
        }
        embeddings[i] = row;
    }

    var resp: EmbeddingResponse = .{
        .embeddings = embeddings,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 3), resp.embeddings.len);
    try std.testing.expectEqual(@as(usize, 4), resp.embeddings[0].len);
    try std.testing.expectEqual(@as(f32, 0.0), resp.embeddings[0][0]);
    try std.testing.expectEqual(@as(f32, 4.0), resp.embeddings[1][0]);
    try std.testing.expectEqual(@as(f32, 8.0), resp.embeddings[2][0]);
}

test "EmbeddingRequest: creation" {
    const input = &[_][]const u8{ "text1", "text2", "text3" };

    const req: EmbeddingRequest = .{
        .input = input,
        .model = "text-embedding-3-small",
    };

    try std.testing.expectEqual(@as(usize, 3), req.input.len);
    try std.testing.expectEqualStrings("text1", req.input[0]);
    try std.testing.expectEqualStrings("text2", req.input[1]);
    try std.testing.expectEqualStrings("text3", req.input[2]);
    try std.testing.expectEqualStrings("text-embedding-3-small", req.model);
}

test "EmbeddingRequest: empty input" {
    const input = &[_][]const u8{};

    const req: EmbeddingRequest = .{
        .input = input,
        .model = "text-embedding-3-small",
    };

    try std.testing.expectEqual(@as(usize, 0), req.input.len);
    try std.testing.expectEqualStrings("text-embedding-3-small", req.model);
}

test "EmbeddingResponse: empty embeddings" {
    const allocator = std.testing.allocator;
    const embeddings = try allocator.alloc([]const f32, 0);

    var resp: EmbeddingResponse = .{
        .embeddings = embeddings,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 0), resp.embeddings.len);
}

test "LlmResponse: empty content and no tool calls" {
    const allocator = std.testing.allocator;

    var resp: LlmResponse = .{
        .content = null,
        .tool_calls = null,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expect(resp.content == null);
    try std.testing.expect(resp.tool_calls == null);
}

test "ToolCall: creation and validation" {
    _ = @as(std.mem.Allocator, undefined); // Mark as used

    const tool_call: ToolCall = .{
        .id = "test_call_123",
        .type = "function",
        .function = .{
            .name = "test_function",
            .arguments = "{\"param\": \"value\"}",
        },
    };

    try std.testing.expectEqualStrings("test_call_123", tool_call.id);
    try std.testing.expectEqualStrings("function", tool_call.type);
    try std.testing.expectEqualStrings("test_function", tool_call.function.name);
    try std.testing.expectEqualStrings("{\"param\": \"value\"}", tool_call.function.arguments);
}

test "ToolDefinition: validation" {
    _ = @as(std.mem.Allocator, undefined); // Mark as used

    const tool_def: ToolDefinition = .{
        .name = "search_web",
        .description = "Search the web for information",
        .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
    };

    try std.testing.expectEqualStrings("search_web", tool_def.name);
    try std.testing.expectEqualStrings("Search the web for information", tool_def.description);
    try std.testing.expect(std.mem.indexOf(u8, tool_def.parameters, "query") != null);
}

test "EmbeddingRequest: creation with allocated inputs" {
    const allocator = std.testing.allocator;

    const input_texts = try allocator.alloc([]const u8, 2);
    defer allocator.free(input_texts);

    input_texts[0] = "Hello world";
    input_texts[1] = "How are you?";

    const request: EmbeddingRequest = .{
        .input = input_texts,
        .model = "text-embedding-ada-002",
    };

    try std.testing.expectEqual(@as(usize, 2), request.input.len);
    try std.testing.expectEqualStrings("Hello world", request.input[0]);
    try std.testing.expectEqualStrings("How are you?", request.input[1]);
    try std.testing.expectEqualStrings("text-embedding-ada-002", request.model);
}

test "ChunkCallback: function pointer type" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test that ChunkCallback can be assigned to a function
    const TestCallback = struct {
        fn callback(ctx: ?*anyopaque, chunk: []const u8) void {
            _ = ctx;
            _ = chunk;
        }
    };

    const callback: ChunkCallback = TestCallback.callback;
    _ = callback; // Just verify the type is compatible
}

test "LlmMessage: with tool result" {
    const allocator = std.testing.allocator;
    _ = allocator;

    const msg: LlmMessage = .{
        .role = "tool",
        .content = "Function executed successfully",
        .tool_call_id = "call_abc123",
        .tool_calls = null,
    };

    try std.testing.expectEqualStrings("tool", msg.role);
    try std.testing.expectEqualStrings("Function executed successfully", msg.content.?);
    try std.testing.expectEqualStrings("call_abc123", msg.tool_call_id.?);
    try std.testing.expect(msg.tool_calls == null);
}

test "LlmMessage: assistant with multiple tool calls" {
    var allocator = std.testing.allocator;

    const tool_calls = try allocator.alloc(ToolCall, 2);
    defer {
        for (tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(tool_calls);
    }

    tool_calls[0] = .{
        .id = try allocator.dupe(u8, "call_1"),
        .type = "function",
        .function = .{
            .name = try allocator.dupe(u8, "search"),
            .arguments = try allocator.dupe(u8, "{\"query\": \"test\"}"),
        },
    };

    tool_calls[1] = .{
        .id = try allocator.dupe(u8, "call_2"),
        .type = "function",
        .function = .{
            .name = try allocator.dupe(u8, "calculate"),
            .arguments = try allocator.dupe(u8, "{\"expression\": \"1+1\"}"),
        },
    };

    const msg: LlmMessage = .{
        .role = "assistant",
        .content = "I'll help you with that",
        .tool_calls = tool_calls,
    };

    try std.testing.expectEqualStrings("assistant", msg.role);
    try std.testing.expectEqualStrings("I'll help you with that", msg.content.?);
    try std.testing.expect(msg.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), msg.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", msg.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("call_2", msg.tool_calls.?[1].id);
}

test "ProviderInterface: function pointer compatibility" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test that ProviderInterface can be created with proper function pointers
    const MockProvider = struct {
        fn getApiKey(ctx: *anyopaque, config: Config) ?[]const u8 {
            _ = ctx;
            _ = config;
            return "test-key";
        }

        fn initProvider(alloc: std.mem.Allocator, api_key: []const u8) !*anyopaque {
            _ = alloc;
            _ = api_key;
            return @as(*anyopaque, @ptrCast(@alignCast(@constCast(&@as(u8, 0)))));
        }

        fn deinitProvider(provider: *anyopaque) void {
            _ = provider;
        }

        fn chatStream(
            provider: *anyopaque,
            messages: []const LlmMessage,
            model: []const u8,
            tools: []const ToolDefinition,
            chunk_callback: ChunkCallback,
            callback_ctx: ?*anyopaque,
        ) !LlmResponse {
            _ = provider;
            _ = messages;
            _ = model;
            _ = tools;
            _ = chunk_callback;
            _ = callback_ctx;
            return .{
                .content = "test response",
                .tool_calls = null,
                .allocator = std.testing.allocator,
            };
        }

        fn getProviderName() []const u8 {
            return "MockProvider";
        }
    };

    const interface: ProviderInterface = .{
        .ctx = undefined,
        .getApiKey = MockProvider.getApiKey,
        .initProvider = MockProvider.initProvider,
        .deinitProvider = MockProvider.deinitProvider,
        .chatStream = MockProvider.chatStream,
        .getProviderName = MockProvider.getProviderName,
    };

    try std.testing.expectEqualStrings("MockProvider", interface.getProviderName());
}

test "executeWithRetry handles RateLimitExceeded without retry" {
    const allocator = std.testing.allocator;

    // Mock provider that returns RateLimitExceeded error
    const MockProvider = struct {
        fn getApiKey(ctx: *anyopaque, config: Config) ?[]const u8 {
            _ = ctx;
            _ = config;
            return "test-key";
        }

        fn initProvider(alloc: std.mem.Allocator, api_key: []const u8) !*anyopaque {
            _ = alloc;
            _ = api_key;
            return @as(*anyopaque, @ptrCast(@alignCast(@constCast(&@as(u8, 0)))));
        }

        fn deinitProvider(provider: *anyopaque) void {
            _ = provider;
        }

        fn chatStream(
            provider: *anyopaque,
            messages: []const LlmMessage,
            model: []const u8,
            tools: []const ToolDefinition,
            chunk_callback: ChunkCallback,
            callback_ctx: ?*anyopaque,
        ) !LlmResponse {
            _ = provider;
            _ = messages;
            _ = model;
            _ = tools;
            _ = chunk_callback;
            _ = callback_ctx;
            return error.RateLimitExceeded;
        }

        fn getProviderName() []const u8 {
            return "MockProvider";
        }
    };

    const interface: ProviderInterface = .{
        .ctx = undefined,
        .getApiKey = MockProvider.getApiKey,
        .initProvider = MockProvider.initProvider,
        .deinitProvider = MockProvider.deinitProvider,
        .chatStream = MockProvider.chatStream,
        .getProviderName = MockProvider.getProviderName,
    };

    const messages = [_]LlmMessage{.{ .role = "user", .content = "Hello" }};
    const tools: []const ToolDefinition = &[_]ToolDefinition{};

    const mockCallback = struct {
        fn callback(ctx: ?*anyopaque, chunk: []const u8) void {
            _ = ctx;
            _ = chunk;
        }
    }.callback;

    // Test that RateLimitExceeded is returned immediately without retry
    const result = executeWithRetry(
        interface,
        allocator,
        .{ .providers = .{}, .agents = .{ .defaults = .{ .model = "test" } }, .tools = .{ .web = .{ .search = .{} } } },
        &messages,
        "test-model",
        tools,
        mockCallback,
        null,
    );

    try std.testing.expectError(OpenRouterError.RateLimitExceeded, result);
}

test "executeWithRetry handles ModelNotSupported without retry" {
    const allocator = std.testing.allocator;

    // Mock provider that returns ModelNotSupported error
    const MockProvider = struct {
        fn getApiKey(ctx: *anyopaque, config: Config) ?[]const u8 {
            _ = ctx;
            _ = config;
            return "test-key";
        }

        fn initProvider(alloc: std.mem.Allocator, api_key: []const u8) !*anyopaque {
            _ = alloc;
            _ = api_key;
            return @as(*anyopaque, @ptrCast(@alignCast(@constCast(&@as(u8, 0)))));
        }

        fn deinitProvider(provider: *anyopaque) void {
            _ = provider;
        }

        fn chatStream(
            provider: *anyopaque,
            messages: []const LlmMessage,
            model: []const u8,
            tools: []const ToolDefinition,
            chunk_callback: ChunkCallback,
            callback_ctx: ?*anyopaque,
        ) !LlmResponse {
            _ = provider;
            _ = messages;
            _ = model;
            _ = tools;
            _ = chunk_callback;
            _ = callback_ctx;
            return error.ModelNotSupported;
        }

        fn getProviderName() []const u8 {
            return "MockProvider";
        }
    };

    const interface: ProviderInterface = .{
        .ctx = undefined,
        .getApiKey = MockProvider.getApiKey,
        .initProvider = MockProvider.initProvider,
        .deinitProvider = MockProvider.deinitProvider,
        .chatStream = MockProvider.chatStream,
        .getProviderName = MockProvider.getProviderName,
    };

    const messages = [_]LlmMessage{.{ .role = "user", .content = "Hello" }};
    const tools: []const ToolDefinition = &[_]ToolDefinition{};

    const mockCallback = struct {
        fn callback(ctx: ?*anyopaque, chunk: []const u8) void {
            _ = ctx;
            _ = chunk;
        }
    }.callback;

    // Test that ModelNotSupported is returned immediately without retry
    const result = executeWithRetry(
        interface,
        allocator,
        .{ .providers = .{}, .agents = .{ .defaults = .{ .model = "test" } }, .tools = .{ .web = .{ .search = .{} } } },
        &messages,
        "test-model",
        tools,
        mockCallback,
        null,
    );

    try std.testing.expectError(OpenRouterError.ModelNotSupported, result);
}
