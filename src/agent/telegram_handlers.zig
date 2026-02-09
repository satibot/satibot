/// Telegram-specific handlers for the generic event loop
const std = @import("std");
const event_loop = @import("event_loop.zig");
const xev_event_loop = @import("xev_event_loop.zig");
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
    event_loop: ?*xev_event_loop.XevEventLoop = null,

    pub fn init(allocator: std.mem.Allocator, config: Config, client: *const http.Client) TelegramContext {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
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

/// Parse task data from xev event loop
fn parseXevTelegramTask(allocator: std.mem.Allocator, task: xev_event_loop.Task) !TelegramTaskData {
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
    std.debug.print("handleTelegramTask: Starting task processing\n", .{});

    const tg_data = try parseTelegramTask(ctx.allocator, task);
    defer ctx.allocator.free(tg_data.text);

    try handleTelegramTaskData(ctx, tg_data);
}

/// Handle Telegram task data (shared between event loop implementations)
pub fn handleTelegramTaskData(ctx: *TelegramContext, tg_data: TelegramTaskData) !void {
    std.debug.print("Processing Telegram message from chat {d}: {s}\n", .{ tg_data.chat_id, tg_data.text });

    // Get Telegram config
    const tg_config = ctx.config.tools.telegram orelse {
        std.debug.print("Error: No Telegram config found\n", .{});
        return;
    };
    std.debug.print("Got Telegram config\n", .{});

    // Use a temporary allocator since we're in a worker thread
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("Created temporary allocator\n", .{});

    // Create or get agent for this chat
    const session_id = try std.fmt.allocPrint(allocator, "tg_{d}", .{tg_data.chat_id});
    defer allocator.free(session_id);
    std.debug.print("Created session_id: {s}\n", .{session_id});

    var agent = Agent.init(allocator, ctx.config, session_id);
    defer agent.deinit();
    std.debug.print("Initialized agent\n", .{});

    // Check if agent has proper context
    std.debug.print("Agent context: {}\n", .{agent.ctx});
    std.debug.print("Agent allocator: {any}\n", .{agent.allocator});

    // Send "typing" indicator
    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{tg_data.chat_id});
    defer allocator.free(chat_id_str);

    sendChatAction(ctx.client, tg_config.botToken, chat_id_str, "typing", allocator) catch |err| {
        std.debug.print("Failed to send typing action: {any}\n", .{err});
    };
    std.debug.print("Sent typing action\n", .{});

    // Process message with agent
    std.debug.print("Calling agent.run()...\n", .{});
    agent.run(tg_data.text) catch |err| {
        std.debug.print("Error processing message: {any}\n", .{err});

        // Use last_chunk if it contains an error message from the provider
        const error_msg = if (agent.last_chunk) |chunk|
            try allocator.dupe(u8, chunk)
        else
            try std.fmt.allocPrint(allocator, "⚠️ Error: Failed to process message\n\nPlease try again.", .{});

        defer allocator.free(error_msg);
        try sendMessage(ctx.client, tg_config.botToken, chat_id_str, error_msg, allocator);
        return;
    };
    std.debug.print("agent.run() completed successfully\n", .{});

    // Get response from agent's messages
    const messages = agent.ctx.get_messages();
    std.debug.print("Agent has {d} messages\n", .{messages.len});

    // Print all messages for debugging
    for (messages, 0..) |msg, i| {
        std.debug.print("Message {d}: role={s}, content={any}\n", .{ i, msg.role, msg.content });
    }

    if (messages.len > 0) {
        const last_msg = messages[messages.len - 1];
        std.debug.print("Last message role: {s}, content: {any}\n", .{ last_msg.role, last_msg.content });

        if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
            std.debug.print("Sending response to Telegram...\n", .{});
            sendMessage(ctx.client, tg_config.botToken, chat_id_str, last_msg.content.?, allocator) catch |err| {
                std.debug.print("Failed to send message: {any}\n", .{err});
            };
            std.debug.print("Response sent successfully\n", .{});
        } else {
            std.debug.print("No assistant response found\n", .{});
            // Send a default response if no assistant message
            const default_msg = "I received your message but couldn't generate a response. Please try again.";
            sendMessage(ctx.client, tg_config.botToken, chat_id_str, default_msg, allocator) catch |err| {
                std.debug.print("Failed to send default message: {any}\n", .{err});
            };
        }
    } else {
        std.debug.print("No messages in agent context\n", .{});
        // Send a default response if no messages
        const default_msg = "I'm having trouble processing messages right now. Please try again.";
        sendMessage(ctx.client, tg_config.botToken, chat_id_str, default_msg, allocator) catch |err| {
            std.debug.print("Failed to send default message: {any}\n", .{err});
        };
    }

    // Save session state to Vector/Graph DB for long-term memory.
    // This enables RAG (Retrieval-Augmented Generation) functionality.
    agent.index_conversation() catch {};
}

/// Global task handler that uses the global context
fn globalTaskHandler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
    std.debug.print("globalTaskHandler: Received task from {s}\n", .{task.source});
    const ctx = global_telegram_context orelse {
        std.debug.print("Error: Global telegram context not set\n", .{});
        return error.ContextNotSet;
    };
    _ = allocator;
    try handleTelegramTask(ctx, task);
    std.debug.print("globalTaskHandler: Task processing completed\n", .{});
}

/// Handle HTTP requests for Telegram API
fn handleHttpRequest(ctx: *TelegramContext, task: xev_event_loop.Task, allocator: std.mem.Allocator) !void {
    // Debug: Check if ctx and allocator are valid
    std.debug.print("handleHttpRequest: ctx={*}, allocator={any}\n", .{ ctx, allocator });

    // Parse the HTTP request from task data
    // Format: "GET:URL" or "POST:URL:body"
    // Note: URL contains :// so we need to handle that carefully

    // Find the first colon to separate method
    const first_colon = std.mem.indexOfScalar(u8, task.data, ':') orelse return error.InvalidHttpRequest;
    const method = task.data[0..first_colon];

    // The rest starts after the first colon
    const rest = task.data[first_colon + 1 ..];

    if (std.mem.eql(u8, method, "GET")) {
        // For GET, the entire rest is the URL
        std.debug.print("Parsing HTTP request: method='{s}', task_data='{s}'\n", .{ method, task.data });
        try handleGetRequest(ctx, rest, allocator);
    } else if (std.mem.eql(u8, method, "POST")) {
        // For POST, we need to split URL and body
        // Find the colon that separates URL from body
        // It should be after the :// part of the URL
        const scheme_end = std.mem.indexOf(u8, rest, "://") orelse return error.InvalidHttpRequest;
        const url_start = scheme_end + 3; // Skip "://"

        // Look for the next colon after the URL scheme
        const url_body_separator = std.mem.indexOfScalar(u8, rest[url_start..], ':') orelse return error.InvalidHttpRequest;
        const url_body_separator_pos = url_start + url_body_separator;

        const url = rest[0..url_body_separator_pos];
        const body = rest[url_body_separator_pos + 1 ..];

        std.debug.print("Parsing HTTP request: method='{s}', task_data='{s}'\n", .{ method, task.data });
        try handlePostRequest(ctx, url, body);
    } else {
        std.debug.print("Unsupported HTTP method: {s}\n", .{method});
        return error.UnsupportedHttpMethod;
    }
}

/// Handle GET requests
fn handleGetRequest(ctx: *TelegramContext, url: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("GET request URL: {s}\n", .{url});

    // Create a temporary HTTP client for this request
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var temp_client = try http.Client.initWithSettings(gpa.allocator(), .{
        .request_timeout_ms = 60000,
        .keep_alive = true,
    });
    defer temp_client.deinit();

    const response = try temp_client.get(url, &[_]std.http.Header{});
    defer @constCast(&response).deinit();

    std.debug.print("Making GET request to: {s}\n", .{url});
    std.debug.print("HTTP Response status: {d}, body length: {d}\n", .{ response.status, response.body.len });

    if (response.status != .ok) {
        std.debug.print("HTTP request failed with status {any}\n", .{response.status});
        return;
    }

    std.debug.print("Response body: {s}\n", .{response.body});

    // Parse JSON response
    const parsed = std.json.parseFromSlice(struct {
        ok: bool,
        result: []struct {
            update_id: i64,
            message: ?struct {
                message_id: i64,
                from: struct {
                    id: i64,
                    is_bot: bool,
                    first_name: []const u8,
                    username: []const u8,
                    language_code: []const u8,
                },
                chat: struct {
                    id: i64,
                    first_name: []const u8,
                    username: []const u8,
                    type: []const u8,
                },
                date: i64,
                text: []const u8,
            },
        },
    }, gpa.allocator(), response.body, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse Telegram response: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value.ok and parsed.value.result.len > 0) {
        var max_update_id: i64 = 0;

        for (parsed.value.result) |update| {
            if (update.update_id > max_update_id) {
                max_update_id = update.update_id;
            }

            if (update.message) |msg| {
                // Create a task to process this message
                const task_data = try std.fmt.allocPrint(allocator, "{d}:{d}:{s}", .{ msg.chat.id, msg.message_id, msg.text });
                defer allocator.free(task_data);

                // Add task to event loop
                if (ctx.event_loop) |el| {
                    try el.addTask(try std.fmt.allocPrint(allocator, "msg_{d}", .{msg.message_id}), task_data, "telegram_message");
                } else {
                    std.debug.print("Error: event_loop is null, cannot add task\n", .{});
                }
            }
        }

        // Update the offset
        if (max_update_id > 0 and ctx.event_loop != null) {
            ctx.event_loop.?.updateOffset(max_update_id + 1);
            std.debug.print("Updated offset to {d}\n", .{max_update_id + 1});
        }
    }
}

/// Handle POST requests
fn handlePostRequest(ctx: *TelegramContext, url: []const u8, body: []const u8) !void {
    // Log the request using context for potential future debugging
    std.debug.print("POST request (ctx: {*}) to URL: {s}\n", .{ ctx, url });

    // Create a temporary HTTP client for this request
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var temp_client = try http.Client.initWithSettings(gpa.allocator(), .{
        .request_timeout_ms = 60000,
        .keep_alive = true,
    });
    defer temp_client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const response = try temp_client.post(url, headers, body);
    defer @constCast(&response).deinit();

    std.debug.print("HTTP Response status: {any}\n", .{response.status});
    if (response.status != .ok) {
        std.debug.print("Response body: {s}\n", .{response.body});
    }
}

/// Global task handler for xev event loop
fn globalXevTaskHandler(allocator: std.mem.Allocator, task: xev_event_loop.Task) !void {
    std.debug.print("globalXevTaskHandler: Received task from {s}, data: {s}\n", .{ task.source, task.data });
    const ctx = global_telegram_context orelse {
        std.debug.print("Error: Global telegram context not set\n", .{});
        return error.ContextNotSet;
    };

    // Handle HTTP requests
    if (std.mem.eql(u8, task.source, "telegram_http")) {
        // For HTTP requests, we need to process them but can't add tasks from here
        // since we're in a worker thread. Instead, we'll process directly.
        try handleHttpRequestDirect(ctx, task, allocator);
        return;
    }

    const tg_data = try parseXevTelegramTask(ctx.allocator, task);
    defer ctx.allocator.free(tg_data.text);

    std.debug.print("globalXevTaskHandler: Parsed task - chat_id: {d}, text: {s}\n", .{ tg_data.chat_id, tg_data.text });

    try handleTelegramTaskData(ctx, tg_data);
    std.debug.print("globalXevTaskHandler: Task processing completed\n", .{});
}

/// Handle HTTP requests for Telegram API (direct processing without adding tasks)
fn handleHttpRequestDirect(ctx: *TelegramContext, task: xev_event_loop.Task, allocator: std.mem.Allocator) !void {
    // Debug: Check if ctx and allocator are valid
    std.debug.print("handleHttpRequestDirect: ctx={*}, allocator={any}\n", .{ ctx, allocator });

    // Parse the HTTP request from task data
    // Format: "GET:URL" or "POST:URL:body"
    // Note: URL contains :// so we need to handle that carefully

    // Find the first colon to separate method
    const first_colon = std.mem.indexOfScalar(u8, task.data, ':') orelse return error.InvalidHttpRequest;
    const method = task.data[0..first_colon];

    // The rest starts after the first colon
    const rest = task.data[first_colon + 1 ..];

    if (std.mem.eql(u8, method, "GET")) {
        // For GET, the entire rest is the URL
        std.debug.print("Parsing HTTP request: method='{s}', task_data='{s}'\n", .{ method, task.data });
        try handleGetRequestDirect(ctx, rest, allocator);
    } else if (std.mem.eql(u8, method, "POST")) {
        // For POST, we need to split URL and body
        // Find the colon that separates URL from body
        // It should be after the :// part of the URL
        const scheme_end = std.mem.indexOf(u8, rest, "://") orelse return error.InvalidHttpRequest;
        const url_start = scheme_end + 3; // Skip "://"

        // Look for the next colon after the URL scheme
        const url_body_separator = std.mem.indexOfScalar(u8, rest[url_start..], ':') orelse return error.InvalidHttpRequest;
        const url_body_separator_pos = url_start + url_body_separator;

        const url = rest[0..url_body_separator_pos];
        const body = rest[url_body_separator_pos + 1 ..];

        std.debug.print("Parsing HTTP request: method='{s}', task_data='{s}'\n", .{ method, task.data });
        try handlePostRequest(ctx, url, body);
    } else {
        std.debug.print("Unsupported HTTP method: {s}\n", .{method});
        return error.UnsupportedHttpMethod;
    }
}

/// Handle GET requests directly without adding new tasks
fn handleGetRequestDirect(ctx: *TelegramContext, url: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("GET request URL: {s}\n", .{url});

    // Create a temporary HTTP client for this request
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var temp_client = try http.Client.initWithSettings(gpa.allocator(), .{
        .request_timeout_ms = 60000,
        .keep_alive = true,
    });
    defer temp_client.deinit();

    const response = try temp_client.get(url, &[_]std.http.Header{});
    defer @constCast(&response).deinit();

    std.debug.print("Making GET request to: {s}\n", .{url});
    std.debug.print("HTTP Response status: {d}, body length: {d}\n", .{ response.status, response.body.len });

    if (response.status != .ok) {
        std.debug.print("HTTP request failed with status {any}\n", .{response.status});
        return;
    }

    std.debug.print("Response body: {s}\n", .{response.body});

    // Parse JSON response
    const parsed = std.json.parseFromSlice(struct {
        ok: bool,
        result: []struct {
            update_id: i64,
            message: ?struct {
                message_id: i64,
                from: struct {
                    id: i64,
                    is_bot: bool,
                    first_name: []const u8,
                    username: []const u8,
                    language_code: []const u8,
                },
                chat: struct {
                    id: i64,
                    first_name: []const u8,
                    username: []const u8,
                    type: []const u8,
                },
                date: i64,
                text: []const u8,
            },
        },
    }, gpa.allocator(), response.body, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse Telegram response: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value.ok and parsed.value.result.len > 0) {
        var max_update_id: i64 = 0;

        for (parsed.value.result) |update| {
            if (update.update_id > max_update_id) {
                max_update_id = update.update_id;
            }

            if (update.message) |msg| {
                // Process the message directly instead of adding a task
                std.debug.print("Processing message directly: chat_id={d}, text={s}\n", .{ msg.chat.id, msg.text });

                // Create TelegramTaskData directly
                const tg_data = TelegramTaskData{
                    .chat_id = msg.chat.id,
                    .message_id = msg.message_id,
                    .text = try allocator.dupe(u8, msg.text),
                    .voice_duration = null,
                    .update_id = update.update_id,
                };

                // Handle the message directly
                handleTelegramTaskData(ctx, tg_data) catch |err| {
                    std.debug.print("Error handling message: {any}\n", .{err});
                };

                // Clean up
                allocator.free(tg_data.text);
            }
        }

        // Update the offset
        if (max_update_id > 0 and ctx.event_loop != null) {
            ctx.event_loop.?.updateOffset(max_update_id + 1);
            std.debug.print("Updated offset to {d}\n", .{max_update_id + 1});
        }
    }
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

/// Handle Telegram-specific events for xev event loop
pub fn handleXevTelegramEvent(allocator: std.mem.Allocator, event: xev_event_loop.Event) !void {
    _ = allocator;
    if (event.payload) |payload| {
        std.debug.print("Processing Xev Telegram event: {s}\n", .{payload});

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
fn sendMessage(client: *const http.Client, bot_token: []const u8, chat_id: []const u8, text: []const u8, allocator: std.mem.Allocator) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id,
        .text = text,
        .parse_mode = "Markdown",
    }, .{});
    defer allocator.free(body);

    const response = try @constCast(client).post(url, &.{}, body);
    defer @constCast(&response).deinit();
}

/// Send chat action (e.g., "typing")
fn sendChatAction(client: *const http.Client, bot_token: []const u8, chat_id: []const u8, action: []const u8, allocator: std.mem.Allocator) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{bot_token});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id,
        .action = action,
    }, .{});
    defer allocator.free(body);

    const response = try @constCast(client).post(url, &.{}, body);
    defer @constCast(&response).deinit();
}

/// Create a task handler wrapper that captures Telegram context
pub fn createTelegramTaskHandler(ctx: *TelegramContext) event_loop.TaskHandler {
    global_telegram_context = ctx;
    return globalTaskHandler;
}

/// Create a task handler wrapper for xev event loop
pub fn createXevTelegramTaskHandler(ctx: *TelegramContext) xev_event_loop.TaskHandler {
    global_telegram_context = ctx;
    return globalXevTaskHandler;
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

/// Create an event handler wrapper for xev event loop
pub fn createXevTelegramEventHandler(ctx: *TelegramContext) xev_event_loop.EventHandler {
    _ = ctx;
    return struct {
        fn handler(allocator: std.mem.Allocator, event: xev_event_loop.Event) !void {
            try handleXevTelegramEvent(allocator, event);
        }
    }.handler;
}
