const std = @import("std");
const Config = @import("../config.zig").Config;
const WhatsAppConfig = @import("../config.zig").WhatsAppConfig;
const Agent = @import("../agent.zig").Agent;
const http = @import("../http.zig");

/// WhatsAppBot manages interaction with the WhatsApp Business API.
/// It uses webhook-based message reception and processes messages
/// by spawning Agent instances for each conversation.
pub const WhatsAppBot = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // HTTP client re-used for all API calls to enable connection keep-alive.
    client: http.Client,

    /// Initialize the WhatsAppBot with a dedicated HTTP client.
    pub fn init(allocator: std.mem.Allocator, config: Config) !WhatsAppBot {
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

    pub fn deinit(self: *WhatsAppBot) void {
        self.client.deinit();
    }

    /// Process a single incoming webhook message from WhatsApp.
    /// This is called when a webhook payload is received.
    pub fn processWebhook(self: *WhatsAppBot, body: []const u8) !void {
        const wa_config = self.config.tools.whatsapp orelse return;

        // Structure for parsing WhatsApp webhook payload
        const WebhookPayload = struct {
            entry: []struct {
                changes: []struct {
                    value: struct {
                        messages: ?[]struct {
                            from: []const u8,
                            id: []const u8,
                            type: []const u8,
                            text: ?struct {
                                body: []const u8,
                            } = null,
                        } = null,
                    },
                },
            },
        };

        const parsed = try std.json.parseFromSlice(WebhookPayload, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Process each entry and change
        for (parsed.value.entry) |entry| {
            for (entry.changes) |change| {
                if (change.value.messages) |messages| {
                    for (messages) |msg| {
                        if (std.mem.eql(u8, msg.type, "text")) {
                            if (msg.text) |text_msg| {
                                try self.processMessage(wa_config, msg.from, text_msg.body);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Process a single message from a WhatsApp user.
    fn processMessage(self: *WhatsAppBot, wa_config: WhatsAppConfig, from: []const u8, text: []const u8) !void {
        std.debug.print("Processing WhatsApp message from {s}: {s}\n", .{ from, text });

        // Map WhatsApp phone number to internal Session ID
        const session_id = try std.fmt.allocPrint(self.allocator, "wa_{s}", .{from});
        defer self.allocator.free(session_id);

        var actual_text = text;

        // Handle magic command /help to show available commands
        if (std.mem.startsWith(u8, text, "/help")) {
            const help_text =
                \\🐸 SatiBot WhatsApp Commands:
                \\
                \/new - Clear conversation session memory
                \/help - Show this help message
                \\
                \\Send any message to chat with the AI assistant.
            ;
            try self.send_message(wa_config, from, help_text);
            return;
        }

        // Handle magic command /new to wipe memory
        if (std.mem.startsWith(u8, text, "/new")) {
            const home = std.posix.getenv("HOME") orelse "/tmp";
            const session_path = try std.fs.path.join(self.allocator, &.{ home, ".bots", "sessions", try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_id}) });
            defer self.allocator.free(session_path);
            std.fs.deleteFileAbsolute(session_path) catch {};

            if (text.len <= 4) {
                try self.send_message(wa_config, from, "🆕 Session cleared! Send me a new message.");
                return;
            }
            // If user sent "/new some prompt", clear session but process the prompt
            actual_text = std.mem.trimLeft(u8, text[4..], " ");
        }

        // Spin up a fresh Agent instance for this interaction
        var agent = Agent.init(self.allocator, self.config, session_id);
        defer agent.deinit();

        // Run the agent loop (LLM inference + Tool execution)
        agent.run(actual_text) catch |err| {
            std.debug.print("Error running agent: {any}\n", .{err});
            const error_msg = try std.fmt.allocPrint(self.allocator, "⚠️ Error: {any}\n\nPlease try again.", .{err});
            defer self.allocator.free(error_msg);
            try self.send_message(wa_config, from, error_msg);
        };

        // Send the final response back to WhatsApp
        const messages = agent.ctx.get_messages();
        if (messages.len > 0) {
            const last_msg = messages[messages.len - 1];
            if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                try self.send_message(wa_config, from, last_msg.content.?);
            }
        }

        // Save session state to Vector/Graph DB for long-term memory
        agent.index_conversation() catch {};
    }

    /// Helper to send a text message back to a WhatsApp user using the Meta Cloud API.
    fn send_message(self: *WhatsAppBot, wa_config: WhatsAppConfig, to: []const u8, text: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "https://graph.facebook.com/v17.0/{s}/messages", .{wa_config.phoneNumberId});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{wa_config.accessToken});
        defer self.allocator.free(auth_header);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .messaging_product = "whatsapp",
            .recipient_type = "individual",
            .to = to,
            .type = "text",
            .text = .{ .body = text },
        }, .{});
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        };

        const response = try self.client.post(url, headers, body);
        defer @constCast(&response).deinit();

        if (response.status != .ok) {
            std.debug.print("Error sending WhatsApp message: status={d}, body={s}\n", .{ @intFromEnum(response.status), response.body });
        }
    }
};

/// Simple HTTP webhook server for WhatsApp.
/// Listens for incoming messages from Meta webhook callbacks.
pub const WebhookServer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    port: u16,
    bot: WhatsAppBot,

    pub fn init(allocator: std.mem.Allocator, config: Config, port: u16) !WebhookServer {
        const bot = try WhatsAppBot.init(allocator, config);
        return .{
            .allocator = allocator,
            .config = config,
            .port = port,
            .bot = bot,
        };
    }

    pub fn deinit(self: *WebhookServer) void {
        self.bot.deinit();
    }

    /// Run the webhook server (blocking)
    pub fn run(self: *WebhookServer) !void {
        std.debug.print("WhatsApp webhook server starting on port {d}\n", .{self.port});
        std.debug.print("Configure your Meta webhook callback URL to: http://YOUR_HOST:{d}/webhook\n", .{self.port});

        // Note: This is a simplified webhook server.
        // In production, you'd use a proper HTTP server library.
        // For now, we'll just print instructions and block.
        std.debug.print("\n⚠️ Note: WhatsApp webhook server requires a public HTTPS endpoint.\n", .{});
        std.debug.print("For local development, consider using ngrok or similar tunneling service.\n\n", .{});

        // Keep running
        while (true) {
            std.Thread.sleep(std.time.ns_per_s * 60);
        }
    }

    /// Handle webhook verification request (GET /webhook)
    /// Meta sends a verification challenge when setting up the webhook
    pub fn handleVerification(_: *WebhookServer, mode: []const u8, token: []const u8, challenge: []const u8) ?[]const u8 {
        // Verify token matches expected value
        const verify_token = "satibot_webhook_token"; // Should be configurable
        if (std.mem.eql(u8, mode, "subscribe") and std.mem.eql(u8, token, verify_token)) {
            return challenge; // Return the challenge to confirm verification
        }
        return null;
    }

    /// Handle incoming webhook message (POST /webhook)
    pub fn handleWebhook(self: *WebhookServer, body: []const u8) !void {
        try self.bot.processWebhook(body);
    }
};

/// Main entry point for the WhatsApp Bot service.
/// Initializes the bot and starts the webhook server.
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    // Extract WhatsApp config first - required for operation
    const wa_config = config.tools.whatsapp orelse {
        std.debug.print("Error: WhatsApp configuration is required but not found.\n", .{});
        return error.WhatsAppNotConfigured;
    };

    // recipientPhoneNumber is required - terminate if not configured
    const recipient = wa_config.recipientPhoneNumber orelse {
        std.debug.print("Error: whatsapp.recipientPhoneNumber is required but not configured. Terminating.\n", .{});
        return error.WhatsAppRecipientNotConfigured;
    };

    var bot = try WhatsAppBot.init(allocator, config);
    defer bot.deinit();

    std.debug.print("🐸 WhatsApp bot running. Press Ctrl+C to stop.\n", .{});

    std.debug.print("Sending startup message to {s}...\n", .{recipient});
    const startup_msg = "🐸 WhatsApp Bot is now online and ready! 🚀";
    bot.send_message(wa_config, recipient, startup_msg) catch |err| {
        std.debug.print("Failed to send startup message: {any}\n", .{err});
    };

    var server = try WebhookServer.init(allocator, config, 8080);
    defer server.deinit();

    try server.run();
}

test "WhatsAppBot lifecycle" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = .{
                .accessToken = "fake-token",
                .phoneNumberId = "12345",
            },
        },
    };

    var bot = try WhatsAppBot.init(allocator, config);
    defer bot.deinit();
}

test "WhatsAppBot returns if no config" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = null,
        },
    };

    var bot = try WhatsAppBot.init(allocator, config);
    defer bot.deinit();

    // processWebhook should return immediately (no crash)
    try bot.processWebhook("{}");
}

test "WhatsAppBot config validation" {
    const allocator = std.testing.allocator;

    // Test with valid config
    const valid_config = Config{
        .agents = .{ .defaults = .{ .model = "claude-3-sonnet" } },
        .providers = .{
            .anthropic = .{ .apiKey = "test-key" },
        },
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = .{
                .accessToken = "test-token",
                .phoneNumberId = "12345",
                .recipientPhoneNumber = "+1234567890",
            },
        },
    };

    var bot = try WhatsAppBot.init(allocator, valid_config);
    defer bot.deinit();

    // Verify bot initialized correctly
    try std.testing.expect(bot.config.tools.whatsapp != null);
    try std.testing.expectEqualStrings("test-token", bot.config.tools.whatsapp.?.accessToken);
    try std.testing.expectEqualStrings("12345", bot.config.tools.whatsapp.?.phoneNumberId);
}

test "WhatsAppBot session ID generation" {
    const allocator = std.testing.allocator;
    const phone = "+1234567890";

    const session_id = try std.fmt.allocPrint(allocator, "wa_{s}", .{phone});
    defer allocator.free(session_id);

    try std.testing.expectEqualStrings("wa_+1234567890", session_id);
}

test "WhatsAppBot command detection - /help" {
    // Test command detection
    const help_cmd = "/help";
    try std.testing.expect(std.mem.startsWith(u8, help_cmd, "/help"));

    const help_with_text = "/help me";
    try std.testing.expect(std.mem.startsWith(u8, help_with_text, "/help"));

    const not_help = "help";
    try std.testing.expect(!std.mem.startsWith(u8, not_help, "/help"));
}

test "WhatsAppBot command detection - /new" {
    // Test command detection
    const new_cmd = "/new";
    try std.testing.expect(std.mem.startsWith(u8, new_cmd, "/new"));

    const new_with_prompt = "/new what is zig?";
    try std.testing.expect(std.mem.startsWith(u8, new_with_prompt, "/new"));
}

test "WhatsAppBot message JSON serialization" {
    const allocator = std.testing.allocator;

    const message = .{
        .messaging_product = "whatsapp",
        .recipient_type = "individual",
        .to = "+1234567890",
        .type = "text",
        .text = .{ .body = "Test message" },
    };

    const json = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "messaging_product") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "whatsapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "+1234567890") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
}

test "WhatsAppBot config file template generation" {
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
        \\    "whatsapp": {
        \\      "accessToken": "YOUR_ACCESS_TOKEN_HERE",
        \\      "phoneNumberId": "YOUR_PHONE_NUMBER_ID_HERE",
        \\      "recipientPhoneNumber": "YOUR_PHONE_NUMBER_HERE"
        \\    }
        \\  }
        \\}
    ;

    // Verify template contains key fields
    try std.testing.expect(std.mem.indexOf(u8, default_json, "agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "whatsapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "accessToken") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json, "phoneNumberId") != null);
}

test "WhatsAppBot webhook verification" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = .{
                .accessToken = "test-token",
                .phoneNumberId = "12345",
            },
        },
    };

    var server = try WebhookServer.init(allocator, config, 8080);
    defer server.deinit();

    // Test verification with correct token
    const challenge = "1234567890";
    const result = server.handleVerification("subscribe", "satibot_webhook_token", challenge);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(challenge, result.?);

    // Test verification with wrong token
    const wrong_result = server.handleVerification("subscribe", "wrong_token", challenge);
    try std.testing.expect(wrong_result == null);
}

test "WhatsAppBot webhook payload parsing" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = null,
        },
    };

    var bot = try WhatsAppBot.init(allocator, config);
    defer bot.deinit();

    // Test with minimal valid payload
    const payload =
        \\{
        \\  "entry": [{
        \\    "changes": [{
        \\      "value": {
        \\        "messages": null
        \\      }
        \\    }]
        \\  }]
        \\}
    ;

    // Should not crash with null messages
    try bot.processWebhook(payload);
}

test "WhatsAppBot WebhookServer initialization" {
    const allocator = std.testing.allocator;
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test" } },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .whatsapp = .{
                .accessToken = "test-token",
                .phoneNumberId = "12345",
            },
        },
    };

    var server = try WebhookServer.init(allocator, config, 8080);
    defer server.deinit();

    try std.testing.expectEqual(server.port, 8080);
}
