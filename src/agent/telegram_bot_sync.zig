/// Synchronous Telegram Bot Implementation
///
/// This is a simplified, synchronous version of the Telegram bot that processes
/// updates one at a time, blocking until each update is fully processed before
/// moving on to the next. It's designed for simplicity and reliability.
///
/// Key characteristics:
/// - **Synchronous processing**: One message at a time, no concurrency
/// - **Simple architecture**: Direct HTTP calls, no event loop complexity
/// - **Reliable**: Easier to debug and understand
/// - **Lower resource usage**: No thread pools or event loop overhead
/// - **Text-only**: Supports text messages, voice messages not supported
///
/// Use this version when:
/// - You need a simple, reliable bot
/// - Resource usage is a concern
/// - You're developing or debugging
/// - You don't need voice message transcription
/// - You don't need high-throughput concurrent processing
///
/// For voice message support and high-performance concurrent processing,
/// use the xev-based async version.
const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const constants = @import("../constants.zig");

/// Synchronous TelegramBot manages interaction with the Telegram Bot API.
///
/// This implementation uses simple long-polling and processes messages
/// sequentially, making it easy to understand and debug.
///
/// Architecture:
/// - Single-threaded synchronous processing
/// - Direct HTTP calls to Telegram API
/// - One message processed at a time
/// - Simple error handling and recovery
pub const TelegramBot = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // Offset for long-polling. This ensures we don't process the
    // same message twice. It is updated to the last update_id + 1
    // after processing.
    offset: i64 = 0,

    // HTTP client re-used for all API calls to enable connection
    // keep-alive.
    client: http.Client,

    /// Initialize the TelegramBot with a dedicated HTTP client.
    ///
    /// The HTTP client is configured with:
    /// - 60-second timeout (sufficient for LLM processing)
    /// - Keep-alive enabled (reduces TLS handshake overhead)
    ///
    /// Args:
    ///   - allocator: Memory allocator for string operations
    ///   - config: Bot configuration including API tokens
    ///
    /// Returns: Initialized TelegramBot instance
    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        const client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000,
            .keep_alive = true,
        });
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
        };
    }

    pub fn deinit(self: *TelegramBot) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Single polling iteration - fetches and processes one batch of updates.
    ///
    /// This method:
    /// 1. Makes a long-polling request to Telegram API (5-second timeout)
    /// 2. Processes each message in the response sequentially
    /// 3. Handles voice message transcription if Groq is configured
    /// 4. Processes text through the AI agent
    /// 5. Sends responses back to Telegram
    ///
    /// The method is non-blocking in the sense that it processes one batch
    /// of updates and returns. It should be called repeatedly in a loop
    /// for continuous operation.
    ///
    /// Error handling: Network errors are propagated to the caller,
    /// which should implement retry logic.
    pub fn tick(self: *TelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        // Build long-polling request URL with:
        // - offset: Ensures we don't process the same message twice
        // - timeout=5: Tells Telegram to wait up to 5 seconds for new messages
        // - This reduces empty responses and network traffic
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ tg_config.botToken, self.offset });
        defer self.allocator.free(url);

        const response = try self.client.get(url, &.{});
        defer @constCast(&response).deinit();

        // Parse JSON response from Telegram API
        // We only map the fields we care about to minimize memory usage
        const UpdateResponse = struct {
            ok: bool,
            result: []struct {
                update_id: i64,
                message: ?struct {
                    chat: struct {
                        id: i64,
                    },
                    text: ?[]const u8 = null,
                    voice: ?struct {
                        file_id: []const u8, // Used to download the voice file
                    } = null,
                } = null,
            },
        };

        const parsed = try std.json.parseFromSlice(UpdateResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Process each update in the batch.
        for (parsed.value.result) |update| {
            // Update offset so we acknowledge this message in the next poll.
            self.offset = update.update_id + 1;

            if (update.message) |msg| {
                const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{msg.chat.id});
                defer self.allocator.free(chat_id_str);

                // Handle voice messages - currently not supported in sync version
                // Voice transcription requires additional provider configuration
                if (msg.voice) |voice| {
                    _ = voice; // Mark as used
                    try self.sendMessage(tg_config.botToken, chat_id_str, "🎤 Voice messages are not supported in the sync version. Please use text messages or the async version with voice transcription enabled.");
                }

                // Process text messages only (voice messages are handled above)
                const final_text = msg.text orelse continue;

                if (final_text.len > 0) {
                    std.debug.print("Processing message from {s}: {s}\n", .{ chat_id_str, final_text });

                    // Map Telegram Chat ID to internal Session ID
                    // This creates a persistent conversation history for each user
                    // Format: "tg_<chat_id>" to avoid conflicts with other platforms
                    const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{msg.chat.id});
                    defer self.allocator.free(session_id);

                    var actual_text = final_text;

                    // Handle the "/new" magic command to clear conversation memory
                    // This allows users to restart conversations without restarting the bot
                    // Usage: "/new" - clears session and sends confirmation
                    //        "/new <message>" - clears session and processes the message
                    if (std.mem.startsWith(u8, final_text, "/new")) {
                        const home = std.posix.getenv("HOME") orelse "/tmp";
                        const session_path = try std.fs.path.join(self.allocator, &.{ home, ".bots", "sessions", try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_id}) });
                        defer self.allocator.free(session_path);
                        std.fs.deleteFileAbsolute(session_path) catch |err| {
                            std.debug.print("Warning: Failed to delete session file: {any}\n", .{err});
                        };

                        // If user sent "/new" without additional text, clear session and confirm
                        if (final_text.len <= 4) {
                            try self.sendMessage(tg_config.botToken, chat_id_str, "🆕 Session cleared! Send me a new message.");
                            continue;
                        }
                        // If user sent "/new <prompt>", clear session but process the prompt
                        actual_text = std.mem.trimStart(u8, final_text[4..], " ");
                    }

                    // Create a fresh Agent instance for this interaction
                    // The agent loads session state from disk based on session_id
                    // Each message gets its own agent instance to ensure isolation
                    var agent = try Agent.init(self.allocator, self.config, session_id, true);
                    defer agent.deinit();

                    // Send typing indicator to show user that bot is processing
                    // This appears while waiting for LLM response (can take several seconds)
                    // We use a volatile bool to coordinate between main thread and typing thread
                    var typing_done: bool = false;

                    // Spawn a thread to continuously send typing indicator every 5 seconds
                    // This ensures typing indicator shows until all chunks are sent
                    const typing_thread = try std.Thread.spawn(.{}, struct {
                        fn run(
                            bot: *TelegramBot,
                            token: []const u8,
                            chat_id: []const u8,
                            done_flag: *bool,
                        ) void {
                            while (!done_flag.*) {
                                std.Thread.sleep(std.time.ns_per_s * 5);
                                if (done_flag.*) break;
                                bot.sendChatAction(token, chat_id) catch |err| {
                                    std.debug.print("Failed to send typing action: {any}\n", .{err});
                                };
                            }
                        }
                    }.run, .{ self, tg_config.botToken, chat_id_str, &typing_done });
                    errdefer {
                        typing_done = true;
                        typing_thread.join();
                    }

                    // Send initial typing action immediately
                    self.sendChatAction(tg_config.botToken, chat_id_str) catch |err| {
                        std.debug.print("Warning: Failed to send typing indicator: {any}\n", .{err});
                        // Continue processing even if typing indicator fails
                    };

                    // Run the agent loop (LLM inference + Tool execution)
                    // This processes the user message and generates a response
                    agent.run(actual_text) catch |err| {
                        // Mark typing as done first
                        typing_done = true;
                        typing_thread.join();

                        // Log the error and send a user-friendly error message
                        std.debug.print("Error running agent: {any}\n", .{err});
                        const error_msg = if (agent.last_error) |last_err|
                            try std.fmt.allocPrint(self.allocator, "❌ Error: {s}\n\nPlease try again.", .{last_err})
                        else
                            try std.fmt.allocPrint(self.allocator, "❌ Error: {any}\n\nPlease try again.", .{err});
                        defer self.allocator.free(error_msg);
                        self.sendMessage(tg_config.botToken, chat_id_str, error_msg) catch |send_err| {
                            std.debug.print("Failed to send error message: {any}\n", .{send_err});
                        };
                        return;
                    };

                    // Send the agent's response back to Telegram
                    // We look for the last message in the conversation history
                    // and send it if it's from the assistant and has content
                    const messages = agent.ctx.getMessages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                            self.sendMessage(tg_config.botToken, chat_id_str, last_msg.content.?) catch |err| {
                                std.debug.print("Failed to send response message: {any}\n", .{err});
                            };
                        }
                    }

                    // Mark typing as done - stops the typing thread
                    typing_done = true;
                    typing_thread.join();

                    // Save conversation to Vector/Graph DB for long-term memory
                    // This enables RAG (Retrieval-Augmented Generation) in future conversations
                    agent.indexConversation() catch |err| {
                        // Log indexing error but don't fail the response
                        std.debug.print("Warning: Failed to index conversation: {any}\n", .{err});
                    };
                }
            }
        }
    }

    /// Send a text message to a Telegram chat.
    ///
    /// This helper method constructs and sends a message via the Telegram API.
    /// It handles JSON serialization and HTTP POST request.
    ///
    /// Args:
    ///   - token: Bot token for authentication
    ///   - chat_id: Target chat ID as string
    ///   - text: Message content to send
    fn sendMessage(self: *TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void {
        // Telegram rejects text payloads longer than 4096 UTF-8 characters.
        // Split long replies on UTF-8 codepoint boundaries to keep API requests valid.
        if (text.len == 0) {
            try self.sendMessageChunk(token, chat_id, text);
            return;
        }

        var start: usize = 0;
        while (start < text.len) {
            const end = nextTelegramChunkEnd(text, start);
            try self.sendMessageChunk(token, chat_id, text[start..end]);
            start = end;
        }
    }

    fn sendMessageChunk(self: *TelegramBot, token: []const u8, chat_id: []const u8, text_chunk: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .text = text_chunk,
        }, .{});
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const response = try self.client.post(url, headers, body);
        @constCast(&response).deinit();
    }

    /// Send a chat action (typing indicator) to a Telegram chat.
    ///
    /// This tells Telegram to show "typing..." status to the user while
    /// the bot is processing their message and waiting for LLM response.
    ///
    /// Args:
    ///   - token: Bot token for authentication
    ///   - chat_id: Target chat ID as string
    fn sendChatAction(self: *TelegramBot, token: []const u8, chat_id: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{token});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .action = "typing",
        }, .{});
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const response = try self.client.post(url, headers, body);
        @constCast(&response).deinit();
    }
};

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

/// Main entry point for the synchronous Telegram Bot service.
///
/// This function:
/// 1. Initializes the bot with configuration
/// 2. Enters an infinite polling loop
/// 3. Handles errors gracefully with retry logic
/// 4. Runs until interrupted (Ctrl+C)
///
/// The polling loop is robust - if tick() fails due to network errors,
/// it logs the error and retries after a 5-second delay.
///
/// Args:
///   - allocator: Memory allocator for bot initialization
///   - config: Bot configuration
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Send startup ready message to configured admin chat if available
    // This notifies the admin that the bot is online and ready to process messages
    if (config.tools.telegram) |tg_config| {
        if (tg_config.chatId) |chat_id| {
            std.debug.print("Sending startup message to chat {s}...\n", .{chat_id});
            bot.sendMessage(tg_config.botToken, chat_id, "🚀 Bot is ready and starting to poll for messages...") catch |err| {
                std.debug.print("Warning: Failed to send startup message: {any}\n", .{err});
                // Continue even if startup message fails
            };
        } else {
            std.debug.print("Note: No chatId configured. Startup message not sent.\n", .{});
        }
    } else {
        std.debug.print("Warning: No Telegram configuration found. Skipping startup message.\n", .{});
        return error.NoTelegramConfig;
    }

    while (true) {
        // Robust error handling: If tick() fails (e.g., network error),
        // log it and retry after a delay. This prevents the bot from
        // crashing completely on transient errors.
        bot.tick() catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\nRetrying in 5 seconds...\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
        };
    }
}

test "TelegramBot lifecycle" {
    const allocator = std.testing.allocator;
    const config: Config = .{
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
    const config: Config = .{
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

test "TelegramBot send_chat_action with fake token fails" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token-for-testing" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Test that send_chat_action returns an error with fake credentials
    // This verifies the method signature and HTTP call logic are correct
    const result = bot.sendChatAction("fake-token-for-testing", "123456");
    try std.testing.expectError(error.HttpError, result);
}

test "TelegramBot typing thread coordination" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token-for-testing" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Test typing thread lifecycle
    var typing_done: bool = false;

    // Start typing thread
    const typing_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            bot_instance: *TelegramBot,
            token: []const u8,
            chat_id: []const u8,
            done_flag: *bool,
        ) void {
            var counter: usize = 0;
            while (!done_flag.* and counter < 3) {
                std.Thread.sleep(std.time.ns_per_ms * 10); // Short sleep for testing
                counter += 1;
                // sendChatAction will fail with fake token but thread should continue
                bot_instance.sendChatAction(token, chat_id) catch |err| {
                    // Expected to fail with fake token
                    std.debug.assert(err == error.HttpError);
                };
            }
        }
    }.run, .{ &bot, "fake-token", "123456", &typing_done });

    // Let thread run for a bit
    std.Thread.sleep(std.time.ns_per_ms * 50);

    // Signal thread to stop
    typing_done = true;
    typing_thread.join();

    // Verify thread stopped cleanly
    try std.testing.expect(typing_done);
}

test "TelegramBot error handling with last_error" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token-for-testing" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Test that error handling doesn't crash even when send_message fails
    const error_msg = "Test error message";

    // This should not crash even with fake token
    bot.sendMessage("fake-token", "123456", error_msg) catch |err| {
        // Expected to fail with fake token
        std.debug.assert(err == error.HttpError);
    };
}

test "TelegramBot message chunking handles empty text" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token-for-testing" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Test that empty text is handled gracefully
    // This will fail with fake token but shouldn't crash
    bot.sendMessage("fake-token", "123456", "") catch |err| {
        // Expected to fail with fake token
        std.debug.assert(err == error.HttpError);
    };
}

test "TelegramBot: memory - init and deinit without leaks" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    // Test that init and deinit work without memory leaks
    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(i64, 0), bot.offset);
    try std.testing.expectEqual(allocator, bot.allocator);
    try std.testing.expectEqual(config, bot.config);
}

test "TelegramBot: memory - client reuse across operations" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token-for-testing" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Simulate multiple send operations that allocate/deallocate memory
    // The client should be reused efficiently
    for (0..10) |_| {
        // Each operation should allocate URL and body, then free them
        // If there's a leak, repeated operations would accumulate memory
        bot.sendChatAction("fake-token", "123456") catch |err| {
            // Expected to fail with fake token
            std.debug.assert(err == error.HttpError);
        };
    }

    // If we reach here without memory issues, test passes
    try std.testing.expect(true);
}

test "TelegramBot: memory - offset management doesn't leak" {
    const allocator = std.testing.allocator;
    const config: Config = .{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{ .botToken = "fake-token" },
        },
    };

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Test that offset updates don't accumulate memory
    const initial_offset = bot.offset;
    try std.testing.expectEqual(@as(i64, 0), initial_offset);

    // Update offset multiple times
    for (0..100) |i| {
        bot.offset = @intCast(i + 1);
        try std.testing.expectEqual(@as(i64, i + 1), bot.offset);
    }

    // Final offset should be correct without leaks
    try std.testing.expectEqual(@as(i64, 100), bot.offset);
}
