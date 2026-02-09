/// Base types and structures for LLM provider interactions.
/// Defines common message formats, tool call structures, and response types
/// used across all LLM provider implementations (Anthropic, OpenRouter, Groq).
const std = @import("std");
const Config = @import("../config.zig").Config;

/// Callback function for streaming response chunks.
/// Takes a context pointer and the chunk content.
pub const ChunkCallback = *const fn (ctx: ?*anyopaque, chunk: []const u8) void;

/// Message in a conversation with an LLM.
/// Can represent messages from user, assistant, system, or tool results.
pub const LLMMessage = struct {
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
pub const LLMResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    allocator: std.mem.Allocator,

    /// Free all allocated memory in the response.
    pub fn deinit(self: *LLMResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            self.allocator.free(calls);
        }
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
    }
};

/// Request to generate embeddings for a list of text inputs.
pub const EmbeddingRequest = struct {
    input: []const []const u8,
    model: []const u8,
};

test "LLMResponse: deinit" {
    const allocator = std.testing.allocator;
    var resp = LLMResponse{
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

    var resp = EmbeddingResponse{
        .embeddings = embeddings,
        .allocator = allocator,
    };
    resp.deinit();
}

test "LLMMessage: creation" {
    const msg = LLMMessage{
        .role = "user",
        .content = "hello",
    };

    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("hello", msg.content.?);
    try std.testing.expect(msg.tool_call_id == null);
    try std.testing.expect(msg.tool_calls == null);
}

test "LLMMessage: with tool calls" {
    const tool_calls = &[_]ToolCall{
        .{ .id = "call_1", .function = .{ .name = "test_func", .arguments = "{\"arg\": \"value\"}" } },
    };

    const msg = LLMMessage{
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

test "LLMMessage: tool result message" {
    const msg = LLMMessage{
        .role = "tool",
        .content = "Tool output",
        .tool_call_id = "call_123",
    };

    try std.testing.expectEqualStrings("tool", msg.role);
    try std.testing.expectEqualStrings("Tool output", msg.content.?);
    try std.testing.expectEqualStrings("call_123", msg.tool_call_id.?);
    try std.testing.expect(msg.tool_calls == null);
}

test "ToolCall: struct fields" {
    const call = ToolCall{
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

test "LLMResponse: creation with content only" {
    const allocator = std.testing.allocator;
    var resp = LLMResponse{
        .content = try allocator.dupe(u8, "Hello world"),
        .tool_calls = null,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("Hello world", resp.content.?);
    try std.testing.expect(resp.tool_calls == null);
}

test "LLMResponse: creation with tool calls only" {
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

    var resp = LLMResponse{
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

test "LLMResponse: creation with both content and tool calls" {
    const allocator = std.testing.allocator;

    const calls = try allocator.alloc(ToolCall, 1);
    calls[0] = .{
        .id = try allocator.dupe(u8, "call_1"),
        .function = .{
            .name = try allocator.dupe(u8, "func1"),
            .arguments = try allocator.dupe(u8, "{}"),
        },
    };

    var resp = LLMResponse{
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

    var resp = EmbeddingResponse{
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

    const req = EmbeddingRequest{
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

    const req = EmbeddingRequest{
        .input = input,
        .model = "text-embedding-3-small",
    };

    try std.testing.expectEqual(@as(usize, 0), req.input.len);
    try std.testing.expectEqualStrings("text-embedding-3-small", req.model);
}

test "EmbeddingResponse: empty embeddings" {
    const allocator = std.testing.allocator;
    const embeddings = try allocator.alloc([]const f32, 0);

    var resp = EmbeddingResponse{
        .embeddings = embeddings,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 0), resp.embeddings.len);
}

test "LLMResponse: empty content and no tool calls" {
    const allocator = std.testing.allocator;

    var resp = LLMResponse{
        .content = null,
        .tool_calls = null,
        .allocator = allocator,
    };
    defer resp.deinit();

    try std.testing.expect(resp.content == null);
    try std.testing.expect(resp.tool_calls == null);
}
