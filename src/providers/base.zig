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
