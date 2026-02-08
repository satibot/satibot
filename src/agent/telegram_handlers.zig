/// Telegram-specific handlers for the generic event loop
const std = @import("std");
const event_loop = @import("event_loop.zig");
const Agent = @import("../agent.zig").Agent;
const Config = @import("../config.zig").Config;
const http = @import("../http.zig");

/// Telegram task data
pub const TelegramTaskData = struct {
    chat_id: i64,
    message_id: i64,
    text: []const u8,
    voice_duration: ?i32,
    update_id: i64,
};

/// Telegram event data
pub const TelegramEventData = struct {
    type: []const u8,
    data: ?[]const u8,
};

/// Context for Telegram handlers
pub const TelegramContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    client: *const http.Client,
    agent: ?*Agent,
    
    pub fn init(allocator: std.mem.Allocator, config: Config, client: *const http.Client) TelegramContext {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
            .agent = null,
        };
    }
};

/// Parse task data to extract Telegram-specific information
fn parseTelegramTask(allocator: std.mem.Allocator, task: event_loop.Task) !TelegramTaskData {
    // Parse the task data which should contain JSON or structured data
    // For now, we'll use a simple format: "chat_id:message_id:text"
    var it = std.mem.splitScalar(u8, task.data, ':');
    const chat_id_str = it.next() orelse return error.InvalidTaskData;
    const message_id_str = it.next() orelse return error.InvalidTaskData;
    const text = it.rest();
    
    const chat_id = try std.fmt.parseInt(i64, chat_id_str, 10);
    const message_id = try std.fmt.parseInt(i64, message_id_str, 10);
    
    return TelegramTaskData{
        .chat_id = chat_id,
        .message_id = message_id,
        .text = try allocator.dupe(u8, text),
        .voice_duration = null, // TODO: Extract from task source if needed
        .update_id = 0, // TODO: Extract from task if needed
    };
}

/// Global Telegram context for handlers
var global_telegram_context: ?*TelegramContext = null;

/// Handle incoming Telegram messages
pub fn handleTelegramTask(ctx: *TelegramContext, task: event_loop.Task) !void {
    const tg_data = try parseTelegramTask(ctx.allocator, task);
    defer ctx.allocator.free(tg_data.text);
    
    std.debug.print("Processing Telegram message from chat {d}: {s}\n", .{ tg_data.chat_id, tg_data.text });
    
    // Get Telegram config
    const tg_config = ctx.config.tools.telegram orelse return;
    
    // Create or get agent for this chat
    const session_id = try std.fmt.allocPrint(ctx.allocator, "tg_{d}", .{tg_data.chat_id});
    defer ctx.allocator.free(session_id);
    
    var agent = Agent.init(ctx.allocator, ctx.config, session_id);
    defer agent.deinit();
    
    // Send "typing" indicator
    const chat_id_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{tg_data.chat_id});
    defer ctx.allocator.free(chat_id_str);
    
    sendChatAction(ctx.client, tg_config.botToken, chat_id_str, "typing") catch |err| {
        std.debug.print("Failed to send typing action: {any}\n", .{err});
    };
    
    // Process message with agent
    agent.run(tg_data.text) catch |err| {
        std.debug.print("Error processing message: {any}\n", .{err});
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "⚠️ Error: Failed to process message\n\nPlease try again.", .{});
        defer ctx.allocator.free(error_msg);
        try sendMessage(ctx.client, tg_config.botToken, chat_id_str, error_msg);
        return;
    };
    
    // Get response from agent's messages
    const messages = agent.ctx.get_messages();
    if (messages.len > 0) {
        const last_msg = messages[messages.len - 1];
        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
            try sendMessage(ctx.client, tg_config.botToken, chat_id_str, last_msg.content.?);
        }
    }
}

/// Global task handler that uses the global context
fn globalTaskHandler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
    const ctx = global_telegram_context orelse return error.ContextNotSet;
    _ = allocator;
    try handleTelegramTask(ctx, task);
}

/// Handle Telegram-specific events (e.g., scheduled messages, reminders)
pub fn handleTelegramEvent(allocator: std.mem.Allocator, event: event_loop.Event) !void {
    _ = allocator;
    if (event.payload) |payload| {
        std.debug.print("Processing Telegram event: {s}\n", .{payload});
        
        // Parse event data
        // TODO: Implement specific event handling based on event type
        // Examples:
        // - Scheduled messages
        // - Reminders
        // - Daily reports
        // - Bot maintenance tasks
    }
}

/// Send message to Telegram
fn sendMessage(client: *const http.Client, bot_token: []const u8, chat_id: []const u8, text: []const u8) !void {
    const url = try std.fmt.allocPrint(client.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer client.allocator.free(url);
    
    const body = try std.json.Stringify.valueAlloc(client.allocator, .{
        .chat_id = chat_id,
        .text = text,
        .parse_mode = "Markdown",
    }, .{});
    defer client.allocator.free(body);
    
    const response = try @constCast(client).post(url, &.{}, body);
    defer @constCast(&response).deinit();
}

/// Send chat action (e.g., "typing")
fn sendChatAction(client: *const http.Client, bot_token: []const u8, chat_id: []const u8, action: []const u8) !void {
    const url = try std.fmt.allocPrint(client.allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{bot_token});
    defer client.allocator.free(url);
    
    const body = try std.json.Stringify.valueAlloc(client.allocator, .{
        .chat_id = chat_id,
        .action = action,
    }, .{});
    defer client.allocator.free(body);
    
    const response = try @constCast(client).post(url, &.{}, body);
    defer @constCast(&response).deinit();
}

/// Create a task handler wrapper that captures Telegram context
pub fn createTelegramTaskHandler(ctx: *TelegramContext) event_loop.TaskHandler {
    global_telegram_context = ctx;
    return globalTaskHandler;
}

/// Create an event handler wrapper that captures Telegram context
pub fn createTelegramEventHandler(ctx: *TelegramContext) event_loop.EventHandler {
    _ = ctx;
    return struct {
        fn handler(allocator: std.mem.Allocator, event: event_loop.Event) !void {
            try handleTelegramEvent(allocator, event);
        }
    }.handler;
}
