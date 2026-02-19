/// Memory usage tests for chat operations
/// Tests memory growth patterns and leak detection in chat scenarios
const std = @import("std");
const Agent = @import("../agent.zig").Agent;
const Config = @import("../config.zig").Config;
const context = @import("context.zig");
const messages = @import("messages.zig");
const base = @import("../providers/base.zig");

/// Get current memory usage in bytes
fn getMemoryUsage() usize {
    // This is a simplified approach - in real scenarios you might use
    // platform-specific APIs or heap tracking
    return std.heap.page_allocator.allocation_size;
}

/// Calculate memory usage of a context
fn calculateContextMemoryUsage(ctx: *context.Context) usize {
    var total: usize = 0;
    const context_messages = ctx.getMessages();

    for (context_messages) |msg| {
        total += msg.role.len;
        if (msg.content) |c| total += c.len;
        if (msg.tool_call_id) |id| total += id.len;
        if (msg.tool_calls) |calls| {
            for (calls) |call| {
                total += call.id.len;
                total += call.type.len;
                total += call.function.name.len;
                total += call.function.arguments.len;
            }
        }
    }

    // Add ArrayList overhead
    total += context_messages.len * @sizeOf(context.Context.messages.Item);

    return total;
}

/// Calculate memory usage of session history
fn calculateSessionHistoryMemoryUsage(history: *messages.SessionHistory) usize {
    var total: usize = 0;
    const msgs = history.getMessages();

    for (msgs) |msg| {
        total += msg.role.len;
        if (msg.content) |c| total += c.len;
        if (msg.tool_call_id) |id| total += id.len;
        if (msg.tool_calls) |calls| {
            for (calls) |call| {
                total += call.id.len;
                total += call.type.len;
                total += call.function.name.len;
                total += call.function.arguments.len;
            }
        }
    }

    // Add ArrayList overhead
    total += msgs.len * @sizeOf(messages.Message);

    return total;
}

test "Chat memory: Context memory increases with more messages" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Measure initial memory
    const initial_memory = calculateContextMemoryUsage(&ctx);
    std.debug.print("Initial context memory: {d} bytes\n", .{initial_memory});

    // Add first message
    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    const after_first = calculateContextMemoryUsage(&ctx);
    std.debug.print("After first message: {d} bytes (+{d})\n", .{ after_first, after_first - initial_memory });

    // Add second message
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there! How can I help you today?" });
    const after_second = calculateContextMemoryUsage(&ctx);
    std.debug.print("After second message: {d} bytes (+{d})\n", .{ after_second, after_second - after_first });

    // Add third message with longer content
    try ctx.addMessage(.{ .role = "user", .content = "I need help with understanding memory management in Zig programming language. Can you explain how memory allocation works, especially with allocators, and what are the best practices for avoiding memory leaks?" });
    const after_third = calculateContextMemoryUsage(&ctx);
    std.debug.print("After third message: {d} bytes (+{d})\n", .{ after_third, after_third - after_second });

    // Verify memory increases with each message
    try std.testing.expect(after_first > initial_memory);
    try std.testing.expect(after_second > after_first);
    try std.testing.expect(after_third > after_second);

    // Verify proportional growth - longer message should use more memory
    const first_increment = after_first - initial_memory;
    const third_increment = after_third - after_second;
    try std.testing.expect(third_increment > first_increment);
}

test "Chat memory: SessionHistory memory increases with more messages" {
    const allocator = std.testing.allocator;
    var history = messages.SessionHistory.init(allocator);
    defer history.deinit();

    // Measure initial memory
    const initial_memory = calculateSessionHistoryMemoryUsage(&history);
    std.debug.print("Initial session history memory: {d} bytes\n", .{initial_memory});

    // Add multiple messages and track memory growth
    const test_messages = [_]messages.Message{
        .{ .role = "system", .content = "You are a helpful assistant." },
        .{ .role = "user", .content = "Hello!" },
        .{ .role = "assistant", .content = "Hi! How can I help you?" },
        .{ .role = "user", .content = "What is Zig programming language?" },
        .{ .role = "assistant", .content = "Zig is a general-purpose programming language and toolchain for maintaining robust, optimal, and reusable software." },
        .{ .role = "user", .content = "Can you show me an example?" },
        .{ .role = "assistant", .content = "Sure! Here's a simple Hello World example in Zig:\n\nconst std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello, World!\\n\", .{});\n}" },
    };

    var previous_memory = initial_memory;
    for (test_messages, 0..) |msg, i| {
        try history.addMessage(msg);
        const current_memory = calculateSessionHistoryMemoryUsage(&history);
        const increment = current_memory - previous_memory;

        std.debug.print("After message {d}: {d} bytes (+{d})\n", .{ i + 1, current_memory, increment });

        // Memory should increase with each message
        try std.testing.expect(current_memory > previous_memory);
        previous_memory = current_memory;
    }

    // Final memory should be significantly higher than initial
    const final_memory = calculateSessionHistoryMemoryUsage(&history);
    try std.testing.expect(final_memory > initial_memory * 2); // At least 2x growth
}

test "Chat memory: Agent memory usage during conversation simulation" {
    const allocator = std.testing.allocator;

    // Create a minimal config for testing
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const session_id = "memory-test-session";
    var agent = try Agent.init(allocator, parsed.value, session_id, true);
    defer agent.deinit();

    // Measure initial agent memory (context + registry)
    const initial_context_memory = calculateContextMemoryUsage(&agent.ctx);
    std.debug.print("Initial agent context memory: {d} bytes\n", .{initial_context_memory});

    // Simulate adding messages to context (without actually running LLM)
    const conversation = [_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "user", .content = "Hello" },
        .{ .role = "assistant", .content = "Hi there!" },
        .{ .role = "user", .content = "How are you?" },
        .{ .role = "assistant", .content = "I'm doing well, thanks for asking!" },
        .{ .role = "user", .content = "Can you help me with something?" },
        .{ .role = "assistant", .content = "Of course! I'm here to help. What do you need assistance with?" },
    };

    var previous_memory = initial_context_memory;
    for (conversation, 0..) |turn, i| {
        try agent.ctx.addMessage(.{ .role = turn.role, .content = turn.content });
        const current_memory = calculateContextMemoryUsage(&agent.ctx);
        const increment = current_memory - previous_memory;

        std.debug.print("After turn {d} ({s}): {d} bytes (+{d})\n", .{ i + 1, turn.role, current_memory, increment });

        // Memory should increase with each message
        try std.testing.expect(current_memory > previous_memory);
        previous_memory = current_memory;
    }

    // Verify total growth
    const final_memory = calculateContextMemoryUsage(&agent.ctx);
    const total_growth = final_memory - initial_context_memory;
    std.debug.print("Total memory growth: {d} bytes\n", .{total_growth});

    try std.testing.expect(total_growth > 0);
}

test "Chat memory: Tool calls memory overhead" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Add a message without tool calls
    try ctx.addMessage(.{ .role = "assistant", .content = "I'll help you with that." });
    const without_tools = calculateContextMemoryUsage(&ctx);

    // Add a message with tool calls
    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "vector_search", .arguments = "{\"query\": \"memory management\", \"top_k\": 5}" } },
        .{ .id = "call_2", .type = "function", .function = .{ .name = "vector_upsert", .arguments = "{\"text\": \"Memory management is important in Zig\"}" } },
    };

    try ctx.addMessage(.{
        .role = "assistant",
        .content = "Let me search for information and remember this.",
        .tool_calls = tool_calls,
    });
    const with_tools = calculateContextMemoryUsage(&ctx);

    std.debug.print("Message without tools: {d} bytes\n", .{without_tools});
    std.debug.print("Message with tools: {d} bytes\n", .{with_tools});
    std.debug.print("Tool calls overhead: {d} bytes\n", .{with_tools - without_tools});

    // Tool calls should add significant memory overhead
    try std.testing.expect(with_tools > without_tools);
    const tool_overhead = with_tools - without_tools;
    try std.testing.expect(tool_overhead > 100); // At least 100 bytes for tool call data
}

test "Chat memory: Memory leak detection - proper cleanup" {
    const allocator = std.testing.allocator;

    // Test that Context properly cleans up all memory
    {
        var ctx = context.Context.init(allocator);

        // Add many messages with various content
        for (0..100) |i| {
            const content = try std.fmt.allocPrint(allocator, "Message {d} with some content to allocate memory", .{i});
            defer allocator.free(content);

            try ctx.addMessage(.{ .role = if (i % 2 == 0) "user" else "assistant", .content = content });
        }

        const before_cleanup = calculateContextMemoryUsage(&ctx);
        std.debug.print("Before cleanup: {d} bytes\n", .{before_cleanup});

        // Context.deinit() should free all memory
        ctx.deinit();
        // After deinit, we can't measure memory since ctx is undefined
    }

    // Test that SessionHistory properly cleans up all memory
    {
        var history = messages.SessionHistory.init(allocator);

        // Add many messages
        for (0..50) |i| {
            const content = try std.fmt.allocPrint(allocator, "History message {d}", .{i});
            defer allocator.free(content);

            const msg: messages.Message = .{
                .role = "user",
                .content = try allocator.dupe(u8, content),
            };
            try history.addMessage(msg);
        }

        const before_cleanup = calculateSessionHistoryMemoryUsage(&history);
        std.debug.print("History before cleanup: {d} bytes\n", .{before_cleanup});

        history.deinit();
        // After deinit, all memory should be freed
    }

    // If we reach here without memory leaks detected by the test allocator,
    // the cleanup is working properly
}

test "Chat memory: Large message memory impact" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Create a large message (simulating a long conversation or code)
    var large_content: std.ArrayList(u8) = .init(allocator);
    defer large_content.deinit();

    try large_content.appendSlice(allocator, "This is a large message containing multiple lines.\n");
    for (0..1000) |i| {
        try large_content.appendSlice(allocator, "Line ");
        try large_content.print(allocator, "{d}: This is some sample content to increase memory usage.\n", .{i});
    }

    const initial_memory = calculateContextMemoryUsage(&ctx);

    // Add the large message
    try ctx.addMessage(.{ .role = "assistant", .content = large_content.items });

    const after_large = calculateContextMemoryUsage(&ctx);
    const large_increment = after_large - initial_memory;

    std.debug.print("Initial memory: {d} bytes\n", .{initial_memory});
    std.debug.print("After large message: {d} bytes\n", .{after_large});
    std.debug.print("Large message increment: {d} bytes\n", .{large_increment});

    // The increment should be approximately the size of the large content
    try std.testing.expect(large_increment > large_content.items.len - 100); // Allow some overhead
    try std.testing.expect(large_increment < large_content.items.len + 1000); // But not too much overhead
}

test "Chat memory: Memory growth pattern analysis" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    var memory_measurements: [10]usize = undefined;
    var measurement_count: usize = 0;

    // Add messages and measure memory at each step
    const test_messages = [_][]const u8{
        "Hi",
        "Hello there!",
        "How are you doing today?",
        "I'm doing great, thanks for asking! How about you?",
        "I'm doing well too. I wanted to ask you about something.",
        "Sure, feel free to ask anything you'd like to know!",
        "Can you explain memory management in programming?",
        "Memory management is the process of controlling and coordinating computer memory, assigning portions called blocks to various running programs to optimize overall system performance.",
        "That's helpful. Can you give me a specific example?",
        "Certainly! In languages like C, you use malloc() to allocate memory and free() to deallocate it. In Zig, you use allocators that provide a more structured approach.",
    };

    for (test_messages) |content| {
        const role: []const u8 = if (measurement_count % 2 == 0) "user" else "assistant";
        try ctx.addMessage(.{ .role = role, .content = content });

        memory_measurements[measurement_count] = calculateContextMemoryUsage(&ctx);
        measurement_count += 1;
    }

    // Analyze growth pattern
    std.debug.print("Memory growth pattern:\n");
    var previous_memory: usize = 0;
    for (memory_measurements[0..measurement_count], 0..) |memory, i| {
        const increment = if (i == 0) memory else memory - previous_memory;
        std.debug.print("  Message {d}: {d} bytes (+{d})\n", .{ i + 1, memory, increment });
        previous_memory = memory;
    }

    // Verify consistent growth pattern
    for (1..measurement_count) |i| {
        try std.testing.expect(memory_measurements[i] > memory_measurements[i - 1]);
    }

    // Calculate average growth per message
    const total_growth = memory_measurements[measurement_count - 1] - memory_measurements[0];
    const avg_growth = total_growth / (measurement_count - 1);
    std.debug.print("Average growth per message: {d} bytes\n", .{avg_growth});

    // Average growth should be reasonable (not too small, not too large)
    try std.testing.expect(avg_growth > 10); // At least 10 bytes per message
    try std.testing.expect(avg_growth < 1000); // But not excessively large
}
