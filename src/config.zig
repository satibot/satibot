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

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Config file not found at {s}. Using defaults.\n", .{path});
            // Return default config (wrapped in Parsed for consistency, though kinda hacky to create a dummy arena)
            // Actually, easier to just error for now or fallback.
            // Let's fallback by parsing a default JSON string to get a proper Parsed(Config)
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

    return std.json.parseFromSlice(Config, allocator, content, .{ .ignore_unknown_fields = true });
}
