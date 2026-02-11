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
const xev_event_loop = @import("../utils/xev_event_loop.zig");
const XevEventLoop = xev_event_loop.XevEventLoop;

/// Global flag for shutdown signal
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Global flag to prevent multiple shutdown messages
var shutdown_message_printed = std.atomic.Value(bool).init(false);

/// Global event loop pointer for signal handler access
var global_event_loop: ?*XevEventLoop = null;

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;

    // Only print shutdown message once
    if (!shutdown_message_printed.load(.seq_cst)) {
        shutdown_message_printed.store(true, .seq_cst);
        std.debug.print("\n🛑 Mock bot shutting down...\n", .{});
    }

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
fn mockTaskHandler(allocator: std.mem.Allocator, task: xev_event_loop.Task) anyerror!void {
    if (!std.mem.eql(u8, task.source, "console_input")) return;

    // Access global or shared context
    // In this functional-lite approach, we'll use a global pointer for simplicity in the mock
    const ctx = global_mock_context orelse {
        std.debug.print("Error: Global mock context not set\n", .{});
        return;
    };

    var actual_text = task.data;

    // Handle magic command /new to start a new session (increment counter so next session ID is different)
    if (std.mem.startsWith(u8, actual_text, "/new")) {
        mock_session_counter += 1;
        if (actual_text.len <= 4) {
            std.debug.print("\n-----<Starting new session! Send me a new message.>-----\n", .{});
            return;
        }
        // If user sent "/new some prompt", start new session and process the prompt
        actual_text = std.mem.trimLeft(u8, actual_text[4..], " ");
    }

    // Handle /help command
    if (std.mem.startsWith(u8, actual_text, "/help")) {
        const help_text =
            \\🐸 SatiBot Console Commands:
            \\ /help - Show this help message
            \\
            \\Send any message to chat with the AI assistant.
        ;
        std.debug.print("\n{s}\n", .{help_text});
        return;
    }

    std.debug.print("\n[Processing Message]: {s}\n", .{actual_text});

    // Use counter in session ID so /new creates a fresh session without loading old history
    const session_id = try std.fmt.allocPrint(allocator, "mock_tg_99999_{d}", .{mock_session_counter});
    defer allocator.free(session_id);

    // Run agent logic with shutdown flag support
    var agent = Agent.init(allocator, ctx.config, session_id);
    agent.shutdown_flag = &shutdown_requested;
    defer agent.deinit();

    agent.run(actual_text) catch |err| {
        if (err == error.Interrupted) {
            std.debug.print("\n🛑 Agent task cancelled\n", .{});
            return;
        }
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

/// Session counter to generate unique session IDs when /new is used
var mock_session_counter: u32 = 0;

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
        const n = stdin.read(&buf) catch |err| {
            // Handle interrupted input (e.g., from Ctrl+C signal)
            if (err == error.InputOutput or err == error.BrokenPipe) {
                // Signal was received, check if we should shutdown
                if (shutdown_requested.load(.seq_cst)) {
                    return;
                }
                // Otherwise continue the loop
                return;
            }
            return err;
        };
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
                if (err == error.InputOutput or err == error.BrokenPipe) {
                    // Input was interrupted, check shutdown flag
                    if (shutdown_requested.load(.seq_cst)) {
                        break;
                    }
                    // Otherwise continue to next iteration
                    continue;
                }
                std.debug.print("Tick error: {any}\n", .{err});
            };
        }

        // Ensure clean shutdown message
        if (shutdown_message_printed.load(.seq_cst)) {
            std.debug.print("--- Mock bot shut down successfully. ---\n", .{});
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

test "MockBot /new command increments session counter" {
    const allocator = std.testing.allocator;

    // Reset global counter for test
    mock_session_counter = 0;

    // Load config
    const config = try @import("../config.zig").load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value);
    defer bot.deinit();

    // Test /new command increments counter
    try bot.event_loop.addTask("test1", "/new", "console_input");
    try bot.event_loop.addTask("test2", "Hello after new", "console_input");

    // Verify session counter was incremented
    try std.testing.expect(mock_session_counter == 1);

    // Test another /new increments again
    try bot.event_loop.addTask("test3", "/new", "console_input");
    try std.testing.expect(mock_session_counter == 2);
}

test "MockBot /new with prompt processes prompt after incrementing counter" {
    const allocator = std.testing.allocator;

    // Reset global counter for test
    mock_session_counter = 0;

    // Load config
    const config = try @import("../config.zig").load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value);
    defer bot.deinit();

    // Test /new with prompt
    try bot.event_loop.addTask("test1", "/new what is zig?", "console_input");

    // Verify counter was incremented
    try std.testing.expect(mock_session_counter == 1);

    // The task should still be processed (we can't easily test the actual processing
    // without running the full event loop, but we can verify the task was added)
    try std.testing.expect(bot.event_loop.task_queue.items.len == 1);
}
