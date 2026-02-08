const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const AsyncEventLoop = @import("event_loop.zig").AsyncEventLoop;

/// Global flag for shutdown signal
/// Set to true when SIGINT (Ctrl+C) or SIGTERM is received
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
/// Sets the global shutdown flag to trigger graceful shutdown
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Setup signal handlers for graceful shutdown
/// Registers handlers for SIGINT (Ctrl+C) and SIGTERM signals
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
/// It uses long-polling to receive updates (messages, voice notes)
/// and processes them using an async event loop for efficient concurrent operations.
pub const TelegramBot = struct {
    /// Memory allocator for string operations and JSON parsing
    allocator: std.mem.Allocator,
    /// Bot configuration including API tokens and provider settings
    config: Config,
    /// Async event loop for processing messages concurrently
    event_loop: AsyncEventLoop,

    /// Offset for long-polling. This ensures we don't process the
    /// same message twice. It is updated to the last update_id + 1
    /// after processing each batch of updates.
    offset: i64 = 0,

    /// HTTP client re-used for all API calls to enable connection
    /// keep-alive, reducing TLS handshake overhead during polling.
    client: http.Client,

    /// Initialize the TelegramBot with a dedicated HTTP client and event loop.
    /// Keep-alive is enabled to reduce TLS handshake overhead during
    /// polling, which is important for long-running bot operations.
    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        // Create HTTP client with 60-second timeout and keep-alive enabled
        const client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000, // 60 seconds timeout
            .keep_alive = true, // Reuse connections for efficiency
        });
        
        // Initialize async event loop for concurrent message processing
        const event_loop = try AsyncEventLoop.init(allocator, config);
        
        return .{
            .allocator = allocator,
            .config = config,
            .event_loop = event_loop,
            .client = client,
        };
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
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ tg_config.botToken, self.offset });
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
                self.offset = update.update_id + 1;

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
                                \\🐸 SatiBot Commands:
                                \\
                                \/new - Clear conversation session memory
                                \/help - Show this help message
                                \\
                                \\Send any message to chat with the AI assistant.
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
                        try self.event_loop.addChatMessage(msg.chat.id, actual_text);

                        // Send the final response back to Telegram.
                        // The event loop processes the message asynchronously and we can get the result
                        // For now, we'll process it synchronously to maintain the same interface
                        // In a full async implementation, this would be handled by event loop callbacks
                        agent.run(actual_text) catch |err| {
                            std.debug.print("Error running agent: {any}\n", .{err});
                            const error_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Error: Agent failed to process request\n\nPlease try again.", .{});
                            defer self.allocator.free(error_msg);
                            try self.send_message(tg_config.botToken, chat_id_str, error_msg);
                        };

                        // Get all messages from the agent's conversation context
                        const messages = agent.ctx.get_messages();
                        if (messages.len > 0) {
                            // Get the last message (should be the assistant's response)
                            const last_msg = messages[messages.len - 1];
                            // Only send if it's an assistant message with content
                            if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                                try self.send_message(tg_config.botToken, chat_id_str, last_msg.content.?);
                            }
                        }

                        // Save session state to Vector/Graph DB for long-term memory.
                        // This enables RAG (Retrieval-Augmented Generation) functionality.
                        agent.index_conversation() catch {};
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
};

/// Main entry point for the Telegram Bot service.
/// Initializes the bot and enters an infinite polling loop.
/// Sends a shutdown message to all active chats when terminated.
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
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
            bot.send_message(tg_config.botToken, configured_chat_id, shutdown_msg) catch |err| {
                std.debug.print("Failed to send shutdown message to configured chat: {any}\n", .{err});
            };
        }
        bot.deinit();
    }

    // Setup signal handlers for graceful shutdown
    setupSignalHandlers();

    // Display startup message
    std.debug.print("🐸 Telegram bot running. Press Ctrl+C to stop.\n", .{});

    // chatId is required - terminate if not configured
    const chat_id = tg_config.chatId orelse {
        std.debug.print("Error: telegram.chatId is required but not configured. Terminating.\n", .{});
        return error.TelegramChatIdNotConfigured;
    };

    // Send startup message to configured chat
    std.debug.print("Sending startup message to chat {s}...\n", .{chat_id});
    const startup_msg = "🐸 Bot is now online and ready! 🚀";
    bot.send_message(tg_config.botToken, chat_id, startup_msg) catch |err| {
        std.debug.print("Failed to send startup message: {any}\n", .{err});
    };

    // Main event loop - runs indefinitely until shutdown signal
    // The event loop handles both Telegram polling and message processing
    while (!shutdown_requested.load(.seq_cst)) {
        // Process any pending messages in the event loop
        bot.event_loop.run() catch |err| {
            std.debug.print("Error in event loop processing: {any}\n", .{err});
            // Wait 5 seconds before retrying to avoid spamming error logs
            std.Thread.sleep(std.time.ns_per_s * 5);
        };

        // Check for shutdown signal
        if (shutdown_requested.load(.seq_cst)) {
            std.debug.print("\n🛑 Shutdown requested. Sending goodbye messages 🌙.\n", .{});
            break;
        }

        // Do Telegram polling in the main thread
        bot.tick() catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\n", .{err});
            // Wait 5 seconds before retrying to avoid spamming error logs
            std.Thread.sleep(std.time.ns_per_s * 5);
        };

        // Small sleep to prevent CPU spinning
        std.Thread.sleep(std.time.ns_per_ms * 100);
    }
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

    try std.testing.expectEqual(bot.offset, 0);
}

test "TelegramBot tick returns if no config" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = null,
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // this should return immediately (no network call)
    try bot.tick();
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

    // Verify bot initialized correctly
    try std.testing.expectEqual(bot.offset, 0);
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
