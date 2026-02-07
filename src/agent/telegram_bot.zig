const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");

/// Global flag for shutdown signal
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Set of active chat IDs that have received messages
var active_chats: std.ArrayList(i64) = undefined;
var active_chats_mutex: std.Thread.Mutex = .{};

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Add a chat ID to active chats if not already present
fn trackActiveChat(allocator: std.mem.Allocator, chat_id: i64) void {
    active_chats_mutex.lock();
    defer active_chats_mutex.unlock();

    // Check if already in list
    for (active_chats.items) |id| {
        if (id == chat_id) return;
    }

    active_chats.append(allocator, chat_id) catch {
        std.debug.print("Failed to track chat {d}\n", .{chat_id});
    };
    std.debug.print("Tracked active chat: {d} (total: {d})\n", .{ chat_id, active_chats.items.len });
}

/// Setup signal handlers for graceful shutdown
fn setupSignalHandlers() void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };

    // Handle SIGINT (Ctrl+C)
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    // Handle SIGTERM
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// TelegramBot manages the interaction with the Telegram Bot API.
/// It uses long-polling to receive updates (messages, voice notes)
/// and processes them by spawning Agent instances for each conversation.
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
    /// Keep-alive is enabled to reduce TLS handshake overhead during
    /// polling.
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
    }

    /// Single polling iteration.
    /// Fetches updates from Telegram, processes them, and sends replies.
    /// This function is non-blocking in the sense that it processes one
    /// batch of updates and returns.
    pub fn tick(self: *TelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        // Long-polling request URL.
        // timeout=5 tells Telegram to wait up to 5 seconds for new
        // messages if none are immediately available. This reduces empty
        // responses and network traffic.
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ tg_config.botToken, self.offset });
        defer self.allocator.free(url);

        const response = try self.client.get(url, &.{});
        defer @constCast(&response).deinit();

        // Structure for parsing the JSON response from Telegram.
        // We only map the fields we care about (ID, text, voice).
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
                // Track this chat for shutdown notifications
                trackActiveChat(self.allocator, msg.chat.id);

                const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{msg.chat.id});
                defer self.allocator.free(chat_id_str);

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

                        const file_info_resp = try self.client.get(file_info_url, &.{});
                        defer @constCast(&file_info_resp).deinit();

                        const FileInfo = struct {
                            ok: bool,
                            result: ?struct {
                                file_path: []const u8,
                            } = null,
                        };
                        const parsed_file_info = try std.json.parseFromSlice(FileInfo, self.allocator, file_info_resp.body, .{ .ignore_unknown_fields = true });
                        defer parsed_file_info.deinit();

                        if (parsed_file_info.value.result) |res| {
                            // 2. Download the actual audio file
                            const download_url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/file/bot{s}/{s}", .{ tg_config.botToken, res.file_path });
                            defer self.allocator.free(download_url);

                            const file_data_resp = try self.client.get(download_url, &.{});
                            defer @constCast(&file_data_resp).deinit();

                            // 3. Transcribe using Groq
                            // We initialize a temporary provider instance just for this operation.
                            // In a higher-load system, we might want to share a provider instance.
                            var groq = try @import("../root.zig").providers.groq.GroqProvider.init(self.allocator, groq_cfg.apiKey);
                            defer groq.deinit();

                            transcribed_text = try groq.transcribe(file_data_resp.body, "voice.ogg");
                            std.debug.print("Transcription: {s}\n", .{transcribed_text.?});
                        }
                    } else {
                        try self.send_message(tg_config.botToken, chat_id_str, "🎤 Voice message received, but transcription is not configured (need Groq API key).");
                    }
                }

                // Determine final text input: either transcription result or direct text message.
                const final_text = transcribed_text orelse msg.text orelse continue;

                if (final_text.len > 0) {
                    std.debug.print("Processing message from {s}: {s}\n", .{ chat_id_str, final_text });

                    // Map Telegram Chat ID to internal Session ID.
                    // This creates a persistent conversation history for this specific user.
                    const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{msg.chat.id});
                    defer self.allocator.free(session_id);

                    var actual_text = final_text;

                    // Handle magic command /help to show available commands.
                    if (std.mem.startsWith(u8, final_text, "/help")) {
                        const help_text =
                            \\🐸 SatiBot Commands:
                            \\
                            \\/setibot - Generate default config file at ~/.bots/config.json
                            \\/new - Clear conversation session memory
                            \\/help - Show this help message
                            \\
                            \\Send any message to chat with the AI assistant.
                        ;
                        try self.send_message(tg_config.botToken, chat_id_str, help_text);
                        continue;
                    }

                    // Handle magic command /setibot to auto-generate config file.
                    // This allows users to set up satibot configuration directly from Telegram.
                    if (std.mem.startsWith(u8, final_text, "/setibot")) {
                        const home = std.posix.getenv("HOME") orelse "/tmp";

                        // Create .bots directory if it doesn't exist
                        const bots_dir = try std.fs.path.join(self.allocator, &.{ home, ".bots" });
                        defer self.allocator.free(bots_dir);

                        std.fs.makeDirAbsolute(bots_dir) catch |err| {
                            if (err != error.PathAlreadyExists) {
                                try self.send_message(tg_config.botToken, chat_id_str, "❌ Error creating .bots directory");
                                continue;
                            }
                        };

                        // Create config.json with default template
                        const config_path = try std.fs.path.join(self.allocator, &.{ bots_dir, "config.json" });
                        defer self.allocator.free(config_path);

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

                        // Check if config already exists
                        std.fs.accessAbsolute(config_path, .{}) catch |err| {
                            if (err == error.FileNotFound) {
                                const file = try std.fs.createFileAbsolute(config_path, .{});
                                defer file.close();
                                try file.writeAll(default_json);

                                const response_msg = try std.fmt.allocPrint(self.allocator, "✅ Config file created at: {s}\n\n📋 Next steps:\n1. Edit the config file with your API keys\n2. Restart satibot with your new config\n\n💡 Current chat ID: {s}", .{ config_path, chat_id_str });
                                defer self.allocator.free(response_msg);
                                try self.send_message(tg_config.botToken, chat_id_str, response_msg);
                                continue;
                            }
                        };

                        // Config already exists
                        const response_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Config file already exists at: {s}\n\nUse /new to clear session or edit the file manually.\n\n💡 Your chat ID: {s}", .{ config_path, chat_id_str });
                        defer self.allocator.free(response_msg);
                        try self.send_message(tg_config.botToken, chat_id_str, response_msg);
                        continue;
                    }

                    // Handle magic command /new to wipe memory.
                    // Helpful for restarting conversations without restarting the bot.
                    if (std.mem.startsWith(u8, final_text, "/new")) {
                        const home = std.posix.getenv("HOME") orelse "/tmp";
                        const session_path = try std.fs.path.join(self.allocator, &.{ home, ".bots", "sessions", try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_id}) });
                        defer self.allocator.free(session_path);
                        std.fs.deleteFileAbsolute(session_path) catch {};

                        if (final_text.len <= 4) {
                            try self.send_message(tg_config.botToken, chat_id_str, "🆕 Session cleared! Send me a new message.");
                            continue;
                        }
                        // If user sent "/new some prompt", clear session but process
                        // the prompt.
                        actual_text = std.mem.trimLeft(u8, final_text[4..], " ");
                    }

                    // Spin up a fresh Agent instance for this interaction.
                    // The Agent loads the session state from disk based on session_id.
                    var agent = Agent.init(self.allocator, self.config, session_id);
                    defer agent.deinit();

                    // Send initial "typing" action to show the user we're processing.
                    self.send_chat_action(tg_config.botToken, chat_id_str, "typing") catch {};

                    // Shared state to coordinate between agent thread and typing thread
                    const AgentState = struct {
                        mutex: std.Thread.Mutex,
                        done: bool,
                        error_occurred: bool,
                    };
                    var state = AgentState{
                        .mutex = .{},
                        .done = false,
                        .error_occurred = false,
                    };

                    // Thread context for agent processing
                    const AgentContext = struct {
                        agent: *Agent,
                        text: []const u8,
                        state: *AgentState,
                    };
                    const agent_ctx = AgentContext{
                        .agent = &agent,
                        .text = actual_text,
                        .state = &state,
                    };

                    // Spawn agent thread to run LLM processing concurrently
                    const agent_thread = try std.Thread.spawn(.{}, struct {
                        fn run(ctx: AgentContext) void {
                            ctx.agent.run(ctx.text) catch |err| {
                                std.debug.print("Error running agent: {any}\n", .{err});
                                ctx.state.mutex.lock();
                                defer ctx.state.mutex.unlock();
                                ctx.state.error_occurred = true;
                            };
                            ctx.state.mutex.lock();
                            defer ctx.state.mutex.unlock();
                            ctx.state.done = true;
                        }
                    }.run, .{agent_ctx});
                    defer agent_thread.join();

                    // Spawn typing indicator thread that sends "typing" action every 5 seconds
                    // while the agent is processing
                    const TypingContext = struct {
                        bot: *TelegramBot,
                        token: []const u8,
                        chat_id: []const u8,
                        state: *AgentState,
                    };
                    const typing_ctx = TypingContext{
                        .bot = self,
                        .token = tg_config.botToken,
                        .chat_id = chat_id_str,
                        .state = &state,
                    };

                    const typing_thread = try std.Thread.spawn(.{}, struct {
                        fn run(ctx: TypingContext) void {
                            // Send typing action every 5 seconds until agent is done
                            while (true) {
                                std.Thread.sleep(std.time.ns_per_s * 5);

                                ctx.state.mutex.lock();
                                const is_done = ctx.state.done;
                                ctx.state.mutex.unlock();

                                if (is_done) break;

                                // Send typing action (ignore errors)
                                ctx.bot.send_chat_action(ctx.token, ctx.chat_id, "typing") catch {};
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
                        const error_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Error: Agent failed to process request\n\nPlease try again.", .{});
                        defer self.allocator.free(error_msg);
                        try self.send_message(tg_config.botToken, chat_id_str, error_msg);
                    } else {
                        // Send the final response back to Telegram.
                        const messages = agent.ctx.get_messages();
                        if (messages.len > 0) {
                            const last_msg = messages[messages.len - 1];
                            if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                                try self.send_message(tg_config.botToken, chat_id_str, last_msg.content.?);
                            }
                        }
                    }

                    // Save session state to Vector/Graph DB for long-term memory.
                    agent.index_conversation() catch {};
                }
            }
        }
    }

    /// Send a chat action (typing, upload_photo, record_video, etc.) to Telegram.
    /// This shows the user that the bot is processing their request.
    fn send_chat_action(self: *TelegramBot, token: []const u8, chat_id: []const u8, action: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{token});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .action = action,
        }, .{});
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const response = try self.client.post(url, headers, body);
        @constCast(&response).deinit();
    }

    /// Helper to send a text message back to a chat using the Telegram API.
    fn send_message(self: *TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .chat_id = chat_id,
            .text = text,
        }, .{});
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

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

    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    // Initialize active chats tracking
    active_chats = std.ArrayList(i64).empty;
    defer {
        std.debug.print("Defer running: active_chats.len = {d}\n", .{active_chats.items.len});
        // Send shutdown message to all active chats before cleanup
        // This code run when the bot is terminated (Ctrl+C)
        // Ctrl+C triggers SIGINT, then signalHandler sets shutdown_requested = true
        // The main loop checks shutdown_requested and breaks, then this defer runs
        if (active_chats.items.len > 0) {
            std.debug.print("Sending shutdown message to {d} active chats...\n", .{active_chats.items.len});

            for (active_chats.items) |chat_id| {
                std.debug.print("Sending goodbye to chat {d}...\n", .{chat_id});
                const chat_id_str = std.fmt.allocPrint(allocator, "{d}", .{chat_id}) catch continue;
                defer allocator.free(chat_id_str);

                // Send shutdown message
                const shutdown_msg = "🛑 Bot is turned off. See you next time! 👋";
                bot.send_message(tg_config.botToken, chat_id_str, shutdown_msg) catch |err| {
                    std.debug.print("Failed to send shutdown message to chat {d}: {any}\n", .{ chat_id, err });
                };
                std.debug.print("Sent goodbye to chat {d}\n", .{chat_id});
            }
        } else {
            std.debug.print("No active chats to send goodbye to\n", .{});
        }
        active_chats.deinit(allocator);
        std.debug.print("Defer completed\n", .{});
    }

    // Setup signal handlers for graceful shutdown
    setupSignalHandlers();

    std.debug.print("🐸 Telegram bot running. Press Ctrl+C to stop.\n", .{});

    // chatId is required - terminate if not configured
    const chat_id = tg_config.chatId orelse {
        std.debug.print("Error: telegram.chatId is required but not configured. Terminating.\n", .{});
        return error.TelegramChatIdNotConfigured;
    };

    std.debug.print("Sending startup message to chat {s}...\n", .{chat_id});
    const startup_msg = "🐸 Bot is now online and ready! 🚀";
    bot.send_message(tg_config.botToken, chat_id, startup_msg) catch |err| {
        std.debug.print("Failed to send startup message: {any}\n", .{err});
    };

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

test "TelegramBot command detection - /help" {
    // Test command detection
    const help_cmd = "/help";
    try std.testing.expect(std.mem.startsWith(u8, help_cmd, "/help"));

    const help_with_text = "/help me";
    try std.testing.expect(std.mem.startsWith(u8, help_with_text, "/help"));

    const not_help = "help";
    try std.testing.expect(!std.mem.startsWith(u8, not_help, "/help"));
}

test "TelegramBot command detection - /setibot" {
    // Test command detection
    const setibot_cmd = "/setibot";
    try std.testing.expect(std.mem.startsWith(u8, setibot_cmd, "/setibot"));

    const setibot_with_args = "/setibot --force";
    try std.testing.expect(std.mem.startsWith(u8, setibot_with_args, "/setibot"));
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
