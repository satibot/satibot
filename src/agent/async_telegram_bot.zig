const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");
const TelegramEventLoop = @import("telegram_event_loop.zig").TelegramEventLoop;

/// AsyncTelegramBot manages the interaction with the Telegram Bot API using the async event loop.
/// It integrates with TelegramEventLoop for efficient message processing and resource management.
pub const AsyncTelegramBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    event_loop: *TelegramEventLoop,

    // Offset for long-polling. This ensures we don't process the
    // same message twice. It is updated to the last update_id + 1
    // after processing.
    offset: i64 = 0,

    // HTTP client re-used for all API calls to enable connection
    // keep-alive.
    client: http.Client,

    /// Initialize the AsyncTelegramBot with a dedicated HTTP client and event loop.
    pub fn init(allocator: std.mem.Allocator, config: Config, event_loop: *TelegramEventLoop) !AsyncTelegramBot {
        const client = try http.Client.initWithSettings(allocator, .{
            .request_timeout_ms = 60000,
            .keep_alive = true,
        });
        return .{
            .allocator = allocator,
            .config = config,
            .event_loop = event_loop,
            .client = client,
        };
    }

    pub fn deinit(self: *AsyncTelegramBot) void {
        self.client.deinit();
    }

    /// Send a message to a Telegram chat
    fn send_message(self: *AsyncTelegramBot, bot_token: []const u8, chat_id: []const u8, text: []const u8) !void {
        const encoded_text = try std.Uri.Component.escape(text);
        defer self.allocator.free(encoded_text);

        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage?chat_id={s}&text={s}", .{ bot_token, chat_id, encoded_text });
        defer self.allocator.free(url);

        const response = try self.client.get(url, &.{});
        defer @constCast(&response).deinit();

        if (response.status_code != 200) {
            std.debug.print("Failed to send message: status {d}, body: {s}\n", .{ response.status_code, response.body });
        }
    }

    /// Process voice message transcription asynchronously
    fn processVoiceMessage(self: *AsyncTelegramBot, chat_id: i64, voice_file_id: []const u8) !?[]const u8 {
        const tg_config = self.config.tools.telegram orelse return null;
        
        if (self.config.providers.groq == null) {
            try self.send_message(tg_config.botToken, try std.fmt.allocPrint(self.allocator, "{d}", .{chat_id}), "🎤 Voice message received, but transcription is not configured (need Groq API key).");
            return null;
        }

        // 1. Get file path from Telegram API
        const file_info_url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getFile?file_id={s}", .{ tg_config.botToken, voice_file_id });
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
            var groq = try @import("../root.zig").providers.groq.GroqProvider.init(self.allocator, self.config.providers.groq.?.apiKey);
            defer groq.deinit();

            const transcribed_text = try groq.transcribe(file_data_resp.body, "voice.ogg");
            std.debug.print("Transcription for chat {d}: {s}\n", .{ chat_id, transcribed_text });
            return transcribed_text;
        }

        return null;
    }

    /// Single polling iteration that adds messages to the event loop queue
    pub fn tick(self: *AsyncTelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        // Long-polling request URL with timeout=30 seconds
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=30", .{ tg_config.botToken, self.offset });
        defer self.allocator.free(url);

        const response = try self.client.get(url, &.{});
        defer @constCast(&response).deinit();

        // Structure for parsing the JSON response from Telegram
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
                        file_id: []const u8,
                    } = null,
                } = null,
            },
        };

        const parsed = try std.json.parseFromSlice(UpdateResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Process each update in the batch
        for (parsed.value.result) |update| {
            // Update offset so we acknowledge this message in the next poll
            self.offset = update.update_id + 1;

            if (update.message) |msg| {
                var transcribed_text: ?[]const u8 = null;
                defer if (transcribed_text) |t| self.allocator.free(t);

                // Handle voice messages
                if (msg.voice) |voice| {
                    transcribed_text = try self.processVoiceMessage(msg.chat.id, voice.file_id);
                }

                // Determine final text input: either transcription result or direct text message
                const final_text = transcribed_text orelse msg.text orelse continue;

                if (final_text.len > 0) {
                    // Add message to event loop for async processing
                    try self.event_loop.addChatMessage(msg.chat.id, final_text);
                    std.debug.print("Queued message from chat {d} for async processing\n", .{msg.chat.id});
                }
            }
        }
    }

    /// Main polling loop that runs continuously and feeds messages to the event loop
    pub fn run(self: *AsyncTelegramBot) !void {
        std.debug.print("🤖 Async Telegram Bot started polling\n", .{});

        // Setup signal handlers for graceful shutdown
        self.setupSignalHandlers();

        while (!self.event_loop.shutdown.load(.seq_cst)) {
            self.tick() catch |err| {
                std.debug.print("Error in polling tick: {any}\n", .{err});
                // Continue polling even if there's an error
                std.Thread.sleep(std.time.ns_per_s * 5);
            };
        }

        std.debug.print("🛑 Telegram Bot polling stopped\n", .{});
    }

    /// Setup signal handlers for graceful shutdown
    fn setupSignalHandlers(self: *AsyncTelegramBot) void {
        const Handler = struct {
            event_loop: *TelegramEventLoop,

            fn handler(sig: i32) callconv(.c) void {
                _ = sig;
                std.debug.print("\nReceived shutdown signal, gracefully stopping...\n", .{});
                @This().event_loop.shutdown();
            }
        };

        const sa = std.posix.Sigaction{
            .handler = .{ .handler = Handler{ .event_loop = self.event_loop }.handler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };

        // Handle SIGINT (Ctrl+C)
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        // Handle SIGTERM
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    }
};
