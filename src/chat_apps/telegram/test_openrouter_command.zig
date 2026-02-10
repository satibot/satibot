const std = @import("std");
const config = @import("../../config.zig");
const telegram_handlers = @import("telegram_handlers.zig");
const http = @import("../../http.zig");

const allocator = std.testing.allocator;

test "handleOpenrouterCommand: valid model update" {
    // Create a temporary config directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create initial config
    const initial_config =
        \\{
        \\  "agents": {
        \\    "defaults": {
        \\      "model": "old-model"
        \\    }
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = initial_config });

    // Get the absolute path
    const config_path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(config_path);

    // Create a mock HTTP client
    var client = try http.Client.init(allocator);
    defer client.deinit();

    // Create Telegram context with mock config
    const mock_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "old-model",
                .embeddingModel = null,
                .disableRag = false,
            },
        },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{
                .botToken = "test-token",
                .chatId = null,
            },
        },
    };

    var ctx = telegram_handlers.TelegramContext.init(allocator, mock_config, &client);
    defer ctx.deinit();

    // Mock HOME environment variable to point to our temp directory
    const original_home = std.posix.getenv("HOME");
    defer if (original_home) |home| {
        _ = std.posix.setenv("HOME", home) catch {};
    } else {
        _ = std.posix.unsetenv("HOME") catch {};
    };
    const temp_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_home);
    try std.posix.setenv("HOME", temp_home);

    // Create test data
    const tg_data = telegram_handlers.TelegramTaskData{
        .chat_id = 12345,
        .message_id = 67890,
        .text = "/openrouter z-ai/glm-4.5-air:free",
        .voice_duration = null,
        .update_id = 0,
    };

    // Execute the command
    try telegram_handlers.handleOpenrouterCommand(&ctx, tg_data);

    // Verify the config was updated
    const updated_config = try config.loadFromPath(allocator, config_path);
    defer updated_config.deinit();

    try std.testing.expectEqualStrings("z-ai/glm-4.5-air:free", updated_config.value.agents.defaults.model);
}

test "handleOpenrouterCommand: empty model name" {
    var client = try http.Client.init(allocator);
    defer client.deinit();

    const mock_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "old-model",
                .embeddingModel = null,
                .disableRag = false,
            },
        },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{
                .botToken = "test-token",
                .chatId = null,
            },
        },
    };

    var ctx = telegram_handlers.TelegramContext.init(allocator, mock_config, &client);
    defer ctx.deinit();

    const tg_data = telegram_handlers.TelegramTaskData{
        .chat_id = 12345,
        .message_id = 67890,
        .text = "/openrouter ",
        .voice_duration = null,
        .update_id = 0,
    };

    // This should not panic and should handle gracefully
    try telegram_handlers.handleOpenrouterCommand(&ctx, tg_data);
}

test "handleOpenrouterCommand: no config file" {
    var client = try http.Client.init(allocator);
    defer client.deinit();

    const mock_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "old-model",
                .embeddingModel = null,
                .disableRag = false,
            },
        },
        .providers = .{},
        .tools = .{
            .web = .{ .search = .{} },
            .telegram = .{
                .botToken = "test-token",
                .chatId = null,
            },
        },
    };

    var ctx = telegram_handlers.TelegramContext.init(allocator, mock_config, &client);
    defer ctx.deinit();

    // Mock HOME to a non-existent directory
    const original_home = std.posix.getenv("HOME");
    defer if (original_home) |home| {
        _ = std.posix.setenv("HOME", home) catch {};
    } else {
        _ = std.posix.unsetenv("HOME") catch {};
    };
    try std.posix.setenv("HOME", "/non/existent/path");

    const tg_data = telegram_handlers.TelegramTaskData{
        .chat_id = 12345,
        .message_id = 67890,
        .text = "/openrouter z-ai/glm-4.5-air:free",
        .voice_duration = null,
        .update_id = 0,
    };

    // This should create a new config file
    try telegram_handlers.handleOpenrouterCommand(&ctx, tg_data);
}

test "Config save and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create config file first
    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = "{}" });
    const path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(path);

    const original_config = config.Config{
        .agents = .{
            .defaults = .{
                .model = "test-model-roundtrip",
                .embeddingModel = "local",
                .disableRag = true,
            },
        },
        .providers = .{
            .openrouter = .{ .apiKey = "test-key" },
            .anthropic = .{ .apiKey = "another-key", .apiBase = "https://api.anthropic.com" },
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

    try std.testing.expectEqualStrings("test-model-roundtrip", loaded.value.agents.defaults.model);
    try std.testing.expectEqualStrings("local", loaded.value.agents.defaults.embeddingModel.?);
    try std.testing.expect(loaded.value.agents.defaults.disableRag == true);

    try std.testing.expectEqualStrings("test-key", loaded.value.providers.openrouter.?.apiKey);
    try std.testing.expectEqualStrings("another-key", loaded.value.providers.anthropic.?.apiKey);
    try std.testing.expectEqualStrings("https://api.anthropic.com", loaded.value.providers.anthropic.?.apiBase.?);

    try std.testing.expectEqualStrings("search-key", loaded.value.tools.web.search.apiKey.?);
    try std.testing.expectEqualStrings("tg-token", loaded.value.tools.telegram.?.botToken);
    try std.testing.expectEqualStrings("12345", loaded.value.tools.telegram.?.chatId.?);
}
