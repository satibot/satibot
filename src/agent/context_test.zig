const std = @import("std");
const context = @import("context.zig");
const base = @import("../providers/base.zig");

test "Context: init and deinit" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), ctx.getMessages().len);
}

test "Context: addMessage with simple text" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const msg: base.LlmMessage = .{
        .role = "user",
        .content = "Hello world",
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    try ctx.addMessage(msg);
    
    const messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expectEqualStrings("Hello world", messages[0].content.?);
}

test "Context: addMessage with tool calls" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const tool_calls = try allocator.alloc(base.ToolCall, 1);
    defer {
        for (tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(tool_calls);
    }
    
    tool_calls[0] = .{
        .id = try allocator.dupe(u8, "call_123"),
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "test_func"),
            .arguments = try allocator.dupe(u8, "{\"arg\": \"value\"}"),
        },
    };
    
    const msg: base.LlmMessage = .{
        .role = "assistant",
        .content = "I'll use a tool",
        .tool_call_id = null,
        .tool_calls = tool_calls,
    };
    
    try ctx.addMessage(msg);
    
    const messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("assistant", messages[0].role);
    try std.testing.expectEqualStrings("I'll use a tool", messages[0].content.?);
    try std.testing.expect(messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_123", messages[0].tool_calls.?[0].id);
}

test "Context: addMessage with tool result" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const msg: base.LlmMessage = .{
        .role = "tool",
        .content = "Function executed successfully",
        .tool_call_id = "call_123",
        .tool_calls = null,
    };
    
    try ctx.addMessage(msg);
    
    const messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("tool", messages[0].role);
    try std.testing.expectEqualStrings("Function executed successfully", messages[0].content.?);
    try std.testing.expectEqualStrings("call_123", messages[0].tool_call_id.?);
}

test "Context: multiple messages" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const messages = &[_]base.LlmMessage{
        .{ .role = "system", .content = "You are a helpful assistant." },
        .{ .role = "user", .content = "Hello!" },
        .{ .role = "assistant", .content = "Hi there!" },
    };
    
    for (messages) |msg| {
        try ctx.addMessage(msg);
    }
    
    const ctx_messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 3), ctx_messages.len);
    try std.testing.expectEqualStrings("system", ctx_messages[0].role);
    try std.testing.expectEqualStrings("user", ctx_messages[1].role);
    try std.testing.expectEqualStrings("assistant", ctx_messages[2].role);
}

test "Context: message with all fields" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const tool_calls = try allocator.alloc(base.ToolCall, 2);
    defer {
        for (tool_calls) |call| {
            allocator.free(call.id);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(tool_calls);
    }
    
    tool_calls[0] = .{
        .id = try allocator.dupe(u8, "call_1"),
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "search"),
            .arguments = try allocator.dupe(u8, "{\"query\": \"test\"}"),
        },
    };
    
    tool_calls[1] = .{
        .id = try allocator.dupe(u8, "call_2"),
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "calculate"),
            .arguments = try allocator.dupe(u8, "{\"expr\": \"1+1\"}"),
        },
    };
    
    const msg: base.LlmMessage = .{
        .role = "assistant",
        .content = "I'll help you with that",
        .tool_call_id = null,
        .tool_calls = tool_calls,
    };
    
    try ctx.addMessage(msg);
    
    const ctx_messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 1), ctx_messages.len);
    try std.testing.expectEqualStrings("assistant", ctx_messages[0].role);
    try std.testing.expectEqualStrings("I'll help you with that", ctx_messages[0].content.?);
    try std.testing.expect(ctx_messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), ctx_messages[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", ctx_messages[0].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("call_2", ctx_messages[0].tool_calls.?[1].id);
}

test "Context: empty message" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    const msg: base.LlmMessage = .{
        .role = "user",
        .content = null,
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    try ctx.addMessage(msg);
    
    const messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].role);
    try std.testing.expect(messages[0].content == null);
}

test "Context: memory management" {
    const allocator = std.testing.allocator;
    
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();
    
    // Add many messages to test memory management
    for (0..100) |i| {
        const content = try std.fmt.allocPrint(allocator, "Message {d}", .{i});
        defer allocator.free(content);
        
        const msg: base.LlmMessage = .{
            .role = "user",
            .content = content,
            .tool_call_id = null,
            .tool_calls = null,
        };
        
        try ctx.addMessage(msg);
    }
    
    const messages = ctx.getMessages();
    try std.testing.expectEqual(@as(usize, 100), messages.len);
    
    // Verify first and last messages
    try std.testing.expectEqualStrings("Message 0", messages[0].content.?);
    try std.testing.expectEqualStrings("Message 99", messages[99].content.?);
}
