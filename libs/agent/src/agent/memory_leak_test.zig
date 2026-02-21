/// Memory Leak Test for SatiBot Agent
///
/// This test simulates multiple chat sessions to detect memory leaks.
/// It uses a mock provider so no real API calls are made.
///
/// Usage:
///   cd /Users/a0/w/chatbot/satibot && zig build test
const std = @import("std");
const testing = std.testing;
const Config = @import("core").config.Config;
const Agent = @import("../agent.zig").Agent;
const NoopObserver = @import("../observability.zig").NoopObserver;

const test_config: Config = .{
    .agents = .{
        .defaults = .{
            .model = "mock/model",
            .maxChatHistory = 10,
            .loadChatHistory = false,
            .disableRag = true,
            .embeddingModel = "local",
        },
    },
    .providers = .{
        .openrouter = .{
            .apiKey = "mock-key",
        },
    },
    .tools = .{
        .web = .{
            .search = .{
                .apiKey = "",
            },
        },
    },
};

test "Memory Leak Test - Multiple Agent Init/Deinit Cycles" {
    const allocator = testing.allocator;
    const num_iterations: usize = 5;

    std.debug.print("\n=== Memory Leak Test: {d} iterations ===\n", .{num_iterations});

    for (0..num_iterations) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "test_session_{d}", .{i});
        defer allocator.free(session_id);

        var agent = try Agent.init(allocator, test_config, session_id, false);

        // Use noop observer
        var noop = NoopObserver{};
        agent.observer = noop.observer();

        // Run agent (this will call the mock provider in base.zig)
        agent.run("Test message") catch |err| {
            // Expected to fail with mock provider
            std.debug.print("  Iteration {d}: Agent error (expected): {any}\n", .{ i, err });
        };

        agent.deinit();

        std.debug.print("  Iteration {d}: OK\n", .{i});
    }

    std.debug.print("=== Memory Leak Test Complete ===\n", .{});
}

test "Memory Leak Test - Agent with Context" {
    const allocator = testing.allocator;
    const num_iterations: usize = 3;

    std.debug.print("\n=== Memory Leak Test with Context: {d} iterations ===\n", .{num_iterations});

    for (0..num_iterations) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "test_session_ctx_{d}", .{i});
        defer allocator.free(session_id);

        var agent = try Agent.init(allocator, test_config, session_id, false);

        var noop = NoopObserver{};
        agent.observer = noop.observer();

        // Add some messages to context
        try agent.ctx.addMessage(.{ .role = "user", .content = "Hello" });
        try agent.ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });
        try agent.ctx.addMessage(.{ .role = "user", .content = "How are you?" });

        const msg_count = agent.ctx.getMessages().len;

        // Run agent
        agent.run("Test message") catch |err| {
            std.debug.print("  Iteration {d}: Agent error: {any}\n", .{ i, err });
        };

        std.debug.print("  Iteration {d}: Context has {d} messages\n", .{ i, msg_count });

        agent.deinit();
    }

    std.debug.print("=== Context Memory Test Complete ===\n", .{});
}
