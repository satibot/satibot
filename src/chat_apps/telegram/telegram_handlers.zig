/// Telegram-specific handlers for the generic event loop
const std = @import("std");
const xev_event_loop = @import("../../utils/xev_event_loop.zig");
const messages = @import("../../agent/messages.zig");
const Config = @import("../../config.zig").Config;
const http = @import("../../http.zig");
const ConfigModule = @import("../../config.zig");

/// Session history cache - simple HashMap for performance
pub const SessionCache = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(messages.SessionHistory),
    last_used: std.StringHashMap(i64),
    max_idle_time_ms: u64 = 30 * 60 * 1000, // 30 minutes

    pub fn init(allocator: std.mem.Allocator) SessionCache {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(messages.SessionHistory).init(allocator),
            .last_used = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *SessionCache) void {
        // Free all session histories
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();

        // Free last_used keys
        var time_it = self.last_used.iterator();
        while (time_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_used.deinit();

        self.* = undefined;
    }

    pub fn getOrCreateSession(self: *SessionCache, session_id: []const u8) !*messages.SessionHistory {
        const now = std.time.timestamp();

        if (self.sessions.getPtr(session_id)) |history| {
            // Update last used timestamp
            if (self.last_used.getPtr(session_id)) |time_ptr| {
                time_ptr.* = now;
            }
            return history;
        }

        // Create new session
        const session_id_dupe = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(session_id_dupe);

        const history = messages.SessionHistory.init(self.allocator);
        try self.sessions.put(session_id_dupe, history);
        try self.last_used.put(session_id_dupe, now);

        return self.sessions.getPtr(session_id_dupe).?;
    }

    pub fn cleanup(self: *SessionCache) void {
        const now = std.time.timestamp();
        const max_idle_seconds = @divFloor(self.max_idle_time_ms, 1000);

        var keys_to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer keys_to_remove.deinit(self.allocator);

        var it = self.last_used.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.* > max_idle_seconds) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch |append_err| {
                    std.debug.print("Failed to append key for removal: {any}\n", .{append_err});
                };
            }
        }

        for (keys_to_remove.items) |session_id| {
            if (self.sessions.fetchRemove(session_id)) |removed| {
                @constCast(&removed.value).deinit();
            }
            if (self.last_used.fetchRemove(session_id)) |_| {
                self.allocator.free(session_id);
                std.debug.print("Cleaned up idle session: {s}\n", .{session_id});
            }
        }
    }
};

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
    session_cache: ?SessionCache = null,

    pub fn init(allocator: std.mem.Allocator, config: Config, client: *const http.Client) TelegramContext {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
        };
    }

    /// Initialize the session cache
    pub fn initSessionCache(self: *TelegramContext) void {
        if (self.session_cache == null) {
            self.session_cache = SessionCache.init(self.allocator);
            std.debug.print("Session cache initialized\n", .{});
        }
    }

    pub fn deinit(self: *TelegramContext) void {
        if (self.session_cache) |*cache| {
            cache.deinit();
        }
        self.* = undefined;
    }
};

/// Parse task data from xev event loop
fn parseTelegramTask(allocator: std.mem.Allocator, task: xev_event_loop.Task) !TelegramTaskData {
    // Parse the task data which should contain JSON or structured data
    // For now, we'll use a simple format: "chat_id:message_id:text"
    var it = std.mem.splitScalar(u8, task.data, ':');
    const chat_id_str = it.next() orelse return error.InvalidTaskData;
    const message_id_str = it.next() orelse return error.InvalidTaskData;
    const text = it.rest();

    const chat_id = try std.fmt.parseInt(i64, chat_id_str, 10);
    const message_id = try std.fmt.parseInt(i64, message_id_str, 10);

    return .{
        .chat_id = chat_id,
        .message_id = message_id,
        .text = try allocator.dupe(u8, text),
        .voice_duration = null, // TODO: Extract from task source if needed
        .update_id = 0, // TODO: Extract from task if needed
    };
}

/// Global Telegram context for handlers
var global_telegram_context: ?*TelegramContext = null;

/// Handle /openrouter command to update model configuration
fn handleOpenrouterCommand(ctx: *TelegramContext, tg_data: TelegramTaskData) !void {
    // Extract model name from command
    const command = tg_data.text["/openrouter ".len..];
    const model_name = std.mem.trim(u8, command, " \t\r\n");

    if (model_name.len == 0) {
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "❌ Usage: `/openrouter <model-name>`\nExample: `/openrouter z-ai/glm-4.5-air:free`", .{});
        defer ctx.allocator.free(error_msg);

        const chat_id_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{tg_data.chat_id});
        defer ctx.allocator.free(chat_id_str);

        const tg_config = ctx.config.tools.telegram orelse return;
        sendMessage(ctx.allocator, ctx.client, tg_config.botToken, chat_id_str, error_msg) catch |send_err| {
            std.debug.print("Failed to send error message: {any}\n", .{send_err});
        };
        return;
    }

    var loaded_config = try ConfigModule.load(ctx.allocator);
    defer loaded_config.deinit();

    // Update model in config
    const old_model = loaded_config.value.agents.defaults.model;
    loaded_config.value.agents.defaults.model = try ctx.allocator.dupe(u8, model_name);

    // Save config to file
    ConfigModule.save(ctx.allocator, loaded_config.value) catch |err| {
        std.debug.print("Failed to save config: {any}\n", .{err});
        const error_msg = try std.fmt.allocPrint(ctx.allocator, "❌ Failed to save configuration: {any}", .{err});
        defer ctx.allocator.free(error_msg);

        const chat_id_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{tg_data.chat_id});
        defer ctx.allocator.free(chat_id_str);

        const tg_config = ctx.config.tools.telegram orelse return;
        sendMessage(ctx.allocator, ctx.client, tg_config.botToken, chat_id_str, error_msg) catch |send_err| {
            std.debug.print("Failed to save config error message: {any}\n", .{send_err});
        };
        return;
    };

    // Send confirmation message
    const success_msg = try std.fmt.allocPrint(ctx.allocator, "✅ Model updated successfully!\n\nOld model: `{s}`\nNew model: `{s}`\n\nNote: Bot restart may be required for changes to take effect.", .{ old_model, model_name });
    defer ctx.allocator.free(success_msg);

    const chat_id_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{tg_data.chat_id});
    defer ctx.allocator.free(chat_id_str);

    const tg_config = ctx.config.tools.telegram orelse return;
    sendMessage(ctx.allocator, ctx.client, tg_config.botToken, chat_id_str, success_msg) catch |err| {
        std.debug.print("Failed to send success message: {any}\n", .{err});
    };

    std.debug.print("Updated model from '{s}' to '{s}'\n", .{ old_model, model_name });
}

/// Handle incoming Telegram messages
pub fn handleTelegramTask(ctx: *TelegramContext, task: xev_event_loop.Task) !void {
    std.debug.print("handleTelegramTask: Starting task processing\n", .{});

    const tg_data = try parseTelegramTask(ctx.allocator, task);
    defer ctx.allocator.free(tg_data.text);

    try handleTelegramTaskData(ctx, tg_data);
}

/// Handle Telegram task data (shared between event loop implementations)
pub fn handleTelegramTaskData(ctx: *TelegramContext, tg_data: TelegramTaskData) !void {
    std.debug.print("Processing Telegram message from chat {d}: {s}\n", .{ tg_data.chat_id, tg_data.text });

    // Check for /openrouter command to update model
    if (std.mem.startsWith(u8, tg_data.text, "/openrouter ")) {
        try handleOpenrouterCommand(ctx, tg_data);
        return;
    }

    // Get Telegram config
    const tg_config = ctx.config.tools.telegram orelse {
        std.debug.print("Error: No Telegram config found\n", .{});
        return;
    };
    std.debug.print("Got Telegram config\n", .{});

    // Initialize session cache if not already done
    ctx.initSessionCache();

    // Use context allocator
    const allocator = ctx.allocator;
    std.debug.print("Using context allocator\n", .{});

    // Create session ID for this chat
    const session_id = try std.fmt.allocPrint(allocator, "tg_{d}", .{tg_data.chat_id});
    defer allocator.free(session_id);
    std.debug.print("Created session_id: {s}\n", .{session_id});

    // Send "typing" indicator
    const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{tg_data.chat_id});
    defer allocator.free(chat_id_str);

    sendChatAction(allocator, ctx.client, tg_config.botToken, chat_id_str, "typing") catch |err| {
        std.debug.print("Failed to send typing action: {any}\n", .{err});
    };
    std.debug.print("Sent typing action\n", .{});

    // Process message using functional approach
    std.debug.print("Calling messages.processMessage()...\n", .{});
    const result = messages.processMessage(allocator, ctx.config, session_id, tg_data.text) catch |err| {
        std.debug.print("Error processing message: {any}\n", .{err});

        const error_msg = try std.fmt.allocPrint(allocator, "⚠️ Error: Failed to process message\n\nPlease try again.", .{});
        defer allocator.free(error_msg);
        try sendMessage(allocator, ctx.client, tg_config.botToken, chat_id_str, error_msg);
        return;
    };
    defer @constCast(&result.history).deinit();

    std.debug.print("processMessage() completed successfully\n", .{});

    // Send response or error message
    if (result.response) |response| {
        std.debug.print("Sending response to Telegram...\n", .{});
        sendMessage(allocator, ctx.client, tg_config.botToken, chat_id_str, response) catch |err| {
            std.debug.print("Failed to send message: {any}\n", .{err});
        };
        std.debug.print("Response sent successfully\n", .{});
    } else if (result.error_msg) |error_msg| {
        std.debug.print("Sending error message to Telegram...\n", .{});
        sendMessage(allocator, ctx.client, tg_config.botToken, chat_id_str, error_msg) catch |err| {
            std.debug.print("Failed to send error message: {any}\n", .{err});
        };
        std.debug.print("Error message sent successfully\n", .{});
    }

    // Save session state to Vector/Graph DB for long-term memory.
    // This enables RAG (Retrieval-Augmented Generation) functionality.
    messages.indexConversation(@constCast(&result.history), session_id) catch |err| {
        std.debug.print("Failed to index conversation: {any}\n", .{err});
    };
}

/// Handle HTTP requests for Telegram API
fn handleHttpRequest(allocator: std.mem.Allocator, ctx: *TelegramContext, task: xev_event_loop.Task) !void {
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
fn handleGetRequest(allocator: std.mem.Allocator, ctx: *TelegramContext, url: []const u8) !void {
    std.debug.print("GET request URL: {s}\n", .{url});

    // Create a temporary HTTP client for this request
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var temp_client = try http.Client.initWithSettings(temp_allocator, .{
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
    }, temp_allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var temp_client = try http.Client.initWithSettings(temp_allocator, .{
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
fn globalTaskHandler(allocator: std.mem.Allocator, task: xev_event_loop.Task) !void {
    std.debug.print("globalXevTaskHandler: Received task from {s}, data: {s}\n", .{ task.source, task.data });
    const ctx = global_telegram_context orelse {
        std.debug.print("Error: Global telegram context not set\n", .{});
        return error.ContextNotSet;
    };

    // Handle HTTP requests
    if (std.mem.eql(u8, task.source, "telegram_http")) {
        // For HTTP requests, we need to process them but can't add tasks from here
        // since we're in a worker thread. Instead, we'll process directly.
        try handleHttpRequestDirect(allocator, ctx, task);
        return;
    }

    const tg_data = try parseTelegramTask(ctx.allocator, task);
    defer ctx.allocator.free(tg_data.text);

    std.debug.print("globalXevTaskHandler: Parsed task - chat_id: {d}, text: {s}\n", .{ tg_data.chat_id, tg_data.text });

    try handleTelegramTaskData(ctx, tg_data);
    std.debug.print("globalXevTaskHandler: Task processing completed\n", .{});
}

/// Handle HTTP requests for Telegram API (direct processing without adding tasks)
fn handleHttpRequestDirect(allocator: std.mem.Allocator, ctx: *TelegramContext, task: xev_event_loop.Task) !void {
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
        try handleGetRequestDirect(allocator, ctx, rest);
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
fn handleGetRequestDirect(allocator: std.mem.Allocator, ctx: *TelegramContext, url: []const u8) !void {
    std.debug.print("GET request URL: {s}\n", .{url});

    // Create a temporary HTTP client for this request
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var temp_client = try http.Client.initWithSettings(temp_allocator, .{
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
    }, temp_allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
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
                const tg_data: TelegramTaskData = .{
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
pub fn handleTelegramEvent(allocator: std.mem.Allocator, event: xev_event_loop.Event) !void {
    _ = allocator;
    if (event.payload) |payload| {
        std.debug.print("Processing Xev Telegram event: {s}\n", .{payload});
    }

    // Check if this is a session cache cleanup event
    if (std.mem.eql(u8, event.id, "session_cache_cleanup")) {
        if (global_telegram_context) |ctx| {
            if (ctx.session_cache) |*cache| {
                cache.cleanup();
                // Schedule next cleanup
                if (ctx.event_loop) |el| {
                    const cleanup_interval_ms = 30 * 60 * 1000; // 30 minutes
                    el.scheduleEvent("session_cache_cleanup", .custom, null, cleanup_interval_ms) catch |err| {
                        std.debug.print("Failed to schedule cleanup event: {any}\n", .{err});
                    };
                }
            }
        }
        return;
    }

    // Parse event data
    // TODO: Implement specific event handling based on event type
    // Examples:
    // - Scheduled messages
    // - Reminders
    // - Daily reports
    // - Bot maintenance tasks
}

/// Send message to Telegram
fn sendMessage(allocator: std.mem.Allocator, client: *const http.Client, bot_token: []const u8, chat_id: []const u8, text: []const u8) !void {
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
fn sendChatAction(allocator: std.mem.Allocator, client: *const http.Client, bot_token: []const u8, chat_id: []const u8, action: []const u8) !void {
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
pub fn createTelegramTaskHandler(ctx: *TelegramContext) xev_event_loop.TaskHandler {
    global_telegram_context = ctx;
    return globalTaskHandler;
}

/// Create an event handler wrapper that captures Telegram context
pub fn createTelegramEventHandler(ctx: *TelegramContext) xev_event_loop.EventHandler {
    _ = ctx;
    return struct {
        fn handler(allocator: std.mem.Allocator, event: xev_event_loop.Event) !void {
            try handleTelegramEvent(allocator, event);
        }
    }.handler;
}
