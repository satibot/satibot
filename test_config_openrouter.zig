const std = @import("std");
const config = @import("src/config.zig");

const allocator = std.testing.allocator;

test "Config save and load roundtrip with openrouter model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create config file first
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(path);

    const original_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "tngtech/deepseek-r1t2-chimera:free",
                .embeddingModel = "local",
                .disableRag = false,
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
    try config.saveToPath(allocator, original_config, path);

    // Load and verify
    const loaded = try config.loadFromPath(allocator, path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("tngtech/deepseek-r1t2-chimera:free", loaded.value.agents.defaults.model);

    // Update model to z-ai/glm-4.5-air:free
    const updated_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "z-ai/glm-4.5-air:free",
                .embeddingModel = "local",
                .disableRag = false,
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
    try config.saveToPath(allocator, updated_config, path);

    // Load again and verify update
    const reloaded = try config.loadFromPath(allocator, path);
    defer reloaded.deinit();

    try std.testing.expectEqualStrings("z-ai/glm-4.5-air:free", reloaded.value.agents.defaults.model);
}
