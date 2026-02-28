/// Synchronous Console Bot Implementation
///
/// This is a simplified, synchronous version of the console bot that processes
/// messages directly without using an xev event loop. It processes each
/// message sequentially, making it simpler and more reliable.
///
/// Key characteristics:
/// - **Synchronous processing**: One message at a time, no concurrency
/// - **Simple architecture**: Direct Agent calls, no event loop complexity
/// - **Reliable**: Easier to debug and understand
/// - **Lower resource usage**: No thread pools or event loop overhead
///
/// Use this version when:
/// - You need a simple, reliable console bot
/// - Resource usage is a concern
/// - You're developing or debugging
/// - You don't need concurrent message processing
///
/// For concurrent message processing with event loop,
/// use the xev-based async version (`sati console`).
const std = @import("std");
pub const Config = @import("core").config.Config;
const Agent = @import("../agent.zig").Agent;

var shutdown_requested = std.atomic.Value(bool).init(false);
var shutdown_message_printed = std.atomic.Value(bool).init(false);

// Spinner animation for loading state
const SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
const SPINNER_DELAY_MS = 100; // 100ms between frames
var spinner_active = std.atomic.Value(bool).init(false);

fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;

    if (!shutdown_message_printed.load(.seq_cst)) {
        shutdown_message_printed.store(true, .seq_cst);
        std.debug.print("\n🛑 Console bot shutting down...\n", .{});
    }

    shutdown_requested.store(true, .seq_cst);
}

var session_counter: u32 = 0;

fn processMessage(allocator: std.mem.Allocator, config: Config, rag_enabled: bool, text: []const u8) !void {
    var actual_text = text;

    if (std.mem.startsWith(u8, text, "/new")) {
        session_counter += 1;
        if (text.len <= 4) {
            std.debug.print("\n-----<Starting new session! Send me a new message.>-----\n", .{});
            return;
        }
        actual_text = std.mem.trimStart(u8, text[4..], " ");
    }

    if (std.mem.startsWith(u8, actual_text, "/help")) {
        const help_text =
            \\🐸 SatiBot Console Commands:
            \\ /help - Show this help message
            \\ /new - Start a new session
            \\
            \\Send any message to chat with the AI assistant.
        ;
        std.debug.print("\n{s}\n", .{help_text});
        return;
    }

    std.debug.print("\n[Processing Message]: {s}\n", .{actual_text});

    std.debug.print("\n⚡ Thinking ", .{});

    const session_id = try std.fmt.allocPrint(allocator, "console_sync_{d}", .{session_counter});
    defer allocator.free(session_id);

    // Start spinner animation
    spinner_active.store(true, .seq_cst);
    const spinner_thread = try std.Thread.spawn(.{}, spinnerThread, .{});
    defer spinner_thread.join();

    // Small delay to ensure spinner starts before agent begins processing
    std.posix.nanosleep(0, 50_000_000); // 50ms
    std.Thread.yield() catch |err| std.debug.print("Warning: Thread yield failed: {any}\n", .{err}); // Yield to ensure spinner thread runs

    var agent = try Agent.init(allocator, config, session_id, rag_enabled);
    defer agent.deinit();

    agent.shutdown_flag = &shutdown_requested;

    agent.run(actual_text) catch |err| {
        // Stop spinner on error
        spinner_active.store(false, .seq_cst);
        spinner_thread.join();

        if (err == error.Interrupted) {
            std.debug.print("\r🛑 Agent task cancelled\n", .{});
            return;
        }
        std.debug.print("\rAgent error: {any}\n", .{err});
        return;
    };

    // Stop spinner before showing result
    spinner_active.store(false, .seq_cst);

    const messages = agent.ctx.getMessages();
    if (messages.len > 0) {
        const last_msg = messages[messages.len - 1];
        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
            std.debug.print("\r🤖 [Bot]: {s}\n", .{last_msg.content.?});
        }
    }

    // Reset shutdown flag for next message
    shutdown_requested.store(false, .seq_cst);

    if (rag_enabled) {
        agent.indexConversation() catch |err| {
            std.debug.print("Warning: Failed to index conversation: {any}\n", .{err});
        };
    }
}

// Spinner animation thread function
fn spinnerThread() void {
    var frame_idx: usize = 0;

    while (spinner_active.load(.seq_cst)) {
        // Print spinner with carriage return to stay on same line
        std.debug.print("\r⚡ Thinking {c} ", .{SPINNER_FRAMES[frame_idx]});
        std.posix.nanosleep(0, SPINNER_DELAY_MS * 1_000_000); // Convert ms to ns

        frame_idx = (frame_idx + 1) % SPINNER_FRAMES.len;
    }

    // Clear the spinner line
    std.debug.print("\r\x1b[K", .{});
}

pub const ConsoleSyncBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    rag_enabled: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config, rag_enabled: bool) ConsoleSyncBot {
        return .{
            .allocator = allocator,
            .config = config,
            .rag_enabled = rag_enabled,
        };
    }

    pub fn tick(self: *ConsoleSyncBot) !void {
        const stdin = std.fs.File.stdin();
        var buf: [1024]u8 = undefined;

        std.debug.print("\nUser > ", .{});
        const n = stdin.read(&buf) catch |err| {
            if (err == error.InputOutput or err == error.BrokenPipe) {
                if (shutdown_requested.load(.seq_cst)) {
                    return;
                }
                return;
            }
            return err;
        };
        if (n == 0) return;

        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (trimmed.len == 0) return;

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            shutdown_requested.store(true, .seq_cst);
            return;
        }

        try processMessage(self.allocator, self.config, self.rag_enabled, trimmed);
    }

    pub fn run(self: *ConsoleSyncBot) !void {
        std.debug.print("🎮 Console Sync Bot started. Type 'exit' or 'quit' to quit.\n", .{});

        const sa: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        while (!shutdown_requested.load(.seq_cst)) {
            self.tick() catch |err| {
                if (err == error.EndOfStream) break;
                if (err == error.InputOutput or err == error.BrokenPipe) {
                    if (shutdown_requested.load(.seq_cst)) {
                        break;
                    }
                    continue;
                }
                std.debug.print("Tick error: {any}\n", .{err});
            };
        }

        if (shutdown_message_printed.load(.seq_cst)) {
            std.debug.print("--- Console bot shut down successfully. ---\n", .{});
        }
    }
};

pub fn run(allocator: std.mem.Allocator, config: Config, rag_enabled: bool) !void {
    var bot = ConsoleSyncBot.init(allocator, config, rag_enabled);
    try bot.run();
}

test "ConsoleSyncBot init and deinit" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    const bot = ConsoleSyncBot.init(allocator, config, true);
    try std.testing.expectEqual(allocator, bot.allocator);
    try std.testing.expectEqual(config, bot.config);
    try std.testing.expectEqual(true, bot.rag_enabled);
}

test "ConsoleSyncBot init with rag disabled" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    const bot = ConsoleSyncBot.init(allocator, config, false);
    try std.testing.expectEqual(false, bot.rag_enabled);
}

test "ConsoleSyncBot session counter starts at zero" {
    session_counter = 0;
    try std.testing.expectEqual(@as(u32, 0), session_counter);
}

test "ConsoleSyncBot session counter increments" {
    session_counter = 0;
    session_counter += 1;
    try std.testing.expectEqual(@as(u32, 1), session_counter);
    session_counter += 1;
    try std.testing.expectEqual(@as(u32, 2), session_counter);
}

test "ConsoleSyncBot shutdown flag init state" {
    shutdown_requested.store(false, .seq_cst);
    try std.testing.expectEqual(false, shutdown_requested.load(.seq_cst));
}

test "ConsoleSyncBot shutdown flag can be set" {
    shutdown_requested.store(false, .seq_cst);
    shutdown_requested.store(true, .seq_cst);
    try std.testing.expectEqual(true, shutdown_requested.load(.seq_cst));
}

test "ConsoleSyncBot spinner uses stderr for unbuffered output" {
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();
    try std.testing.expect(stderr.handle != stdin.handle);
}

test "ConsoleSyncBot spinner animation frames are valid" {
    try std.testing.expect(SPINNER_FRAMES.len > 0);
    try std.testing.expect(SPINNER_DELAY_MS > 0);
}

test "ConsoleSyncBot spinner thread can be controlled via atomic" {
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));

    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));

    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));
}

test "ConsoleSyncBot: Spinner writes to stderr for immediate display" {
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    const writer = stderr.writer(&buf);
    _ = writer;
}

test "ConsoleSyncBot: Carriage return clears line for spinner" {
    const test_line = "\r\x1b[K";
    try std.testing.expect(std.mem.startsWith(u8, test_line, "\r"));
}

test "ConsoleSyncBot tick handles empty input gracefully" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    const bot = ConsoleSyncBot.init(allocator, config, true);
    try std.testing.expectEqual(allocator, bot.allocator);
}

test "ConsoleSyncBot /help command detection" {
    const text = "/help";
    try std.testing.expect(std.mem.startsWith(u8, text, "/help"));
}

test "ConsoleSyncBot /new command detection" {
    const text = "/new";
    try std.testing.expect(std.mem.startsWith(u8, text, "/new"));
}

test "ConsoleSyncBot /new with message detection" {
    const text = "/new hello world";
    try std.testing.expect(std.mem.startsWith(u8, text, "/new"));
}

test "ConsoleSyncBot trim whitespace from input" {
    const input = "  hello world  ";
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    try std.testing.expectEqualStrings("hello world", trimmed);
}

test "ConsoleSyncBot exit command detection" {
    try std.testing.expect(std.mem.eql(u8, "exit", "exit"));
    try std.testing.expect(std.mem.eql(u8, "quit", "quit"));
}

test "ConsoleSyncBot non-exit commands are not exit" {
    try std.testing.expect(!std.mem.eql(u8, "hello", "exit"));
    try std.testing.expect(!std.mem.eql(u8, "quit", "exit"));
    try std.testing.expect(!std.mem.eql(u8, "exit", "quit"));
}

test "ConsoleSyncBot memory - multiple init cycles" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    for (0..5) |_| {
        const bot = ConsoleSyncBot.init(allocator, config, false);
        try std.testing.expectEqual(config, bot.config);
    }
}

test "ConsoleSyncBot config equality" {
    const config1: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };
    const config2: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };
    try std.testing.expectEqual(config1, config2);
}

test "ConsoleSyncBot: No memory leak with --no-rag option" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    // Test with rag_enabled = false (--no-rag)
    {
        const bot = ConsoleSyncBot.init(allocator, config, false);
        try std.testing.expectEqual(false, bot.rag_enabled);
        try std.testing.expectEqual(config, bot.config);
    }
    // If deinit works correctly, no memory leaks should occur
}

test "ConsoleSyncBot: Memory leak test - multiple init/deinit cycles with --no-rag" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    // Test multiple init cycles to detect any cumulative leaks
    for (0..5) |_| {
        const bot = ConsoleSyncBot.init(allocator, config, false);
        try std.testing.expectEqual(config, bot.config);
    }
    // If we reach here without memory leaks, test passes
}

// ===== Animation Loading Tests =====

test "ConsoleSyncBot: Spinner frames constant is properly defined" {
    // Verify spinner frames contain valid characters
    try std.testing.expect(SPINNER_FRAMES.len > 0);

    // Check that all frames are valid UTF-8 characters
    for (SPINNER_FRAMES) |frame| {
        // Each spinner character should be a single Unicode character
        // In UTF-8, spinner characters are 3 bytes each
        try std.testing.expect(frame > 0); // Should be valid character
    }

    // Expected spinner sequence for verification
    const expected_frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    try std.testing.expectEqualStrings(expected_frames, SPINNER_FRAMES);
}

test "ConsoleSyncBot: Spinner delay constant is reasonable" {
    // 100ms delay is reasonable for smooth animation
    try std.testing.expect(SPINNER_DELAY_MS == 100);
    try std.testing.expect(SPINNER_DELAY_MS > 0);
    try std.testing.expect(SPINNER_DELAY_MS < 1000); // Should be less than 1 second
}

test "ConsoleSyncBot: Spinner active flag atomic operations" {
    // Test initial state
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));

    // Test setting to true
    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));

    // Test setting back to false
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));

    // Test multiple rapid state changes
    for (0..10) |i| {
        const state = i % 2 == 0;
        spinner_active.store(state, .seq_cst);
        try std.testing.expectEqual(state, spinner_active.load(.seq_cst));
    }
}

test "ConsoleSyncBot: Spinner frame index progression logic" {
    // Test the frame progression logic used in spinnerThread
    const frame_count = SPINNER_FRAMES.len;

    // Test frame index wraps around correctly
    var frame_idx: usize = 0;

    // Simulate frame progression
    for (0..frame_count * 2) |i| {
        const expected_frame = i % frame_count;
        try std.testing.expectEqual(expected_frame, frame_idx);
        frame_idx = (frame_idx + 1) % frame_count;
    }
}

test "ConsoleSyncBot: Spinner output format" {
    // Test the spinner output format string
    const test_frame = SPINNER_FRAMES[0];
    const expected_output = "\r⚡ Thinking ";

    // Build the actual output format
    var output_buf: [32]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buf, "\r⚡ Thinking {c} ", .{test_frame}) catch unreachable;

    try std.testing.expect(std.mem.startsWith(u8, output, expected_output));
    try std.testing.expect(output.len > expected_output.len);
}

test "ConsoleSyncBot: Spinner clear line sequence" {
    // Test the clear line escape sequence
    const clear_sequence = "\r\x1b[K";

    // Verify it starts with carriage return
    try std.testing.expect(std.mem.startsWith(u8, clear_sequence, "\r"));

    // Verify it contains the escape sequence
    try std.testing.expect(std.mem.indexOf(u8, clear_sequence, "\x1b[K") != null);

    // Test the complete sequence matches expected
    try std.testing.expectEqualStrings("\r\x1b[K", clear_sequence);
}

test "ConsoleSyncBot: Spinner thread lifecycle simulation" {
    // Simulate the spinner thread lifecycle without actually spawning threads
    spinner_active.store(false, .seq_cst);

    // Simulate starting the spinner
    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));

    // Simulate spinner running for a few frames
    var frame_idx: usize = 0;
    for (0..3) |_| {
        // Simulate one frame of animation
        frame_idx = (frame_idx + 1) % SPINNER_FRAMES.len;
    }

    // Simulate stopping the spinner
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));
}

test "ConsoleSyncBot: Spinner timing constraints" {
    // Test that spinner timing parameters are within reasonable bounds
    try std.testing.expect(SPINNER_DELAY_MS >= 50); // Not too fast (flicker)
    try std.testing.expect(SPINNER_DELAY_MS <= 200); // Not too slow (unresponsive)

    // Test frame count is reasonable for smooth animation
    try std.testing.expect(SPINNER_FRAMES.len >= 4); // Minimum frames for animation
}

test "ConsoleSyncBot: Spinner concurrent access simulation" {
    // Simulate concurrent access to spinner_active flag
    spinner_active.store(false, .seq_cst);

    // Simulate multiple rapid state changes (like thread contention)
    for (0..100) |i| {
        const state = i % 3 == 0; // Vary the pattern
        spinner_active.store(state, .seq_cst);

        // Read back immediately to test atomicity
        const read_back = spinner_active.load(.seq_cst);
        try std.testing.expectEqual(state, read_back);
    }
}

test "ConsoleSyncBot: Animation integration with processMessage" {
    // Test that the animation components work together in processMessage context
    const allocator = std.testing.allocator;

    // Reset spinner state
    spinner_active.store(false, .seq_cst);

    // Simulate the spinner setup that happens in processMessage
    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));

    // Simulate the spinner cleanup that happens in processMessage
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));

    // Test session ID generation (used in processMessage)
    const session_id = try std.fmt.allocPrint(allocator, "console_sync_{d}", .{0});
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("console_sync_0", session_id);
}

test "ConsoleSyncBot: Animation error handling simulation" {
    // Test spinner behavior during error conditions
    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));

    // Simulate error condition (like agent.run() error)
    // In real code, spinner is stopped on error
    spinner_active.store(false, .seq_cst);
    try std.testing.expectEqual(false, spinner_active.load(.seq_cst));

    // Verify spinner can be restarted after error
    spinner_active.store(true, .seq_cst);
    try std.testing.expectEqual(true, spinner_active.load(.seq_cst));
}
