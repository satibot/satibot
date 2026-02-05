const std = @import("std");
const satibot = @import("satibot");
const build_options = @import("build_options");

pub fn main() !void {
    std.debug.print("--- satibot 🧞‍♂️ (build: {s}) ---\n", .{build_options.build_time_str});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try usage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "agent")) {
        try runAgent(allocator, args);
    } else if (std.mem.eql(u8, command, "onboard")) {
        std.debug.print("Onboarding not implemented yet.\n", .{});
    } else if (std.mem.eql(u8, command, "test-llm")) {
        try runTestLlm(allocator);
    } else if (std.mem.eql(u8, command, "telegram")) {
        try runTelegramBot(allocator, args);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try usage();
    }
}

fn usage() !void {
    std.debug.print("Usage: satibot <command> [args...]\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  agent -m \"msg\" [-s id] [--no-rag] [openrouter] Run the agent\n", .{});
    std.debug.print("  telegram [openrouter] Run satibot as a Telegram bot (validates key if specified)\n", .{});
    std.debug.print("  onboard              Initialize configuration\n", .{});
}

fn runAgent(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var message: []const u8 = "";
    var session_id: []const u8 = "default";
    var save_to_rag = true;
    var check_openrouter = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            message = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            session_id = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-rag")) {
            save_to_rag = false;
        } else if (std.mem.eql(u8, args[i], "--rag")) {
            save_to_rag = true;
        } else if (std.mem.eql(u8, args[i], "openrouter")) {
            check_openrouter = true;
        }
    }

    if (message.len == 0) {
        std.debug.print("Error: Message required (-m \"message\")\n", .{});
        return;
    }

    if (check_openrouter) {
        try validateConfig(config);
    }

    var agent = satibot.agent.Agent.init(allocator, config, session_id);
    defer agent.deinit();

    try agent.run(message);

    if (save_to_rag) {
        try agent.index_conversation();
    }
}

fn runTestLlm(allocator: std.mem.Allocator) !void {
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OpenRouter API key not configured. Set OPENROUTER_API_KEY env var or update config.json.\n", .{});
        return;
    };

    var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
    defer provider.deinit();

    const messages = &[_]satibot.providers.base.LLMMessage{
        .{ .role = "user", .content = "Say hello from Zig!" },
    };

    std.debug.print("Sending request to OpenRouter...\n", .{});
    var response = try provider.chat(messages, config.agents.defaults.model);
    defer response.deinit();

    std.debug.print("Response: {s}\n", .{response.content orelse "(no content)"});
}

fn runTelegramBot(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var check_openrouter = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "openrouter")) {
            check_openrouter = true;
            break;
        }
    }

    if (check_openrouter) {
        try validateConfig(config);
    }

    std.debug.print("Active Model: {s}\n", .{config.agents.defaults.model});
    std.debug.print("Telegram bot started. Press Ctrl+C to stop.\n", .{});

    try satibot.agent.telegram_bot.run(allocator, config);
}

fn validateConfig(config: satibot.config.Config) !void {
    const model = config.agents.defaults.model;
    if (std.mem.indexOf(u8, model, "claude") != null) {
        if (config.providers.anthropic == null and std.posix.getenv("ANTHROPIC_API_KEY") == null) {
            std.debug.print("\n❌ Error: Anthropic API key not found.\n", .{});
            std.debug.print("Please set ANTHROPIC_API_KEY environment variable or update config.json at ~/.bots/config.json\n\n", .{});
            std.process.exit(1);
        }
    } else {
        // Assume OpenRouter for other models
        if (config.providers.openrouter == null and std.posix.getenv("OPENROUTER_API_KEY") == null) {
            std.debug.print("\n❌ Error: OpenRouter API key not found.\n", .{});
            std.debug.print("Please set OPENROUTER_API_KEY environment variable or update config.json at ~/.bots/config.json\n\n", .{});
            std.process.exit(1);
        }
    }
}
