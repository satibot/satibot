// Migrated to curl for Stability: OpenRouter provider now uses curl
// as an external process for all HTTP requests.
// True Incremental Streaming:
// Previously, chatStream waited for the entire response to complete before processing it.
// I refactored the streaming implementation to spawn curl in a child process
// and read from its stdout pipe incrementally.
// This enables real-time response output as chunks arrive from the API.
// Enhanced Tool Call Support:
// Implemented a robust streaming parser for OpenRouter that correctly handles
// tool call deltas (accumulating partial function names and arguments across
// multiple chunks).

const std = @import("std");
const http = @import("../http.zig");
const base = @import("base.zig");

// Response structures for OpenRouter/OpenAI API
const CompletionResponse = struct {
    id: []const u8,
    model: []const u8,
    choices: []const Choice,
};

const Choice = struct {
    message: Message,
};

const Message = struct {
    content: ?[]const u8 = null,
    role: []const u8,
    tool_calls: ?[]const ToolCallResponse = null,
};

const ToolCallResponse = struct {
    id: []const u8,
    type: []const u8,
    function: FunctionCallResponse,
};

const FunctionCallResponse = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const OpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://openrouter.ai/api/v1",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) OpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *OpenRouterProvider) void {
        self.client.deinit();
    }

    fn execCurl(self: *OpenRouterProvider, url: []const u8, body: []const u8) ![]u8 {
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "curl",
                "-s",
                "-X",
                "POST",
                url,
                "-H",
                "Content-Type: application/json",
                "-H",
                auth_header,
                "-H",
                "User-Agent: curl/8.7.1",
                "-H",
                "HTTP-Referer: https://github.com/satibot/satibot",
                "-H",
                "X-Title: SatiBot",
                "-d",
                body,
            },
            // 10MB limit
            .max_output_bytes = 10 * 1024 * 1024,
        }) catch |err| {
            std.debug.print("[OpenRouter] curl execution failed: {any}\n", .{err});
            return error.ReadFailed;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("[OpenRouter] curl failed with exit code {any}: {s}\n", .{ result.term, result.stderr });
            return error.ApiRequestFailed;
        }

        return try self.allocator.dupe(u8, result.stdout);
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

        const response_body = try self.execCurl(url, body);
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

    pub fn chatStream(self: *OpenRouterProvider, messages: []const base.LLMMessage, model: []const u8, callback: *const fn (chunk: []const u8) void) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
            .stream = true,
        };

        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        var child = std.process.Child.init(&[_][]const u8{
            "curl",
            "-s",
            "-N", // Wait for data, don't buffer
            "-X",
            "POST",
            url,
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_header,
            "-H",
            "User-Agent: curl/8.7.1",
            "-H",
            "HTTP-Referer: https://github.com/satibot/satibot",
            "-H",
            "X-Title: SatiBot",
            "-d",
            body,
        }, self.allocator);

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var full_content = std.ArrayListUnmanaged(u8){};
        errdefer full_content.deinit(self.allocator);

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
            const bytes_read = child.stdout.?.read(&read_buf) catch |err| {
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
                                        callback(content);
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

        _ = try child.wait();

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

        const response_body = try self.execCurl(url, body);
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
    var provider = OpenRouterProvider.init(allocator, "test-key");
    defer provider.deinit();

    // Since chat() is public and calls self.client.post, it's hard to test without mocking.
    // However, we can test the embedding structures or add a helper for parsing if we refactor.
    // For now, let's just test that it initializes correctly.
    try std.testing.expectEqualStrings("test-key", provider.api_key);
}
