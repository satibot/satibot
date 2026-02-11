const std = @import("std");

// Simple HTTP client for standalone version (no TLS)
const SimpleHttpClient = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) SimpleHttpClient {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *SimpleHttpClient) void {
        _ = self;
    }

    fn get(self: SimpleHttpClient, url: []const u8) !Response {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
        });
        defer response.deinit();

        return Response{
            .body = try self.allocator.dupe(u8, response.payload.?.body),
            .allocator = self.allocator,
        };
    }

    fn post(self: SimpleHttpClient, url: []const u8, body: []const u8, content_type: []const u8) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("Content-Type", content_type);

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = headers,
            .body = .{ .json = body },
        });
        defer response.deinit();

        _ = response.status; // Fix pointless discard warning
    }
};

const Response = struct {
    body: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

// Standalone config structure to avoid module conflicts
pub const Config = struct {
    agents: struct {
        defaults: struct {
            model: []const u8,
        },
    },
    providers: struct {
        openrouter: ?struct {
            apiKey: []const u8,
        } = null,
    },
    tools: struct {
        telegram: ?struct {
            botToken: []const u8,
        } = null,
    },
};

// Simple agent implementation for sync version
const SyncAgent = struct {
    allocator: std.mem.Allocator,
    config: Config,
    session_id: []const u8,

    fn init(allocator: std.mem.Allocator, config: Config, session_id: []const u8) SyncAgent {
        return .{
            .allocator = allocator,
            .config = config,
            .session_id = session_id,
        };
    }

    fn run(self: *SyncAgent, message: []const u8) ![]const u8 {
        _ = message;
        // Simple echo response for now
        return self.allocator.dupe("Hello from sync bot! I received your message.", .{});
    }
};

/// Simple synchronous Telegram Bot implementation
const TelegramBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http_client: SimpleHttpClient,
    offset: i64 = 0,

    fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = SimpleHttpClient.init(allocator),
        };
    }

    fn deinit(self: *TelegramBot) void {
        self.http_client.deinit();
    }

    fn send_message(self: TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token});
        defer self.allocator.free(url);

        const json_text = try std.fmt.allocPrint(self.allocator, "{{\"chat_id\":\"{s}\",\"text\":\"{s}\"}}", .{ chat_id, text });
        defer self.allocator.free(json_text);

        try self.http_client.post(url, json_text, "application/json");
    }

    fn tick(self: *TelegramBot) !void {
        const tg_config = self.config.tools.telegram orelse return;

        const url = try std.fmt.allocPrint(self.allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ tg_config.botToken, self.offset });
        defer self.allocator.free(url);

        const response = try self.http_client.get(url);
        defer response.deinit();

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

        for (parsed.value.result) |update| {
            self.offset = update.update_id + 1;

            if (update.message) |msg| {
                const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{msg.chat.id});
                defer self.allocator.free(chat_id_str);

                // Handle voice messages - not supported in sync version
                if (msg.voice) |voice| {
                    _ = voice;
                    try self.send_message(tg_config.botToken, chat_id_str, "🎤 Voice messages are not supported in the sync version. Please use text messages or the async version with voice transcription enabled.");
                }

                // Process text messages only
                const final_text = msg.text orelse continue;

                if (final_text.len > 0) {
                    std.debug.print("Processing message from {s}: {s}\n", .{ chat_id_str, final_text });

                    const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{msg.chat.id});
                    defer self.allocator.free(session_id);

                    var actual_text = final_text;

                    // Handle /new command
                    if (std.mem.startsWith(u8, final_text, "/new")) {
                        if (final_text.len <= 4) {
                            try self.send_message(tg_config.botToken, chat_id_str, "🆕 Session cleared! Send me a new message.");
                            continue;
                        }
                        actual_text = std.mem.trimLeft(u8, final_text[4..], " ");
                    }

                    var agent = SyncAgent.init(self.allocator, self.config, session_id);
                    const response_text = try agent.run(actual_text);
                    defer self.allocator.free(response_text);

                    try self.send_message(tg_config.botToken, chat_id_str, response_text);
                }
            }
        }
    }
};

/// Main entry point for the synchronous Telegram Bot
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    var bot = try TelegramBot.init(allocator, config);
    defer bot.deinit();

    std.debug.print("🐸 Synchronous Telegram Bot\n", .{});
    std.debug.print("Model: {s}\n", .{config.agents.defaults.model});
    std.debug.print("Processing: Sequential (one message at a time)\n", .{});
    std.debug.print("Press Ctrl+C to stop.\n\n", .{});

    while (true) {
        bot.tick() catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\n", .{err});
            std.debug.print("Retrying in 5 seconds...\n", .{});
            std.Thread.sleep(std.time.ns_per_s * 5);
        };
    }
}
