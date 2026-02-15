const std = @import("std");
const agent = @import("agent.zig");
const Config = @import("config.zig").Config;

test "Agent: print_chunk function" {
    // Test that print_chunk doesn't crash
    const test_chunk = "Hello, world!";
    agent.print_chunk(null, test_chunk);

    // If we get here without crashing, the test passes
    try std.testing.expect(true);
}

test "Agent: struct field initialization" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const test_session_id = "test-session";
    var test_agent = try agent.Agent.init(allocator, parsed.value, test_session_id, true);
    defer test_agent.deinit();

    try std.testing.expectEqualStrings(test_session_id, test_agent.session_id);
    try std.testing.expectEqual(allocator, test_agent.allocator);
    try std.testing.expectEqual(parsed.value, test_agent.config);
    try std.testing.expect(test_agent.on_chunk == null);
    try std.testing.expect(test_agent.chunk_ctx == null);
    try std.testing.expect(test_agent.last_chunk == null);
    try std.testing.expect(test_agent.shutdown_flag == null);
}

test "Agent: init with minimal config" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "minimal-test", true);
    defer test_agent.deinit();

    // Should initialize without errors
    try std.testing.expectEqualStrings("minimal-test", test_agent.session_id);

    // Should have vector tools registered
    try std.testing.expect(test_agent.registry.get("vector_upsert") != null);
    try std.testing.expect(test_agent.registry.get("vector_search") != null);
}

test "Agent: init with web search API key" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "test-api-key" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "web-search-test", true);
    defer test_agent.deinit();

    // Should still have vector tools registered
    try std.testing.expect(test_agent.registry.get("vector_upsert") != null);
    try std.testing.expect(test_agent.registry.get("vector_search") != null);
}

test "Agent: ensure_system_prompt adds system message" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "system-prompt-test", true);
    defer test_agent.deinit();

    // Initially should not have system message (unless loaded from session)
    const initial_messages = test_agent.ctx.get_messages();
    _ = initial_messages; // We don't need to check this, just ensure it doesn't crash

    // Ensure system prompt exists
    try test_agent.ensure_system_prompt();

    // Should now have system message
    const messages = test_agent.ctx.get_messages();
    var found_system = false;
    for (messages) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) {
            found_system = true;
            try std.testing.expect(std.mem.indexOf(u8, msg.content.?, "satibot") != null);
            try std.testing.expect(std.mem.indexOf(u8, msg.content.?, "Vector Database") != null);
            break;
        }
    }
    try std.testing.expectEqual(true, found_system);
}

test "Agent: ensure_system_prompt doesn't duplicate" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "no-duplicate-test", true);
    defer test_agent.deinit();

    // Add a system message manually
    try test_agent.ctx.add_message(.{ .role = "system", .content = "Existing system prompt" });

    // Call ensure_system_prompt
    try test_agent.ensure_system_prompt();

    // Should still only have one system message
    const messages = test_agent.ctx.get_messages();
    var system_count: usize = 0;
    for (messages) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) {
            system_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), system_count);
}

test "Agent: context operations" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "context-test", true);
    defer test_agent.deinit();

    // Add messages to context
    try test_agent.ctx.add_message(.{ .role = "user", .content = "Hello" });
    try test_agent.ctx.add_message(.{ .role = "assistant", .content = "Hi there!" });
    try test_agent.ctx.add_message(.{ .role = "user", .content = "How are you?" });

    const messages = test_agent.ctx.get_messages();
    try std.testing.expect(messages.len >= 3);

    // Check the last few messages
    if (messages.len >= 3) {
        try std.testing.expectEqualStrings("user", messages[messages.len - 3].role);
        try std.testing.expectEqualStrings("Hello", messages[messages.len - 3].content.?);
        try std.testing.expectEqualStrings("assistant", messages[messages.len - 2].role);
        try std.testing.expectEqualStrings("Hi there!", messages[messages.len - 2].content.?);
        try std.testing.expectEqualStrings("user", messages[messages.len - 1].role);
        try std.testing.expectEqualStrings("How are you?", messages[messages.len - 1].content.?);
    }
}

test "Agent: tool registry functionality" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "registry-test", true);
    defer test_agent.deinit();

    // Test vector_upsert tool
    const vector_upsert_tool = test_agent.registry.get("vector_upsert");
    try std.testing.expect(vector_upsert_tool != null);
    try std.testing.expectEqualStrings("vector_upsert", vector_upsert_tool.?.name);
    try std.testing.expect(std.mem.indexOf(u8, vector_upsert_tool.?.description, "vector database") != null);
    try std.testing.expect(std.mem.indexOf(u8, vector_upsert_tool.?.parameters, "text") != null);

    // Test vector_search tool
    const vector_search_tool = test_agent.registry.get("vector_search");
    try std.testing.expect(vector_search_tool != null);
    try std.testing.expectEqualStrings("vector_search", vector_search_tool.?.name);
    try std.testing.expect(std.mem.indexOf(u8, vector_search_tool.?.description, "similar content") != null);
    try std.testing.expect(std.mem.indexOf(u8, vector_search_tool.?.parameters, "query") != null);

    // Test non-existent tool
    const non_existent_tool = test_agent.registry.get("non_existent_tool");
    try std.testing.expect(non_existent_tool == null);
}

test "Agent: chunk callback functionality" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "chunk-test", true);
    defer test_agent.deinit();

    // Test setting chunk callback with global state
    const CallbackState = struct {
        var called: bool = false;
        var data: []const u8 = "";

        fn call(ctx: ?*anyopaque, chunk: []const u8) void {
            _ = ctx;
            called = true;
            data = chunk;
        }
    };

    test_agent.on_chunk = CallbackState.call;
    test_agent.chunk_ctx = null;

    // Simulate chunk processing
    const test_chunk = "Test chunk content";
    if (test_agent.on_chunk) |cb| {
        cb(test_agent.chunk_ctx, test_chunk);
    }

    try std.testing.expectEqual(true, CallbackState.called);
    try std.testing.expectEqualStrings(test_chunk, CallbackState.data);
}

test "Agent: shutdown flag functionality" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "shutdown-test", true);
    defer test_agent.deinit();

    // Test with shutdown flag
    var shutdown_flag = std.atomic.Value(bool).init(false);
    test_agent.shutdown_flag = &shutdown_flag;

    try std.testing.expectEqual(&shutdown_flag, test_agent.shutdown_flag);
    try std.testing.expectEqual(false, test_agent.shutdown_flag.?.load(.seq_cst));

    // Set shutdown flag
    shutdown_flag.store(true, .seq_cst);
    try std.testing.expectEqual(true, test_agent.shutdown_flag.?.load(.seq_cst));
}

test "Agent: last_chunk tracking" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "last-chunk-test");
    defer test_agent.deinit();

    // Initially should be null
    try std.testing.expect(test_agent.last_chunk == null);

    // Test that the internal callback updates last_chunk
    const internal_cb = struct {
        fn call(ctx: ?*anyopaque, chunk: []const u8) void {
            const a: *agent.Agent = @ptrCast(@alignCast(ctx orelse return));
            if (a.last_chunk) |old| a.allocator.free(old);
            a.last_chunk = a.allocator.dupe(u8, chunk) catch null;
        }
    }.call;

    const test_chunk = "Test chunk for last_chunk";
    internal_cb(&test_agent, test_chunk);

    try std.testing.expect(test_agent.last_chunk != null);
    try std.testing.expectEqualStrings(test_chunk, test_agent.last_chunk.?);
}

test "Agent: indexConversation with disableRag" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "disableRag": true
        \\    }
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "rag-disabled-test", true);
    defer test_agent.deinit();

    // Add some messages to the context
    try test_agent.ctx.add_message(.{ .role = "user", .content = "What is Zig?" });
    try test_agent.ctx.add_message(.{ .role = "assistant", .content = "Zig is a programming language." });

    // Should not error even with RAG disabled
    try test_agent.indexConversation();
}

test "Agent: indexConversation with insufficient messages" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "insufficient-msgs-test", true);
    defer test_agent.deinit();

    // Add only one message
    try test_agent.ctx.add_message(.{ .role = "user", .content = "Hello" });

    // Should not error with insufficient messages
    try test_agent.indexConversation();
}

test "Agent: memory management in deinit" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "memory-test", true);

    // Add some data that needs cleanup
    try test_agent.ctx.add_message(.{ .role = "user", .content = "Test message" });

    // Set last_chunk to simulate chunk processing
    const test_chunk = try allocator.dupe(u8, "Test chunk");
    test_agent.last_chunk = test_chunk;

    // Deinit should clean up all allocated memory
    test_agent.deinit();

    // If we get here without memory leaks, test passes
    try std.testing.expect(true);
}

test "Agent: tool context creation" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var test_agent = try agent.Agent.init(allocator, parsed.value, "tool-context-test", true);
    defer test_agent.deinit();

    // The tool context is created internally during run, but we can verify
    // the agent has the necessary components for tool context creation
    try std.testing.expectEqual(allocator, test_agent.allocator);
    try std.testing.expectEqual(parsed.value, test_agent.config);
}

test "Agent: session ID handling" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const session_ids = [_][]const u8{
        "simple-session",
        "session_with_123",
        "session-with-dashes",
        "session_with_underscores_and_123",
    };

    for (session_ids) |session_id| {
        var test_agent = try agent.Agent.init(allocator, parsed.value, session_id, true);
        defer test_agent.deinit();

        try std.testing.expectEqualStrings(session_id, test_agent.session_id);
    }
}

test "Agent: configuration integration" {
    const allocator = std.testing.allocator;

    const configs = [_][]const u8{
        // Minimal config
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
        ,
        // Config with embedding model
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "embeddingModel": "local"
        \\    }
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
        ,
        // Config with providers
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {
        \\    "openrouter": { "apiKey": "test-key" }
        \\  },
        \\  "tools": { "web": { "search": {} } }
        \\}
        ,
    };

    for (configs) |config_json| {
        const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var test_agent = try agent.Agent.init(allocator, parsed.value, "config-test", true);
        defer test_agent.deinit();

        // Should initialize successfully with different config variations
        try std.testing.expectEqual(parsed.value, test_agent.config);
    }
}
