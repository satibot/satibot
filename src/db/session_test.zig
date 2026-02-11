const std = @import("std");
const session = @import("session.zig");
const base = @import("../providers/base.zig");

test "Session: struct creation" {
    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Hello" },
        .{ .role = "assistant", .content = "Hi there!" },
    };

    const sess = session.Session{
        .messages = @constCast(messages),
    };

    try std.testing.expectEqual(@as(usize, 2), sess.messages.len);
    try std.testing.expectEqualStrings("user", sess.messages[0].role);
    try std.testing.expectEqualStrings("Hello", sess.messages[0].content.?);
    try std.testing.expectEqualStrings("assistant", sess.messages[1].role);
    try std.testing.expectEqualStrings("Hi there!", sess.messages[1].content.?);
}

test "Session: empty session" {
    const messages = &[_]base.LLMMessage{};

    const sess = session.Session{
        .messages = @constCast(messages),
    };

    try std.testing.expectEqual(@as(usize, 0), sess.messages.len);
}

test "saveToPath: basic functionality" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Test message" },
        .{ .role = "assistant", .content = "Test response" },
    };

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_save.json" });
    defer allocator.free(file_path);

    try session.saveToPath(allocator, try allocator.dupe(u8, file_path), messages);

    // Verify file was created and contains expected content
    const file_content = try tmp.dir.readFileAlloc(allocator, "test_save.json", 10240);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test response") != null);
}

test "saveToPath: empty messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const messages = &[_]base.LLMMessage{};

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_empty.json" });
    defer allocator.free(file_path);

    try session.saveToPath(allocator, try allocator.dupe(u8, file_path), messages);

    // Verify file was created
    const file_content = try tmp.dir.readFileAlloc(allocator, "test_empty.json", 10240);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "\"messages\": []") != null);
}

test "saveToPath: messages with null content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = null },
        .{ .role = "assistant", .content = "Has content" },
        .{ .role = "user", .content = null },
    };

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_null_content.json" });
    defer allocator.free(file_path);

    try session.saveToPath(allocator, try allocator.dupe(u8, file_path), messages);

    // Verify file was created
    const file_content = try tmp.dir.readFileAlloc(allocator, "test_null_content.json", 10240);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "\"content\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "\"content\": \"Has content\"") != null);
}

test "saveToPath: messages with tool calls" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_123", .type = "function", .function = .{ .name = "test_func", .arguments = "{\"arg\": \"value\"}" } },
    };

    const messages = &[_]base.LLMMessage{
        .{ .role = "assistant", .content = "I'll call a function", .tool_calls = tool_calls },
    };

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_tools.json" });
    defer allocator.free(file_path);

    try session.saveToPath(allocator, try allocator.dupe(u8, file_path), messages);

    // Verify file was created with tool call content
    const file_content = try tmp.dir.readFileAlloc(allocator, "test_tools.json", 10240);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "tool_calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "call_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "test_func") != null);
}

test "load_internal: basic load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test session file
    const session_json =
        \\{
        \\  "messages": [
        \\    {
        \\      "role": "user",
        \\      "content": "Hello world"
        \\    },
        \\    {
        \\      "role": "assistant", 
        \\      "content": "Hi back!"
        \\    }
        \\  ]
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "test_load.json", .data = session_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_load.json" });
    defer allocator.free(file_path);

    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, file_path));
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

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("Hello world", loaded[0].content.?);
    try std.testing.expectEqualStrings("assistant", loaded[1].role);
    try std.testing.expectEqualStrings("Hi back!", loaded[1].content.?);
}

test "load_internal: load with tool calls" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_json =
        \\{
        \\  "messages": [
        \\    {
        \\      "role": "assistant",
        \\      "content": "I'll use a tool",
        \\      "tool_calls": [
        \\        {
        \\          "id": "call_test",
        \\          "type": "function",
        \\          "function": {
        \\            "name": "test_function",
        \\            "arguments": "{\"param\": \"value\"}"
        \\          }
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "test_tools_load.json", .data = session_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_tools_load.json" });
    defer allocator.free(file_path);

    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, file_path));
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

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("assistant", loaded[0].role);
    try std.testing.expectEqualStrings("I'll use a tool", loaded[0].content.?);
    try std.testing.expect(loaded[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_test", loaded[0].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("test_function", loaded[0].tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"param\": \"value\"}", loaded[0].tool_calls.?[0].function.arguments);
}

test "load_internal: load with tool call id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_json =
        \\{
        \\  "messages": [
        \\    {
        \\      "role": "tool",
        \\      "content": "Tool result",
        \\      "tool_call_id": "call_abc"
        \\    }
        \\  ]
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "test_tool_id.json", .data = session_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_tool_id.json" });
    defer allocator.free(file_path);

    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, file_path));
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

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("tool", loaded[0].role);
    try std.testing.expectEqualStrings("Tool result", loaded[0].content.?);
    try std.testing.expectEqualStrings("call_abc", loaded[0].tool_call_id.?);
}

test "load_internal: load empty session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_json =
        \\{
        \\  "messages": []
        \\}
    ;

    try tmp.dir.writeFile(.{ .sub_path = "test_empty_load.json", .data = session_json });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_empty_load.json" });
    defer allocator.free(file_path);

    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, file_path));
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

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "load_internal: load non-existent file" {
    const allocator = std.testing.allocator;

    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, "/non/existent/file.json"));

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "dupe_tool_calls: single tool call" {
    const allocator = std.testing.allocator;

    const original_calls = &[_]base.ToolCall{
        .{ .id = "call_single", .type = "function", .function = .{ .name = "single_func", .arguments = "{}" } },
    };

    const duped = try session.dupe_tool_calls(allocator, original_calls);
    defer {
        for (duped) |call| {
            allocator.free(call.id);
            allocator.free(call.type);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(duped);
    }

    try std.testing.expectEqual(@as(usize, 1), duped.len);
    try std.testing.expectEqualStrings("call_single", duped[0].id);
    try std.testing.expectEqualStrings("function", duped[0].type);
    try std.testing.expectEqualStrings("single_func", duped[0].function.name);
    try std.testing.expectEqualStrings("{}", duped[0].function.arguments);
}

test "dupe_tool_calls: multiple tool calls" {
    const allocator = std.testing.allocator;

    const original_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "func_1", .arguments = "{\"a\": 1}" } },
        .{ .id = "call_2", .type = "function", .function = .{ .name = "func_2", .arguments = "{\"b\": 2}" } },
        .{ .id = "call_3", .type = "function", .function = .{ .name = "func_3", .arguments = "{\"c\": 3}" } },
    };

    const duped = try session.dupe_tool_calls(allocator, original_calls);
    defer {
        for (duped) |call| {
            allocator.free(call.id);
            allocator.free(call.type);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(duped);
    }

    try std.testing.expectEqual(@as(usize, 3), duped.len);

    for (original_calls, 0..) |original, i| {
        try std.testing.expectEqualStrings(original.id, duped[i].id);
        try std.testing.expectEqualStrings(original.type, duped[i].type);
        try std.testing.expectEqualStrings(original.function.name, duped[i].function.name);
        try std.testing.expectEqualStrings(original.function.arguments, duped[i].function.arguments);
    }
}

test "dupe_tool_calls: empty array" {
    const allocator = std.testing.allocator;

    const original_calls = &[_]base.ToolCall{};

    const duped = try session.dupe_tool_calls(allocator, original_calls);
    defer allocator.free(duped);

    try std.testing.expectEqual(@as(usize, 0), duped.len);
}

test "dupe_tool_calls: complex arguments" {
    const allocator = std.testing.allocator;

    const complex_args = 
        \\{
        \\  "param1": "value1",
        \\  "param2": 42,
        \\  "param3": [1, 2, 3],
        \\  "param4": {"nested": "object"}
        \\}
    ;

    const original_calls = &[_]base.ToolCall{
        .{ .id = "complex_call", .type = "function", .function = .{ .name = "complex_func", .arguments = complex_args } },
    };

    const duped = try session.dupe_tool_calls(allocator, original_calls);
    defer {
        for (duped) |call| {
            allocator.free(call.id);
            allocator.free(call.type);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(duped);
    }

    try std.testing.expectEqual(@as(usize, 1), duped.len);
    try std.testing.expectEqualStrings(complex_args, duped[0].function.arguments);
}

test "save and load: round trip with complex data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "search", .arguments = "{\"query\": \"test\"}" } },
        .{ .id = "call_2", .type = "function", .function = .{ .name = "calculate", .arguments = "{\"expression\": \"1+1\"}" } },
    };

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Search and calculate" },
        .{ .role = "assistant", .content = "I'll help you", .tool_calls = tool_calls },
        .{ .role = "tool", .content = "Search results", .tool_call_id = "call_1" },
        .{ .role = "tool", .content = "Calculation result", .tool_call_id = "call_2" },
        .{ .role = "assistant", .content = "Here are the results" },
    };

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "round_trip.json" });
    defer allocator.free(file_path);

    // Save
    try session.saveToPath(allocator, try allocator.dupe(u8, file_path), messages);

    // Load
    const loaded = try session.load_internal(allocator, try allocator.dupe(u8, file_path));
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

    // Verify round trip
    try std.testing.expectEqual(@as(usize, 5), loaded.len);

    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("Search and calculate", loaded[0].content.?);

    try std.testing.expectEqualStrings("assistant", loaded[1].role);
    try std.testing.expectEqualStrings("I'll help you", loaded[1].content.?);
    try std.testing.expectEqual(@as(usize, 2), loaded[1].tool_calls.?.len);

    try std.testing.expectEqualStrings("tool", loaded[2].role);
    try std.testing.expectEqualStrings("Search results", loaded[2].content.?);
    try std.testing.expectEqualStrings("call_1", loaded[2].tool_call_id.?);

    try std.testing.expectEqualStrings("tool", loaded[3].role);
    try std.testing.expectEqualStrings("Calculation result", loaded[3].content.?);
    try std.testing.expectEqualStrings("call_2", loaded[3].tool_call_id.?);

    try std.testing.expectEqualStrings("assistant", loaded[4].role);
    try std.testing.expectEqualStrings("Here are the results", loaded[4].content.?);
}
