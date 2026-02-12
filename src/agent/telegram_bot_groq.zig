const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const groq_provider = @import("../root.zig").providers.groq.GroqProvider;

/// Global flag for shutdown signal
/// Set to true when SIGINT (Ctrl+C) or SIGTERM is received
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Set of active chat IDs that have received messages
/// Used to send shutdown messages when the bot terminates
var active_chats: std.ArrayList(i64) = undefined;
var active_chats_mutex: std.Thread.Mutex = .{};

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
/// Sets the global shutdown flag to trigger graceful shutdown
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Add a chat ID to active chats if not already present
/// This ensures we only track each chat once and can send
/// shutdown messages to all active users
fn trackActiveChat(allocator: std.mem.Allocator, chat_id: i64) void {
    active_chats_mutex.lock();
    defer active_chats_mutex.unlock();

    // Check if already in list to avoid duplicates
    for (active_chats.items) |id| {
        if (id == chat_id) return;
    }

    // Add new chat ID to tracking list
    active_chats.append(allocator, chat_id) catch {
        std.debug.print("Failed to track chat {d}\n", .{chat_id});
    };
    std.debug.print("Tracked active chat: {d} (total: {d})\n", .{ chat_id, active_chats.items.len });
}

/// Setup signal handlers for graceful shutdown
/// Registers handlers for SIGINT (Ctrl+C) and SIGTERM signals
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
/// It uses long-polling to receive updates (messages, voice notes)
/// and processes them by spawning Agent instances for each conversation.
/// This is the synchronous version that processes messages sequentially.
pub const TelegramBot = struct {
    /// Memory allocator for string operations and JSON parsing
    allocator: std.mem.Allocator,
    /// Bot configuration including API tokens and provider settings
    config: Config,

    /// Offset for long-polling. This ensures we don't process the
    /// same message twice. It is updated to the last update_id + 1
    /// after processing each batch of updates.
    offset: i64 = 0,

    /// HTTP client re-used for all API calls to enable connection
    /// keep-alive, reducing TLS handshake overhead during polling.
    client: http.Client,

    /// Initialize the TelegramBot with a dedicated HTTP client.
    /// Keep-alive is enabled to reduce TLS handshake overhead during
    /// polling, which is important for long-running bot operations.
    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        // Create HTTP client with 60-second timeout and keep-alive enabled
        const client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000, // 60 seconds timeout
            .keep_alive = true, // Reuse connections for efficiency
        });
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
        };
    }

    /// Clean up resources used by the TelegramBot
    /// Must be called when the bot is shutting down
    pub fn deinit(self: *TelegramBot) void {
        self.client.deinit(); // Close HTTP connections
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
                    // Track this chat for shutdown notifications
                    trackActiveChat(self.allocator, msg.chat.id);

                    // Convert chat ID to string for API calls
                    const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{msg.chat.id});
                    defer self.allocator.free(chat_id_str);

                    // Variable to hold transcribed text from voice messages
                    var transcribed_text: ?[]const u8 = null;
                    defer if (transcribed_text) |t| self.allocator.free(t);

                    // --- VOICE MESSAGE HANDLING ---
                    // If the message contains audio, we need to:
                    // 1. Get the file path from Telegram using the file_id.
                    // 2. Download the binary file.
                    // 3. Send it to Groq for transcription.
                    if (msg.voice) |voice| {
                        if (self.config.providers.groq) |groq_cfg| {
                            std.debug.print("Received voice message from {s}, transcribing...\n", .{chat_id_str});

                            // 1. Get file path from Telegram API
                            const file_info_url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getFile?file_id={s}", .{ tg_config.botToken, voice.file_id });
                            defer self.allocator.free(file_info_url);

                            // Request file information from Telegram
                            const file_info_resp = try self.client.get(file_info_url, &.{});
                            defer @constCast(&file_info_resp).deinit();

                            // Structure for parsing file info response
                            const FileInfo = struct {
                                /// Indicates if the request was successful
                                ok: bool,
                                /// File information, can be null if file not found
                                result: ?struct {
                                    /// Path to the file on Telegram servers
                                    file_path: []const u8,
                                } = null,
                            };
                            // Parse the file info response
                            const parsed_file_info = try std.json.parseFromSlice(FileInfo, self.allocator, file_info_resp.body, .{ .ignore_unknown_fields = true });
                            defer parsed_file_info.deinit();

                            // Check if we got valid file info
                            if (parsed_file_info.value.result) |res| {
                                // 2. Download the actual audio file
                                const download_url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/file/bot{s}/{s}", .{ tg_config.botToken, res.file_path });
                                defer self.allocator.free(download_url);

                                // Download the voice file data
                                const file_data_resp = try self.client.get(download_url, &.{});
                                defer @constCast(&file_data_resp).deinit();

                                // 3. Transcribe using Groq
                                // We initialize a temporary provider instance just for this operation.
                                // In a higher-load system, we might want to share a provider instance.
                                var groq = try groq_provider.init(self.allocator, groq_cfg.apiKey);
                                defer groq.deinit();

                                // Transcribe the audio data
                                transcribed_text = try groq.transcribe(file_data_resp.body, "voice.ogg");
                                std.debug.print("Transcription: {s}\n", .{transcribed_text.?});
                            }
                        } else {
                            // Groq is not configured, send error message to user
                            try self.sendMessage(tg_config.botToken, chat_id_str, "🎤 Voice message received, but transcription is not configured (need Groq API key).");
                        }
                    }

                    // Determine final text input: either transcription result or direct text message.
                    // If neither exists (e.g., message with only stickers), continue to next message.
                    const final_text = transcribed_text orelse msg.text orelse continue;

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
                                \\/new - Start a new conversation session
                                \\/help - Show this help message
                                \\
                                \\Send any message to chat with the AI assistant.
                            ;
                            try self.sendMessage(tg_config.botToken, chat_id_str, help_text);
                            continue;
                        }

                        // Handle magic command /new to start a new session.
                        // Creates a new session ID with timestamp so old history is preserved but not loaded.
                        var new_session_id: ?[]const u8 = null;
                        defer if (new_session_id) |ns| self.allocator.free(ns);

                        if (std.mem.startsWith(u8, final_text, "/new")) {
                            // Generate a new session ID with timestamp to start fresh
                            const ts = std.time.milliTimestamp();
                            new_session_id = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ session_id, ts });

                            if (final_text.len <= 4) {
                                try self.sendMessage(tg_config.botToken, chat_id_str, "🆕 New session started! Send me a new message.");
                                continue;
                            }
                            // If user sent "/new some prompt", start new session and process the prompt
                            actual_text = std.mem.trimStart(u8, final_text[4..], " ");
                        }

                        // Spin up a fresh Agent instance for this interaction.
                        // The Agent loads the session state from disk based on session_id.
                        const active_session = new_session_id orelse session_id;
                        var agent = Agent.init(self.allocator, self.config, active_session);
                        defer agent.deinit();

                        // Send initial "typing" action to show the user we're processing.
                        // This provides immediate feedback that the bot is working.
                        self.sendChatAction(tg_config.botToken, chat_id_str, "typing") catch |err| {
                            std.debug.print("Failed to send typing action: {any}\n", .{err});
                        };

                        // Shared state to coordinate between agent thread and typing thread
                        // This allows us to show typing indicator while processing LLM requests
                        const AgentState = struct {
                            /// Mutex for thread-safe access to state
                            mutex: std.Thread.Mutex,
                            /// Flag indicating if agent processing is complete
                            done: bool,
                            /// Flag indicating if an error occurred during processing
                            error_occurred: bool,
                        };
                        var state = AgentState{
                            .mutex = .{},
                            .done = false,
                            .error_occurred = false,
                        };

                        // Thread context for agent processing
                        // Contains all data needed for the agent thread to do its work
                        const AgentContext = struct {
                            /// Reference to the agent instance
                            agent: *Agent,
                            /// Text message to process
                            text: []const u8,
                            /// Shared state for coordination
                            state: *AgentState,
                        };
                        const agent_ctx = AgentContext{
                            .agent = &agent,
                            .text = actual_text,
                            .state = &state,
                        };

                        // Spawn agent thread to run LLM processing concurrently
                        // This allows the bot to remain responsive while processing complex requests
                        const agent_thread = try std.Thread.spawn(.{}, struct {
                            fn run(ctx: AgentContext) void {
                                // Run the agent with the user's message
                                ctx.agent.run(ctx.text) catch |err| {
                                    // Log any errors that occur during processing
                                    std.debug.print("Error running agent: {any}\n", .{err});
                                    // Mark that an error occurred in shared state
                                    ctx.state.mutex.lock();
                                    defer ctx.state.mutex.unlock();
                                    ctx.state.error_occurred = true;
                                };
                                // Mark processing as complete
                                ctx.state.mutex.lock();
                                defer ctx.state.mutex.unlock();
                                ctx.state.done = true;
                            }
                        }.run, .{agent_ctx});
                        defer agent_thread.join();

                        // Spawn typing indicator thread that sends "typing" action every 5 seconds
                        // while the agent is processing. This provides visual feedback to users.
                        const TypingContext = struct {
                            /// Reference to the bot for sending typing actions
                            bot: *TelegramBot,
                            /// Bot token for API authentication
                            token: []const u8,
                            /// Chat ID to send typing actions to
                            chat_id: []const u8,
                            /// Shared state to check if processing is complete
                            state: *AgentState,
                        };
                        const typing_ctx = TypingContext{
                            .bot = self,
                            .token = tg_config.botToken,
                            .chat_id = chat_id_str,
                            .state = &state,
                        };

                        // Start the typing indicator thread
                        const typing_thread = try std.Thread.spawn(.{}, struct {
                            fn run(ctx: TypingContext) void {
                                // Send typing action every 5 seconds until agent is done
                                while (true) {
                                    // Wait 5 seconds between typing indicators
                                    std.Thread.sleep(std.time.ns_per_s * 5);

                                    // Check if agent processing is complete
                                    ctx.state.mutex.lock();
                                    const is_done = ctx.state.done;
                                    ctx.state.mutex.unlock();

                                    // Exit loop if processing is complete
                                    if (is_done) break;

                                    // Send typing action (ignore errors to avoid crashing)
                                    ctx.bot.sendChatAction(ctx.token, ctx.chat_id, "typing") catch |err| {
                                        std.debug.print("Failed to send typing action: {any}\n", .{err});
                                    };
                                }
                            }
                        }.run, .{typing_ctx});
                        defer typing_thread.join();

                        // Wait for agent thread to complete (typing thread will exit when done via defer)
                        agent_thread.join();

                        // Check if an error occurred during agent run
                        state.mutex.lock();
                        const had_error = state.error_occurred;
                        state.mutex.unlock();

                        if (had_error) {
                            // Send error message to user if processing failed
                            const error_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Error: Agent failed to process request\n\nPlease try again.", .{});
                            defer self.allocator.free(error_msg);
                            try self.sendMessage(tg_config.botToken, chat_id_str, error_msg);
                        } else {
                            // Send the final response back to Telegram.
                            // Get all messages from the agent's conversation context
                            const messages = agent.ctx.get_messages();
                            if (messages.len > 0) {
                                // Get the last message (should be the assistant's response)
                                const last_msg = messages[messages.len - 1];
                                // Only send if it's an assistant message with content
                                if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                                    try self.sendMessage(tg_config.botToken, chat_id_str, last_msg.content.?);
                                }
                            }
                        }

                        // Save session state to Vector/Graph DB for long-term memory.
                        // This enables RAG (Retrieval-Augmented Generation) functionality.
                        agent.index_conversation() catch |err| {
                            std.debug.print("Failed to index conversation: {any}\n", .{err});
                        };
                    }
                }
            }
        }
    }

    /// Send a chat action (typing, upload_photo, record_video, etc.) to Telegram.
    /// This shows the user that the bot is processing their request.
    /// Common actions include: "typing", "upload_photo", "record_video", "upload_document"
    fn sendChatAction(self: *TelegramBot, token: []const u8, chat_id: []const u8, action: []const u8) !void {
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
    fn sendMessage(self: *TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void {
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
    defer bot.deinit();

    // Initialize active chats tracking list
    active_chats = std.ArrayList(i64).empty;
    defer {
        std.debug.print("Defer running: active_chats.len = {d}\n", .{active_chats.items.len});
        // Send shutdown message to all active chats before cleanup
        // This code runs when the bot is terminated (Ctrl+C)
        // Ctrl+C triggers SIGINT, then signalHandler sets shutdown_requested = true
        // The main loop checks shutdown_requested and breaks, then this defer runs
        if (active_chats.items.len > 0) {
            std.debug.print("Sending shutdown message to {d} active chats...\n", .{active_chats.items.len});

            // Send goodbye message to each active chat
            for (active_chats.items) |chat_id| {
                std.debug.print("Sending goodbye to chat {d}...\n", .{chat_id});
                // Convert chat ID to string for API call
                const chat_id_str = std.fmt.allocPrint(allocator, "{d}", .{chat_id}) catch continue;
                defer allocator.free(chat_id_str);

                // Send shutdown message to user
                const shutdown_msg = "🛑 Bot is turned off. See you next time! 👋";
                bot.sendMessage(tg_config.botToken, chat_id_str, shutdown_msg) catch |err| {
                    // Log error but continue with other chats
                    std.debug.print("Failed to send shutdown message to chat {d}: {any}\n", .{ chat_id, err });
                };
                std.debug.print("Sent goodbye to chat {d}\n", .{chat_id});
            }
        } else {
            std.debug.print("No active chats to send goodbye to\n", .{});
        }
        // Clean up the active chats list
        active_chats.deinit(allocator);
        std.debug.print("Defer completed\n", .{});
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
    bot.sendMessage(tg_config.botToken, chat_id, startup_msg) catch |err| {
        std.debug.print("Failed to send startup message: {any}\n", .{err});
    };

    // Main polling loop - runs indefinitely until shutdown signal
    while (true) {
        // Check for shutdown signal before tick to avoid network calls during shutdown
        if (shutdown_requested.load(.seq_cst)) {
            std.debug.print("\n🛑 Shutdown requested. Sending goodbye messages 🌙.\n", .{});
            break;
        }

        // Robustness: If tick() fails (e.g., network error),
        // log it and retry after a delay.
        // This prevents the bot from crashing completely on transient errors.
        bot.tick() catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\n", .{err});
            // Wait 5 seconds before retrying to avoid spamming error logs
            std.Thread.sleep(std.time.ns_per_s * 5);
        };

        // Check shutdown again after tick before sleeping
        if (shutdown_requested.load(.seq_cst)) {
            std.debug.print("\n🛑 Shutdown requested. Sending goodbye messages 🌙.\n", .{});
            break;
        }

        // Small sleep to prevent CPU spinning when shutdown is requested
        std.Thread.sleep(std.time.ns_per_ms * 100);
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

test "TelegramBot config validation" {
    const allocator = std.testing.allocator;

    // Test with valid config
    const valid_config: Config = .{
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

test "TelegramBot command detection - /help" {
    // Test command detection
    const help_cmd = "/help";
    try std.testing.expect(std.mem.startsWith(u8, help_cmd, "/help"));

    const help_with_text = "/help me";
    try std.testing.expect(std.mem.startsWith(u8, help_with_text, "/help"));

    const not_help = "help";
    try std.testing.expect(!std.mem.startsWith(u8, not_help, "/help"));
}

test "TelegramBot command detection - /new" {
    // Test command detection
    const new_cmd = "/new";
    try std.testing.expect(std.mem.startsWith(u8, new_cmd, "/new"));

    const new_with_prompt = "/new what is zig?";
    try std.testing.expect(std.mem.startsWith(u8, new_with_prompt, "/new"));
}

test "TelegramBot /new generates timestamp-based session ID" {
    const allocator = std.testing.allocator;

    // Test that /new creates a new session ID with timestamp
    const base_session_id = "tg_123456789";
    const ts1 = std.time.milliTimestamp();
    const new_session_id1 = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base_session_id, ts1 });
    defer allocator.free(new_session_id1);

    // Verify new session ID contains timestamp
    try std.testing.expect(std.mem.indexOf(u8, new_session_id1, base_session_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, new_session_id1, "_") != null);

    // Test with different timestamp
    const ts2 = ts1 + 1000;
    const new_session_id2 = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base_session_id, ts2 });
    defer allocator.free(new_session_id2);

    // Verify they are different
    try std.testing.expect(!std.mem.eql(u8, new_session_id1, new_session_id2));
}

test "TelegramBot /new with prompt extracts prompt correctly" {
    const new_with_prompt = "/new what is zig?";

    // Extract prompt after /new (simulate the logic)
    const actual_prompt = std.mem.trimStart(u8, new_with_prompt[4..], " ");

    try std.testing.expectEqualStrings("what is zig?", actual_prompt);
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
