/// xev-based Mock Bot implementation for console-based testing.
/// This file simulates a Telegram bot by reading input from the console
/// and processing it through the same xev event loop and Agent logic.
///
/// Logic Graph:
/// ```mermaid
/// graph TD
///     Main[Main Thread] --> |tick| Stdin[Read Console Input]
///     Stdin --> |addTask| task_q[(Xev Task Queue)]
///     task_q --> |process| EL[Event Loop Thread]
///     EL --> |Run Agent Logic| Agent[AI Agent]
///     Agent --> |LLM Request| OpenRouter[OpenRouter API]
///     OpenRouter --> |Response| Agent
///     Agent --> |Reply| Console[Print to Console]
/// ```
const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const XevEventLoop = @import("xev_event_loop.zig").XevEventLoop;

/// Global flag for shutdown signal
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Global event loop pointer for signal handler access
var global_event_loop: ?*XevEventLoop = null;

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    std.debug.print("\n🛑 Mock bot shutting down...\n", .{});
    shutdown_requested.store(true, .seq_cst);
    if (global_event_loop) |el| {
        el.requestShutdown();
    }
}

/// Context for mock handlers
pub const MockContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
};

/// Task handler for console messages
fn mockTaskHandler(allocator: std.mem.Allocator, task: @import("xev_event_loop.zig").Task) anyerror!void {
    if (!std.mem.eql(u8, task.source, "console_input")) return;

    // Access global or shared context
    // In this functional-lite approach, we'll use a global pointer for simplicity in the mock
    const ctx = global_mock_context orelse {
        std.debug.print("Error: Global mock context not set\n", .{});
        return;
    };

    std.debug.print("\n[Processing Message]: {s}\n", .{task.data});

    // Mock chat ID for session persistence
    const mock_chat_id = 99999;
    const session_id = try std.fmt.allocPrint(allocator, "mock_tg_{d}", .{mock_chat_id});
    defer allocator.free(session_id);

    // Run agent logic
    var agent = Agent.init(allocator, ctx.config, session_id);
    defer agent.deinit();

    agent.run(task.data) catch |err| {
        std.debug.print("Agent error: {any}\n", .{err});
        return;
    };

    const messages = agent.ctx.get_messages();
    if (messages.len > 0) {
        const last_msg = messages[messages.len - 1];
        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
            std.debug.print("\n🤖 [Bot]: {s}\n", .{last_msg.content.?});
        }
    }

    // Index for RAG
    agent.index_conversation() catch {};
}

var global_mock_context: ?*MockContext = null;

/// MockBot manages console-to-LLM interaction using XevEventLoop
pub const MockBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    event_loop: XevEventLoop,
    ctx: MockContext,

    /// Initialize the mock bot
    pub fn init(allocator: std.mem.Allocator, config: Config) !*MockBot {
        const self = try allocator.create(MockBot);

        self.allocator = allocator;
        self.config = config;
        self.event_loop = try XevEventLoop.init(allocator, config);
        self.ctx = .{
            .allocator = allocator,
            .config = config,
        };

        self.event_loop.setTaskHandler(mockTaskHandler);
        global_mock_context = &self.ctx;

        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *MockBot) void {
        self.event_loop.deinit();
        self.allocator.destroy(self);
        global_mock_context = null;
    }

    /// Read from console and add task to loop
    pub fn tick(self: *MockBot) !void {
        const stdin = std.fs.File.stdin();
        var buf: [1024]u8 = undefined;

        std.debug.print("\nUser > ", .{});
        const n = try stdin.read(&buf);
        if (n == 0) return;

        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (trimmed.len == 0) return;

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            shutdown_requested.store(true, .seq_cst);
            self.event_loop.requestShutdown();
            return;
        }

        try self.event_loop.addTask("console_msg", trimmed, "console_input");
    }

    /// Run the mock bot
    pub fn run(self: *MockBot) !void {
        std.debug.print("🎮 Mock Xev Bot started. Type 'exit' to quit.\n", .{});

        // Setup signal handlers
        global_event_loop = &self.event_loop;
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        // Start event loop thread
        const el_thread = try std.Thread.spawn(.{}, XevEventLoop.run, .{&self.event_loop});
        defer el_thread.join();

        // Main thread handles console input
        while (!shutdown_requested.load(.seq_cst)) {
            self.tick() catch |err| {
                if (err == error.EndOfStream) break;
                std.debug.print("Tick error: {any}\n", .{err});
            };
        }
    }
};

// Unit test for MockBot (requires valid OPENROUTER_API_KEY in environment or config)
test "MockBot logic test" {
    const allocator = std.testing.allocator;

    // Load config
    const config = try @import("../config.zig").load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value);
    defer bot.deinit();

    // Verify task adding
    try bot.event_loop.addTask("test_id", "Hello", "console_input");

    // In UT we don't start the full run loop but can verify initial state
    try std.testing.expect(bot.event_loop.task_queue.items.len == 1);
}
