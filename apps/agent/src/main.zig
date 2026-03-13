const std = @import("std");
const agent = @import("agent");
const core = @import("core");

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

    // Custom system prompt for coding assistant
    const system_prompt =
        \\You are SatiAgent, a highly capable AI software engineer CLI tool.
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
    ;

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
        \\🚀 SatiAgent CLI (Claude-Code style)
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
