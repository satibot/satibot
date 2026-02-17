/// xev-based Telegram bot implementation
/// The bot uses the event loop's HTTP client for all operations.
/// HTTP requests are added as tasks to the event loop.
/// Centralized HTTP handling - All HTTP requests (both Telegram and OpenRouter)
/// are processed through the event loop's task handler.
///
/// Logic Graph:
/// ```mermaid
/// graph TD
///     Main[Main Thread] --> |tick| Loop[Polling Loop]
///     Loop --> |addTask| task_q[(Xev Task Queue)]
///     task_q --> |process| EL[Event Loop Thread]
///     EL --> |HTTP GET| TG[Telegram API]
///     TG --> |Updates| EL
///     EL --> |Parse| Handler[Telegram Handlers]
///     Handler --> |Update Offset| Offset[Event Loop State]
///     Handler --> |Process| Agent[AI Agent]
///     Agent --> |Reply| EL
///     EL --> |HTTP POST| TG
/// ```
///
/// IMPORTANT: Offset Update Fix
/// ---------------------------
/// When using event loop for HTTP requests, we must ensure the polling offset
/// is updated after processing messages. Without this, the bot would poll
/// the same updates repeatedly (offset=0 in logs).
/// The fix requires:
/// 1. Passing event_loop reference to TelegramContext
/// 2. Tracking max update_id in polling response handler
/// 3. Calling event_loop.updateOffset() after processing
const std = @import("std");
const Config = @import("../../config.zig").Config;
const http = @import("../../http.zig");
const XevEventLoop = @import("../../utils/xev_event_loop.zig").XevEventLoop;
const telegram_handlers = @import("telegram_handlers.zig");
const providers = @import("../../root.zig").providers;
const constants = @import("../../constants.zig");

/// Global flag for shutdown signal
/// Set to true when SIGINT (Ctrl+C) or SIGTERM is received
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Global event loop pointer for signal handler access
var global_event_loop: ?*XevEventLoop = null;

/// Global config for sending messages on shutdown
var global_bot_token: ?[]const u8 = null;
var global_chat_id: ?i64 = null;

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
/// Sets the global shutdown flag and requests event loop shutdown
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    std.debug.print("\n🛑 Shutdown signal received, stopping event loop...\n", .{});
    shutdown_requested.store(true, .seq_cst);

    // Try to send shutdown message to chat
    if (global_event_loop) |el| {
        if (global_bot_token) |token| {
            if (global_chat_id) |chat_id| {
                sendMessageToTelegram(el, token, chat_id, "🛑 Bot is shutting down...") catch {
                    std.debug.print("Failed to send shutdown message to chat\n", .{});
                };
            }
        }
        el.requestShutdown();
    }
}

/// Set global config for signal handler to send shutdown messages
pub fn setGlobalConfig(bot_token: []const u8, chat_id: i64) void {
    global_bot_token = bot_token;
    global_chat_id = chat_id;
}

/// Static message sender function that uses the event loop's HTTP client
/// Sends a text message to a Telegram chat
fn sendMessageToTelegram(event_loop: *XevEventLoop, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    // Telegram rejects text payloads longer than 4096 UTF-8 characters.
    // Split into valid chunks so startup/shutdown notices remain deliverable.
    if (text.len == 0) {
        try sendMessageChunkToTelegram(event_loop, bot_token, chat_id, text);
        return;
    }

    var start: usize = 0;
    while (start < text.len) {
        const end = nextTelegramChunkEnd(text, start);
        try sendMessageChunkToTelegram(event_loop, bot_token, chat_id, text[start..end]);
        start = end;
    }
}

fn sendMessageChunkToTelegram(event_loop: *XevEventLoop, bot_token: []const u8, chat_id: i64, text_chunk: []const u8) !void {
    const chat_id_str = try std.fmt.allocPrint(event_loop.allocator, "{d}", .{chat_id});
    defer event_loop.allocator.free(chat_id_str);

    // Build the API URL for sending messages
    const url = try std.fmt.allocPrint(event_loop.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer event_loop.allocator.free(url);

    // Create JSON payload with chat_id and message text
    const body = try std.json.Stringify.valueAlloc(event_loop.allocator, .{
        .chat_id = chat_id_str,
        .text = text_chunk,
    }, .{});
    defer event_loop.allocator.free(body);

    // Create task data for HTTP request
    const task_data = try std.fmt.allocPrint(event_loop.allocator, "POST:{s}:{s}", .{ url, body });
    defer event_loop.allocator.free(task_data);

    // Add HTTP task to event loop
    try event_loop.addTask(try std.fmt.allocPrint(event_loop.allocator, "tg_send_{d}", .{chat_id}), task_data, "telegram_http");
}

fn nextTelegramChunkEnd(text: []const u8, start: usize) usize {
    var cursor = start;
    var char_count: usize = 0;

    while (cursor < text.len and char_count < constants.TELEGRAM_MAX_TEXT_CHARS) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch {
            cursor += 1;
            char_count += 1;
            continue;
        };

        if (cursor + sequence_len > text.len) {
            cursor += 1;
            char_count += 1;
            continue;
        }

        cursor += sequence_len;
        char_count += 1;
    }

    return cursor;
}

fn setupSignalHandlers() void {
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };

    // Handle SIGINT (Ctrl+C) - user initiated shutdown
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    // Handle SIGTERM - system initiated shutdown
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// TelegramBot manages the interaction with the Telegram Bot API.
/// It uses an xev-based event loop for efficient concurrent message processing.
pub const TelegramBot = struct {
    /// Memory allocator for string operations and JSON parsing
    allocator: std.mem.Allocator,
    /// Bot configuration including API tokens and provider settings
    config: Config,
    /// Xev-based event loop for processing messages concurrently
    event_loop: XevEventLoop,
    /// HTTP client for making API requests
    http_client: http.Client,

    /// Telegram context for handlers
    tg_ctx: telegram_handlers.TelegramContext,

    /// Initialize the TelegramBot with xev event loop.
    /// The event loop will manage HTTP connections for efficiency.
    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        // Extract telegram config
        const tg_config = config.tools.telegram orelse return error.TelegramConfigNotFound;
        _ = tg_config; // TODO: Use this for Telegram integration

        // Initialize xev-based event loop
        const event_loop = try XevEventLoop.init(allocator, config);

        // Initialize HTTP client
        const http_client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000,
            .keep_alive = true,
        });

        // Create the bot struct first
        var bot: TelegramBot = .{
            .allocator = allocator,
            .config = config,
            .event_loop = event_loop,
            .http_client = http_client,
            .tg_ctx = undefined, // Will be initialized below
        };

        // Now initialize the context
        bot.tg_ctx = telegram_handlers.TelegramContext.init(allocator, config, &bot.http_client);
        // CRITICAL: Set event_loop reference to enable offset updates
        // Without this, the bot would get stuck polling offset=0 forever
        bot.tg_ctx.event_loop = &bot.event_loop; // Reference after event_loop is moved into bot

        // Initialize session cache for better performance
        bot.tg_ctx.initSessionCache();

        // Schedule periodic session cache cleanup
        const cleanup_interval_ms = 1800000; // 30 minutes in milliseconds
        try bot.event_loop.scheduleEvent("session_cache_cleanup", .custom, null, cleanup_interval_ms);

        // Set up handlers for xev event loop
        bot.event_loop.setTaskHandler(telegram_handlers.createTelegramTaskHandler(&bot.tg_ctx));
        bot.event_loop.setEventHandler(telegram_handlers.createTelegramEventHandler(&bot.tg_ctx));

        return bot;
    }

    /// Clean up resources used by the TelegramBot
    /// Must be called when the bot is shut down
    pub fn deinit(self: *TelegramBot) void {
        // Clean up agent pool first
        self.tg_ctx.deinit();
        self.http_client.deinit();
        self.event_loop.deinit();
        self.* = undefined;
    }

    /// Single polling iteration.
    /// Fetches updates from Telegram, processes them, and sends replies.
    /// This function is non-blocking in the sense that it processes one
    /// batch of updates and returns. It should be called repeatedly
    /// in a loop for continuous operation.
    pub fn tick(self: *TelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        // Long-polling request URL.
        // timeout=5 tells Telegram to wait up to 5 seconds for new
        // messages if none are immediately available. This reduces empty
        // responses and network traffic, making polling more efficient.
        // allowed_updates=["message"] restricts updates to only messages
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5&allowed_updates=message", .{ tg_config.botToken, self.event_loop.getOffset() });
        defer self.allocator.free(url);

        // Create HTTP task for polling
        const task_data = try std.fmt.allocPrint(self.allocator, "GET:{s}", .{url});
        defer self.allocator.free(task_data);

        // Add HTTP task to event loop for polling
        try self.event_loop.addTask("telegram_poll", task_data, "telegram_http");
    }

    /// Start the event loop with Telegram polling
    /// This method integrates the xev event loop with Telegram's long-polling API
    pub fn run(self: *TelegramBot) !void {
        _ = self.config.tools.telegram orelse {
            std.debug.print("Error: telegram configuration is required but not found.\n", .{});
            return error.TelegramConfigNotFound;
        };

        std.debug.print("🐸 Telegram bot running with xev event loop. Press Ctrl+C to stop.\n", .{});

        // Setup signal handlers
        global_event_loop = &self.event_loop;
        const sa: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        // Skip startup message to avoid conflicts
        // if (tg_config.chatId) |chat_id| {
        //     std.debug.print("Sending startup message to chat {s}...\n", .{chat_id});
        //     const startup_msg = "🐸 Bot is now online and ready! 🚀";
        //     sendMessageToTelegram(self.allocator, tg_config.botToken, std.fmt.parseInt(i64, chat_id, 10) catch 0, startup_msg) catch |err| {
        //         std.debug.print("Failed to send startup message: {any}\n", .{err});
        //     };
        // }

        // Start event loop in a separate thread
        const event_loop_thread = try std.Thread.spawn(.{}, XevEventLoop.run, .{&self.event_loop});
        defer event_loop_thread.join();

        // Main thread handles Telegram polling
        while (!shutdown_requested.load(.seq_cst)) {
            self.tick() catch |err| {
                std.debug.print("Error in tick: {any}\n", .{err});
                // Continue running even if there's an error
            };

            // Small delay to prevent excessive polling
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        std.debug.print("\n🌙 Event loop stopped. Goodbye!\n", .{});
    }
};

/// Main entry point for the Telegram Bot service with xev event loop.
/// Initializes the bot and starts the xev-based async event loop.
/// The event loop handles polling, message processing, and cron jobs.
/// Sends a shutdown message to configured chat when terminated.
pub fn runBot(allocator: std.mem.Allocator, config: Config) !void {
    // Extract telegram config first - required for operation
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Error: telegram configuration is required but not found.\n", .{});
        return error.TelegramConfigNotFound;
    };

    // Set global config for signal handler to send shutdown messages
    if (tg_config.chatId) |chat_id_str| {
        const chat_id = std.fmt.parseInt(i64, chat_id_str, 10) catch 0;
        if (chat_id != 0) {
            setGlobalConfig(tg_config.botToken, chat_id);
        }
    }

    // Initialize the bot instance
    var bot = try TelegramBot.init(allocator, config);
    defer {
        // Send shutdown message to configured chat if available
        if (tg_config.chatId) |configured_chat_id| {
            std.debug.print("Sending shutdown message to configured chat {s}...\n", .{configured_chat_id});
            const shutdown_msg = "🛑 Bot is turned off. See you next time! 👋";
            sendMessageToTelegram(&bot.event_loop, tg_config.botToken, std.fmt.parseInt(i64, configured_chat_id, 10) catch 0, shutdown_msg) catch |err| {
                std.debug.print("Failed to send shutdown message to configured chat: {any}\n", .{err});
            };
        }
        bot.deinit();
    }

    // Run the bot (this will start both the event loop and polling)
    try bot.run();
}
