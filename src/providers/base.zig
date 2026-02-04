const std = @import("std");
const Config = @import("../config.zig").Config;

pub const LLMMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};

pub const ToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments: []const u8,
};

pub const LLMResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LLMResponse) void {
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
pub const EmbeddingResponse = struct {
    embeddings: [][]const f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EmbeddingResponse) void {
        for (self.embeddings) |e| {
            self.allocator.free(e);
        }
        self.allocator.free(self.embeddings);
    }
};

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
