const std = @import("std");
const base = @import("../providers/base.zig");

pub const Session = struct {
    messages: []base.LLMMessage,
};

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

pub fn saveToPath(allocator: std.mem.Allocator, path: []const u8, messages: []const base.LLMMessage) !void {
    defer allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    const session = Session{ .messages = @constCast(messages) };

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(session, .{ .whitespace = .indent_2 }, &out.writer);

    try file.writeAll(out.written());
}

pub fn load(allocator: std.mem.Allocator, session_id: []const u8) ![]base.LLMMessage {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions", filename });
    return load_internal(allocator, path);
}

fn load_internal(allocator: std.mem.Allocator, path: []const u8) ![]base.LLMMessage {
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
            .tool_calls = if (msg.tool_calls) |calls| try dupe_tool_calls(allocator, calls) else null,
        };
    }
    parsed.deinit();
    return msgs;
}

fn dupe_tool_calls(allocator: std.mem.Allocator, calls: []const base.ToolCall) ![]base.ToolCall {
    const new_calls = try allocator.alloc(base.ToolCall, calls.len);
    for (calls, 0..) |call, i| {
        new_calls[i] = .{
            .id = try allocator.dupe(u8, call.id),
            .function_name = try allocator.dupe(u8, call.function_name),
            .arguments = try allocator.dupe(u8, call.arguments),
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

    const loaded = try load_internal(allocator, try allocator.dupe(u8, path));
    defer {
        for (loaded) |msg| {
            allocator.free(msg.role);
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    allocator.free(call.id);
                    allocator.free(call.function_name);
                    allocator.free(call.arguments);
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
