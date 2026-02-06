const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");

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

                    // Run the agent loop (LLM inference + Tool execution).
                    agent.run(actual_text) catch |err| {
                        std.debug.print("Error running agent: {any}\n", .{err});
                        const error_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Error: {any}\n\nPlease try again.", .{err});
                        defer self.allocator.free(error_msg);
                        try self.send_message(tg_config.botToken, chat_id_str, error_msg);
                    };

                    // Send the final response back to Telegram.
                    const messages = agent.ctx.get_messages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                            try self.send_message(tg_config.botToken, chat_id_str, last_msg.content.?);
                        }
                    }

                    // Save session state to Vector/Graph DB for long-term memory.
                    agent.index_conversation() catch {};
                }
            }
        }
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
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    while (true) {
        // Robustness: If tick() fails (e.g., network error),
        // log it and retry after a delay.
        // This prevents the bot from crashing completely on transient errors.
        bot.tick() catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
        };
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
