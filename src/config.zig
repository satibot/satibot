const std = @import("std");

/// Configuration module for SatiBot.
/// Handles loading and parsing of JSON configuration files containing
/// agent settings, provider API keys, and tool configurations.
/// Main configuration structure that holds all bot settings.
/// Loaded from ~/.bots/config.json by default.
pub const Config = struct {
    agents: AgentsConfig,
    providers: ProvidersConfig,
    tools: ToolsConfig,
};

/// Configuration for AI agent settings including default models.
pub const AgentsConfig = struct {
    defaults: DefaultAgentConfig,
};

/// Default configuration values for agent behavior.
/// embeddingModel is optional - falls back to default if not specified.
pub const DefaultAgentConfig = struct {
    model: []const u8,
    embeddingModel: ?[]const u8 = null,
};

/// Configuration for LLM provider API credentials.
/// All providers are optional - only configure what you need.
pub const ProvidersConfig = struct {
    openrouter: ?ProviderConfig = null,
    anthropic: ?ProviderConfig = null,
    openai: ?ProviderConfig = null,
    groq: ?ProviderConfig = null,
};

/// API configuration for a single LLM provider.
pub const ProviderConfig = struct {
    apiKey: []const u8,
    apiBase: ?[]const u8 = null,
};

/// Configuration for all available tools and integrations.
pub const ToolsConfig = struct {
    web: WebToolsConfig,
    telegram: ?TelegramConfig = null,
    discord: ?DiscordConfig = null,
    whatsapp: ?WhatsAppConfig = null,
};

/// Telegram bot configuration for messaging integration.
pub const TelegramConfig = struct {
    botToken: []const u8,
    chatId: ?[]const u8 = null,
};

/// Discord webhook configuration for channel notifications.
pub const DiscordConfig = struct {
    webhookUrl: []const u8,
};

/// WhatsApp Business API configuration for messaging.
pub const WhatsAppConfig = struct {
    accessToken: []const u8,
    phoneNumberId: []const u8,
    recipientPhoneNumber: ?[]const u8 = null,
};

/// Configuration for web-based tools like search.
pub const WebToolsConfig = struct {
    search: SearchToolConfig,
};

/// Search tool API configuration (e.g., Brave Search API key).
pub const SearchToolConfig = struct {
    apiKey: ?[]const u8 = null,
};

/// Load configuration from the default location (~/.bots/config.json).
/// Returns error.HomeNotFound if HOME environment variable is not set.
/// If config file doesn't exist, returns default configuration.
pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const path = try std.fs.path.join(allocator, &.{ home, ".bots", "config.json" });
    defer allocator.free(path);

    return loadFromPath(allocator, path);
}

/// Load configuration from a specific file path.
/// If file doesn't exist, returns built-in default configuration.
/// Allocates memory for parsing - caller must call deinit() on result.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const default_json =
                \\{
                \\  "agents": { "defaults": { "model": "anthropic/claude-opus-4-5" } },
                \\  "providers": {},
                \\  "tools": { "web": { "search": {} } }
                \\}
            ;
            return std.json.parseFromSlice(Config, allocator, default_json, .{ .ignore_unknown_fields = true });
        }
        return err;
    };
    defer file.close();

    // Read file content up to 1MB (1048576 = 1024 * 1024)
    const content = try file.readToEndAlloc(allocator, 1048576); // 1024 * 1024
    defer allocator.free(content);

    return std.json.parseFromSlice(Config, allocator, content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "Config: default loading" {
    const allocator = std.testing.allocator;
    const parsed = try loadFromPath(allocator, "/non/existent/path");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("anthropic/claude-opus-4-5", parsed.value.agents.defaults.model);
}

test "Config: loading from file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": { "anthropic": { "apiKey": "test-key" } },
        \\  "tools": {
        \\    "web": { "search": { "apiKey": "web-key" } },
        \\    "telegram": { "botToken": "tg-token" }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = config_json });

    const path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(path);

    const parsed = try loadFromPath(allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-model", parsed.value.agents.defaults.model);
    try std.testing.expectEqualStrings("test-key", parsed.value.providers.anthropic.?.apiKey);
    try std.testing.expectEqualStrings("tg-token", parsed.value.tools.telegram.?.botToken);
}

test "Config: full configuration with all providers" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": {
        \\    "defaults": {
        \\      "model": "anthropic/claude-3-sonnet",
        \\      "embeddingModel": "openai/text-embedding-3-small"
        \\    }
        \\  },
        \\  "providers": {
        \\    "openrouter": { "apiKey": "or-key", "apiBase": "https://api.openrouter.ai" },
        \\    "anthropic": { "apiKey": "ant-key" },
        \\    "openai": { "apiKey": "oa-key" },
        \\    "groq": { "apiKey": "gq-key" }
        \\  },
        \\  "tools": {
        \\    "web": { "search": { "apiKey": "search-key" } },
        \\    "telegram": { "botToken": "tg-token", "chatId": "12345" },
        \\    "discord": { "webhookUrl": "https://discord.com/api/webhooks/123" },
        \\    "whatsapp": {
        \\      "accessToken": "wa-token",
        \\      "phoneNumberId": "phone123",
        \\      "recipientPhoneNumber": "+1234567890"
        \\    }
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test agents config
    try std.testing.expectEqualStrings("anthropic/claude-3-sonnet", parsed.value.agents.defaults.model);
    try std.testing.expectEqualStrings("openai/text-embedding-3-small", parsed.value.agents.defaults.embeddingModel.?);

    // Test providers config
    try std.testing.expectEqualStrings("or-key", parsed.value.providers.openrouter.?.apiKey);
    try std.testing.expectEqualStrings("https://api.openrouter.ai", parsed.value.providers.openrouter.?.apiBase.?);
    try std.testing.expectEqualStrings("ant-key", parsed.value.providers.anthropic.?.apiKey);
    try std.testing.expectEqualStrings("oa-key", parsed.value.providers.openai.?.apiKey);
    try std.testing.expectEqualStrings("gq-key", parsed.value.providers.groq.?.apiKey);

    // Test tools config
    try std.testing.expectEqualStrings("search-key", parsed.value.tools.web.search.apiKey.?);
    try std.testing.expectEqualStrings("tg-token", parsed.value.tools.telegram.?.botToken);
    try std.testing.expectEqualStrings("12345", parsed.value.tools.telegram.?.chatId.?);
    try std.testing.expectEqualStrings("https://discord.com/api/webhooks/123", parsed.value.tools.discord.?.webhookUrl);
    try std.testing.expectEqualStrings("wa-token", parsed.value.tools.whatsapp.?.accessToken);
    try std.testing.expectEqualStrings("phone123", parsed.value.tools.whatsapp.?.phoneNumberId);
    try std.testing.expectEqualStrings("+1234567890", parsed.value.tools.whatsapp.?.recipientPhoneNumber.?);
}

test "Config: invalid JSON handling" {
    const allocator = std.testing.allocator;
    const invalid_json = "{ invalid json }";

    const parsed = std.json.parseFromSlice(Config, allocator, invalid_json, .{ .ignore_unknown_fields = true });
    // Accept any JSON parsing error
    const is_error = parsed == error.UnexpectedToken or
        parsed == error.InvalidCharacter or
        parsed == error.SyntaxError or
        parsed == error.UnexpectedEndOfInput;
    try std.testing.expect(is_error);
}

test "Config: minimal configuration" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-model", parsed.value.agents.defaults.model);
    try std.testing.expect(parsed.value.providers.openrouter == null);
    try std.testing.expect(parsed.value.providers.anthropic == null);
    try std.testing.expect(parsed.value.tools.telegram == null);
}
