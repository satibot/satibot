const std = @import("std");

/// Configuration data - immutable after creation
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

/// Telegram update structure (pure data)
const TelegramUpdate = struct {
    update_id: i64,
    message: ?TelegramMessage,
};

/// Telegram message structure (pure data)
const TelegramMessage = struct {
    chat_id: i64,
    text: ?[]const u8,
    has_voice: bool,
};

/// Result of processing a message (pure data)
const ProcessResult = struct {
    response_text: []const u8,
    should_continue: bool, // false if /new command without message
};

/// Bot state - minimal mutable state, separated from logic
const BotState = struct {
    offset: i64,
    last_chat_id: ?i64,
};

/// Save last_chat_id to file for persistence across restarts
fn saveLastChatId(chat_id: i64) void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const file_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt" }) catch return;
    defer std.heap.page_allocator.free(file_path);

    // Ensure directory exists
    const bots_dir = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots" }) catch return;
    defer std.heap.page_allocator.free(bots_dir);
    std.fs.makeDirAbsolute(bots_dir) catch {};

    // Write chat_id to file
    const file = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch |err| {
        std.debug.print("Warning: Failed to create last_chat_id file: {any}\n", .{err});
        return;
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const chat_id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
    file.writeAll(chat_id_str) catch |err| {
        std.debug.print("Warning: Failed to write last_chat_id: {any}\n", .{err});
    };
}

/// Read last_chat_id from file
fn readLastChatId() ?i64 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const file_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt" }) catch return null;
    defer std.heap.page_allocator.free(file_path);

    const file = std.fs.openFileAbsolute(file_path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;

    return std.fmt.parseInt(i64, buf[0..n], 10) catch null;
}

// =============================================================================
// Pure Functions (Logic Layer)
// =============================================================================

/// Parse update from JSON value - pure function
fn parseUpdate(value: std.json.Value) ?TelegramUpdate {
    const update_id = value.object.get("update_id") orelse return null;
    if (update_id.integer == null) return null;

    var message: ?TelegramMessage = null;
    if (value.object.get("message")) |msg| {
        if (msg.object.get("chat")) |chat| {
            const chat_id = chat.object.get("id") orelse return null;
            const text = msg.object.get("text");
            const has_voice = msg.object.get("voice") != null;

            message = TelegramMessage{
                .chat_id = chat_id.integer,
                .text = if (text) |t| t.string else null,
                .has_voice = has_voice,
            };
        }
    }

    return TelegramUpdate{
        .update_id = update_id.integer,
        .message = message,
    };
}

/// Extract all valid updates from parsed JSON array - pure function
fn extractUpdates(allocator: std.mem.Allocator, result_array: []std.json.Value) ![]TelegramUpdate {
    var updates = std.ArrayList(TelegramUpdate).init(allocator);
    errdefer updates.deinit();

    for (result_array) |item| {
        if (parseUpdate(item)) |update| {
            try updates.append(update);
        }
    }

    return updates.toOwnedSlice();
}

/// Find the maximum update ID from a list of updates - pure function
fn findMaxUpdateId(updates: []const TelegramUpdate) i64 {
    var max_id: i64 = 0;
    for (updates) |update| {
        if (update.update_id > max_id) {
            max_id = update.update_id;
        }
    }
    return max_id;
}

/// Process user message text - pure function
/// Returns the response text and whether processing should continue
fn processMessageText(allocator: std.mem.Allocator, text: []const u8) !ProcessResult {
    // Handle /new command
    if (std.mem.startsWith(u8, text, "/new")) {
        if (text.len <= 4) {
            return ProcessResult{
                .response_text = try allocator.dupe(u8, "🆕 Session cleared! Send me a new message."),
                .should_continue = false,
            };
        }
        // Process the text after /new
        const actual_text = std.mem.trimLeft(u8, text[4..], " ");
        return ProcessResult{
            .response_text = try allocator.dupe(u8, actual_text),
            .should_continue = true,
        };
    }

    // Default: echo the message (in real implementation, this would call LLM)
    const response = try std.fmt.allocPrint(allocator, "Hello from sync bot! I received: {s}", .{text});
    return ProcessResult{
        .response_text = response,
        .should_continue = true,
    };
}

/// Generate voice message response - pure function
fn getVoiceMessageResponse(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "🎤 Voice messages are not supported in the sync version. Please use text messages or the async version with voice transcription enabled.");
}

/// Build Telegram API URL for getUpdates - pure function
fn buildGetUpdatesUrl(allocator: std.mem.Allocator, bot_token: []const u8, offset: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=5", .{ bot_token, offset });
}

/// Build Telegram API URL for sendMessage - pure function
fn buildSendMessageUrl(allocator: std.mem.Allocator, bot_token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
}

/// Build JSON body for sendMessage - pure function
fn buildSendMessageBody(allocator: std.mem.Allocator, chat_id: i64, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"chat_id\":{d},\"text\":\"{s}\"}}", .{ chat_id, text });
}

// =============================================================================
// I/O Layer (Functions)
// =============================================================================

/// Simple HTTP client for standalone version
const SimpleHttpClient = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) SimpleHttpClient {
        return .{ .allocator = allocator };
    }

    fn deinit(self: SimpleHttpClient) void {
        _ = self;
    }

    /// Perform GET request
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

    /// Perform POST request
    fn post(self: SimpleHttpClient, url: []const u8, body: []const u8) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("Content-Type", "application/json");

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .headers = headers,
            .body = .{ .json = body },
        });
        defer response.deinit();

        _ = response.status;
    }
};

const Response = struct {
    body: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

// =============================================================================
// Bot Operations
// =============================================================================

/// Send a message to Telegram
fn sendMessage(allocator: std.mem.Allocator, client: SimpleHttpClient, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    const url = try buildSendMessageUrl(allocator, bot_token);
    defer allocator.free(url);

    const body = try buildSendMessageBody(allocator, chat_id, text);
    defer allocator.free(body);

    try client.post(url, body);
}

/// Send shutdown message to Telegram
fn sendShutdownMessage(allocator: std.mem.Allocator, client: SimpleHttpClient, bot_token: []const u8, chat_id: i64) void {
    const url = buildSendMessageUrl(allocator, bot_token) catch return;
    defer allocator.free(url);

    const body = buildSendMessageBody(allocator, chat_id, "🛑 Bot is shutting down. Goodbye!") catch return;
    defer allocator.free(body);

    client.post(url, body) catch |err| {
        std.debug.print("Warning: Failed to send shutdown message: {any}\n", .{err});
    };

    // Small delay to ensure message is sent
    std.Thread.sleep(std.time.ns_per_ms * 500);
}

/// Process a single update
fn processUpdate(
    allocator: std.mem.Allocator,
    client: SimpleHttpClient,
    bot_token: []const u8,
    update: TelegramUpdate,
) !?i64 {
    const msg = update.message orelse return null;
    const chat_id = msg.chat_id;

    // Handle voice messages
    if (msg.has_voice) {
        const voice_response = try getVoiceMessageResponse(allocator);
        defer allocator.free(voice_response);
        try sendMessage(allocator, client, bot_token, chat_id, voice_response);
        return chat_id;
    }

    // Process text messages
    const text = msg.text orelse return chat_id;
    if (text.len == 0) return chat_id;

    const result = try processMessageText(allocator, text);
    defer allocator.free(result.response_text);

    if (!result.should_continue) {
        try sendMessage(allocator, client, bot_token, chat_id, result.response_text);
        return chat_id;
    }

    // For actual messages (not just /new), echo the response
    try sendMessage(allocator, client, bot_token, chat_id, result.response_text);

    return chat_id;
}

/// Fetch and process updates
fn fetchAndProcessUpdates(
    allocator: std.mem.Allocator,
    client: SimpleHttpClient,
    config: Config,
    state: BotState,
) !BotState {
    const tg_config = config.tools.telegram orelse return state;

    const url = try buildGetUpdatesUrl(allocator, tg_config.botToken, state.offset);
    defer allocator.free(url);

    const response = try client.get(url);
    defer response.deinit();

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Check if response is OK
    const ok = parsed.value.object.get("ok") orelse return state;
    if (!ok.bool) return state;

    const result = parsed.value.object.get("result") orelse return state;
    const updates_array = extractUpdates(allocator, result.array) catch return state;
    defer allocator.free(updates_array);

    if (updates_array.len == 0) return state;

    // Process each update and track last chat
    var new_state = state;
    for (updates_array) |update| {
        new_state.offset = update.update_id + 1;

        if (try processUpdate(allocator, client, tg_config.botToken, update)) |chat_id| {
            new_state.last_chat_id = chat_id;
            saveLastChatId(chat_id); // Persist to file
        }
    }

    return new_state;
}

// =============================================================================
// Signal Handling (Global State - Unavoidable for Signal Handlers)
// =============================================================================

var shutdown_requested = std.atomic.Value(bool).init(false);

fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

// =============================================================================
// Main Entry Point
// =============================================================================

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    const client = SimpleHttpClient.init(allocator);
    defer client.deinit();

    var state = BotState{ .offset = 0, .last_chat_id = null };

    // Try to restore last_chat_id from file
    if (readLastChatId()) |saved_chat_id| {
        state.last_chat_id = saved_chat_id;
        std.debug.print("Restored last chat ID: {d}\n", .{saved_chat_id});
    }

    // Setup signal handlers
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    std.debug.print("🐸 Synchronous Telegram Bot\nModel: {s}\nPress Ctrl+C to stop.\n\n", .{config.agents.defaults.model});

    while (!shutdown_requested.load(.seq_cst)) {
        state = fetchAndProcessUpdates(allocator, client, config, state) catch |err| {
            std.debug.print("Error in Telegram bot tick: {any}\nRetrying in 5 seconds...\n", .{err});
            std.Thread.sleep(std.time.ns_per_s * 5);
            continue;
        };
    }

    // Send shutdown message
    if (state.last_chat_id) |chat_id| {
        if (config.tools.telegram) |tg_config| {
            std.debug.print("Sending shutdown message to chat {d}...\n", .{chat_id});
            sendShutdownMessage(allocator, client, tg_config.botToken, chat_id);
        }
    }

    std.debug.print("Bot shut down successfully.\n", .{});
}

// =============================================================================
// Unit Tests
// =============================================================================

test "parseUpdate with valid message" {
    const allocator = std.testing.allocator;

    // Build test JSON
    const json_str =
        \\{"update_id":12345,"message":{"chat":{"id":67890},"text":"Hello"}}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const update = parseUpdate(parsed.value);
    try std.testing.expect(update != null);
    try std.testing.expectEqual(@as(i64, 12345), update.?.update_id);
    try std.testing.expect(update.?.message != null);
    try std.testing.expectEqual(@as(i64, 67890), update.?.message.?.chat_id);
    try std.testing.expectEqualStrings("Hello", update.?.message.?.text.?);
    try std.testing.expect(!update.?.message.?.has_voice);
}

test "parseUpdate with voice message" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"update_id":12346,"message":{"chat":{"id":67891},"voice":{"file_id":"voice123"}}}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const update = parseUpdate(parsed.value);
    try std.testing.expect(update != null);
    try std.testing.expect(update.?.message != null);
    try std.testing.expect(update.?.message.?.has_voice);
    try std.testing.expect(update.?.message.?.text == null);
}

test "parseUpdate with invalid data" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"invalid":"data"}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const update = parseUpdate(parsed.value);
    try std.testing.expect(update == null);
}

test "findMaxUpdateId with multiple updates" {
    const updates = &[_]TelegramUpdate{
        .{ .update_id = 100, .message = null },
        .{ .update_id = 200, .message = null },
        .{ .update_id = 50, .message = null },
    };

    const max_id = findMaxUpdateId(updates);
    try std.testing.expectEqual(@as(i64, 200), max_id);
}

test "findMaxUpdateId with empty array" {
    const updates: []const TelegramUpdate = &.{};
    const max_id = findMaxUpdateId(updates);
    try std.testing.expectEqual(@as(i64, 0), max_id);
}

test "processMessageText with normal message" {
    const allocator = std.testing.allocator;

    const result = try processMessageText(allocator, "Hello world");
    defer allocator.free(result.response_text);

    try std.testing.expect(result.should_continue);
    try std.testing.expect(std.mem.indexOf(u8, result.response_text, "Hello world") != null);
}

test "processMessageText with /new command (no message)" {
    const allocator = std.testing.allocator;

    const result = try processMessageText(allocator, "/new");
    defer allocator.free(result.response_text);

    try std.testing.expect(!result.should_continue);
    try std.testing.expect(std.mem.indexOf(u8, result.response_text, "Session cleared") != null);
}

test "processMessageText with /new command (with message)" {
    const allocator = std.testing.allocator;

    const result = try processMessageText(allocator, "/new Hello after clear");
    defer allocator.free(result.response_text);

    try std.testing.expect(result.should_continue);
    try std.testing.expectEqualStrings("Hello after clear", result.response_text);
}

test "buildGetUpdatesUrl" {
    const allocator = std.testing.allocator;

    const url = try buildGetUpdatesUrl(allocator, "test_token", 42);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.telegram.org/bottest_token/getUpdates?offset=42&timeout=5", url);
}

test "buildSendMessageUrl" {
    const allocator = std.testing.allocator;

    const url = try buildSendMessageUrl(allocator, "test_token");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.telegram.org/bottest_token/sendMessage", url);
}

test "buildSendMessageBody" {
    const allocator = std.testing.allocator;

    const body = try buildSendMessageBody(allocator, 12345, "Hello");
    defer allocator.free(body);

    try std.testing.expectEqualStrings("{\"chat_id\":12345,\"text\":\"Hello\"}", body);
}

test "extractUpdates with valid and invalid updates" {
    const allocator = std.testing.allocator;

    var valid_update = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try valid_update.object.put("update_id", std.json.Value{ .integer = 100 });

    var invalid_update = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    try invalid_update.object.put("other_field", std.json.Value{ .string = "value" });

    const input = &[_]std.json.Value{ valid_update, invalid_update };

    const updates = try extractUpdates(allocator, input);
    defer allocator.free(updates);

    try std.testing.expectEqual(@as(usize, 1), updates.len);
    try std.testing.expectEqual(@as(i64, 100), updates[0].update_id);
}
