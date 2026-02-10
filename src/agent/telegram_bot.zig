const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const AsyncEventLoop = @import("event_loop.zig").AsyncEventLoop;
const telegram_handlers = @import("../chat_apps/telegram/telegram_handlers.zig");

/// Global flag for shutdown signal
/// Set to true when SIGINT (Ctrl+C) or SIGTERM is received
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Global event loop pointer for signal handler access
var global_event_loop: ?*AsyncEventLoop = null;

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
/// Sets the global shutdown flag and requests event loop shutdown
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    std.debug.print("\n🛑 Shutdown signal received, stopping event loop...\n", .{});
    shutdown_requested.store(true, .seq_cst);
    if (global_event_loop) |el| {
        el.requestShutdown();
    }
}

/// Static message sender function for the event loop callback
/// Sends a text message to a Telegram chat
fn sendMessageToTelegram(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
    defer allocator.free(chat_id_str);

    // Build the API URL for sending messages
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    // Create JSON payload with chat_id and message text
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id_str,
        .text = text,
    }, .{});
    defer allocator.free(body);

    // Set HTTP headers for JSON content
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    // Create a temporary HTTP client for sending (since this is a static function)
    // The main bot will reuse its client for efficiency
    var client = try http.Client.initWithSettings(allocator, .{
        .request_timeout_ms = 30000,
        .keep_alive = false,
    });
    defer client.deinit();

    // Send POST request to Telegram API
    const response = try client.post(url, headers, body);
    defer @constCast(&response).deinit();

    if (response.status != .ok) {
        std.debug.print("Failed to send message: status {d}\n", .{@intFromEnum(response.status)});
        return error.SendMessageFailed;
    }
}

fn setupSignalHandlers() void {
    const sa = std.posix.Sigaction{
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
/// It uses an async event loop for efficient concurrent message processing.
pub const TelegramBot = struct {
    /// Memory allocator for string operations and JSON parsing
    allocator: std.mem.Allocator,
    /// Bot configuration including API tokens and provider settings
    config: Config,
    /// Async event loop for processing messages concurrently
    event_loop: AsyncEventLoop,

    /// HTTP client re-used for all API calls to enable connection
    /// keep-alive, reducing TLS handshake overhead during polling.
    client: http.Client,

    /// Telegram context for handlers
    tg_ctx: telegram_handlers.TelegramContext,

    /// Initialize the TelegramBot with a dedicated HTTP client and event loop.
    /// Keep-alive is enabled to reduce TLS handshake overhead during
    /// polling, which is important for long-running bot operations.
    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        // Extract telegram config
        const tg_config = config.tools.telegram orelse return error.TelegramConfigNotFound;
        _ = tg_config; // TODO: Use this for Telegram integration

        const client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000, // 60 seconds timeout
            .keep_alive = true, // Reuse connections for efficiency
        });

        // Initialize generic event loop
        // TODO: Integrate Telegram bot with new event loop architecture
        var event_loop = try AsyncEventLoop.init(allocator, config);

        // Create the bot struct first
        var bot = TelegramBot{
            .allocator = allocator,
            .config = config,
            .event_loop = event_loop,
            .client = client,
            .tg_ctx = undefined, // Will be initialized below
        };

        // Now initialize the context with a pointer to the client in the struct
        bot.tg_ctx = telegram_handlers.TelegramContext.init(allocator, config, &bot.client);

        // Set up handlers
        event_loop.setTaskHandler(telegram_handlers.createTelegramTaskHandler(&bot.tg_ctx));
        event_loop.setEventHandler(telegram_handlers.createTelegramEventHandler(&bot.tg_ctx));

        return bot;
    }

    /// Clean up resources used by the TelegramBot
    /// Must be called when the bot is shutting down
    pub fn deinit(self: *TelegramBot) void {
        self.event_loop.deinit(); // Clean up event loop
        self.client.deinit(); // Close HTTP connections
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
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ tg_config.botToken, self.event_loop.getOffset() });
        defer self.allocator.free(url);

        // Make HTTP request to Telegram API
        const response = try self.client.get(url, &.{});
        defer @constCast(&response).deinit();

        // Structure for parsing the JSON response from Telegram.
        // We only map the fields we care about (ID, text, voice).
        // The result field is optional to handle cases where Telegram
        // returns no updates or an empty result array.
        const UpdateResponse = struct {
            /// Indicates if the request was successful
            ok: bool,
            /// Array of updates, can be null if no updates are available
            result: ?[]struct {
                /// Unique identifier for this update
                update_id: i64,
                /// Message object, can be null for other update types
                message: ?struct {
                    /// Unique message identifier
                    message_id: i64,
                    /// Chat information
                    chat: struct {
                        /// Unique identifier for this chat
                        id: i64,
                    },
                    /// Text message content, null for voice messages
                    text: ?[]const u8 = null,
                    /// Voice message information, null for text messages
                    voice: ?struct {
                        /// File identifier used to download the voice file
                        file_id: []const u8, // Used to download the voice file
                    } = null,
                } = null,
            } = null,
        };

        // Parse JSON response from Telegram API
        const parsed = try std.json.parseFromSlice(UpdateResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Process each update in the batch if updates exist
        if (parsed.value.result) |updates| {
            for (updates) |update| {
                // Update offset so we acknowledge this message in the next poll.
                // This prevents processing the same message multiple times.
                self.event_loop.updateOffset(update.update_id + 1);

                // Process message if it exists
                if (update.message) |msg| {
                    // Convert chat ID to string for API calls
                    const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{msg.chat.id});
                    defer self.allocator.free(chat_id_str);

                    // --- VOICE MESSAGE HANDLING ---
                    // Voice messages are currently not supported.
                    // This feature requires transcription service configuration.
                    if (msg.voice) |_| {
                        // Send a message indicating voice messages are not supported
                        try self.send_message(tg_config.botToken, chat_id_str, "🎤 Voice messages are not currently supported. Please send text messages instead.");
                        continue; // Skip further processing for voice messages
                    }

                    // Get the text message content
                    const final_text = msg.text orelse continue; // Skip if no text content

                    // Only process non-empty messages
                    if (final_text.len > 0) {
                        std.debug.print("Processing message from {s}: {s}\n", .{ chat_id_str, final_text });

                        // Map Telegram Chat ID to internal Session ID.
                        // This creates a persistent conversation history for this specific user.
                        const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{msg.chat.id});
                        defer self.allocator.free(session_id);

                        // Use the actual text for processing (may be modified by commands)
                        var actual_text = final_text;

                        // Handle magic command /help to show available commands.
                        // This provides users with a quick reference for bot functionality.
                        if (std.mem.startsWith(u8, final_text, "/help")) {
                            const help_text =
                                \\🐸 SatiBot Commands:\n\\n\\/new - Clear conversation session memory\n\\/help - Show this help message\n\\n\\Send any message to chat with the AI assistant.
                            ;
                            try self.send_message(tg_config.botToken, chat_id_str, help_text);
                            continue;
                        }

                        // Handle magic command /new to wipe memory.
                        // Helpful for restarting conversations without restarting the bot.
                        if (std.mem.startsWith(u8, final_text, "/new")) {
                            // Get user's home directory for session storage
                            const home = std.posix.getenv("HOME") orelse "/tmp";
                            // Construct path to session file for this chat
                            const session_path = try std.fs.path.join(self.allocator, &.{ home, ".bots", "sessions", try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_id}) });
                            defer self.allocator.free(session_path);
                            // Delete the session file to clear conversation history
                            std.fs.deleteFileAbsolute(session_path) catch {};

                            if (final_text.len <= 4) {
                                // User just sent "/new" without additional text
                                try self.send_message(tg_config.botToken, chat_id_str, "🆕 Session cleared! Send me a new message.");
                                continue;
                            }
                            // If user sent "/new some prompt", clear session but process
                            // the prompt after the "/new" command.
                            actual_text = std.mem.trimLeft(u8, final_text[4..], " ");
                        }

                        // Spin up a fresh Agent instance for this interaction.
                        // The Agent loads the session state from disk based on session_id.
                        var agent = Agent.init(self.allocator, self.config, session_id);
                        defer agent.deinit();

                        // Send initial "typing" action to show the user we're processing.
                        // This provides immediate feedback that the bot is working.
                        self.send_chat_action(tg_config.botToken, chat_id_str, "typing") catch {};

                        // Add message to event loop for async processing
                        const task_data = try std.fmt.allocPrint(self.allocator, "{d}:{d}:{s}", .{ msg.chat.id, msg.message_id, actual_text });
                        defer self.allocator.free(task_data);

                        try self.event_loop.addTask(try std.fmt.allocPrint(self.allocator, "tg_{d}", .{msg.chat.id}), task_data, "telegram");

                        // The event loop will process the message asynchronously
                        // and send the response through the handler
                    }
                }
            }
        }
    }

    /// Send a chat action (typing, upload_photo, record_video, etc.) to Telegram.
    /// This shows the user that the bot is processing their request.
    /// Common actions include: "typing", "upload_photo", "record_video", "upload_document"
    fn send_chat_action(self: *TelegramBot, token: []const u8, chat_id: []const u8, action: []const u8) !void {
        // Build the API URL for sending chat actions
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{token});
        defer self.allocator.free(url);

        // Create JSON payload with chat_id and action
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .action = action,
        }, .{});
        defer self.allocator.free(body);

        // Set HTTP headers for JSON content
        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        // Send POST request to Telegram API
        const response = try self.client.post(url, headers, body);
        @constCast(&response).deinit();
    }

    /// Helper to send a text message back to a chat using the Telegram API.
    /// This is the primary method for sending bot responses to users.
    fn send_message(self: *TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void {
        // Build the API URL for sending messages
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
        defer self.allocator.free(url);

        // Create JSON payload with chat_id and message text
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .text = text,
        }, .{});
        defer self.allocator.free(body);

        // Set HTTP headers for JSON content
        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        // Send POST request to Telegram API
        const response = try self.client.post(url, headers, body);
        @constCast(&response).deinit();
    }

    /// Start the event loop with Telegram polling
    /// This method integrates the event loop with Telegram's long-polling API
    pub fn run(self: *TelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        std.debug.print("� Telegram bot running with async event loop. Press Ctrl+C to stop.\n", .{});

        // Setup signal handlers
        global_event_loop = &self.event_loop;
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        // Send startup message if configured
        if (tg_config.chatId) |chat_id| {
            std.debug.print("Sending startup message to chat {s}...\n", .{chat_id});
            const startup_msg = "🐸 Bot is now online and ready! 🚀";
            sendMessageToTelegram(self.allocator, tg_config.botToken, std.fmt.parseInt(i64, chat_id, 10) catch 0, startup_msg) catch |err| {
                std.debug.print("Failed to send startup message: {any}\n", .{err});
            };
        }

        // Start event loop in a separate thread
        const event_loop_thread = try std.Thread.spawn(.{}, AsyncEventLoop.run, .{&self.event_loop});
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

/// Main entry point for the Telegram Bot service.
/// Initializes the bot and starts the async event loop.
/// The event loop handles polling, message processing, and cron jobs.
/// Sends a shutdown message to configured chat when terminated.
pub fn runBot(allocator: std.mem.Allocator, config: Config) !void {
    // Extract telegram config first - required for operation
    const tg_config = config.tools.telegram orelse {
        std.debug.print("Error: telegram configuration is required but not found.\n", .{});
        return error.TelegramConfigNotFound;
    };

    // Initialize the bot instance
    var bot = try TelegramBot.init(allocator, config);
    defer {
        // Send shutdown message to configured chat if available
        if (tg_config.chatId) |configured_chat_id| {
            std.debug.print("Sending shutdown message to configured chat {s}...\n", .{configured_chat_id});
            const shutdown_msg = "🛑 Bot is turned off. See you next time! 👋";
            sendMessageToTelegram(allocator, tg_config.botToken, std.fmt.parseInt(i64, configured_chat_id, 10) catch 0, shutdown_msg) catch |err| {
                std.debug.print("Failed to send shutdown message to configured chat: {any}\n", .{err});
            };
        }
        bot.deinit();
    }

    // Run the bot (this will start both the event loop and polling)
    try bot.run();
}

test "TelegramBot lifecycle" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Verify bot initialized correctly with event loop configured for Telegram
    try std.testing.expect(bot.config.tools.telegram != null);
    try std.testing.expectEqualStrings("fake-token", bot.config.tools.telegram.?.botToken);
}

test "TelegramBot init fails without config" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = null,
        },
    };

    // init() should fail if no telegram config
    const result = TelegramBot.init(allocator, config);
    try std.testing.expectError(error.TelegramConfigNotFound, result);
}

test "TelegramBot config validation" {
    const allocator = std.testing.allocator;

    // Test with valid config
    const valid_config = Config{
        .agents = .{ .defaults = .{ .model = "claude-3-sonnet" } },
        .providers = .{
            .anthropic = .{ .apiKey = "test-key" },
        },
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "test-token", .chatId = "12345" },
        },
    };

    var bot = try TelegramBot.init(allocator, valid_config);
    defer bot.deinit();

    // Verify bot initialized correctly with Telegram event loop
    try std.testing.expect(bot.config.tools.telegram != null);
    try std.testing.expectEqualStrings("test-token", bot.config.tools.telegram.?.botToken);
}

test "TelegramBot session ID generation" {
    const allocator = std.testing.allocator;
    const chat_id: i64 = 123456789;

    const session_id = try std.fmt.allocPrint(allocator, "tg_{d}", .{chat_id});
    defer allocator.free(session_id);

    try std.testing.expectEqualStrings("tg_123456789", session_id);
}

test "TelegramBot command detection - /new" {
    // Test command detection
    const new_cmd = "/new";
    try std.testing.expect(std.mem.startsWith(u8, new_cmd, "/new"));

    const new_with_prompt = "/new what is zig?";
    try std.testing.expect(std.mem.startsWith(u8, new_with_prompt, "/new"));
}

test "TelegramBot message JSON serialization" {
    const message = .{
        .chat_id = "12345",
        .text = "Test message",
    };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, message, .{});
    defer std.testing.allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "chat_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
}

test "TelegramBot config file template generation" {
    const default_json =
        \\{
        \\  "agents": {
        \\    "defaults": {
        \\      "model": "anthropic/claude-3-5-sonnet-20241022"
        \\    }
        \\  },
        \\  "providers": {
        \\    "openrouter": {
        \\      "apiKey": "sk-or-v1-..."
        \\    }
        \\  },
        \\  "tools": {
        \\    "web": {
        \\      "search": {
        \\        "apiKey": "BSA..."
        \\      }
        \\    },
        \\    "telegram": {
        \\      "botToken": "YOUR_BOT_TOKEN_HERE",
        \\      "chatId": "YOUR_CHAT_ID_HERE"
        \\    }
        \\  }
        \\}
    ;

    // Verify template contains key fields
    try std.testing.expect(std.mem.indexOf(u8, default_json, "agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "botToken") != null);
}

test "TelegramBot parallel messages - same user sends 2 messages rapidly" {
    // TODO: Update test for new event loop architecture
    // The new event loop doesn't track active chats internally
    return error.SkipZigTest;
}

test "TelegramBot parallel messages - offset updates correctly for batch" {
    // When 2 updates arrive in same getUpdates batch, offset should
    // advance to the highest update_id + 1. This ensures no duplicate processing.
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Simulate offset updates as if processing 2 messages in a batch
    // (the event loop does: updateOffset(update_id + 1))
    const update_ids = [_]i64{ 100, 101 };
    for (update_ids) |update_id| {
        bot.event_loop.updateOffset(update_id + 1);
    }

    // After processing both updates, offset should be at 102
    // (last update_id 101 + 1), so next poll skips both messages
    try std.testing.expectEqual(@as(i64, 102), bot.event_loop.getOffset());
}

test "TelegramBot parallel messages - command detection is per-message" {
    // When 2 messages arrive together, one may be a command (/new) and
    // the other a regular message. Each should be detected independently.
    const msg1 = "/new";
    const msg2 = "What is Zig?";

    // msg1 is a /new command
    try std.testing.expect(std.mem.startsWith(u8, msg1, "/new"));
    try std.testing.expect(!std.mem.startsWith(u8, msg1, "/help"));

    // msg2 is a regular message (not a command)
    try std.testing.expect(!std.mem.startsWith(u8, msg2, "/new"));
    try std.testing.expect(!std.mem.startsWith(u8, msg2, "/help"));

    // Both have independent session cleanup behavior:
    // msg1 triggers session delete, msg2 goes to agent.run()
}

test "TelegramBot parallel messages - session IDs are independent per chat" {
    // Two parallel messages from different chats should generate
    // independent session IDs, ensuring conversations don't cross-contaminate.
    const allocator = std.testing.allocator;

    const chat_id_a: i64 = 111222333;
    const chat_id_b: i64 = 444555666;

    const session_a = try std.fmt.allocPrint(allocator, "tg_{d}", .{chat_id_a});
    defer allocator.free(session_a);
    const session_b = try std.fmt.allocPrint(allocator, "tg_{d}", .{chat_id_b});
    defer allocator.free(session_b);

    // Session IDs must be different
    try std.testing.expect(!std.mem.eql(u8, session_a, session_b));

    // Each follows the tg_{chat_id} pattern
    try std.testing.expectEqualStrings("tg_111222333", session_a);
    try std.testing.expectEqualStrings("tg_444555666", session_b);
}
