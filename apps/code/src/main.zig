const std = @import("std");
const builtin = @import("builtin");

const agent = @import("agent");

const config = @import("config.zig");

extern "c" var stdin: *anyopaque;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;

fn loadAgentConfig(allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    return "";
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Load SatiCode configuration
    const saticode_config = try config.load(arena_allocator);
    const agent_config = try config.toAgentConfig(arena_allocator, saticode_config.saticode);

    const args = try init.args.toSlice(arena_allocator);

    // Check for version flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            const build_info = "Zig " ++ builtin.zig_version_string;
            std.debug.print("SatiCode CLI {s}\n", .{build_info});
            return;
        }
    }

    // Override RAG setting from command line
    var rag_enabled = if (saticode_config.saticode.rag) |rag| rag.enabled else true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-rag")) {
            rag_enabled = false;
        }
    }

    const session_id = "saticode_session";
    var bot = try agent.Agent.init(arena_allocator, agent_config, session_id, rag_enabled);
    defer bot.deinit();

    // Load agent rules and skills from .agent/ and .agents/ directories
    const agent_rules = loadAgentConfig(arena_allocator) catch "";
    defer arena_allocator.free(agent_rules);

    // Custom system prompt for coding assistant
    var system_prompt_builder: std.ArrayList(u8) = .empty;
    defer system_prompt_builder.deinit(arena_allocator);

    // Use custom system prompt from config if provided, otherwise use default
    if (saticode_config.saticode.systemPrompt) |custom_prompt| {
        try system_prompt_builder.appendSlice(arena_allocator, custom_prompt);
    } else {
        try system_prompt_builder.appendSlice(arena_allocator,
            \\You are SatiCode, a highly capable AI software engineer CLI tool.
            \\Your goal is to help the user with coding tasks, debugging, and project management.
            \\You have access to the local filesystem and can execute shell commands.
            \\
            \\When you are asked to solve a problem:
            \\1. Explore the codebase using 'list_files' and 'read_file'.
            \\2. Plan your approach.
            \\3. Implement changes using 'write_file' or 'edit_file'.
            \\4. Verify your changes by running tests or build commands using 'run_command'.
            \\
            \\Be concise and efficient. Always explain your reasoning before taking actions.
            \\If you need to search the web, use 'web_fetch' (though it works for specific URLs).
        );
    }

    if (agent_rules.len > 0) {
        try system_prompt_builder.appendSlice(arena_allocator, "\n\n");
        try system_prompt_builder.appendSlice(arena_allocator, "=== AGENT RULES & SKILLS ===\n");
        try system_prompt_builder.appendSlice(arena_allocator, agent_rules);
    }

    const system_prompt = try system_prompt_builder.toOwnedSlice(arena_allocator);
    defer arena_allocator.free(system_prompt);

    // Check if we already have a system message, if not add ours
    var has_system = false;
    for (bot.ctx.getMessages()) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) {
            has_system = true;
            break;
        }
    }
    if (!has_system) {
        try bot.ctx.addMessage(.{ .role = "system", .content = system_prompt });
    }

    const model = saticode_config.saticode.model;

    // Build version info
    const build_info = "Zig " ++ builtin.zig_version_string;

    std.debug.print(
        \\🐵 SatiCode CLI (Claude-Code style)
        \\Model: {s}
        \\RAG: {s}
        \\Config: {s}
        \\Build: {s}
        \\Type your request (Ctrl+D or 'exit' to quit):
        \\
        \\
    , .{ model, if (rag_enabled) "Enabled" else "Disabled", saticode_config.path orelse "default", build_info });

    while (true) {
        std.debug.print("\nUser > ", .{});

        var read_buf: [4096:0]u8 = undefined;
        const ptr = fgets(&read_buf, @intCast(read_buf.len), stdin);
        if (ptr == null) break; // EOF
        var n: usize = 0;
        while (n < read_buf.len and read_buf[n] != 0) n += 1;

        const trimmed = std.mem.trim(u8, read_buf[0..n], " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

        std.debug.print("\n⚡ Working...\n", .{});

        bot.run(trimmed) catch |err| {
            std.debug.print("\n❌ Error: {any}\n", .{err});
            if (bot.last_error) |le| {
                std.debug.print("Details: {s}\n", .{le});
            }
            continue;
        };

        const messages = bot.ctx.getMessages();
        if (messages.len > 0) {
            const last_msg = messages[messages.len - 1];
            if (std.mem.eql(u8, last_msg.role, "assistant") and last_msg.content != null) {
                std.debug.print("\n🤖 Assistant:\n{s}\n", .{last_msg.content.?});
            }
        }
    }

    std.debug.print("\nGoodbye!\n", .{});
}
