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
    disableRag: bool = false,
    loadChatHistory: bool = false,
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
                \\  "agents": {
                \\    "defaults": {
                \\      "model": "arcee-ai/trinity-large-preview:free",
                \\      "embeddingModel": "local",
                \\      "loadChatHistory": false
                \\    }
                \\  },
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

    try std.testing.expectEqualStrings("arcee-ai/trinity-large-preview:free", parsed.value.agents.defaults.model);
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
        \\      "embeddingModel": "arcee-ai/trinity-mini:free"
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
    try std.testing.expectEqualStrings("arcee-ai/trinity-mini:free", parsed.value.agents.defaults.embeddingModel.?);

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

/// Save configuration to the default location (~/.bots/config.json).
/// Returns error.HomeNotFound if HOME environment variable is not set.
pub fn save(allocator: std.mem.Allocator, config: Config) !void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const path = try std.fs.path.join(allocator, &.{ home, ".bots", "config.json" });
    defer allocator.free(path);

    return saveToPath(allocator, config, path);
}

/// Save configuration to a specific file path.
/// Creates the directory if it doesn't exist.
pub fn saveToPath(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    // Create directory if it doesn't exist
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);

    // Serialize config to JSON
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, &out.writer);

    // Write to file
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.written());
}

test "Config: save and reload" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original_config: Config = .{
        .agents = .{
            .defaults = .{
                .model = "test-model-saved",
                .embeddingModel = "local",
                .disableRag = false,
                .loadChatHistory = true,
            },
        },
        .providers = .{
            .openrouter = .{ .apiKey = "or-key-saved" },
        },
        .tools = .{
            .web = .{ .search = .{ .apiKey = "search-key-saved" } },
        },
    };

    // Create config file first
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(path);

    // Save config
    try saveToPath(allocator, original_config, path);

    // Reload config
    const parsed = try loadFromPath(allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-model-saved", parsed.value.agents.defaults.model);
    try std.testing.expectEqualStrings("or-key-saved", parsed.value.providers.openrouter.?.apiKey);
    try std.testing.expectEqualStrings("search-key-saved", parsed.value.tools.web.search.apiKey.?);
}

test "Config: disableRag parsing" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": {
        \\    "defaults": {
        \\      "model": "test-model",
        \\      "disableRag": true
        \\    }
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.agents.defaults.disableRag == true);
}

test "Config: loadChatHistory parsing" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": {
        \\    "defaults": {
        \\      "model": "test-model",
        \\      "loadChatHistory": false
        \\    }
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.agents.defaults.loadChatHistory == false);
}

test "Config save and load roundtrip with openrouter model" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create config file first
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(path);

    const original_config: Config = .{
        .agents = .{
            .defaults = .{
                .model = "tngtech/deepseek-r1t2-chimera:free",
                .embeddingModel = "local",
                .disableRag = false,
                .loadChatHistory = true,
            },
        },
        .providers = .{
            .openrouter = .{ .apiKey = "test-key" },
        },
        .tools = .{
            .web = .{ .search = .{ .apiKey = "search-key" } },
            .telegram = .{ .botToken = "tg-token", .chatId = "12345" },
        },
    };

    // Save config
    try saveToPath(allocator, original_config, path);

    // Load and verify
    const loaded = try loadFromPath(allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("tngtech/deepseek-r1t2-chimera:free", loaded.value.agents.defaults.model);

    // Update model to z-ai/glm-4.5-air:free
    const updated_config: Config = .{
        .agents = .{
            .defaults = .{
                .model = "z-ai/glm-4.5-air:free",
                .embeddingModel = "local",
                .disableRag = false,
                .loadChatHistory = true,
            },
        },
        .providers = .{
            .openrouter = .{ .apiKey = "test-key" },
        },
        .tools = .{
            .web = .{ .search = .{ .apiKey = "search-key" } },
            .telegram = .{ .botToken = "tg-token", .chatId = "12345" },
        },
    };

    // Save updated config
    try saveToPath(allocator, updated_config, path);

    // Load again and verify update
    const reloaded = try loadFromPath(allocator, path);
    defer reloaded.deinit();

    try std.testing.expectEqualStrings("z-ai/glm-4.5-air:free", reloaded.value.agents.defaults.model);
}
