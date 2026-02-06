/// Conversation context management module.
/// Stores and manages conversation history (messages) for agent interactions.
/// Messages are stored in memory and can be serialized to/from JSON for persistence.
///
/// Storage location: ~/.bots/sessions/
/// Using a shared directory like ~/.bots/ allows sharing memory and config
/// across different bot instances while keeping the user's home directory clean.
/// It prevents conflicts with other "bot" frameworks and allows storing
/// project-specific data (like config.json or vector_db) in the same root folder.
///
/// File format: JSON - ideal for conversation history because:
/// - Structured data: Conversations contain roles (user, assistant, tool, system),
///   tool calls, tool results, and metadata. JSON handles this nesting naturally.
/// - Easy parsing: Zig's std.json makes serialization/deserialization trivial.
/// - Interoperability: JSON is the universal language for web UIs and dashboards.
const std = @import("std");
const base = @import("../providers/base.zig");

/// Context manages a list of conversation messages.
/// Provides methods to add messages and retrieve conversation history.
pub const Context = struct {
    messages: std.ArrayListUnmanaged(base.LLMMessage),
    allocator: std.mem.Allocator,

    /// Initialize a new empty conversation context.
    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .messages = .{},
            .allocator = allocator,
        };
    }

    /// Clean up all messages and free allocated memory.
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

    /// Add a message to the conversation context.
    /// Creates deep copies of all strings to ensure memory safety.
    /// Handles both regular messages and messages with tool calls.
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

    /// Get all messages in the conversation as a slice.
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

test "Context: multiple messages" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Add multiple messages
    try ctx.add_message(.{ .role = "system", .content = "You are a helpful assistant." });
    try ctx.add_message(.{ .role = "user", .content = "Hello!" });
    try ctx.add_message(.{ .role = "assistant", .content = "Hi there!" });
    try ctx.add_message(.{ .role = "user", .content = "How are you?" });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);

    try std.testing.expectEqualStrings("system", messages[0].role);
    try std.testing.expectEqualStrings("You are a helpful assistant.", messages[0].content.?);

    try std.testing.expectEqualStrings("user", messages[1].role);
    try std.testing.expectEqualStrings("Hello!", messages[1].content.?);

    try std.testing.expectEqualStrings("assistant", messages[2].role);
    try std.testing.expectEqualStrings("Hi there!", messages[2].content.?);

    try std.testing.expectEqualStrings("user", messages[3].role);
    try std.testing.expectEqualStrings("How are you?", messages[3].content.?);
}

test "Context: message with null content" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.add_message(.{
        .role = "tool",
        .tool_call_id = "call_123",
        .content = null,
    });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("tool", messages[0].role);
    try std.testing.expect(messages[0].content == null);
    try std.testing.expectEqualStrings("call_123", messages[0].tool_call_id.?);
}

test "Context: multiple tool calls" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .function_name = "search_web", .arguments = "{\"query\": \"zig\"}" },
        .{ .id = "call_2", .function_name = "read_file", .arguments = "{\"path\": \"test.zig\"}" },
        .{ .id = "call_3", .function_name = "write_file", .arguments = "{\"path\": \"out.txt\", \"content\": \"hello\"}" },
    };

    try ctx.add_message(.{
        .role = "assistant",
        .content = "I'll help you with that.",
        .tool_calls = tool_calls,
    });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(@as(usize, 3), messages[0].tool_calls.?.len);

    try std.testing.expectEqualStrings("call_1", messages[0].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("search_web", messages[0].tool_calls.?[0].function_name);
    try std.testing.expectEqualStrings("{\"query\": \"zig\"}", messages[0].tool_calls.?[0].arguments);

    try std.testing.expectEqualStrings("call_2", messages[0].tool_calls.?[1].id);
    try std.testing.expectEqualStrings("read_file", messages[0].tool_calls.?[1].function_name);

    try std.testing.expectEqualStrings("call_3", messages[0].tool_calls.?[2].id);
    try std.testing.expectEqualStrings("write_file", messages[0].tool_calls.?[2].function_name);
}

test "Context: empty context" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 0), messages.len);
}

test "Context: message with all fields" {
    const allocator = std.testing.allocator;
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_abc", .function_name = "test_func", .arguments = "{\"arg\": \"value\"}" },
    };

    try ctx.add_message(.{
        .role = "assistant",
        .content = "I'm calling a tool",
        .tool_call_id = null,
        .tool_calls = tool_calls,
    });

    const messages = ctx.get_messages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("assistant", messages[0].role);
    try std.testing.expectEqualStrings("I'm calling a tool", messages[0].content.?);
    try std.testing.expect(messages[0].tool_call_id == null);
    try std.testing.expect(messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[0].tool_calls.?.len);
}
