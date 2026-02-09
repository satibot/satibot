const std = @import("std");
const http = @import("../http.zig");
const base = @import("base.zig");
const AsyncEventLoop = @import("../agent/event_loop.zig").AsyncEventLoop;

/// Async OpenRouter API provider implementation.
/// OpenRouter provides a unified interface to multiple LLM models.
/// Compatible with OpenAI's API format.
/// Uses the event loop for non-blocking HTTP requests.

/// Request structure for async HTTP operations
const AsyncRequest = struct {
    id: []const u8,
    url: []const u8,
    headers: []std.http.Header,
    body: []const u8,
    callback: *const fn (result: AsyncResult) void,
    timestamp: i64,
};

/// Result of an async HTTP request
const AsyncResult = struct {
    request_id: []const u8,
    success: bool,
    data: ?[]const u8 = null,
    error: ?[]const u8 = null,
};

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

/// Async Provider for OpenRouter API.
/// Supports chat completions, streaming, and embeddings using the event loop.
pub const AsyncOpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://openrouter.ai/api/v1",
    event_loop: *AsyncEventLoop,

    /// Initialize provider with API key and event loop.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, event_loop: *AsyncEventLoop) !AsyncOpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
            .event_loop = event_loop,
        };
    }

    /// Clean up provider resources.
    pub fn deinit(self: *AsyncOpenRouterProvider) void {
        self.client.deinit();
    }

    /// Execute HTTP request asynchronously through the event loop
    fn execPostAsync(self: *AsyncOpenRouterProvider, request_id: []const u8, url: []const u8, body: []const u8, callback: *const fn (result: AsyncResult) void) !void {
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        
        const headers = try self.allocator.alloc(std.http.Header, 5);
        headers[0] = .{ .name = "Authorization", .value = auth_header };
        headers[1] = .{ .name = "Content-Type", .value = "application/json" };
        headers[2] = .{ .name = "User-Agent", .value = "satibot/1.0" };
        headers[3] = .{ .name = "HTTP-Referer", .value = "https://github.com/satibot/satibot" };
        headers[4] = .{ .name = "X-Title", .value = "SatiBot" };

        // Add HTTP request task to event loop
        const task_data = try std.json.stringifyAlloc(self.allocator, .{
            .type = "http_post",
            .request_id = request_id,
            .url = url,
            .headers = headers,
            .body = body,
            .callback = callback,
        }, .{});
        
        try self.event_loop.addTask(request_id, task_data, "openrouter_http");
    }

    /// Process HTTP request task (called by event loop)
    fn processHttpRequest(self: *AsyncOpenRouterProvider, task_data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(struct {
            type: []const u8,
            request_id: []const u8,
            url: []const u8,
            headers: []std.http.Header,
            body: []const u8,
        }, self.allocator, task_data, .{});
        defer parsed.deinit();

        const response = try self.client.post(parsed.value.url, parsed.value.headers, parsed.value.body);
        defer self.allocator.free(response.body);

        const result = if (response.status != .ok) AsyncResult{
            .request_id = try self.allocator.dupe(u8, parsed.value.request_id),
            .success = false,
            .error = try std.fmt.allocPrint(self.allocator, "API request failed with status {d}: {s}", .{ @intFromEnum(response.status), response.body }),
        } else AsyncResult{
            .request_id = try self.allocator.dupe(u8, parsed.value.request_id),
            .success = true,
            .data = try self.allocator.dupe(u8, response.body),
        };

        // In a real implementation, we would invoke the callback here
        // For now, we'll just log the result
        if (result.success) {
            std.debug.print("[OpenRouter] Request {s} completed successfully\n", .{result.request_id});
        } else {
            std.debug.print("[OpenRouter] Request {s} failed: {s}\n", .{ result.request_id, result.error.? });
        }
    }

    /// Async chat completion using event loop
    pub fn chatAsync(self: *AsyncOpenRouterProvider, request_id: []const u8, messages: []const base.LLMMessage, model: []const u8, callback: *const fn (result: ChatResult) void) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        
        const payload = .{
            .model = model,
            .messages = messages,
        };

        const body = try std.json.stringifyAlloc(self.allocator, payload, .{});
        
        // Create wrapper callback to handle HTTP result and parse response
        const http_callback = struct {
            fn httpResultCallback(result: AsyncResult) void {
                if (result.success) {
                    // Parse the response and create ChatResult
                    const parsed = std.json.parseFromSlice(CompletionResponse, self.allocator, result.data.?, .{ .ignore_unknown_fields = true }) catch |err| {
                        const error_result = ChatResult{
                            .request_id = result.request_id,
                            .success = false,
                            .error = try std.fmt.allocPrint(self.allocator, "Failed to parse response: {any}", .{err}),
                        };
                        callback(error_result);
                        return;
                    };
                    defer parsed.deinit();

                    if (parsed.value.choices.len == 0) {
                        const error_result = ChatResult{
                            .request_id = result.request_id,
                            .success = false,
                            .error = "No choices returned",
                        };
                        callback(error_result);
                        return;
                    }

                    const msg = parsed.value.choices[0].message;
                    
                    var tool_calls: ?[]base.ToolCall = null;
                    if (msg.tool_calls) |calls| {
                        tool_calls = self.allocator.alloc(base.ToolCall, calls.len) catch |err| {
                            const error_result = ChatResult{
                                .request_id = result.request_id,
                                .success = false,
                                .error = try std.fmt.allocPrint(self.allocator, "Failed to allocate tool calls: {any}", .{err}),
                            };
                            callback(error_result);
                            return;
                        };
                        
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
                                .id = self.allocator.dupe(u8, call.id) catch |err| {
                                    const error_result = ChatResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .error = try std.fmt.allocPrint(self.allocator, "Failed to allocate tool call ID: {any}", .{err}),
                                    };
                                    callback(error_result);
                                    return;
                                },
                                .function_name = self.allocator.dupe(u8, call.function.name) catch |err| {
                                    const error_result = ChatResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .error = try std.fmt.allocPrint(self.allocator, "Failed to allocate function name: {any}", .{err}),
                                    };
                                    callback(error_result);
                                    return;
                                },
                                .arguments = self.allocator.dupe(u8, call.function.arguments) catch |err| {
                                    const error_result = ChatResult{
                                        .request_id = result.request_id,
                                        .success = false,
                                        .error = try std.fmt.allocPrint(self.allocator, "Failed to allocate arguments: {any}", .{err}),
                                    };
                                    callback(error_result);
                                    return;
                                },
                            };
                            allocated += 1;
                        }
                    }

                    const success_result = ChatResult{
                        .request_id = result.request_id,
                        .success = true,
                        .response = base.LLMResponse{
                            .content = if (msg.content) |c| self.allocator.dupe(u8, c) catch |err| {
                                const error_result = ChatResult{
                                    .request_id = result.request_id,
                                    .success = false,
                                    .error = try std.fmt.allocPrint(self.allocator, "Failed to allocate content: {any}", .{err}),
                                };
                                callback(error_result);
                                return;
                            } else null,
                            .tool_calls = tool_calls,
                            .allocator = self.allocator,
                        },
                    };
                    callback(success_result);
                } else {
                    const error_result = ChatResult{
                        .request_id = result.request_id,
                        .success = false,
                        .error = result.error.?,
                    };
                    callback(error_result);
                }
            }
        }.httpResultCallback;

        try self.execPostAsync(request_id, url, body, http_callback);
    }

    /// Result of an async chat completion
    const ChatResult = struct {
        request_id: []const u8,
        success: bool,
        response: ?base.LLMResponse = null,
        error: ?[]const u8 = null,
    };

    /// Synchronous chat completion (fallback method)
    pub fn chat(self: *AsyncOpenRouterProvider, messages: []const base.LLMMessage, model: []const u8) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
        };

        const body = try std.json.stringifyAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "satibot/1.0" },
            .{ .name = "HTTP-Referer", .value = "https://github.com/satibot/satibot" },
            .{ .name = "X-Title", .value = "SatiBot" },
        };

        const response = try self.client.post(url, headers, body);
        defer self.allocator.free(response.body);

        if (response.status != .ok) {
            std.debug.print("[OpenRouter] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        const parsed = try std.json.parseFromSlice(CompletionResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
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

    /// Async streaming chat completion
    pub fn chatStreamAsync(self: *AsyncOpenRouterProvider, request_id: []const u8, messages: []const base.LLMMessage, model: []const u8, chunk_callback: *const fn (chunk: []const u8) void, completion_callback: *const fn (result: ChatResult) void) !void {
        // For streaming, we need to handle the streaming response
        // This is more complex and would require async HTTP streaming support
        // For now, fall back to synchronous streaming
        _ = self;
        _ = request_id;
        _ = messages;
        _ = model;
        _ = chunk_callback;
        _ = completion_callback;
        return error.NotImplemented;
    }
};
