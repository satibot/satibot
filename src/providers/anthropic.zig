const std = @import("std");
const http = @import("../http.zig");
const base = @import("base.zig");

// Response structures for Anthropic Messages API
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
    // For tool_use blocks
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

// Request message structure for Anthropic
const AnthropicMessage = struct {
    role: []const u8,
    content: AnthropicContent,
};

const AnthropicContent = union(enum) {
    text: []const u8,
    blocks: []const AnthropicContentBlock,
};

const AnthropicContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const AnthropicProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://api.anthropic.com/v1",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !AnthropicProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *AnthropicProvider) void {
        self.client.deinit();
    }

    pub fn chat(self: *AnthropicProvider, messages: []const base.LLMMessage, model: []const u8) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/messages", .{self.api_base});
        defer self.allocator.free(url);

        // Convert messages to Anthropic format and build request body
        const body = try self.buildRequestBody(messages, model, false);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("Anthropic API Error: {d} {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        return self.parseResponse(response.body);
    }

    pub fn chatStream(self: *AnthropicProvider, messages: []const base.LLMMessage, model: []const u8, callback: *const fn (chunk: []const u8) void) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/messages", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildRequestBody(messages, model, true);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var req = try self.client.postStream(url, headers, body);
        defer req.deinit();

        var head_buf: [4096]u8 = undefined;
        // TODO
        var response = try req.receiveHead(&head_buf);

        if (response.head.status != .ok) {
            return error.ApiRequestFailed;
        }

        var full_content = std.ArrayListUnmanaged(u8){};
        errdefer full_content.deinit(self.allocator);

        var response_body_buf: [8192]u8 = undefined;
        var reader = response.reader(&response_body_buf);

        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        // Track tool calls from content_block_start/delta events
        var tool_calls = std.ArrayListUnmanaged(base.ToolCall){};
        errdefer {
            for (tool_calls.items) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.function_name);
                self.allocator.free(call.arguments);
            }
            tool_calls.deinit(self.allocator);
        }

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

                    // Anthropic streaming events
                    const StreamEvent = struct {
                        type: []const u8,
                        delta: ?struct {
                            type: ?[]const u8 = null,
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
                            if (delta.text) |text| {
                                try full_content.appendSlice(self.allocator, text);
                                callback(text);
                            }
                        }
                    } else if (std.mem.eql(u8, event.type, "content_block_start")) {
                        if (event.content_block) |block| {
                            if (std.mem.eql(u8, block.type, "tool_use")) {
                                try tool_calls.append(self.allocator, .{
                                    .id = try self.allocator.dupe(u8, block.id orelse ""),
                                    .function_name = try self.allocator.dupe(u8, block.name orelse ""),
                                    .arguments = try self.allocator.dupe(u8, ""),
                                });
                            }
                        }
                    } else if (std.mem.eql(u8, event.type, "message_stop")) {
                        // End of message
                    }
                }
                try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
            }
        }

        const result_tool_calls: ?[]base.ToolCall = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(self.allocator) else null;

        return base.LLMResponse{
            .content = if (full_content.items.len > 0) try full_content.toOwnedSlice(self.allocator) else null,
            .tool_calls = result_tool_calls,
            .allocator = self.allocator,
        };
    }

    fn buildRequestBody(self: *AnthropicProvider, messages: []const base.LLMMessage, model: []const u8, stream: bool) ![]u8 {
        // Anthropic uses a different message format
        // - system message goes in "system" field
        // - messages array contains only user/assistant turns
        // - tool results are sent as user messages with tool_result content blocks

        var system_prompt: ?[]const u8 = null;
        var anthropic_messages = std.ArrayListUnmanaged(AnthropicMessage){};
        defer anthropic_messages.deinit(self.allocator);

        // We need to allocate content blocks for tool_result messages
        var content_blocks_storage = std.ArrayListUnmanaged([]const AnthropicContentBlock){};
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
                // Tool results in Anthropic are sent as user messages with tool_result content blocks
                const blocks = try self.allocator.alloc(AnthropicContentBlock, 1);
                blocks[0] = .{
                    .type = "tool_result",
                    .tool_use_id = msg.tool_call_id,
                    .content = msg.content,
                };
                try content_blocks_storage.append(self.allocator, blocks);

                try anthropic_messages.append(self.allocator, .{
                    .role = "user",
                    .content = .{ .blocks = blocks },
                });
            } else {
                try anthropic_messages.append(self.allocator, .{
                    .role = msg.role,
                    .content = .{ .text = msg.content orelse "" },
                });
            }
        }

        // Build the request using a custom approach since we need dynamic struct
        var json_buf = std.ArrayListUnmanaged(u8){};
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

        try writer.writeAll("\"messages\": [");
        for (anthropic_messages.items, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"role\": \"{s}\",", .{msg.role});
            try writer.writeAll("\"content\": ");

            switch (msg.content) {
                .text => |t| {
                    // Escape the text for JSON
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

        return try json_buf.toOwnedSlice(self.allocator);
    }

    fn parseResponse(self: *AnthropicProvider, body: []const u8) !base.LLMResponse {
        const parsed = try std.json.parseFromSlice(MessageResponse, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const msg = parsed.value;

        var text_content = std.ArrayListUnmanaged(u8){};
        errdefer text_content.deinit(self.allocator);

        var tool_calls = std.ArrayListUnmanaged(base.ToolCall){};
        errdefer {
            for (tool_calls.items) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.function_name);
                self.allocator.free(call.arguments);
            }
            tool_calls.deinit(self.allocator);
        }

        for (msg.content) |block| {
            if (std.mem.eql(u8, block.type, "text")) {
                if (block.text) |t| {
                    try text_content.appendSlice(self.allocator, t);
                }
            } else if (std.mem.eql(u8, block.type, "tool_use")) {
                const args = if (block.input) |input|
                    try std.json.Stringify.valueAlloc(self.allocator, input, .{})
                else
                    try self.allocator.dupe(u8, "{}");

                try tool_calls.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, block.id orelse ""),
                    .function_name = try self.allocator.dupe(u8, block.name orelse ""),
                    .arguments = args,
                });
            }
        }

        const result_content: ?[]u8 = if (text_content.items.len > 0) try text_content.toOwnedSlice(self.allocator) else null;
        const result_tool_calls: ?[]base.ToolCall = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(self.allocator) else null;

        return base.LLMResponse{
            .content = result_content,
            .tool_calls = result_tool_calls,
            .allocator = self.allocator,
        };
    }
};

test "Anthropic: parseResponse" {
    const allocator = std.testing.allocator;
    var provider = try AnthropicProvider.init(allocator, "test-key");
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
    try std.testing.expectEqualStrings("test_tool", response.tool_calls.?[0].function_name);
}
