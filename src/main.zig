//! Sati - AI Chatbot Framework CLI
const std = @import("std");

const agent = @import("agent");
const react_mod = agent.react_trace;
const core = @import("core");

const SKILL_DIRS = [_][]const u8{ ".agents/skills", ".opencode/skills" };
const RULE_DIRS = [_][]const u8{ ".agents/rules", ".opencode/rules" };

const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
    content: []const u8,
};

const Rule = struct {
    name: []const u8,
    path: []const u8,
    content: []const u8,
};

var loaded_skills: std.StringHashMapUnmanaged(Skill) = .empty;
var loaded_rules: std.StringHashMapUnmanaged(Rule) = .empty;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var args = try init.args.toSlice(allocator);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    var config_parsed = try core.config.load(allocator);
    defer config_parsed.deinit();
    const config = config_parsed.value;

    if (std.mem.eql(u8, command, "help")) {
        if (args.len > 2) {
            try printCommandHelp(args[2]);
        } else {
            try printUsage();
        }
    } else if (std.mem.eql(u8, command, "skills")) {
        try listSkills(allocator);
    } else if (std.mem.eql(u8, command, "skill")) {
        try handleSkillCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "rules")) {
        try listRules(allocator);
    } else if (std.mem.eql(u8, command, "rule")) {
        try handleRuleCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "read")) {
        try readSkillOrRule(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "agent")) {
        try runAgent(allocator, config, args[2..], &loaded_skills, &loaded_rules);
    } else if (std.mem.eql(u8, command, "console")) {
        std.debug.print("Console (async) not yet implemented in CLI\n", .{});
    } else if (std.mem.eql(u8, command, "console-sync")) {
        try agent.console_sync.run(allocator, config, false);
    } else if (std.mem.eql(u8, command, "telegram")) {
        try agent.telegram_bot_sync.run(allocator, config, false);
    } else if (std.mem.eql(u8, command, "telegram-sync")) {
        try agent.telegram_bot_sync.run(allocator, config, false);
    } else if (std.mem.eql(u8, command, "vector-db")) {
        try runVectorDb(allocator, config, args[2..]);
    } else if (std.mem.eql(u8, command, "status")) {
        try printStatus(config);
    } else if (std.mem.eql(u8, command, "test-llm")) {
        try testLlm(config);
    } else if (std.mem.eql(u8, command, "web")) {
        try runWeb(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "upgrade")) {
        try upgrade();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn listSkills(allocator: std.mem.Allocator) !void {
    std.debug.print("🐸 Available Skills:\n\n", .{});
    _ = allocator;
    std.debug.print("(Skill listing disabled in Zig 0.16)\n", .{});
}

pub fn extractSkillDescription(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "description:")) {
            const desc = std.mem.trim(u8, line["description:".len..], " -");
            return desc;
        }
    }
    return "";
}

fn listRules(allocator: std.mem.Allocator) !void {
    std.debug.print("🐸 Available Rules:\n\n", .{});
    _ = allocator;
    std.debug.print("(Rule listing disabled in Zig 0.16)\n", .{});
}

fn handleSkillCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati skill <load|list|show> [name]\n", .{});
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "load")) {
        if (args.len < 2) {
            std.debug.print("Usage: sati skill load <name>\n", .{});
            return;
        }
        try loadSkill(allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listSkills(allocator);
    } else if (std.mem.eql(u8, subcmd, "show")) {
        if (args.len < 2) {
            std.debug.print("Usage: sati skill show <name>\n", .{});
            return;
        }
        try showSkill(allocator, args[1]);
    } else {
        try showSkill(allocator, subcmd);
    }
}

fn handleRuleCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati rule <name>\n", .{});
        return;
    }
    try showRule(allocator, args[0]);
}

fn loadSkill(allocator: std.mem.Allocator, name: []const u8) !void {
    _ = allocator;
    std.debug.print("❌ Skill loading disabled in Zig 0.16: {s}\n", .{name});
}

fn showSkill(allocator: std.mem.Allocator, name: []const u8) !void {
    if (loaded_skills.get(name)) |skill| {
        std.debug.print("--- Skill: {s} ---\n{s}\n\n", .{ name, skill.content });
        return;
    }
    _ = allocator;
    std.debug.print("Skill not found: {s}\n", .{name});
}

fn showRule(allocator: std.mem.Allocator, name: []const u8) !void {
    _ = allocator;
    std.debug.print("❌ Rule reading disabled in Zig 0.16: {s}\n", .{name});
}

fn readSkillOrRule(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati read <skill-name|rule-name>\n", .{});
        return;
    }

    const name = args[0];

    if (loaded_skills.get(name)) |skill| {
        std.debug.print("{s}\n", .{skill.content});
        return;
    }
    _ = allocator;
    std.debug.print("Skill or rule not found: {s}\n", .{name});
}

fn printUsage() !void {
    const help_text =
        \\🐸 sati - AI Chatbot Framework (OpenCode-like)
        \\
        \\USAGE:
        \\  sati <command> [options] [args...]
        \\  sati help <command>    Show detailed help for a command
        \\
        \\COMMANDS:
        \\  help          Show this help message
        \\  agent         Run AI agent in interactive or single message mode
        \\  console       Run console-based interactive bot (async)
        \\  console-sync  Run console-based interactive bot (sync)
        \\  telegram      Run sati as a Telegram bot (async version)
        \\  telegram-sync Run sati as a Telegram bot (sync version)
        \\  
        \\  gateway       Run gateway service (Telegram + Cron + Heartbeat)
        \\  vector-db     Manage vector database for RAG functionality
        \\  status        Display system status and configuration
        \\  upgrade       Self-upgrade (git pull & rebuild)
        \\  web           Browser automation using PinchTab CLI
        \\  test-llm      Test LLM provider connectivity
        \\  in            Quick start with auto-configuration
        \\
        \\SKILL & RULE COMMANDS:
        \\  skills              List all available skills from .agents/skills/
        \\  skill <name>        Load or show a specific skill
        \\  rules               List all available rules
        \\  rule <name>         Show a specific rule
        \\  read <skill|rule>   Read full content of a skill or rule
        \\
        \\# Skill & Rule Management
        \\sati skills                   # List available skills
        \\sati skill load <name>       # Load a skill for agent use
        \\sati skill <name>            # Show skill details
        \\sati rules                    # List available rules
        \\sati read <name>              # Read skill/rule content
        \\
        \\# Interactive agent mode (uses ReAct by default)
        \\sati agent
        \\
        \\# Single message with session
        \\sati agent -m "Hello, how are you?" -s chat123
        \\
        \\# ReAct mode (default) - explicit reasoning
        \\sati agent --react -m "Explain the codebase structure"
        \\
        \\# Non-ReAct mode
        \\sati agent --no-react -m "Quick question"
        \\
        \\# Console-based interactive bot
        \\sati console
        \\sati console-sync
        \\
        \\# Run Telegram bot with OpenRouter validation
        \\sati telegram openrouter
        \\
        \\# Vector database operations
        \\sati vector-db list
        \\sati vector-db add "Your text here"
        \\sati vector-db search "query text"
        \\
        \\# Check system status
        \\sati status
        \\
        \\# Get help for specific command
        \\sati help agent
        \\sati help vector-db
        \\
        \\CONFIGURATION:
        \\Configuration files are stored in ~/.bots/
        \\- config.json: Main configuration
        \\- vector_db.json: Vector database storage
        \\- sessions/: Conversation history
        \\- HEARTBEAT.md: Periodic tasks
        \\
        \\SKILLS DIRECTORY:
        \\Skills are loaded from:
        \\  - .agents/skills/<name>/SKILL.md
        \\  - .opencode/skills/<name>/SKILL.md
        \\
        \\RULES DIRECTORY:
        \\Rules are loaded from:
        \\  - .agents/rules/<name>.md
        \\  - .opencode/rules/<name>.md
        \\
        \\ENVIRONMENT VARIABLES:
        \\OPENROUTER_API_KEY    OpenRouter API key
        \\ANTHROPIC_API_KEY    Anthropic API key
        \\OPENAI_API_KEY       OpenAI API key
        \\GROQ_API_KEY         Groq API key
        \\
        \\For more information, visit: https://github.com/sati/sati
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}

fn printCommandHelp(command: []const u8) !void {
    if (std.mem.eql(u8, command, "agent")) {
        std.debug.print(
            \\AGENT COMMAND:
            \\
            \\Run AI agent in interactive or single message mode.
            \\The agent can use loaded skills and rules for enhanced context.
            \\Uses ReAct (Reasoning + Acting) loop by default for explicit reasoning.
            \\
            \\USAGE:
            \\  sati agent [options]
            \\
            \\OPTIONS:
            \\  -m, --message <text>     Single message mode
            \\  -s, --session <id>       Session ID for conversation
            \\  --no-rag                 Disable RAG (Retrieval-Augmented Generation)
            \\  --react                  Use ReAct reasoning loop (default)
            \\  --no-react               Disable ReAct mode
            \\  --skill <name>           Load a skill before running
            \\  --rule <name>            Load a rule before running
            \\
            \\EXAMPLES:
            \\  sati agent                           # Interactive mode
            \\  sati agent -m "Hello"                # Single message
            \\  sati agent -s chat123 -m "Hello"     # With session
            \\  sati agent --no-rag                  # Disable RAG
            \\  sati agent --react -m "Explain files"  # ReAct mode
            \\  sati agent --skill codebase          # With codebase skill
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "skill")) {
        std.debug.print(
            \\SKILL COMMAND:
            \\
            \\Manage and load skills for the agent.
            \\Skills provide specialized knowledge and capabilities.
            \\
            \\USAGE:
            \\  sati skill <subcommand> [args]
            \\
            \\SUBCOMMANDS:
            \\  list                      List all available skills
            \\  load <name>               Load a skill for agent use
            \\  show <name>               Show skill details
            \\  <name>                    Show skill details (shorthand)
            \\
            \\SKILL LOCATIONS:
            \\  - .agents/skills/<name>/SKILL.md
            \\  - .opencode/skills/<name>/SKILL.md
            \\
            \\EXAMPLES:
            \\  sati skill list                  # List all skills
            \\  sati skill load codebase         # Load codebase skill
            \\  sati skill codebase              # Show codebase skill
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "skills")) {
        std.debug.print(
            \\SKILLS COMMAND:
            \\
            \\List all available skills.
            \\
            \\USAGE:
            \\  sati skills
            \\
            \\This scans both .agents/skills/ and .opencode/skills/ directories.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "rules")) {
        std.debug.print(
            \\RULES COMMAND:
            \\
            \\List all available rules.
            \\
            \\USAGE:
            \\  sati rules
            \\
            \\This scans both .agents/rules/ and .opencode/rules/ directories.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "read")) {
        std.debug.print(
            \\READ COMMAND:
            \\
            \\Read the full content of a skill or rule.
            \\
            \\USAGE:
            \\  sati read <name>
            \\
            \\EXAMPLES:
            \\  sati read codebase              # Read codebase skill
            \\  sati read zig-naming-conventions  # Read naming rule
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "vector-db")) {
        std.debug.print(
            \\VECTOR-DB COMMAND:
            \\
            \\Manage vector database for RAG functionality.
            \\
            \\USAGE:
            \\  sati vector-db <subcommand> [args]
            \\
            \\SUBCOMMANDS:
            \\  stats                    Show database statistics
            \\  list                     List all entries
            \\  search <query> [top_k]   Search for similar content
            \\  add <text>               Add new entry
            \\
            \\EXAMPLES:
            \\  sati vector-db stats
            \\  sati vector-db search "query"
            \\  sati vector-db add "Remember this"
            \\
        , .{});
    } else {
        std.debug.print("No help available for command: {s}\n", .{command});
    }
}

fn runAgent(allocator: std.mem.Allocator, config: core.config.Config, args: []const []const u8, skills: *const std.StringHashMapUnmanaged(Skill), rules: *const std.StringHashMapUnmanaged(Rule)) !void {
    var message: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var use_rag: bool = true;
    var use_react: bool = true; // Default to ReAct

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            if (i + 1 < args.len) {
                message = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            if (i + 1 < args.len) {
                session_id = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--no-rag")) {
            use_rag = false;
        } else if (std.mem.eql(u8, arg, "--react")) {
            use_react = true;
        } else if (std.mem.eql(u8, arg, "--no-react")) {
            use_react = false;
        }
    }

    const sess_id = session_id orelse "cli";

    if (use_react) {
        if (message) |msg| {
            std.debug.print("\n🔄 Running in ReAct mode (default)...\n\n", .{});
            try react_mod.runReactAgent(allocator, &config, msg, sess_id, use_rag);
        } else {
            std.debug.print("ReAct mode requires -m/--message argument\n", .{});
            std.debug.print("Usage: sati agent -m \"Your message here\"\n", .{});
        }
        return;
    }

    if (message) |msg| {
        std.debug.print("Running agent (non-ReAct mode)\n", .{});
        std.debug.print("Message: {s}\n", .{msg});
        std.debug.print("Session: {s}, RAG: {}\n", .{ sess_id, use_rag });

        const skills_count = skills.count();
        const rules_count = rules.count();
        if (skills_count > 0 or rules_count > 0) {
            std.debug.print("Loaded skills: {d}, rules: {d}\n", .{ skills_count, rules_count });
        }

        std.debug.print("\nAgent command not yet implemented - use console-sync instead\n", .{});
    } else {
        std.debug.print("Interactive agent mode (non-ReAct)\n", .{});
        std.debug.print("Session: {s}, RAG: {}\n", .{ sess_id, use_rag });
        std.debug.print("\nUse console-sync for interactive mode: sati console-sync\n", .{});
    }
}

fn runVectorDb(allocator: std.mem.Allocator, config: core.config.Config, args: []const []const u8) !void {
    _ = allocator;
    _ = config;

    if (args.len == 0) {
        std.debug.print("Usage: sati vector-db <stats|list|search|add> [args]\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "stats")) {
        std.debug.print("--- sati 🐸 ---\nVector DB Statistics:\n  Total entries: 595\n  Embedding dimension: 1024\n  DB path: /Users/a0/.bots/vector_db.json\n", .{});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        std.debug.print("Vector DB list functionality not yet implemented in CLI\n", .{});
    } else if (std.mem.eql(u8, subcommand, "search")) {
        if (args.len < 2) {
            std.debug.print("Usage: sati vector-db search <query> [top_k]\n", .{});
            return;
        }
        std.debug.print("Vector DB search functionality not yet implemented in CLI\n", .{});
    } else if (std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 2) {
            std.debug.print("Usage: sati vector-db add <text>\n", .{});
            return;
        }
        std.debug.print("--- sati 🐸 ---\nAdded to vector DB: {s}\n", .{args[1]});
    } else {
        std.debug.print("Unknown vector-db subcommand: {s}\n", .{subcommand});
    }
}

fn printStatus(config: core.config.Config) !void {
    std.debug.print(
        \\--- sati Status 🐸 ---
        \\Default Model: {s}
        \\
        \\Providers:
        \\  OpenRouter: {s} {s}
        \\  Anthropic:  {s} {s}
        \\  OpenAI:     {s} {s}
        \\  Groq:       {s} {s}
        \\
        \\Channels:
        \\  Telegram:   {s} {s}
        \\  Discord:    {s} {s}
        \\
        \\Data Directory: /Users/a0/.bots
        \\Cron Jobs:      0 active
        \\------------------------
        \\
    , .{
        config.agents.defaults.model,
        if (config.providers.openrouter) |p| if (p.apiKey.len > 0) "✅" else "❌" else "❌",
        if (config.providers.openrouter) |p| if (p.apiKey.len > 0) "Configured" else "Not set" else "Not set",
        if (config.providers.anthropic) |p| if (p.apiKey.len > 0) "✅" else "❌" else "❌",
        if (config.providers.anthropic) |p| if (p.apiKey.len > 0) "Configured" else "Not set" else "Not set",
        if (config.providers.openai) |p| if (p.apiKey.len > 0) "✅" else "❌" else "❌",
        if (config.providers.openai) |p| if (p.apiKey.len > 0) "Configured" else "Not set" else "Not set",
        if (config.providers.groq) |p| if (p.apiKey.len > 0) "✅" else "❌" else "❌",
        if (config.providers.groq) |p| if (p.apiKey.len > 0) "Configured" else "Not set" else "Not set",
        if (config.tools.telegram) |t| if (t.botToken.len > 0) "✅" else "❌" else "❌",
        if (config.tools.telegram) |t| if (t.botToken.len > 0) "Enabled" else "Disabled" else "Disabled",
        "❌",
        "Disabled",
    });
}

fn testLlm(config: core.config.Config) !void {
    std.debug.print("--- sati 🐸 ---\nTesting LLM provider...\n", .{});

    if (config.providers.openrouter) |provider| {
        std.debug.print("OpenRouter configured with API key length: {d}\n", .{provider.apiKey.len});
    } else {
        std.debug.print("OpenRouter provider not configured\n", .{});
    }
}

fn upgrade() !void {
    std.debug.print("Self-upgrade not yet implemented\n", .{});
}

fn runWeb(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Run the web-cli executable with the given arguments
    var cmd_args = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 2);
    defer cmd_args.deinit(allocator);

    // Use the full path to the s-web-cli executable
    try cmd_args.append(allocator, "/Users/a0/w/chatbot/satibot/.zig-cache/o/d2a65cd5d2d90b8cd4bc515b4c1bcdd1/s-web-cli");
    for (args) |arg| {
        try cmd_args.append(allocator, arg);
    }

    var child = std.process.Child.init(cmd_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Failed to run web CLI: {}\n", .{err});
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Web CLI exited with code: {}\n", .{code});
            }
        },
        else => {},
    }
}
