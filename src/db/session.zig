/// Session persistence module for saving and loading conversation history.
/// Stores conversations as JSON files in ~/.bots/sessions/
/// Each session is identified by a unique session ID.
const std = @import("std");
const base = @import("../providers/base.zig");

/// Session container for serialization.
/// Holds an array of messages to be saved/loaded from disk.
pub const Session = struct {
    messages: []base.LLMMessage,
};

/// Save conversation messages to a session file.
/// Creates the sessions directory if it doesn't exist.
/// File is saved as {session_id}.json in ~/.bots/sessions/
pub fn save(allocator: std.mem.Allocator, session_id: []const u8, messages: []const base.LLMMessage) !void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const session_dir = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions" });
    defer allocator.free(session_dir);

    std.fs.makeDirAbsolute(session_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ session_dir, filename });
    try saveToPath(allocator, path, messages);
}

/// Save messages to a specific file path.
/// Serializes messages to JSON format with indentation.
pub fn saveToPath(allocator: std.mem.Allocator, path: []const u8, messages: []const base.LLMMessage) !void {
    defer allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    const session: Session = .{ .messages = @constCast(messages) };

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(session, .{ .whitespace = .indent_2 }, &out.writer);

    try file.writeAll(out.written());
}

/// Load conversation messages from a session file.
/// Returns empty array if session file doesn't exist.
/// Caller owns the returned memory and must free it.
pub fn load(allocator: std.mem.Allocator, session_id: []const u8) ![]base.LLMMessage {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions", filename });
    return loadInternal(allocator, path);
}

/// Internal function to load messages from a file path.
/// Returns empty array if file not found.
fn loadInternal(allocator: std.mem.Allocator, path: []const u8) ![]base.LLMMessage {
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return &[_]base.LLMMessage{};
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10485760); // 10 * 1024 * 1024
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(Session, allocator, content, .{ .ignore_unknown_fields = true });
    // We need to dupe the messages because parsed will be deinitialized
    const msgs = try allocator.alloc(base.LLMMessage, parsed.value.messages.len);
    for (parsed.value.messages, 0..) |msg, i| {
        msgs[i] = .{
            .role = try allocator.dupe(u8, msg.role),
            .content = if (msg.content) |c| try allocator.dupe(u8, c) else null,
            .tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
            .tool_calls = if (msg.tool_calls) |calls| try dupeToolCalls(allocator, calls) else null,
        };
    }
    parsed.deinit();
    return msgs;
}

/// Deep copy tool calls array.
/// Creates independent copies of all tool call data.
fn dupeToolCalls(allocator: std.mem.Allocator, calls: []const base.ToolCall) ![]base.ToolCall {
    const new_calls = try allocator.alloc(base.ToolCall, calls.len);
    for (calls, 0..) |call, i| {
        new_calls[i] = .{
            .id = try allocator.dupe(u8, call.id),
            .type = try allocator.dupe(u8, call.type),
            .function = .{
                .name = try allocator.dupe(u8, call.function.name),
                .arguments = try allocator.dupe(u8, call.function.arguments),
            },
        };
    }
    return new_calls;
}

test "Session: save and load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "hello" },
        .{ .role = "assistant", .content = "hi" },
    };
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "test_session.json" });
    defer allocator.free(path);

    try saveToPath(allocator, try allocator.dupe(u8, path), messages);

    const loaded = try loadInternal(allocator, try allocator.dupe(u8, path));
    defer {
        for (loaded) |msg| {
            allocator.free(msg.role);
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    allocator.free(call.id);
                    allocator.free(call.type);
                    allocator.free(call.function.name);
                    allocator.free(call.function.arguments);
                }
                allocator.free(calls);
            }
        }
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("hello", loaded[0].content.?);
    try std.testing.expectEqualStrings("assistant", loaded[1].role);
    try std.testing.expectEqualStrings("hi", loaded[1].content.?);
}

test "Session: save and load with tool calls" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "test_tool", .arguments = "{\"arg\": \"value\"}" } },
    };

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Use the test tool" },
        .{
            .role = "assistant",
            .content = "I'll use the test tool",
            .tool_calls = tool_calls,
        },
        .{
            .role = "tool",
            .content = "Tool result",
            .tool_call_id = "call_1",
        },
    };

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "test_session_tools.json" });
    defer allocator.free(path);

    try saveToPath(allocator, try allocator.dupe(u8, path), messages);

    const loaded = try loadInternal(allocator, try allocator.dupe(u8, path));
    defer {
        for (loaded) |msg| {
            allocator.free(msg.role);
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |id| allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    allocator.free(call.id);
                    allocator.free(call.type);
                    allocator.free(call.function.name);
                    allocator.free(call.function.arguments);
                }
                allocator.free(calls);
            }
        }
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.len);

    // Check first message
    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("Use the test tool", loaded[0].content.?);

    // Check second message with tool calls
    try std.testing.expectEqualStrings("assistant", loaded[1].role);
    try std.testing.expectEqualStrings("I'll use the test tool", loaded[1].content.?);
    try std.testing.expect(loaded[1].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), loaded[1].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", loaded[1].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("test_tool", loaded[1].tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"arg\": \"value\"}", loaded[1].tool_calls.?[0].function.arguments);

    // Check third message (tool result)
    try std.testing.expectEqualStrings("tool", loaded[2].role);
    try std.testing.expectEqualStrings("Tool result", loaded[2].content.?);
    try std.testing.expectEqualStrings("call_1", loaded[2].tool_call_id.?);
}

test "Session: load non-existent file" {
    const allocator = std.testing.allocator;
    const loaded = try loadInternal(allocator, try allocator.dupe(u8, "/non/existent/path.json"));
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "Session: save and load empty messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const messages = &[_]base.LLMMessage{};
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "empty_session.json" });
    defer allocator.free(path);

    try saveToPath(allocator, try allocator.dupe(u8, path), messages);

    const loaded = try loadInternal(allocator, try allocator.dupe(u8, path));
    defer {
        for (loaded) |msg| {
            allocator.free(msg.role);
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    allocator.free(call.id);
                    allocator.free(call.type);
                    allocator.free(call.function.name);
                    allocator.free(call.function.arguments);
                }
                allocator.free(calls);
            }
        }
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "Session: dupeToolCalls function" {
    const allocator = std.testing.allocator;

    const original_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "func1", .arguments = "{\"a\": 1}" } },
        .{ .id = "call_2", .type = "function", .function = .{ .name = "func2", .arguments = "{\"b\": 2}" } },
    };

    const duped = try dupeToolCalls(allocator, original_calls);
    defer {
        for (duped) |call| {
            allocator.free(call.id);
            allocator.free(call.type);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(duped);
    }

    try std.testing.expectEqual(@as(usize, 2), duped.len);
    try std.testing.expectEqualStrings("call_1", duped[0].id);
    try std.testing.expectEqualStrings("func1", duped[0].function.name);
    try std.testing.expectEqualStrings("{\"a\": 1}", duped[0].function.arguments);
    try std.testing.expectEqualStrings("call_2", duped[1].id);
    try std.testing.expectEqualStrings("func2", duped[1].function.name);
    try std.testing.expectEqualStrings("{\"b\": 2}", duped[1].function.arguments);

    // Verify they are independent copies by checking different memory addresses
    try std.testing.expect(@intFromPtr(duped[0].id.ptr) != @intFromPtr(original_calls[0].id.ptr));
    try std.testing.expect(@intFromPtr(duped[0].function.name.ptr) != @intFromPtr(original_calls[0].function.name.ptr));
    try std.testing.expect(@intFromPtr(duped[0].function.arguments.ptr) != @intFromPtr(original_calls[0].function.arguments.ptr));
}
