const std = @import("std");
const minbot = @import("minbot");

pub fn main() !void {
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
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try usage();
    }
}

fn usage() !void {
    std.debug.print("Usage: minbot <command> [args...]\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  agent -m \"msg\" [-s id] [--no-rag] Run the agent (RAG enabled by default)\n", .{});
    std.debug.print("  onboard              Initialize configuration\n", .{});
}

fn runAgent(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const parsed_config = try minbot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var message: []const u8 = "";
    var session_id: []const u8 = "default";
    var save_to_rag = true;
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
        }
    }

    if (message.len == 0) {
        std.debug.print("Error: Message required (-m \"message\")\n", .{});
        return;
    }

    var agent = minbot.agent.Agent.init(allocator, config, session_id);
    defer agent.deinit();

    try agent.run(message);

    if (save_to_rag) {
        try agent.index_conversation();
    }
}

fn runTestLlm(allocator: std.mem.Allocator) !void {
    const parsed_config = try minbot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OpenRouter API key not configured. Set OPENROUTER_API_KEY env var or update config.json.\n", .{});
        return;
    };

    var provider = minbot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
    defer provider.deinit();

    const messages = &[_]minbot.providers.base.LLMMessage{
        .{ .role = "user", .content = "Say hello from Zig!" },
    };

    std.debug.print("Sending request to OpenRouter...\n", .{});
    var response = try provider.chat(messages, config.agents.defaults.model);
    defer response.deinit();

    std.debug.print("Response: {s}\n", .{response.content orelse "(no content)"});
}
