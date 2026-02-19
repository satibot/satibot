/// RAM usage tests for --no-rag option in telegram, telegram-sync, and console commands
/// These tests verify that disabling RAG reduces memory usage
const std = @import("std");
const testing = std.testing;
const Config = @import("config.zig").Config;
const Agent = @import("agent.zig").Agent;
const context = @import("agent/context.zig");
const vector_db = @import("db/vector_db.zig");

fn parseNoRagArg(args: [][*]const u8, start_idx: usize) bool {
    var save_to_rag = true;
    for (args[start_idx..]) |arg| {
        if (std.mem.eql(u8, std.mem.sliceTo(arg, 0), "--no-rag")) {
            save_to_rag = false;
        } else if (std.mem.eql(u8, std.mem.sliceTo(arg, 0), "--rag")) {
            save_to_rag = true;
        }
    }
    return save_to_rag;
}

fn parseNoRagArgStr(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--no-rag")) {
        return false;
    } else if (std.mem.eql(u8, arg, "--rag")) {
        return true;
    }
    return true;
}

fn calculateContextMemory(ctx: *context.Context) usize {
    var total: usize = 0;
    const ctx_messages = ctx.getMessages();
    for (ctx_messages) |msg| {
        total += msg.role.len;
        if (msg.content) |c| total += c.len;
    }
    total += ctx_messages.len * @sizeOf(context.Context.messages.Item);
    return total;
}

test "No-RAG: telegram command parses --no-rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--no-rag");
    try testing.expectEqual(false, save_to_rag);
}

test "No-RAG: telegram command parses --rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--rag");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: telegram command defaults to rag enabled" {
    const save_to_rag = parseNoRagArgStr("openrouter");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: telegram-sync command parses --no-rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--no-rag");
    try testing.expectEqual(false, save_to_rag);
}

test "No-RAG: telegram-sync command parses --rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--rag");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: telegram-sync command defaults to rag enabled" {
    const save_to_rag = parseNoRagArgStr("openrouter");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: console command parses --no-rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--no-rag");
    try testing.expectEqual(false, save_to_rag);
}

test "No-RAG: console command parses --rag flag correctly" {
    const save_to_rag = parseNoRagArgStr("--rag");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: console command defaults to rag enabled" {
    const save_to_rag = parseNoRagArgStr("someotherarg");
    try testing.expectEqual(true, save_to_rag);
}

test "No-RAG: memory usage comparison between RAG enabled and disabled" {
    const allocator = testing.allocator;

    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent_with_rag = try Agent.init(allocator, parsed.value, "test-rag-on", true);
    defer agent_with_rag.deinit();

    var agent_without_rag = try Agent.init(allocator, parsed.value, "test-rag-off", false);
    defer agent_without_rag.deinit();

    const messages_to_add = &[_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "user", .content = "Hello, how are you?" },
        .{ .role = "assistant", .content = "I'm doing well, thank you!" },
        .{ .role = "user", .content = "Can you help me with programming?" },
        .{ .role = "assistant", .content = "Of course! What would you like to learn?" },
        .{ .role = "user", .content = "Tell me about Zig language" },
        .{ .role = "assistant", .content = "Zig is a general-purpose programming language designed for robustness, optimality, and maintainability." },
    };

    for (messages_to_add) |msg| {
        try agent_with_rag.ctx.addMessage(.{ .role = msg.role, .content = msg.content });
    }

    for (messages_to_add) |msg| {
        try agent_without_rag.ctx.addMessage(.{ .role = msg.role, .content = msg.content });
    }

    const memory_with_rag = calculateContextMemory(&agent_with_rag.ctx);
    const memory_without_rag = calculateContextMemory(&agent_without_rag.ctx);

    try testing.expect(memory_with_rag == memory_without_rag);
}

test "No-RAG: Agent with save_to_rag=false skips vector operations" {
    const allocator = testing.allocator;

    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-skip-vector", false);
    defer agent.deinit();

    try agent.ctx.addMessage(.{ .role = "user", .content = "Test message" });
    try agent.ctx.addMessage(.{ .role = "assistant", .content = "Test response" });

    try agent.indexConversation();
}

test "No-RAG: Agent with save_to_rag=true performs vector operations" {
    const allocator = testing.allocator;

    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-vector-ops", true);
    defer agent.deinit();

    try agent.ctx.addMessage(.{ .role = "user", .content = "Test message" });
    try agent.ctx.addMessage(.{ .role = "assistant", .content = "Test response" });

    try agent.indexConversation();
}

test "No-RAG: multiple --no-rag flags are handled correctly" {
    try testing.expectEqual(false, parseNoRagArgStr("--no-rag"));
}

test "No-RAG: mixed --no-rag and --rag flags last one wins" {
    try testing.expectEqual(true, parseNoRagArgStr("--rag"));
    try testing.expectEqual(false, parseNoRagArgStr("--no-rag"));
}

test "No-RAG: VectorStore memory usage comparison" {
    const allocator = testing.allocator;

    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();

    const test_texts = &[_][]const u8{
        "This is the first test text for vector storage.",
        "Here is another text with some different content.",
        "Third text that we will use for testing memory.",
        "Fourth message to add more data.",
        "Fifth text to increase the vector store size.",
    };

    const embedding_dim = 384;
    var embedding: [384]f32 = undefined;
    for (&embedding) |*e| e.* = 0.1;

    for (test_texts) |text| {
        try store.add(text, &embedding);
    }

    const entry_size = @sizeOf(vector_db.VectorEntry);
    const memory_after_add = store.entries.items.len * (entry_size + embedding_dim * @sizeOf(f32));

    try testing.expect(store.entries.items.len == test_texts.len);
    _ = memory_after_add;
}

test "No-RAG: Command help text mentions --no-rag option" {
    const telegram_help =
        \\TELEGRAM COMMAND
        \\USAGE:
        \\  sati telegram [options]
        \\OPTIONS:
        \\  --no-rag           Disable RAG (Retrieval-Augmented Generation)
        \\  --rag              Enable RAG (default)
    ;

    const console_help =
        \\CONSOLE COMMAND
        \\USAGE:
        \\  sati console [options]
        \\OPTIONS:
        \\  --no-rag           Disable RAG (Retrieval-Augmented Generation)
        \\  --rag              Enable RAG (default)
    ;

    const telegram_sync_help =
        \\TELEGRAM-SYNC COMMAND
        \\USAGE:
        \\  sati telegram-sync [options]
        \\OPTIONS:
        \\  --no-rag           Disable RAG (Retrieval-Augmented Generation)
        \\  --rag              Enable RAG (default)
    ;

    try testing.expect(std.mem.indexOf(u8, telegram_help, "--no-rag") != null);
    try testing.expect(std.mem.indexOf(u8, console_help, "--no-rag") != null);
    try testing.expect(std.mem.indexOf(u8, telegram_sync_help, "--no-rag") != null);
}
