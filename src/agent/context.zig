// Conversation history

// Where: ~/.bots/sessions/
// Using a shared directory like ~/.bots/ allows sharing memory and config
// across different bot instances.

// It keeps the user's home directory clean.
// It prevents conflicts with other "bot" frameworks.
// It allows you to store other project-specific data (like config.json or vector_db)
// in the same root folder.
// 2. File Type: .json (JSON)
// JSON is the ideal file type for conversation history in an agent framework because:

// Structured Data: Conversations aren't just text; they contain roles
// (user, assistant, tool, system), tool calls, tool results, and metadata
// (model used, timestamps). JSON handles this nesting naturally.
// Easy Parsing: Zig’s std.json makes it trivial to serialize and deserialize
// the LLMMessage structs directly.
// Interoperability: If you ever want to build a web UI or a dashboard for
// your bot, JSON is the universal language for the web.

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

test "Context: init and add_message" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.add_message(.{
        .role = "user",
        .content = "hello",
    });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expectEqualStrings("hello", messages[0].content.?);
}

test "Context: tool calls" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const tool_calls = &[_]base.ToolCall{
        .{
            .id = "call_1",
            .function_name = "test_tool",
            .arguments = "{}",
        },
    };

    try ctx.add_message(.{
        .role = "assistant",
        .content = "thinking",
        .tool_calls = tool_calls,
    });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", messages[0].tool_calls.?[0].id);
}
