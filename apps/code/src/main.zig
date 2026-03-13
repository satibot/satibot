const std = @import("std");
const agent = @import("agent");

fn loadAgentConfig(allocator: std.mem.Allocator) ![]const u8 {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(allocator);

    const agent_paths = [_][]const u8{ ".agent", ".agents" };

    for (agent_paths) |agent_path| {
        var rules_dir = std.fs.cwd().openDir(agent_path, .{ .iterate = true }) catch continue;
        defer rules_dir.close();

        var rules_subdir = rules_dir.openDir("rules", .{}) catch continue;
        defer rules_subdir.close();

        var iter = rules_subdir.iterate();
        while (iter.next() catch continue) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md") and !std.mem.endsWith(u8, entry.name, ".zig.md")) continue;

            const file_path = try std.fs.path.join(allocator, &.{ "rules", entry.name });
            defer allocator.free(file_path);

            const file = rules_subdir.openFile(file_path, .{}) catch continue;
            defer file.close();

            const file_content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
            defer allocator.free(file_content);

            try content.appendSlice(allocator, "\n\n=== ");
            try content.appendSlice(allocator, entry.name);
            try content.appendSlice(allocator, " ===\n\n");
            try content.appendSlice(allocator, file_content);
        }

        var skills_subdir = rules_dir.openDir("skills", .{}) catch continue;
        defer skills_subdir.close();

        var skills_iter = skills_subdir.iterate();
        while (skills_iter.next() catch continue) |entry| {
            if (entry.kind != .directory) continue;

            var skill_dir = skills_subdir.openDir(entry.name, .{}) catch continue;
            defer skill_dir.close();

            const skill_file = skill_dir.openFile("SKILL.md", .{}) catch continue;
            defer skill_file.close();

            const skill_content = skill_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
            defer allocator.free(skill_content);

            try content.appendSlice(allocator, "\n\n=== Skill: ");
            try content.appendSlice(allocator, entry.name);
            try content.appendSlice(allocator, " ===\n\n");
            try content.appendSlice(allocator, skill_content);
        }
    }

    if (content.items.len == 0) {
        return allocator.dupe(u8, "");
    }

    return content.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Load configuration
    var parsed_config = try agent.config.load(arena_allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    const args = try std.process.argsAlloc(arena_allocator);
    defer std.process.argsFree(arena_allocator, args);

    var rag_enabled = true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-rag")) {
            rag_enabled = false;
        }
    }

    const session_id = "agent_cli_session";
    var bot = try agent.Agent.init(arena_allocator, config, session_id, rag_enabled);
    defer bot.deinit();

    // Load agent rules and skills from .agent/ and .agents/ directories
    const agent_config = loadAgentConfig(arena_allocator) catch "";
    defer arena_allocator.free(agent_config);

    // Custom system prompt for coding assistant
    var system_prompt_builder: std.ArrayList(u8) = .empty;
    defer system_prompt_builder.deinit(arena_allocator);

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

    if (agent_config.len > 0) {
        try system_prompt_builder.appendSlice(arena_allocator, "\n\n");
        try system_prompt_builder.appendSlice(arena_allocator, "=== AGENT RULES & SKILLS ===\n");
        try system_prompt_builder.appendSlice(arena_allocator, agent_config);
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

    const model = config.agents.defaults.model;
    std.debug.print(
        \\🐵 SatiCode CLI (Claude-Code style)
        \\Model: {s}
        \\RAG: {s}
        \\Type your request (Ctrl+D or 'exit' to quit):
        \\
        \\
    , .{ model, if (rag_enabled) "Enabled" else "Disabled" });

    const stdin = std.fs.File.stdin();
    var read_buf: [4096]u8 = undefined;

    while (true) {
        std.debug.print("\nUser > ", .{});

        const n = try stdin.read(&read_buf);
        if (n == 0) break; // EOF

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
