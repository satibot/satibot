const std = @import("std");
const http = @import("http");
const base = @import("base.zig");
const core = @import("core");
const Config = core.config.Config;

const MessageResponse = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    content: []const ContentBlock,
    stop_reason: ?[]const u8 = null,
};

const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const MinimaxMessage = struct {
    role: []const u8,
    content: MinimaxContent,
};

const MinimaxContent = union(enum) {
    text: []const u8,
    blocks: []const MinimaxContentBlock,
};

const MinimaxContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const MinimaxProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://api.minimax.io/anthropic",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !MinimaxProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *MinimaxProvider) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn chat(self: *MinimaxProvider, messages: []const base.LlmMessage, model: []const u8, tools: ?[]const base.ToolDefinition) !base.LlmResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/messages", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildRequestBody(messages, model, tools, false);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            const display_err: []const u8 = response.body;
            const ErrorResponse = struct {
                @"error": struct {
                    message: []const u8,
                },
            };
            if (std.json.parseFromSlice(ErrorResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true })) |parsed_err| {
                defer parsed_err.deinit();
                const nice_msg = try self.allocator.dupe(u8, parsed_err.value.@"error".message);
                defer self.allocator.free(nice_msg);
                std.debug.print("[Minimax] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), nice_msg });
            } else |_| {
                std.debug.print("[Minimax] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), display_err });
            }
            return error.ApiRequestFailed;
        }

        return self.parseResponse(response.body);
    }

    pub fn chatStream(self: *MinimaxProvider, messages: []const base.LlmMessage, model: []const u8, tools: ?[]const base.ToolDefinition, callback: base.ChunkCallback, cb_ctx: ?*anyopaque) !base.LlmResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/messages", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildRequestBody(messages, model, tools, true);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var req = try self.client.postStream(url, headers, body);
        defer req.deinit();

        var head_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&head_buf);

        if (response.head.status != .ok) {
            var err_body: std.ArrayList(u8) = .empty;
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

            const final_msg = try std.fmt.allocPrint(self.allocator, "Minimax API request failed with status {d}: {s}\n", .{ @intFromEnum(response.head.status), display_err });
            defer self.allocator.free(final_msg);

            std.debug.print("[Minimax] {s}", .{final_msg});
            callback(cb_ctx, final_msg);
            return error.ApiRequestFailed;
        }

        var full_content: std.ArrayList(u8) = .empty;
        errdefer full_content.deinit(self.allocator);

        var thinking_content: std.ArrayList(u8) = .empty;
        errdefer thinking_content.deinit(self.allocator);

        var response_body_buf: [8192]u8 = undefined;
        var reader = response.reader(&response_body_buf);

        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        var tool_calls: std.ArrayList(base.ToolCall) = .empty;
        errdefer {
            for (tool_calls.items) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.type);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            tool_calls.deinit(self.allocator);
        }

        var current_tool_call_index: ?usize = null;

        while (true) {
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
                const trimmed = std.mem.trim(u8, line, " \r\n");

                if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, "data: ")) {
                    const data = trimmed[6..];

                    const StreamEvent = struct {
                        type: []const u8,
                        delta: ?struct {
                            type: ?[]const u8 = null,
                            thinking: ?[]const u8 = null,
                            text: ?[]const u8 = null,
                            partial_json: ?[]const u8 = null,
                        } = null,
                        content_block: ?struct {
                            type: []const u8,
                            id: ?[]const u8 = null,
                            name: ?[]const u8 = null,
                        } = null,
                        index: ?usize = null,
                    };

                    const parsed = std.json.parseFromSlice(StreamEvent, self.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
                        std.debug.print("Failed to parse stream event: {any} Data: {s}\n", .{ err, data });
                        try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
                        continue;
                    };
                    defer parsed.deinit();

                    const event = parsed.value;

                    if (std.mem.eql(u8, event.type, "content_block_delta")) {
                        if (event.delta) |delta| {
                            if (delta.thinking) |thinking| {
                                try thinking_content.appendSlice(self.allocator, thinking);
                                callback(cb_ctx, thinking);
                            }
                            if (delta.text) |text| {
                                try full_content.appendSlice(self.allocator, text);
                                callback(cb_ctx, text);
                            }
                            if (delta.partial_json) |partial| {
                                if (current_tool_call_index) |idx| {
                                    const existing = tool_calls.items[idx];
                                    const new_args = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing.function.arguments, partial });
                                    self.allocator.free(existing.function.arguments);
                                    tool_calls.items[idx].function.arguments = new_args;
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, event.type, "content_block_start")) {
                        if (event.content_block) |block| {
                            if (std.mem.eql(u8, block.type, "tool_use")) {
                                current_tool_call_index = tool_calls.items.len;
                                try tool_calls.append(self.allocator, .{
                                    .id = try self.allocator.dupe(u8, block.id orelse ""),
                                    .type = "function",
                                    .function = .{
                                        .name = try self.allocator.dupe(u8, block.name orelse ""),
                                        .arguments = try self.allocator.dupe(u8, ""),
                                    },
                                });
                            }
                        }
                    } else if (std.mem.eql(u8, event.type, "content_block_stop")) {
                        current_tool_call_index = null;
                    } else if (std.mem.eql(u8, event.type, "message_stop")) {}
                }
                try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
            }
        }

        const result_tool_calls: ?[]base.ToolCall = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(self.allocator) else null;

        return .{
            .content = if (full_content.items.len > 0) try full_content.toOwnedSlice(self.allocator) else null,
            .tool_calls = result_tool_calls,
            .allocator = self.allocator,
        };
    }

    fn buildRequestBody(self: *MinimaxProvider, messages: []const base.LlmMessage, model: []const u8, tools: ?[]const base.ToolDefinition, stream: bool) ![]u8 {
        var system_prompt: ?[]const u8 = null;
        var minimax_messages: std.ArrayList(MinimaxMessage) = .empty;
        defer minimax_messages.deinit(self.allocator);

        var content_blocks_storage: std.ArrayList([]const MinimaxContentBlock) = .empty;
        defer {
            for (content_blocks_storage.items) |blocks| {
                self.allocator.free(blocks);
            }
            content_blocks_storage.deinit(self.allocator);
        }

        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                system_prompt = msg.content;
            } else if (std.mem.eql(u8, msg.role, "tool")) {
                const blocks = try self.allocator.alloc(MinimaxContentBlock, 1);
                blocks[0] = .{
                    .type = "tool_result",
                    .tool_use_id = msg.tool_call_id,
                    .content = msg.content,
                };
                try content_blocks_storage.append(self.allocator, blocks);

                try minimax_messages.append(self.allocator, .{
                    .role = "user",
                    .content = .{ .blocks = blocks },
                });
            } else {
                try minimax_messages.append(self.allocator, .{
                    .role = msg.role,
                    .content = .{ .text = msg.content orelse "" },
                });
            }
        }

        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        const writer = json_buf.writer(self.allocator);

        try writer.writeAll("{");
        try writer.print("\"model\": \"{s}\",", .{model});
        try writer.writeAll("\"max_tokens\": 4096,");

        if (stream) {
            try writer.writeAll("\"stream\": true,");
        }

        if (system_prompt) |sys| {
            try writer.print("\"system\": \"{s}\",", .{sys});
        }

        if (tools) |t_list| {
            if (t_list.len > 0) {
                try writer.writeAll("\"tools\": [");
                for (t_list, 0..) |t, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.writeAll("{");
                    try writer.print("\"name\": \"{s}\",", .{t.name});
                    try writer.print("\"description\": \"{s}\",", .{t.description});
                    try writer.writeAll("\"input_schema\": ");
                    try writer.writeAll(t.parameters);
                    try writer.writeAll("}");
                }
                try writer.writeAll("],");
            }
        }

        try writer.writeAll("\"messages\": [");
        for (minimax_messages.items, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"role\": \"{s}\",", .{msg.role});
            try writer.writeAll("\"content\": ");

            switch (msg.content) {
                .text => |t| {
                    try writer.writeAll("\"");
                    for (t) |c| {
                        switch (c) {
                            '"' => try writer.writeAll("\\\""),
                            '\\' => try writer.writeAll("\\\\"),
                            '\n' => try writer.writeAll("\\n"),
                            '\r' => try writer.writeAll("\\r"),
                            '\t' => try writer.writeAll("\\t"),
                            else => try writer.writeByte(c),
                        }
                    }
                    try writer.writeAll("\"");
                },
                .blocks => |blocks| {
                    try writer.writeAll("[");
                    for (blocks, 0..) |block, j| {
                        if (j > 0) try writer.writeAll(",");
                        try writer.writeAll("{");
                        try writer.print("\"type\": \"{s}\"", .{block.type});
                        if (block.tool_use_id) |id| {
                            try writer.print(",\"tool_use_id\": \"{s}\"", .{id});
                        }
                        if (block.content) |content| {
                            try writer.writeAll(",\"content\": \"");
                            for (content) |c| {
                                switch (c) {
                                    '"' => try writer.writeAll("\\\""),
                                    '\\' => try writer.writeAll("\\\\"),
                                    '\n' => try writer.writeAll("\\n"),
                                    '\r' => try writer.writeAll("\\r"),
                                    '\t' => try writer.writeAll("\\t"),
                                    else => try writer.writeByte(c),
                                }
                            }
                            try writer.writeAll("\"");
                        }
                        try writer.writeAll("}");
                    }
                    try writer.writeAll("]");
                },
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        try writer.writeAll("}");

        return json_buf.toOwnedSlice(self.allocator);
    }

    fn parseResponse(self: *MinimaxProvider, body: []const u8) !base.LlmResponse {
        const parsed = try std.json.parseFromSlice(MessageResponse, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const msg = parsed.value;

        var text_content: std.ArrayList(u8) = .empty;
        errdefer text_content.deinit(self.allocator);

        var tool_calls: std.ArrayList(base.ToolCall) = .empty;
        errdefer {
            for (tool_calls.items) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.type);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            tool_calls.deinit(self.allocator);
        }

        for (msg.content) |block| {
            if (std.mem.eql(u8, block.type, "text")) {
                if (block.text) |t| {
                    try text_content.appendSlice(self.allocator, t);
                }
            } else if (std.mem.eql(u8, block.type, "thinking")) {
                if (block.thinking) |t| {
                    try text_content.appendSlice(self.allocator, t);
                }
            } else if (std.mem.eql(u8, block.type, "tool_use")) {
                const args = if (block.input) |input|
                    try std.json.Stringify.valueAlloc(self.allocator, input, .{})
                else
                    try self.allocator.dupe(u8, "{}");

                try tool_calls.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, block.id orelse ""),
                    .type = "function",
                    .function = .{
                        .name = try self.allocator.dupe(u8, block.name orelse ""),
                        .arguments = args,
                    },
                });
            }
        }

        const result_content: ?[]u8 = if (text_content.items.len > 0) try text_content.toOwnedSlice(self.allocator) else null;
        const result_tool_calls: ?[]base.ToolCall = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(self.allocator) else null;

        return .{
            .content = result_content,
            .tool_calls = result_tool_calls,
            .allocator = self.allocator,
        };
    }
};

test "Minimax: parseResponse" {
    const allocator = std.testing.allocator;
    var provider = try MinimaxProvider.init(allocator, "test-key");
    defer provider.deinit();

    const response_json =
        \\{
        \\  "id": "msg_123",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    { "type": "text", "text": "Hello!" },
        \\    { "type": "tool_use", "id": "tool_1", "name": "test_tool", "input": {"arg": 1} }
        \\  ]
        \\}
    ;

    var response = try provider.parseResponse(response_json);
    defer response.deinit();

    try std.testing.expectEqualStrings("Hello!", response.content.?);
    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("tool_1", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("test_tool", response.tool_calls.?[0].function.name);
}

test "Minimax: parseResponse with thinking" {
    const allocator = std.testing.allocator;
    var provider = try MinimaxProvider.init(allocator, "test-key");
    defer provider.deinit();

    const response_json =
        \\{
        \\  "id": "msg_456",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    { "type": "thinking", "thinking": "Let me think about this..." },
        \\    { "type": "text", "text": "Hello!" }
        \\  ]
        \\}
    ;

    var response = try provider.parseResponse(response_json);
    defer response.deinit();

    try std.testing.expect(response.content != null);
    try std.testing.expect(std.mem.indexOf(u8, response.content.?, "Let me think") != null);
}

test "Minimax: init and deinit" {
    const allocator = std.testing.allocator;
    var provider = try MinimaxProvider.init(allocator, "my-api-key");
    defer provider.deinit();

    try std.testing.expectEqual(allocator, provider.allocator);
    try std.testing.expectEqualStrings("my-api-key", provider.api_key);
    try std.testing.expectEqualStrings("https://api.minimax.io/anthropic", provider.api_base);
}

test "Minimax: buildRequestBody with simple message" {
    const allocator = std.testing.allocator;
    var provider = try MinimaxProvider.init(allocator, "test-key");
    defer provider.deinit();

    const messages = &[_]base.LlmMessage{
        .{ .role = "user", .content = "Hello!" },
    };

    const body = try provider.buildRequestBody(messages, "MiniMax-M2.5", null, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\": \"MiniMax-M2.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\": 4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\": \"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Hello!") != null);
}

fn getApiKey(ctx: *anyopaque, config: Config) ?[]const u8 {
    _ = ctx;
    return if (config.providers.minimax) |p| p.apiKey else std.posix.getenv("MINIMAX_API_KEY");
}

fn initProvider(allocator: std.mem.Allocator, api_key: []const u8) !*anyopaque {
    const provider = try allocator.create(MinimaxProvider);
    provider.* = try MinimaxProvider.init(allocator, api_key);
    return provider;
}

fn deinitProvider(provider: *anyopaque) void {
    const minimax_provider: *MinimaxProvider = @ptrCast(@alignCast(provider));
    const allocator = minimax_provider.allocator;
    minimax_provider.deinit();
    allocator.destroy(minimax_provider);
}

fn chatStream(
    provider: *anyopaque,
    messages: []const base.LlmMessage,
    model: []const u8,
    tools: []const base.ToolDefinition,
    chunk_callback: base.ChunkCallback,
    callback_ctx: ?*anyopaque,
) !base.LlmResponse {
    const minimax_provider: *MinimaxProvider = @ptrCast(@alignCast(provider));
    return minimax_provider.chatStream(messages, model, tools, chunk_callback, callback_ctx);
}

fn getProviderName() []const u8 {
    return "Minimax";
}

pub fn createInterface() base.ProviderInterface {
    return .{
        .ctx = undefined,
        .getApiKey = getApiKey,
        .initProvider = initProvider,
        .deinitProvider = deinitProvider,
        .chatStream = chatStream,
        .getProviderName = getProviderName,
    };
}
