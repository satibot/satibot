const std = @import("std");

pub const Config = struct {
    agents: AgentsConfig,
    providers: ProvidersConfig,
    tools: ToolsConfig,
};

pub const AgentsConfig = struct {
    defaults: DefaultAgentConfig,
};

pub const DefaultAgentConfig = struct {
    model: []const u8,
    embeddingModel: ?[]const u8 = null,
};

pub const ProvidersConfig = struct {
    openrouter: ?ProviderConfig = null,
    anthropic: ?ProviderConfig = null,
    openai: ?ProviderConfig = null,
    groq: ?ProviderConfig = null,
};

pub const ProviderConfig = struct {
    apiKey: []const u8,
    apiBase: ?[]const u8 = null,
};

pub const ToolsConfig = struct {
    web: WebToolsConfig,
    telegram: ?TelegramConfig = null,
    discord: ?DiscordConfig = null,
    whatsapp: ?WhatsAppConfig = null,
};

pub const TelegramConfig = struct {
    botToken: []const u8,
    chatId: ?[]const u8 = null,
};

pub const DiscordConfig = struct {
    webhookUrl: []const u8,
};

pub const WhatsAppConfig = struct {
    accessToken: []const u8,
    phoneNumberId: []const u8,
    recipientPhoneNumber: ?[]const u8 = null,
};

pub const WebToolsConfig = struct {
    search: SearchToolConfig,
};

pub const SearchToolConfig = struct {
    apiKey: ?[]const u8 = null,
};

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const path = try std.fs.path.join(allocator, &.{ home, ".bots", "config.json" });
    defer allocator.free(path);

    return loadFromPath(allocator, path);
}

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

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
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
