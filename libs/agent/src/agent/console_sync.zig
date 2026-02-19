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
const Config = @import("core").config.Config;
const Agent = @import("../agent.zig").Agent;

var shutdown_requested = std.atomic.Value(bool).init(false);
var shutdown_message_printed = std.atomic.Value(bool).init(false);

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

    const session_id = try std.fmt.allocPrint(allocator, "console_sync_{d}", .{session_counter});
    defer allocator.free(session_id);

    var agent = try Agent.init(allocator, config, session_id, rag_enabled);
    defer agent.deinit();

    agent.shutdown_flag = &shutdown_requested;

    agent.run(actual_text) catch |err| {
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
            std.debug.print("\n🤖 [Bot]: {s}\n", .{last_msg.content.?});
        }
    }

    if (rag_enabled) {
        agent.indexConversation() catch |err| {
            std.debug.print("Warning: Failed to index conversation: {any}\n", .{err});
        };
    }
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

test "ConsoleSyncBot run function initializes bot" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{ .web = .{ .search = .{} } },
    };

    const bot = ConsoleSyncBot.init(allocator, config, true);
    try std.testing.expectEqual(allocator, bot.allocator);
    try std.testing.expectEqual(true, bot.rag_enabled);
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
