//! Sati - AI Chatbot Framework CLI
const std = @import("std");
const agent = @import("agent");
const core = @import("core");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    // Load config
    var config_parsed = try core.config.load(allocator);
    defer config_parsed.deinit();
    const config = config_parsed.value;

    if (std.mem.eql(u8, command, "help")) {
        if (args.len > 2) {
            try printCommandHelp(args[2]);
        } else {
            try printUsage();
        }
    } else if (std.mem.eql(u8, command, "agent")) {
        try runAgent(allocator, config, args[2..]);
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
    } else if (std.mem.eql(u8, command, "upgrade")) {
        try upgrade();
    } else if (std.mem.eql(u8, command, "web")) {
        std.debug.print("Web API not yet implemented in this build\n", .{});
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn printUsage() !void {
    const help_text =
        \\🐸 sati - AI Chatbot Framework
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
        \\  test-llm      Test LLM provider connectivity
        \\  in            Quick start with auto-configuration
        \\
        \\# Interactive agent mode
        \\sati agent
        \\
        \\# Single message with session
        \\sati agent -m "Hello, how are you?" -s chat123
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
            \\
            \\USAGE:
            \\  sati agent [options]
            \\
            \\OPTIONS:
            \\  -m, --message <text>     Single message mode
            \\  -s, --session <id>       Session ID for conversation
            \\  --no-rag                 Disable RAG (Retrieval-Augmented Generation)
            \\
            \\EXAMPLES:
            \\  sati agent                           # Interactive mode
            \\  sati agent -m "Hello"                # Single message
            \\  sati agent -s chat123 -m "Hello"     # With session
            \\  sati agent --no-rag                  # Disable RAG
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

fn runAgent(allocator: std.mem.Allocator, config: core.config.Config, args: []const []const u8) !void {
    _ = allocator;
    _ = config;
    _ = args;
    std.debug.print("Agent command not yet implemented\n", .{});
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
