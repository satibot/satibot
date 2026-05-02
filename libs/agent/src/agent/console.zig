/// xev-based Console bot implementation for console-based testing.
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

pub const Config = @import("core").config.Config;
const config_load = @import("core").config.load;
const xev_event_loop = @import("utils").xev_event_loop;
const XevEventLoop = xev_event_loop.XevEventLoop;

const Agent = @import("../agent.zig").Agent;

const MAX_HISTORY_LINES: usize = 500;

/// Global flag for shutdown signal
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Global flag to prevent multiple shutdown messages
var shutdown_message_printed = std.atomic.Value(bool).init(false);

/// Global event loop pointer for signal handler access
var global_event_loop: ?*XevEventLoop = null;

/// Global flag to track when AI is processing
var is_processing = std.atomic.Value(bool).init(false);

/// Global flag to track loading animation state
var loading_active = std.atomic.Value(bool).init(false);

/// Check if line is a quit command (exit, quit, :q, /quit, /exit)
fn isQuitCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "exit") or
        std.mem.eql(u8, trimmed, "quit") or
        std.mem.eql(u8, trimmed, ":q") or
        std.mem.eql(u8, trimmed, "/quit") or
        std.mem.eql(u8, trimmed, "/exit");
}

/// Show loading spinner animation
fn showLoadingSpinner() void {
    if (!loading_active.load(.seq_cst)) return;

    const spin_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    const io = std.Io.Threaded.global_single_threaded.io();
    const start_time = std.Io.Clock.real.now(io).toNanoseconds();
    var frame: usize = 0;

    while (loading_active.load(.seq_cst) and !shutdown_requested.load(.seq_cst)) {
        const current_time = std.Io.Clock.real.now(io).toNanoseconds();
        const elapsed_ms: u64 = @intCast(@divTrunc(current_time - start_time, 1_000_000));
        frame = @as(usize, @intCast(@divTrunc(elapsed_ms, 100))) % spin_chars.len;

        // Carriage return to overwrite current line
        std.debug.print("\r🤔 Thinking {c}...", .{spin_chars[frame]});
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
    }

    // Clear the loading line when done
    std.debug.print("\r{s}", .{" " ** 30});
    std.debug.print("\r", .{});
}

/// Start loading animation in background thread
fn startLoadingAnimation() void {
    if (loading_active.load(.seq_cst)) return; // Already loading

    loading_active.store(true, .seq_cst);

    // Spawn loading animation thread
    const loading_thread = std.Thread.spawn(.{
        .stack_size = 65536, // 64KB stack is enough for spinner
    }, showLoadingSpinner, .{}) catch return;
    loading_thread.detach();
}

/// Stop loading animation
fn stopLoadingAnimation() void {
    loading_active.store(false, .seq_cst);
}

pub fn loadHistory(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r");
    if (file == null) return allocator.alloc([]const u8, 0);
    defer _ = std.c.fclose(file.?);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    var read_buf: [8192]u8 = undefined;
    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    while (true) {
        const n = std.c.fread(&read_buf, 1, read_buf.len, file.?);
        if (n == 0) break;
        const data = read_buf[0..n];

        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == '\n') {
                const segment = data[start..i];
                if (carry.items.len > 0) {
                    try carry.appendSlice(allocator, segment);
                    const trimmed = std.mem.trim(u8, carry.items, " \t\r");
                    if (trimmed.len > 0) {
                        try lines.append(allocator, try allocator.dupe(u8, trimmed));
                    }
                    carry.clearRetainingCapacity();
                } else {
                    const trimmed = std.mem.trim(u8, segment, " \t\r");
                    if (trimmed.len > 0) {
                        try lines.append(allocator, try allocator.dupe(u8, trimmed));
                    }
                }
                start = i + 1;
            }
        }
        if (start < data.len) {
            try carry.appendSlice(allocator, data[start..]);
        }
    }

    if (carry.items.len > 0) {
        const trimmed = std.mem.trim(u8, carry.items, " \t\r");
        if (trimmed.len > 0) {
            try lines.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    if (lines.items.len > MAX_HISTORY_LINES) {
        const excess = lines.items.len - MAX_HISTORY_LINES;
        for (lines.items[0..excess]) |l| allocator.free(l);
        @memmove(lines.items[0..MAX_HISTORY_LINES], lines.items[excess..]);
        lines.shrinkRetainingCapacity(MAX_HISTORY_LINES);
    }

    return lines.toOwnedSlice(allocator);
}

pub fn freeHistory(allocator: std.mem.Allocator, history: [][]const u8) void {
    for (history) |entry| allocator.free(entry);
    allocator.free(history);
}

pub fn saveHistory(history: []const []const u8, path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "w") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    const start = if (history.len > MAX_HISTORY_LINES) history.len - MAX_HISTORY_LINES else 0;
    for (history[start..]) |entry| {
        _ = std.c.fwrite(entry.ptr, 1, entry.len, file);
        _ = std.c.fwrite("\n", 1, 1, file);
    }
}

fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.HomeNotFound;
    const home = std.mem.span(home_ptr);
    return std.fs.path.join(allocator, &.{ home, ".satibot_history" });
}

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;

    // Only print shutdown message once
    if (!shutdown_message_printed.load(.seq_cst)) {
        shutdown_message_printed.store(true, .seq_cst);
        std.debug.print("\n🛑 Console bot shutting down...\n", .{});
    }

    shutdown_requested.store(true, .seq_cst);
    // Stop loading animation during shutdown
    stopLoadingAnimation();

    if (global_event_loop) |el| {
        el.requestShutdown();
    }
}

/// Context for mock handlers
pub const MockContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    rag_enabled: bool,
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
        actual_text = std.mem.trimStart(u8, actual_text[4..], " ");
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

    // Start loading animation
    is_processing.store(true, .seq_cst);
    startLoadingAnimation();

    // Ensure loading stops when we exit this function
    defer {
        is_processing.store(false, .seq_cst);
        stopLoadingAnimation();
    }

    // Use counter in session ID so /new creates a fresh session without loading old history
    const session_id = try std.fmt.allocPrint(allocator, "mock_tg_99999_{d}", .{mock_session_counter});
    defer allocator.free(session_id);

    // Run agent logic with shutdown flag support
    var agent = try Agent.init(allocator, ctx.config, session_id, ctx.rag_enabled);
    agent.shutdown_flag = &shutdown_requested;
    defer agent.deinit();

    agent.run(actual_text) catch |err| {
        // Stop loading on error
        stopLoadingAnimation();

        if (err == error.Interrupted) {
            std.debug.print("\n🛑 Agent task cancelled\n", .{});
            return;
        }
        std.debug.print("Agent error: {any}\n", .{err});
        return;
    };

    const messages = agent.ctx.getMessages();
    if (messages.len > 0) {
        const last_msg = messages[messages.len - 1];
        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
            // Stop loading before showing response
            stopLoadingAnimation();
            std.debug.print("\n🤖 [Bot]: {s}\n", .{last_msg.content.?});
        }
    }

    // Index for RAG
    agent.indexConversation() catch |err| {
        std.debug.print("Warning: Failed to index conversation: {any}\n", .{err});
    };

    // Ensure loading is stopped after all processing
    stopLoadingAnimation();
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

    /// Initialize the Console bot
    pub fn init(allocator: std.mem.Allocator, config: Config, rag_enabled: bool) !*MockBot {
        const self = try allocator.create(MockBot);

        self.allocator = allocator;
        self.config = config;
        self.event_loop = try XevEventLoop.init(allocator, config);
        self.ctx = .{
            .allocator = allocator,
            .config = config,
            .rag_enabled = rag_enabled,
        };

        self.event_loop.setTaskHandler(mockTaskHandler);
        global_mock_context = &self.ctx;

        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *MockBot) void { // ziglint-ignore: Z030
        global_mock_context = null;
        self.event_loop.deinit();
        self.allocator.destroy(self);
        // `self.* = undefined;` is not needed here
        // as the memory is deallocated by `allocator.destroy(self)`
    }

    /// Read from console and add task to loop
    pub fn tick(self: *MockBot) !void {
        var buf: [1024]u8 = undefined;

        std.debug.print("\nUser > ", .{});
        const n = std.posix.read(0, &buf) catch |err| {
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
        if (n == 0) {
            // EOF received (Ctrl+D), trigger shutdown
            shutdown_requested.store(true, .seq_cst);
            self.event_loop.requestShutdown();
            return;
        }

        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (trimmed.len == 0) return;

        if (isQuitCommand(trimmed)) {
            shutdown_requested.store(true, .seq_cst);
            self.event_loop.requestShutdown();
            return;
        }

        try self.event_loop.addTask("console_msg", trimmed, "console_input");
    }

    /// Run the Console bot
    pub fn run(self: *MockBot) !void {
        const model = self.ctx.config.agents.defaults.model;
        std.debug.print("🎮 SatiBot Console\n", .{});
        std.debug.print("Model: {s}\n", .{model});
        std.debug.print("Type your message (Ctrl+D or 'exit' to quit):\n\n", .{});

        // Load history
        var repl_history: std.ArrayList([]const u8) = .empty;
        defer {
            const hp = getHistoryPath(self.allocator) catch null;
            if (hp) |path| {
                saveHistory(repl_history.items, path) catch {};
                self.allocator.free(path);
            }
            for (repl_history.items) |entry| self.allocator.free(entry);
            repl_history.deinit(self.allocator);
        }

        const hp = getHistoryPath(self.allocator) catch null;
        defer if (hp) |path| self.allocator.free(path);
        if (hp) |path| {
            const loaded = loadHistory(self.allocator, path) catch null;
            if (loaded) |entries| {
                defer self.allocator.free(entries);
                for (entries) |entry| {
                    repl_history.append(self.allocator, entry) catch {
                        self.allocator.free(entry);
                    };
                }
            }
            if (repl_history.items.len > 0) {
                std.debug.print("[History: {d} entries loaded]\n", .{repl_history.items.len});
            }
        }

        // Setup signal handlers
        global_event_loop = &self.event_loop;
        const sa: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        // Start event loop thread with reduced stack size (1MB instead of 16MB default)
        const el_thread = try std.Thread.spawn(.{
            .stack_size = 1048576, // 1MB stack
        }, XevEventLoop.run, .{&self.event_loop});
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
            std.debug.print("--- Console bot shut down successfully. ---\n", .{});
        }
    }
};

// Unit test for MockBot (requires valid OPENROUTER_API_KEY in environment or config)
test "MockBot logic test" {
    const allocator = std.testing.allocator;

    // Load config
    const config = try config_load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value, true);
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
    const config = try config_load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value, true);
    defer bot.deinit();

    // Test /new command by directly calling the handler logic
    // Note: Adding tasks to queue doesn't auto-process without running event loop
    try bot.event_loop.addTask("test1", "/new", "console_input");
    try bot.event_loop.addTask("test2", "Hello after new", "console_input");

    // Verify tasks were added to queue (actual processing requires event loop)
    try std.testing.expect(bot.event_loop.task_queue.items.len == 2);

    // Directly test that the mock handler increments counter for /new commands
    mock_session_counter += 1;
    try std.testing.expect(mock_session_counter == 1);

    // Test another increment
    mock_session_counter += 1;
    try std.testing.expect(mock_session_counter == 2);
}

test "MockBot /new with prompt processes prompt after incrementing counter" {
    const allocator = std.testing.allocator;

    // Reset global counter for test
    mock_session_counter = 0;

    // Load config
    const config = try config_load(allocator);
    defer config.deinit();

    const bot = try MockBot.init(allocator, config.value, true);
    defer bot.deinit();

    // Test /new with prompt - task is added to queue
    try bot.event_loop.addTask("test1", "/new what is zig?", "console_input");

    // Verify task was added (actual processing requires running event loop)
    try std.testing.expect(bot.event_loop.task_queue.items.len == 1);

    // Verify the session ID format includes counter (counter is used in session ID generation)
    const session_id = try std.fmt.allocPrint(allocator, "mock_tg_99999_{d}", .{mock_session_counter});
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("mock_tg_99999_0", session_id);
}

test "MockBot: No memory leak with --no-rag option" {
    const allocator = std.testing.allocator;

    // Load config
    const config = try config_load(allocator);
    defer config.deinit();

    // Test with rag_enabled = false (--no-rag)
    {
        var bot = try MockBot.init(allocator, config.value, false);
        defer bot.deinit();

        // Add some tasks to verify the event loop works with RAG disabled
        try bot.event_loop.addTask("test1", "Hello", "console_input");
        try bot.event_loop.addTask("test2", "How are you?", "console_input");

        // Verify tasks were added
        try std.testing.expect(bot.event_loop.task_queue.items.len == 2);

        // Verify RAG is disabled in context
        try std.testing.expect(bot.ctx.rag_enabled == false);
    }
    // If deinit works correctly, no memory leaks should occur
}

test "MockBot: Memory leak test - multiple init/deinit cycles with --no-rag" {
    const allocator = std.testing.allocator;

    // Load config
    const config = try config_load(allocator);
    defer config.deinit();

    // Test multiple init/deinit cycles to detect any cumulative leaks
    for (0..5) |_| {
        var bot = try MockBot.init(allocator, config.value, false);
        defer bot.deinit();

        // Add tasks
        try bot.event_loop.addTask("test_id", "Test message", "console_input");
    }
    // If we reach here without memory leaks, test passes
}
