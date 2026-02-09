const std = @import("std");
const http = @import("../http.zig");
const http_async = @import("../http_async.zig");
const base = @import("base.zig");
const AsyncEventLoop = @import("../agent/event_loop.zig").AsyncEventLoop;

/// OpenRouter API provider implementation.
/// OpenRouter provides a unified interface to multiple LLM models.
/// Compatible with OpenAI's API format.
/// Response structure from OpenRouter/OpenAI compatible API.
const CompletionResponse = struct {
    id: []const u8,
    model: []const u8,
    choices: []const Choice,
};

/// Choice containing the generated message.
const Choice = struct {
    message: Message,
};

/// Message in the response with optional content and tool calls.
const Message = struct {
    content: ?[]const u8 = null,
    role: []const u8,
    tool_calls: ?[]const ToolCallResponse = null,
};

/// Tool call response from the API.
const ToolCallResponse = struct {
    id: []const u8,
    type: []const u8,
    function: FunctionCallResponse,
};

/// Function call details within a tool call.
const FunctionCallResponse = struct {
    name: []const u8,
    arguments: []const u8,
};

/// Provider for OpenRouter API.
/// Supports chat completions, streaming, and embeddings.
pub const OpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    async_client: ?http_async.AsyncClient = null,
    api_key: []const u8,
    api_base: []const u8 = "https://openrouter.ai/api/v1",
    event_loop: ?*AsyncEventLoop = null,

    /// Initialize provider with API key.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    /// Initialize provider with API key and event loop for async operations.
    pub fn initWithEventLoop(allocator: std.mem.Allocator, api_key: []const u8, event_loop: *AsyncEventLoop) !OpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .async_client = try http_async.AsyncClient.init(allocator),
            .api_key = api_key,
            .event_loop = event_loop,
        };
    }

    /// Clean up provider resources.
    pub fn deinit(self: *OpenRouterProvider) void {
        self.client.deinit();
        if (self.async_client) |*client| client.deinit();
    }

    fn execPost(self: *OpenRouterProvider, url: []const u8, body: []const u8) ![]u8 {
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "satibot/1.0" },
        };

        const response = try self.client.post(url, headers, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok) {
            const display_err: []const u8 = response.body;
            const ErrorResponse = struct {
                @"error": struct {
                    message: []const u8,
                },
            };
            if (std.json.parseFromSlice(ErrorResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true })) |parsed_err| {
                defer parsed_err.deinit();
                // We need to dupe because parsed_err.deinit() will free the message
                const nice_msg = try self.allocator.dupe(u8, parsed_err.value.@"error".message);
                defer self.allocator.free(nice_msg);
                std.debug.print("[OpenRouter] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), nice_msg });
            } else |_| {
                std.debug.print("[OpenRouter] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), display_err });
            }
            return error.ApiRequestFailed;
        }

        if (response.rate_limit_remaining) |remaining| {
            if (response.rate_limit_limit) |limit| {
                std.debug.print("[OpenRouter] Rate Limit: {d}/{d}\n", .{ remaining, limit });
            }
        }

        return try self.allocator.dupe(u8, response.body);
    }

    /// Result of an async chat completion
    const ChatAsyncResult = struct {
        request_id: []const u8,
        success: bool,
        response: ?base.LLMResponse = null,
        err_msg: ?[]const u8 = null,

        pub fn deinit(self: *ChatAsyncResult) void {
            if (self.response) |resp| resp.deinit();
            if (self.err_msg) |err| self.allocator.free(err);
        }
    };

    /// Async chat completion using event loop
    pub fn chatAsync(self: *OpenRouterProvider, request_id: []const u8, messages: []const base.LLMMessage, model: []const u8, callback: *const fn (result: ChatAsyncResult) void) !void {
        if (self.async_client == null or self.event_loop == null) {
            return error.AsyncNotInitialized;
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});

        const payload = .{
            .model = model,
            .messages = messages,
        };

        const body = try std.json.stringifyAlloc(self.allocator, payload, .{});

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});

        const headers = try self.allocator.alloc(std.http.Header, 3);
        headers[0] = .{ .name = "Authorization", .value = auth_header };
        headers[1] = .{ .name = "Content-Type", .value = "application/json" };
        headers[2] = .{ .name = "User-Agent", .value = "satibot/1.0" };

        const wrapper = struct {
            provider: *OpenRouterProvider,
            original_callback: *const fn (result: ChatAsyncResult) void,

            fn httpResultCallback(wr: *const @This(), result: http_async.AsyncClient.AsyncResult) void {
                if (result.success) {
                    // Parse the response and create ChatResult
                    const parsed = std.json.parseFromSlice(CompletionResponse, wr.provider.allocator, result.response.?.body, .{ .ignore_unknown_fields = true }) catch |err| {
                        const error_result = ChatAsyncResult{
                            .request_id = result.request_id,
                            .success = false,
                            .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to parse response: {any}", .{err}) catch unreachable,
                        };
                        wr.original_callback(error_result);
                        return;
                    };
                    defer parsed.deinit();

                    if (parsed.value.choices.len == 0) {
                        const error_result = ChatAsyncResult{
                            .request_id = result.request_id,
                            .success = false,
                            .err_msg = std.fmt.allocPrint(wr.provider.allocator, "No choices returned", .{}) catch unreachable,
                        };
                        wr.original_callback(error_result);
                        return;
                    }

                    const msg = parsed.value.choices[0].message;

                    var tool_calls: ?[]base.ToolCall = null;
                    if (msg.tool_calls) |calls| {
                        tool_calls = wr.provider.allocator.alloc(base.ToolCall, calls.len) catch {
                            const error_result = ChatAsyncResult{
                                .request_id = result.request_id,
                                .success = false,
                                .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to allocate tool calls", .{}) catch unreachable,
                            };
                            wr.original_callback(error_result);
                            return;
                        };

                        var allocated: usize = 0;
                        errdefer {
                            for (0..allocated) |i| {
                                wr.provider.allocator.free(tool_calls.?[i].id);
                                wr.provider.allocator.free(tool_calls.?[i].function_name);
                                wr.provider.allocator.free(tool_calls.?[i].arguments);
                            }
                            wr.provider.allocator.free(tool_calls.?);
                        }

                        for (calls, 0..) |call, i| {
                            tool_calls.?[i] = .{
                                .id = wr.provider.allocator.dupe(u8, call.id) catch {
                                    const error_result = ChatAsyncResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to allocate tool call ID", .{}) catch unreachable,
                                    };
                                    wr.original_callback(error_result);
                                    return;
                                },
                                .function_name = wr.provider.allocator.dupe(u8, call.function.name) catch {
                                    const error_result = ChatAsyncResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to allocate function name", .{}) catch unreachable,
                                    };
                                    wr.original_callback(error_result);
                                    return;
                                },
                                .arguments = wr.provider.allocator.dupe(u8, call.function.arguments) catch {
                                    const error_result = ChatAsyncResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to allocate arguments", .{}) catch unreachable,
                                    };
                                    wr.original_callback(error_result);
                                    return;
                                },
                            };
                            allocated += 1;
                        }
                    }

                    const success_result = ChatAsyncResult{
                        .request_id = result.request_id,
                        .success = true,
                        .response = base.LLMResponse{
                            .content = if (msg.content) |c| wr.provider.allocator.dupe(u8, c) catch {
                                const error_result = ChatAsyncResult{
                                    .request_id = result.request_id,
                                    .success = false,
                                    .err_msg = std.fmt.allocPrint(wr.provider.allocator, "Failed to allocate content", .{}) catch unreachable,
                                };
                                wr.original_callback(error_result);
                                return;
                            } else null,
                            .tool_calls = tool_calls,
                            .allocator = wr.provider.allocator,
                        },
                    };
                    wr.original_callback(success_result);
                } else {
                    const error_result = ChatAsyncResult{
                        .request_id = result.request_id,
                        .success = false,
                        .err_msg = wr.provider.allocator.dupe(u8, result.err_msg.?),
                    };
                    wr.original_callback(error_result);
                }
            }
        };

        const wrapper_instance = wrapper{
            .provider = self,
            .original_callback = callback,
        };

        try self.async_client.?.postAsync(request_id, url, headers, body, &wrapper_instance.httpResultCallback, self.allocator);
    }

    pub fn chat(self: *OpenRouterProvider, messages: []const base.LLMMessage, model: []const u8) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
        };

        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const response_body = try self.execPost(url, body);
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(CompletionResponse, self.allocator, response_body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        std.debug.print("[Model: {s}]\n", .{parsed.value.model});

        if (parsed.value.choices.len == 0) {
            return error.NoChoicesReturned;
        }

        const msg = parsed.value.choices[0].message;

        var tool_calls: ?[]base.ToolCall = null;
        if (msg.tool_calls) |calls| {
            tool_calls = try self.allocator.alloc(base.ToolCall, calls.len);
            var allocated: usize = 0;
            errdefer {
                for (0..allocated) |i| {
                    self.allocator.free(tool_calls.?[i].id);
                    self.allocator.free(tool_calls.?[i].function_name);
                    self.allocator.free(tool_calls.?[i].arguments);
                }
                self.allocator.free(tool_calls.?);
            }
            for (calls, 0..) |call, i| {
                tool_calls.?[i] = .{
                    .id = try self.allocator.dupe(u8, call.id),
                    .function_name = try self.allocator.dupe(u8, call.function.name),
                    .arguments = try self.allocator.dupe(u8, call.function.arguments),
                };
                allocated += 1;
            }
        }

        return base.LLMResponse{
            .content = if (msg.content) |c| try self.allocator.dupe(u8, c) else null,
            .tool_calls = tool_calls,
            .allocator = self.allocator,
        };
    }

    pub fn chatStream(self: *OpenRouterProvider, messages: []const base.LLMMessage, model: []const u8, callback: base.ChunkCallback, cb_ctx: ?*anyopaque) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
            .stream = true,
        };

        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "satibot/1.0" },
        };

        var req = try self.client.postStream(url, headers, body);
        defer req.deinit();

        var head_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&head_buf);

        if (response.head.status != .ok) {
            var err_body = std.ArrayListUnmanaged(u8){};
            defer err_body.deinit(self.allocator);
            var err_reader = response.reader(&head_buf);
            var buf: [1024]u8 = undefined;
            while (true) {
                const n = try err_reader.read(&buf);
                if (n == 0) break;
                try err_body.appendSlice(self.allocator, buf[0..n]);
            }

            var display_err: []const u8 = err_body.items;
            const ErrorResponse = struct {
                @"error": struct {
                    message: []const u8,
                },
            };
            const parsed_err = std.json.parseFromSlice(ErrorResponse, self.allocator, err_body.items, .{ .ignore_unknown_fields = true }) catch null;
            defer if (parsed_err) |p| p.deinit();

            if (parsed_err) |p| {
                display_err = p.value.@"error".message;
            }

            const final_msg = try std.fmt.allocPrint(self.allocator, "API request failed with status {d}: {s}\n", .{ @intFromEnum(response.head.status), display_err });
            defer self.allocator.free(final_msg);

            std.debug.print("[OpenRouter] {s}", .{final_msg});
            // send message to user, example: "API request failed with status 429: Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day"
            callback(cb_ctx, final_msg);
            return error.ApiRequestFailed;
        }

        // Send rate limit info to user if available
        if (response.head.rate_limit_remaining) |remaining| {
            if (response.head.rate_limit_limit) |limit| {
                const limit_msg = try std.fmt.allocPrint(self.allocator, "📊 Rate Limit: {d}/{d}\n\n", .{ remaining, limit });
                defer self.allocator.free(limit_msg);
                callback(cb_ctx, limit_msg);
            }
        }

        var full_content = std.ArrayListUnmanaged(u8){};
        errdefer full_content.deinit(self.allocator);

        var response_body_buf: [8192]u8 = undefined;
        var reader = response.reader(&response_body_buf);

        // Tool calls are delivered in chunks
        var tool_calls_map = std.AutoHashMap(usize, struct {
            id: std.ArrayListUnmanaged(u8),
            name: std.ArrayListUnmanaged(u8),
            arguments: std.ArrayListUnmanaged(u8),
        }).init(self.allocator);
        defer {
            var it = tool_calls_map.valueIterator();
            while (it.next()) |call| {
                call.id.deinit(self.allocator);
                call.name.deinit(self.allocator);
                call.arguments.deinit(self.allocator);
            }
            tool_calls_map.deinit();
        }

        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        while_read: while (true) {
            var read_buf: [4096]u8 = undefined;
            const bytes_read = reader.readSliceShort(&read_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read == 0) break;

            try buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);

            while (true) {
                const newline_pos = std.mem.indexOfScalar(u8, buffer.items, '\n') orelse break;
                const line = buffer.items[0..newline_pos];
                const trimmed = std.mem.trimLeft(u8, line, " \r\n");

                if (trimmed.len > 0) {
                    if (std.mem.startsWith(u8, trimmed, "data: ")) {
                        const data = std.mem.trim(u8, trimmed[6..], " \r\n");
                        if (std.mem.eql(u8, data, "[DONE]")) {
                            break :while_read;
                        } else {
                            const ChunkResponse = struct {
                                choices: []struct {
                                    delta: struct {
                                        content: ?[]const u8 = null,
                                        tool_calls: ?[]struct {
                                            index: usize,
                                            id: ?[]const u8 = null,
                                            type: ?[]const u8 = null,
                                            function: ?struct {
                                                name: ?[]const u8 = null,
                                                arguments: ?[]const u8 = null,
                                            } = null,
                                        } = null,
                                    },
                                },
                            };

                            if (std.json.parseFromSlice(ChunkResponse, self.allocator, data, .{ .ignore_unknown_fields = true })) |parsed| {
                                defer parsed.deinit();
                                if (parsed.value.choices.len > 0) {
                                    const delta = parsed.value.choices[0].delta;
                                    if (delta.content) |content| {
                                        try full_content.appendSlice(self.allocator, content);
                                        callback(cb_ctx, content);
                                    }
                                    if (delta.tool_calls) |calls| {
                                        for (calls) |call| {
                                            var entry = try tool_calls_map.getOrPut(call.index);
                                            if (!entry.found_existing) {
                                                entry.value_ptr.* = .{
                                                    .id = std.ArrayListUnmanaged(u8){},
                                                    .name = std.ArrayListUnmanaged(u8){},
                                                    .arguments = std.ArrayListUnmanaged(u8){},
                                                };
                                            }
                                            if (call.id) |id| try entry.value_ptr.id.appendSlice(self.allocator, id);
                                            if (call.function) |f| {
                                                if (f.name) |n| try entry.value_ptr.name.appendSlice(self.allocator, n);
                                                if (f.arguments) |args| try entry.value_ptr.arguments.appendSlice(self.allocator, args);
                                            }
                                        }
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }
                try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
            }
        }

        // No child to wait for

        var final_tool_calls: ?[]base.ToolCall = null;
        if (tool_calls_map.count() > 0) {
            final_tool_calls = try self.allocator.alloc(base.ToolCall, tool_calls_map.count());
            var i: usize = 0;
            var it = tool_calls_map.iterator();
            while (it.next()) |entry| {
                final_tool_calls.?[i] = .{
                    .id = try entry.value_ptr.id.toOwnedSlice(self.allocator),
                    .function_name = try entry.value_ptr.name.toOwnedSlice(self.allocator),
                    .arguments = try entry.value_ptr.arguments.toOwnedSlice(self.allocator),
                };
                i += 1;
            }
        }

        return base.LLMResponse{
            .content = if (full_content.items.len > 0) try full_content.toOwnedSlice(self.allocator) else null,
            .tool_calls = final_tool_calls,
            .allocator = self.allocator,
        };
    }

    pub fn embeddings(self: *OpenRouterProvider, request: base.EmbeddingRequest) !base.EmbeddingResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/embeddings", .{self.api_base});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(body);

        const response_body = try self.execPost(url, body);
        defer self.allocator.free(response_body);

        const EmbeddingsData = struct {
            embedding: []f32,
        };
        const EmbeddingsResponse = struct {
            data: []EmbeddingsData,
        };

        const parsed = try std.json.parseFromSlice(EmbeddingsResponse, self.allocator, response_body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var result = try self.allocator.alloc([]const f32, parsed.value.data.len);
        var allocated: usize = 0;
        errdefer {
            for (0..allocated) |i| self.allocator.free(result[i]);
            self.allocator.free(result);
        }

        for (parsed.value.data, 0..) |item, i| {
            result[i] = try self.allocator.dupe(f32, item.embedding);
            allocated += 1;
        }

        return base.EmbeddingResponse{
            .embeddings = result,
            .allocator = self.allocator,
        };
    }
};

test "OpenRouter: parse response" {
    const allocator = std.testing.allocator;
    var provider = try OpenRouterProvider.init(allocator, "test-key");
    defer provider.deinit();

    // Since chat() is public and calls self.client.post, it's hard to test without mocking.
    // However, we can test the embedding structures or add a helper for parsing if we refactor.
    // For now, let's just test that it initializes correctly.
    try std.testing.expectEqualStrings("test-key", provider.api_key);
}

test "OpenRouter: struct definitions" {
    // Test FunctionCallResponse
    const func = FunctionCallResponse{
        .name = "test_function",
        .arguments = "{\"key\": \"value\"}",
    };
    try std.testing.expectEqualStrings("test_function", func.name);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", func.arguments);

    // Test ToolCallResponse
    const tool_call = ToolCallResponse{
        .id = "call_123",
        .type = "function",
        .function = func,
    };
    try std.testing.expectEqualStrings("call_123", tool_call.id);
    try std.testing.expectEqualStrings("function", tool_call.type);
    try std.testing.expectEqualStrings("test_function", tool_call.function.name);

    // Test Message
    const message = Message{
        .content = "Hello world",
        .role = "assistant",
        .tool_calls = null,
    };
    try std.testing.expectEqualStrings("Hello world", message.content.?);
    try std.testing.expectEqualStrings("assistant", message.role);
    try std.testing.expect(message.tool_calls == null);

    // Test Choice
    const choice = Choice{
        .message = message,
    };
    try std.testing.expectEqualStrings("Hello world", choice.message.content.?);

    // Test CompletionResponse
    const choices = &[_]Choice{choice};
    const completion = CompletionResponse{
        .id = "resp_123",
        .model = "gpt-4",
        .choices = choices,
    };
    try std.testing.expectEqualStrings("resp_123", completion.id);
    try std.testing.expectEqualStrings("gpt-4", completion.model);
    try std.testing.expectEqual(@as(usize, 1), completion.choices.len);
}

test "OpenRouter: init and deinit" {
    const allocator = std.testing.allocator;
    var provider = try OpenRouterProvider.init(allocator, "my-api-key-123");
    defer provider.deinit();

    try std.testing.expectEqual(allocator, provider.allocator);
    try std.testing.expectEqualStrings("my-api-key-123", provider.api_key);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", provider.api_base);
}

test "OpenRouter: Message with tool calls" {
    const tool_calls = &[_]ToolCallResponse{
        .{
            .id = "call_1",
            .type = "function",
            .function = .{
                .name = "get_weather",
                .arguments = "{\"location\": \"NYC\"}",
            },
        },
    };

    const message = Message{
        .content = "I'll check the weather",
        .role = "assistant",
        .tool_calls = tool_calls,
    };

    try std.testing.expectEqualStrings("I'll check the weather", message.content.?);
    try std.testing.expectEqualStrings("assistant", message.role);
    try std.testing.expect(message.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("get_weather", message.tool_calls.?[0].function.name);
}

test "OpenRouter: Multiple tool calls in message" {
    const tool_calls = &[_]ToolCallResponse{
        .{
            .id = "call_1",
            .type = "function",
            .function = .{
                .name = "search_web",
                .arguments = "{\"query\": \"zig lang\"}",
            },
        },
        .{
            .id = "call_2",
            .type = "function",
            .function = .{
                .name = "read_file",
                .arguments = "{\"path\": \"main.zig\"}",
            },
        },
    };

    const message = Message{
        .content = "I'll search and read",
        .role = "assistant",
        .tool_calls = tool_calls,
    };

    try std.testing.expectEqual(@as(usize, 2), message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("search_web", message.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("call_2", message.tool_calls.?[1].id);
    try std.testing.expectEqualStrings("read_file", message.tool_calls.?[1].function.name);
}

test "OpenRouter: CompletionResponse with multiple choices" {
    const messages = [_]Message{
        .{
            .content = "First response",
            .role = "assistant",
            .tool_calls = null,
        },
        .{
            .content = "Second response",
            .role = "assistant",
            .tool_calls = null,
        },
    };

    const choices = &[_]Choice{
        .{ .message = messages[0] },
        .{ .message = messages[1] },
    };

    const completion = CompletionResponse{
        .id = "resp_multi",
        .model = "claude-3",
        .choices = choices,
    };

    try std.testing.expectEqualStrings("resp_multi", completion.id);
    try std.testing.expectEqualStrings("claude-3", completion.model);
    try std.testing.expectEqual(@as(usize, 2), completion.choices.len);
    try std.testing.expectEqualStrings("First response", completion.choices[0].message.content.?);
    try std.testing.expectEqualStrings("Second response", completion.choices[1].message.content.?);
}

test "OpenRouter: Message with null content" {
    const tool_calls = &[_]ToolCallResponse{
        .{
            .id = "call_1",
            .type = "function",
            .function = .{
                .name = "compute",
                .arguments = "{\"x\": 1}",
            },
        },
    };

    const message = Message{
        .content = null,
        .role = "assistant",
        .tool_calls = tool_calls,
    };

    try std.testing.expect(message.content == null);
    try std.testing.expectEqualStrings("assistant", message.role);
    try std.testing.expect(message.tool_calls != null);
}
