const std = @import("std");
const base = @import("../providers/base.zig");

pub const Context = struct {
    messages: std.ArrayListUnmanaged(base.LLMMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .messages = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    self.allocator.free(call.id);
                    self.allocator.free(call.function_name);
                    self.allocator.free(call.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.messages.deinit(self.allocator);
    }

    pub fn add_message(self: *Context, msg: base.LLMMessage) !void {
        var new_msg = base.LLMMessage{
            .role = try self.allocator.dupe(u8, msg.role),
            .content = if (msg.content) |c| try self.allocator.dupe(u8, c) else null,
            .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
            .tool_calls = null,
        };

        if (msg.tool_calls) |calls| {
            const new_calls = try self.allocator.alloc(base.ToolCall, calls.len);
            for (calls, 0..) |call, i| {
                new_calls[i] = .{
                    .id = try self.allocator.dupe(u8, call.id),
                    .function_name = try self.allocator.dupe(u8, call.function_name),
                    .arguments = try self.allocator.dupe(u8, call.arguments),
                };
            }
            new_msg.tool_calls = new_calls;
        }

        try self.messages.append(self.allocator, new_msg);
    }

    pub fn get_messages(self: *Context) []const base.LLMMessage {
        return self.messages.items;
    }
};
