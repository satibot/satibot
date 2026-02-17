/// Standalone OpenCode Agent for Telegram
/// This module provides a complete, self-contained OpenCode agent specifically designed for Telegram integration.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const http = @import("../../http.zig");
const opencode_control = @import("../opencode_control.zig");

/// Telegram-specific OpenCode agent
pub const TelegramOpenCodeAgent = struct {
    allocator: std.mem.Allocator,
    config: Config,
    client: *const http.Client,

    pub fn init(allocator: std.mem.Allocator, config: Config, client: *const http.Client) TelegramOpenCodeAgent {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
        };
    }

    /// Validate OpenCode prompt - rejects special characters that could be dangerous
    /// Returns error.InvalidPrompt if the prompt contains special characters
    pub fn validateOpenCodePrompt(prompt: []const u8) !void {
        for (prompt) |byte| {
            switch (byte) {
                // Shell operators and dangerous characters
                '|',
                '&',
                ';',
                '$',
                '`',
                '\\',
                '"',
                '\'',
                '<',
                '>',
                '(',
                ')',
                '{',
                '}',
                '[',
                ']',
                '*',
                '~',
                '#',
                // Control characters
                '\n',
                '\r',
                '\t',
                '\x00',
                => {
                    return error.InvalidPrompt;
                },
                else => {},
            }
        }
    }

    /// Send message to OpenCode and return the result
    pub fn sendOpenCodeMessage(self: *TelegramOpenCodeAgent, message: []const u8) ![]const u8 {
        // Validate prompt - reject special characters
        try validateOpenCodePrompt(message);
        
        if (!opencode_control.OpenCodeControl.isAvailable()) {
            return error.OpenCodeNotAvailable;
        }
        
        var opencode = opencode_control.OpenCodeControl.init(self.allocator);
        return opencode.sendMessage(message);
    }

    /// Handle /opencode command for Telegram
    pub fn handleOpencodeCommand(self: *TelegramOpenCodeAgent, chat_id: i64, message_text: []const u8) ![]const u8 {
        const opencode_msg = std.mem.trim(u8, message_text, " \t\r\n");

        if (opencode_msg.len == 0) {
            return try std.fmt.allocPrint(self.allocator, "❌ Usage: `/opencode <message>`\nExample: `/opencode list files in current dir`", .{});
        }

        const result = self.sendOpenCodeMessage(opencode_msg) catch |err| {
            return switch (err) {
                error.InvalidPrompt => try std.fmt.allocPrint(self.allocator, "❌ Invalid prompt: Special characters are not allowed.\n\nAllowed: letters, numbers, spaces, and basic punctuation (.,:-_)", .{}),
                error.OpenCodeNotAvailable => try std.fmt.allocPrint(self.allocator, "❌ OpenCode is not available. Please install it first.", .{}),
                else => try std.fmt.allocPrint(self.allocator, "❌ OpenCode error: {any}", .{err}),
            };
        };

        return result;
    }

    /// Handle /opencodeconf command for Telegram
    pub fn handleOpencodeConfCommand(self: *TelegramOpenCodeAgent) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "ℹ️ OpenCode configuration is handled by the OpenCode agent module.\nUse /opencode command to interact with OpenCode.", .{});
    }

    /// Send message to Telegram chat
    pub fn sendTelegramMessage(self: *TelegramOpenCodeAgent, chat_id: i64, message: []const u8) !void {
        const tg_config = self.config.tools.telegram orelse return;
        const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chat_id});
        defer self.allocator.free(chat_id_str);

        sendMessage(self.allocator, self.client, tg_config.botToken, chat_id_str, message) catch |err| {
            std.debug.print("Failed to send message: {any}\n", .{err});
        };
    }

    /// Process OpenCode command and send response to Telegram
    pub fn processOpencodeCommand(self: *TelegramOpenCodeAgent, chat_id: i64, message_text: []const u8) !void {
        const response = try self.handleOpencodeCommand(chat_id, message_text);
        defer self.allocator.free(response);
        try self.sendTelegramMessage(chat_id, response);
    }

    /// Process OpenCode configuration command and send response to Telegram
    pub fn processOpencodeConfCommand(self: *TelegramOpenCodeAgent, chat_id: i64) !void {
        const response = try self.handleOpencodeConfCommand();
        defer self.allocator.free(response);
        try self.sendTelegramMessage(chat_id, response);
    }
};

/// Send message to Telegram (utility function)
fn sendMessage(allocator: std.mem.Allocator, client: *const http.Client, bot_token: []const u8, chat_id: []const u8, text: []const u8) !void {
    // Telegram rejects text payloads longer than 4096 UTF-8 characters,
    // so we split on UTF-8 codepoint boundaries and send sequential chunks.
    if (text.len == 0) {
        try sendMessageChunk(allocator, client, bot_token, chat_id, text);
        return;
    }

    var start: usize = 0;
    while (start < text.len) {
        const end = nextTelegramChunkEnd(text, start);
        try sendMessageChunk(allocator, client, bot_token, chat_id, text[start..end]);
        start = end;
    }
}

fn sendMessageChunk(allocator: std.mem.Allocator, client: *const http.Client, bot_token: []const u8, chat_id: []const u8, text_chunk: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .chat_id = chat_id,
        .text = text_chunk,
        .parse_mode = "Markdown",
    }, .{});
    defer allocator.free(body);

    const response = try @constCast(client).post(url, &.{}, body);
    defer @constCast(&response).deinit();
}

fn nextTelegramChunkEnd(text: []const u8, start: usize) usize {
    const max_len = 4096;
    const end = @min(start + max_len, text.len);
    
    // If we're at the end, return it
    if (end == text.len) return end;
    
    // Try to find a good breaking point (space, newline, punctuation)
    var i = end;
    while (i > start) {
        i -= 1;
        switch (text[i]) {
            ' ', '\n', '.', '!', '?', ',', ';', ':' => return i + 1,
            else => continue,
        }
    }
    
    // If no good breaking point, just split at max length
    return end;
}

// Tests
test "TelegramOpenCodeAgent.validateOpenCodePrompt: accepts valid prompts" {
    const agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    try agent.validateOpenCodePrompt("hello world");
    try agent.validateOpenCodePrompt("list files in current directory");
    try agent.validateOpenCodePrompt("write a hello world program in python");
    try agent.validateOpenCodePrompt("Hello, world! How are you?");
    try agent.validateOpenCodePrompt("test-123_test");
    try agent.validateOpenCodePrompt("simple command");
    try agent.validateOpenCodePrompt("Code: foo-bar_baz");
    try agent.validateOpenCodePrompt("");
}

test "TelegramOpenCodeAgent.validateOpenCodePrompt: rejects shell special characters" {
    const agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("ls | grep foo"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("foo & bar"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("cmd; ls"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("echo $PATH"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("`ls`"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test\\n"));
}

test "TelegramOpenCodeAgent.validateOpenCodePrompt: rejects quotes and brackets" {
    const agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("echo \"hello\""));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("echo 'test'"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test < file"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test > output"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("foo(bar)"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("foo[0]"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("foo{bar}"));
}

test "TelegramOpenCodeAgent.validateOpenCodePrompt: rejects wildcards and operators" {
    const agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("ls *"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test~foo"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("# comment"));
}

test "TelegramOpenCodeAgent.validateOpenCodePrompt: rejects control characters" {
    const agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test\n"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test\r"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test\t"));
    try std.testing.expectError(error.InvalidPrompt, agent.validateOpenCodePrompt("test\x00"));
}

test "TelegramOpenCodeAgent.handleOpencodeCommand: empty message" {
    var agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    const result = try agent.handleOpencodeCommand(12345, "");
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "Usage:") != null);
}

test "TelegramOpenCodeAgent.handleOpencodeConfCommand" {
    var agent = TelegramOpenCodeAgent{
        .allocator = std.testing.allocator,
        .config = undefined,
        .client = undefined,
    };
    
    const result = try agent.handleOpencodeConfCommand();
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "OpenCode configuration") != null);
}
