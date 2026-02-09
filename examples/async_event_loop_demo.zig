/// Comprehensive demo of the async event loop handling multiple ChatIDs and providers.
/// This example shows how the event loop can efficiently manage concurrent conversations.
const std = @import("std");
const AsyncEventLoop = @import("../src/agent/event_loop.zig").AsyncEventLoop;
const Config = @import("../src/config.zig").Config;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize config with multiple providers
    var config = Config{
        .agents = .{
            .defaults = .{
                .model = "anthropic/claude-3-5-sonnet-20241022",
                .embeddingModel = "arcee-ai/trinity-mini:free",
            },
        },
        .providers = .{
            .anthropic = .{ .apiKey = "your-anthropic-key" },
            .openrouter = .{ .apiKey = "your-openrouter-key" },
            .groq = .{ .apiKey = "your-groq-key" },
        },
        .tools = .{
            .web = .{ .search = .{ .apiKey = "your-search-key" } },
            .telegram = .{
                .botToken = "your-bot-token",
                .chatId = "your-chat-id",
            },
        },
    };

    // Initialize the async event loop
    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();

    std.debug.print("=== Async Event Loop Demo ===\n", .{});
    std.debug.print("Simulating multi-chat, multi-provider scenario...\n\n", .{});

    // Add various cron jobs
    try event_loop.addCronJob("morning_digest", "Morning Digest", "Create a daily summary of all conversations and important events", .{
        .kind = .every,
        .every_ms = 60 * 60 * 1000, // Every hour for demo (normally 24h)
    });

    try event_loop.addCronJob("health_check", "System Health Check", "Check all systems, databases, and external services", .{
        .kind = .every,
        .every_ms = 5 * 60 * 1000, // Every 5 minutes
    });

    try event_loop.addCronJob("weekly_report", "Weekly Analytics Report", "Generate comprehensive weekly usage and performance report", .{
        .kind = .every,
        .every_ms = 7 * 24 * 60 * 60 * 1000, // Every week
    });

    // Simulate multiple concurrent chats from different platforms
    _ = async simulateTelegramChats(&event_loop);
    _ = async simulateDiscordChats(&event_loop);
    _ = async simulateWhatsAppChats(&event_loop);

    // Simulate admin commands
    _ = async simulateAdminCommands(&event_loop);

    // Run for demo duration then shutdown
    _ = async demoShutdownTimer(&event_loop);

    // Start the event loop
    try event_loop.run();
}

/// Simulate Telegram chat messages
fn simulateTelegramChats(loop: *AsyncEventLoop) void {
    const telegram_chats = [_]struct { id: i64, name: []const u8 }{
        .{ .id = 123456789, .name = "Alice" },
        .{ .id = 987654321, .name = "Bob" },
        .{ .id = 555666777, .name = "Charlie" },
    };

    var message_count: u32 = 0;
    while (message_count < 10) : (message_count += 1) {
        // Wait random interval between messages
        const delay = 2000 + std.crypto.random.intRangeAtMost(u64, 0, 3000);
        loop.waitForTime(delay);

        // Pick random chat
        const chat_idx = std.crypto.random.intRangeAtMost(usize, 0, telegram_chats.len - 1);
        const chat = telegram_chats[chat_idx];

        // Generate message
        const messages = [_][]const u8{
            "What's the weather like?",
            "Help me write some Zig code",
            "Tell me a joke",
            "What are you working on?",
            "Can you help me debug?",
            "Explain async/await in Zig",
            "What's new in technology?",
            "Help me plan my day",
            "Summarize my last conversation",
            "Set a reminder for me",
        };

        const msg_idx = std.crypto.random.intRangeAtMost(usize, 0, messages.len - 1);
        const message = try std.fmt.allocPrint(loop.allocator, "[Telegram] {s}", .{messages[msg_idx]});
        defer loop.allocator.free(message);

        try loop.addChatMessage(chat.id, message);
        std.debug.print("📱 Telegram message from {s} (chat {d})\n", .{ chat.name, chat.id });
    }
}

/// Simulate Discord channel messages
fn simulateDiscordChats(loop: *AsyncEventLoop) void {
    const discord_channels = [_]struct { id: i64, name: []const u8 }{
        .{ .id = 111222333, .name = "#general" },
        .{ .id = 444555666, .name = "#zig-dev" },
        .{ .id = 777888999, .name = "#random" },
    };

    var message_count: u32 = 0;
    while (message_count < 8) : (message_count += 1) {
        const delay = 3000 + std.crypto.random.intRangeAtMost(u64, 0, 2000);
        loop.waitForTime(delay);

        const channel_idx = std.crypto.random.intRangeAtMost(usize, 0, discord_channels.len - 1);
        const channel = discord_channels[channel_idx];

        const message = try std.fmt.allocPrint(loop.allocator, "[Discord] Hey everyone, check out this cool Zig pattern!", .{});
        defer loop.allocator.free(message);

        // Use negative IDs to distinguish from Telegram
        try loop.addChatMessage(-channel.id, message);
        std.debug.print("💬 Discord message in {s} (channel {d})\n", .{ channel.name, channel.id });
    }
}

/// Simulate WhatsApp messages
fn simulateWhatsAppChats(loop: *AsyncEventLoop) void {
    const whatsapp_contacts = [_]struct { id: i64, name: []const u8 }{
        .{ .id = 999888777, .name = "David" },
        .{ .id = 666555444, .name = "Emma" },
    };

    var message_count: u32 = 0;
    while (message_count < 6) : (message_count += 1) {
        const delay = 4000 + std.crypto.random.intRangeAtMost(u64, 0, 4000);
        loop.waitForTime(delay);

        const contact_idx = std.crypto.random.intRangeAtMost(usize, 0, whatsapp_contacts.len - 1);
        const contact = whatsapp_contacts[contact_idx];

        const message = try std.fmt.allocPrint(loop.allocator, "[WhatsApp] Quick question about async programming", .{});
        defer loop.allocator.free(message);

        // Use very large positive IDs for WhatsApp
        try loop.addChatMessage(contact.id + 1000000000, message);
        std.debug.print("📞 WhatsApp message from {s} (contact {d})\n", .{ contact.name, contact.id });
    }
}

/// Simulate admin commands and system events
fn simulateAdminCommands(loop: *AsyncEventLoop) void {
    // Add a dynamic cron job after 10 seconds
    loop.waitForTime(10000);

    try loop.addCronJob("urgent_notification", "Urgent Notification", "Send urgent notification to all active chats", .{
        .kind = .at,
        .at_ms = std.time.milliTimestamp() + 15000, // 15 seconds from now
    });

    std.debug.print("🔔 Added urgent notification cron job\n", .{});

    // Simulate system event
    loop.waitForTime(20000);

    const system_message = try std.fmt.allocPrint(loop.allocator, "[SYSTEM] High load detected on chat servers", .{});
    defer loop.allocator.free(system_message);

    try loop.addChatMessage(0, system_message); // ID 0 for system messages
    std.debug.print("⚠️ System event generated\n", .{});
}

/// Timer to shutdown demo after specified duration
fn demoShutdownTimer(loop: *AsyncEventLoop) void {
    // Run for 30 seconds then shutdown
    loop.waitForTime(30000);

    std.debug.print("\n=== Demo completed, shutting down ===\n", .{});
    std.debug.print("Processed messages from multiple platforms concurrently!\n", .{});
    std.debug.print("Cron jobs were scheduled and executed asynchronously.\n", .{});
    std.debug.print("Event loop efficiently managed all operations.\n\n", .{});

    loop.shutdown();
}
