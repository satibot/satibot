const std = @import("std");
const satibot = @import("satibot");
// Import build options (contains build timestamp)
const build_options = @import("build_options");

/// Main entry point for satibot application
/// Handles command line arguments and dispatches to appropriate handlers
pub fn main() !void {
    // Print startup banner with build timestamp
    std.debug.print("--- satibot 🐸 (build: {s}) ---\n", .{build_options.build_time_str});

    // Initialize general purpose allocator for memory management
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Handle help and version flags
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "help")) {
            try usage();
            return;
        }
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "version")) {
            std.debug.print("satibot version {s} (build: {s})\n", .{ build_options.version, build_options.build_time_str });
            return;
        }
    }

    // If no command is provided, default to running telegram bot with openrouter
    if (args.len < 2) {
        // Create args array for telegram with openrouter
        const telegram_args = try allocator.alloc([:0]u8, 3);
        defer {
            allocator.free(telegram_args[0]);
            allocator.free(telegram_args[1]);
            allocator.free(telegram_args[2]);
            allocator.free(telegram_args);
        }

        telegram_args[0] = try allocator.dupeZ(u8, "satibot");
        telegram_args[1] = try allocator.dupeZ(u8, "telegram");
        telegram_args[2] = try allocator.dupeZ(u8, "openrouter");

        try runTelegramBot(allocator, telegram_args);
        return;
    }

    // Get the command argument and dispatch to appropriate handler
    const command = args[1];
    if (std.mem.eql(u8, command, "help")) {
        // Show help information
        if (args.len >= 3) {
            // Show help for specific command
            try showCommandHelp(args[2]);
        } else {
            // Show general help
            try usage();
        }
    } else if (std.mem.eql(u8, command, "agent")) {
        // Run interactive agent or single message mode
        try runAgent(allocator, args);
    } else if (std.mem.eql(u8, command, "test-llm")) {
        // Test LLM provider connectivity
        try runTestLlm(allocator);
    } else if (std.mem.eql(u8, command, "telegram")) {
        // Run Telegram bot
        try runTelegramBot(allocator, args);
    } else if (std.mem.eql(u8, command, "whatsapp")) {
        // Run WhatsApp bot
        try runWhatsAppBot(allocator, args);
    } else if (std.mem.eql(u8, command, "in")) {
        // Handle "satibot in <platform>" command format
        // This auto-creates config for the specified platform before running
        if (args.len < 3) {
            std.debug.print("Usage: satibot in <platform>\n", .{});
            std.debug.print("Platforms:\n", .{});
            std.debug.print("  whatsapp   Auto-create WhatsApp config and run\n", .{});
            std.debug.print("  telegram   Auto-create Telegram config and run\n", .{});
            return;
        }
        const platform = args[2];
        if (std.mem.eql(u8, platform, "whatsapp")) {
            // Create WhatsApp config if it doesn't exist and run bot
            try autoCreateWhatsAppConfig(allocator);
            try runWhatsAppBot(allocator, args);
        } else if (std.mem.eql(u8, platform, "telegram")) {
            // Create Telegram config if it doesn't exist and run bot
            try autoCreateTelegramConfig(allocator);
            try runTelegramBot(allocator, args);
        } else {
            std.debug.print("Unknown platform: {s}\n", .{platform});
        }
    } else if (std.mem.eql(u8, command, "gateway")) {
        // Run gateway service that manages Telegram bot, Cron jobs, and Heartbeat
        try runGateway(allocator);
    } else if (std.mem.eql(u8, command, "vector-db")) {
        // Manage vector database operations (list, search, add, stats)
        try runVectorDb(allocator, args);
    } else if (std.mem.eql(u8, command, "status")) {
        // Show system status and configuration
        try runStatus(allocator);
    } else if (std.mem.eql(u8, command, "upgrade")) {
        // Self-upgrade: git pull and rebuild
        try runUpgrade(allocator);
    } else {
        // Unknown command - show usage
        std.debug.print("Unknown command: {s}\n", .{command});
        try usage();
    }
}

/// Print usage information for all available commands
fn usage() !void {
    std.debug.print("🐸 satibot - AI Chatbot Framework\n\n", .{});
    std.debug.print("USAGE:\n", .{});
    std.debug.print("  satibot <command> [options] [args...]\n", .{});
    std.debug.print("  satibot help <command>    Show detailed help for a command\n\n", .{});

    std.debug.print("COMMANDS:\n", .{});
    std.debug.print("  help          Show this help message\n", .{});
    std.debug.print("  agent         Run AI agent in interactive or single message mode\n", .{});
    std.debug.print("  telegram      Run satibot as a Telegram bot\n", .{});
    std.debug.print("  whatsapp      Run satibot as a WhatsApp bot\n", .{});
    std.debug.print("  gateway       Run gateway service (Telegram + Cron + Heartbeat)\n", .{});
    std.debug.print("  vector-db     Manage vector database for RAG functionality\n", .{});
    std.debug.print("  status        Display system status and configuration\n", .{});
    std.debug.print("  upgrade       Self-upgrade (git pull & rebuild)\n", .{});
    std.debug.print("  test-llm      Test LLM provider connectivity\n", .{});
    std.debug.print("  in            Quick start with auto-configuration\n", .{});

    std.debug.print("\nOPTIONS:\n", .{});
    std.debug.print("  --help, -h    Show this help message\n", .{});
    std.debug.print("  --version, -v Show version information\n", .{});

    std.debug.print("\nEXAMPLES:\n", .{});
    std.debug.print("  # Interactive agent mode\n", .{});
    std.debug.print("  satibot agent\n\n", .{});

    std.debug.print("  # Single message with session\n", .{});
    std.debug.print("  satibot agent -m \"Hello, how are you?\" -s chat123\n\n", .{});

    std.debug.print("  # Run Telegram bot with OpenRouter validation\n", .{});
    std.debug.print("  satibot telegram openrouter\n\n", .{});

    std.debug.print("  # Quick start WhatsApp (auto-creates config)\n", .{});
    std.debug.print("  satibot in whatsapp\n\n", .{});

    std.debug.print("  # Vector database operations\n", .{});
    std.debug.print("  satibot vector-db list\n", .{});
    std.debug.print("  satibot vector-db add \"Your text here\"\n", .{});
    std.debug.print("  satibot vector-db search \"query text\"\n\n", .{});

    std.debug.print("  # Check system status\n", .{});
    std.debug.print("  satibot status\n\n", .{});

    std.debug.print("  # Get help for specific command\n", .{});
    std.debug.print("  satibot help agent\n", .{});
    std.debug.print("  satibot help vector-db\n\n", .{});

    std.debug.print("CONFIGURATION:\n", .{});
    std.debug.print("  Configuration files are stored in ~/.bots/\n", .{});
    std.debug.print("  - config.json: Main configuration\n", .{});
    std.debug.print("  - whatsapp.json: WhatsApp-specific config\n", .{});
    std.debug.print("  - vector_db.json: Vector database storage\n", .{});
    std.debug.print("  - sessions/: Conversation history\n", .{});
    std.debug.print("  - HEARTBEAT.md: Periodic tasks\n\n", .{});

    std.debug.print("ENVIRONMENT VARIABLES:\n", .{});
    std.debug.print("  OPENROUTER_API_KEY    OpenRouter API key\n", .{});
    std.debug.print("  ANTHROPIC_API_KEY    Anthropic API key\n", .{});
    std.debug.print("  OPENAI_API_KEY       OpenAI API key\n", .{});
    std.debug.print("  GROQ_API_KEY         Groq API key\n\n", .{});

    std.debug.print("For more information, visit: https://github.com/satibot/satibot\n", .{});
}

/// Show detailed help for a specific command
fn showCommandHelp(command: []const u8) !void {
    if (std.mem.eql(u8, command, "agent")) {
        std.debug.print("🤖 AGENT COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot agent [options]\n\n", .{});
        std.debug.print("OPTIONS:\n", .{});
        std.debug.print("  -m \"message\"        Send a single message and exit\n", .{});
        std.debug.print("  -s <session_id>    Use specific session ID (default: \"default\")\n", .{});
        std.debug.print("  --no-rag           Disable RAG (Retrieval-Augmented Generation)\n", .{});
        std.debug.print("  --rag              Enable RAG (default)\n", .{});
        std.debug.print("  openrouter         Validate OpenRouter configuration\n\n", .{});
        std.debug.print("EXAMPLES:\n", .{});
        std.debug.print("  satibot agent                           # Interactive mode\n", .{});
        std.debug.print("  satibot agent -m \"Hello\"                # Single message\n", .{});
        std.debug.print("  satibot agent -s chat123 -m \"Hello\"     # With session\n", .{});
        std.debug.print("  satibot agent --no-rag                  # Disable RAG\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "vector-db")) {
        std.debug.print("🗃️  VECTOR-DB COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot vector-db <subcommand> [args...]\n\n", .{});
        std.debug.print("SUBCOMMANDS:\n", .{});
        std.debug.print("  list              List all entries in vector DB\n", .{});
        std.debug.print("  search <query>    Search vector DB with query\n", .{});
        std.debug.print("  add <text>        Add text to vector DB\n", .{});
        std.debug.print("  stats             Show vector DB statistics\n\n", .{});
        std.debug.print("EXAMPLES:\n", .{});
        std.debug.print("  satibot vector-db list\n", .{});
        std.debug.print("  satibot vector-db add \"Your text here\"\n", .{});
        std.debug.print("  satibot vector-db search \"query text\"\n", .{});
        std.debug.print("  satibot vector-db search \"query\" 5    # Top 5 results\n", .{});
        std.debug.print("  satibot vector-db stats\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "telegram")) {
        std.debug.print("📱 TELEGRAM COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot telegram [options]\n\n", .{});
        std.debug.print("OPTIONS:\n", .{});
        std.debug.print("  openrouter         Validate OpenRouter configuration\n\n", .{});
        std.debug.print("DESCRIPTION:\n", .{});
        std.debug.print("  Runs satibot as a Telegram bot. The bot will listen for messages\n", .{});
        std.debug.print("  and respond using the configured AI model.\n\n", .{});
        std.debug.print("CONFIGURATION:\n", .{});
        std.debug.print("  Requires telegram.botToken and telegram.chatId in config.json\n", .{});
        std.debug.print("  Get bot token from @BotFather\n", .{});
        std.debug.print("  Get chat ID from @userinfobot\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "whatsapp")) {
        std.debug.print("📱 WHATSAPP COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot whatsapp [options]\n\n", .{});
        std.debug.print("OPTIONS:\n", .{});
        std.debug.print("  openrouter         Validate OpenRouter configuration\n\n", .{});
        std.debug.print("DESCRIPTION:\n", .{});
        std.debug.print("  Runs satibot as a WhatsApp bot using the Meta Graph API.\n\n", .{});
        std.debug.print("CONFIGURATION:\n", .{});
        std.debug.print("  Uses ~/.bots/whatsapp.json configuration file\n", .{});
        std.debug.print("  Requires accessToken, phoneNumberId, and recipientPhoneNumber\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "gateway")) {
        std.debug.print("🌉 GATEWAY COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot gateway\n\n", .{});
        std.debug.print("DESCRIPTION:\n", .{});
        std.debug.print("  Runs the gateway service that manages multiple components:\n", .{});
        std.debug.print("  - Telegram bot for message handling\n", .{});
        std.debug.print("  - Cron jobs for scheduled tasks\n", .{});
        std.debug.print("  - Heartbeat for periodic checks\n\n", .{});
        std.debug.print("  This is the main production deployment mode.\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "status")) {
        std.debug.print("📊 STATUS COMMAND\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot status\n\n", .{});
        std.debug.print("DESCRIPTION:\n", .{});
        std.debug.print("  Displays system status including:\n", .{});
        std.debug.print("  - Default model configuration\n", .{});
        std.debug.print("  - Provider configurations\n", .{});
        std.debug.print("  - Channel configurations\n", .{});
        std.debug.print("  - Data directory location\n", .{});
        std.debug.print("  - Active cron jobs\n", .{});
        return;
    } else if (std.mem.eql(u8, command, "in")) {
        std.debug.print("⚡ IN COMMAND (Quick Start)\n\n", .{});
        std.debug.print("USAGE:\n", .{});
        std.debug.print("  satibot in <platform>\n\n", .{});
        std.debug.print("PLATFORMS:\n", .{});
        std.debug.print("  whatsapp   Auto-create WhatsApp config and run\n", .{});
        std.debug.print("  telegram   Auto-create Telegram config and run\n\n", .{});
        std.debug.print("DESCRIPTION:\n", .{});
        std.debug.print("  Quickly starts a bot with auto-configuration.\n", .{});
        std.debug.print("  Creates the necessary config files if they don't exist.\n", .{});
        return;
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        std.debug.print("Available commands: agent, telegram, whatsapp, gateway, vector-db,\n", .{});
        std.debug.print("                  status, in\n", .{});
    }
}

/// Run the AI agent in either interactive mode or single message mode
/// Arguments:
///   -m "message"    Send a single message and exit
///   -s session_id    Use specific session ID (default: "default")
///   --no-rag         Disable RAG (Retrieval-Augmented Generation)
///   openrouter       Validate OpenRouter configuration before running
fn runAgent(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    // Load configuration from ~/.bots/config.json
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Parse command line arguments
    var message: []const u8 = "";
    var session_id: []const u8 = "default";
    var save_to_rag = true;
    var check_openrouter = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            // Message to send to agent
            message = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            // Session ID for conversation persistence
            session_id = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-rag")) {
            // Disable RAG functionality
            save_to_rag = false;
        } else if (std.mem.eql(u8, args[i], "--rag")) {
            // Enable RAG functionality (default)
            save_to_rag = true;
        } else if (std.mem.eql(u8, args[i], "openrouter")) {
            // Validate OpenRouter config
            check_openrouter = true;
        }
    }

    // If no message provided, enter interactive mode
    if (message.len == 0) {
        std.debug.print("Entering interactive mode. Type 'exit' or 'quit' to end.\n", .{});
        var agent = satibot.agent.Agent.init(allocator, config, session_id);
        defer agent.deinit();

        // Read from stdin for interactive mode
        const stdin = std.fs.File.stdin();
        var buf: [4096]u8 = undefined;

        while (true) {
            std.debug.print("\n> ", .{});
            const n = try stdin.read(&buf);
            if (n == 0) break;

            const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

            // Process user input
            agent.run(trimmed) catch |err| {
                std.debug.print("Error: {any}\n", .{err});
            };

            // Save conversation to RAG if enabled
            if (save_to_rag) {
                agent.index_conversation() catch |err| {
                    std.debug.print("Index Error: {any}\n", .{err});
                };
            }
        }
        return;
    }

    // Single message mode
    if (check_openrouter) {
        try validateConfig(config);
    }

    // Initialize agent with session
    var agent = satibot.agent.Agent.init(allocator, config, session_id);
    defer agent.deinit();

    // Process single message
    try agent.run(message);

    // Save to RAG if enabled
    if (save_to_rag) {
        try agent.index_conversation();
    }
}

/// Test LLM provider connectivity by sending a simple message
/// Uses OpenRouter provider to verify API key and model access
fn runTestLlm(allocator: std.mem.Allocator) !void {
    // Load configuration
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Get API key from config or environment
    const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OpenRouter API key not configured. Set OPENROUTER_API_KEY env var or update config.json.\n", .{});
        return;
    };

    // Initialize OpenRouter provider
    var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
    defer provider.deinit();

    // Create test message
    const messages = &[_]satibot.providers.base.LLMMessage{
        .{ .role = "user", .content = "Say hello from Zig!" },
    };

    // Send test request
    std.debug.print("Sending request to OpenRouter...\n", .{});
    var response = try provider.chat(messages, config.agents.defaults.model, null);
    defer response.deinit();

    std.debug.print("Response: {s}\n", .{response.content orelse "(no content)"});
}

/// Run Telegram bot server
/// Listens for Telegram messages and responds using the AI agent
fn runTelegramBot(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    // Load configuration
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Check if OpenRouter validation is requested
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

    // Display active model and start bot
    std.debug.print("Active Model: {s}\n", .{config.agents.defaults.model});
    std.debug.print("Telegram bot started. Press Ctrl+C to stop.\n", .{});

    // Run Telegram bot (blocking call)
    try satibot.agent.telegram_bot.runBot(allocator, config);
}

/// Run WhatsApp bot server
/// Listens for WhatsApp messages via Meta API and responds using the AI agent
/// Note: Loads config from ~/.bots/whatsapp.json instead of default config.json
fn runWhatsAppBot(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    // Load WhatsApp-specific config from ~/.bots/whatsapp.json
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);
    const config_path = try std.fs.path.join(allocator, &.{ bots_dir, "whatsapp.json" });
    defer allocator.free(config_path);

    // Load WhatsApp configuration
    const parsed_config = try satibot.config.loadFromPath(allocator, config_path);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Check if OpenRouter validation is requested
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

    // Display active model and start bot
    std.debug.print("Active Model: {s}\n", .{config.agents.defaults.model});
    std.debug.print("WhatsApp bot started. Press Ctrl+C to stop.\n", .{});

    // Run WhatsApp bot (blocking call)
    try satibot.agent.whatsapp_bot.run(allocator, config);
}

/// Run gateway service that manages multiple components:
/// - Telegram bot for message handling
/// - Cron jobs for scheduled tasks
/// - Heartbeat for periodic checks
/// This is the main production deployment mode
fn runGateway(allocator: std.mem.Allocator) !void {
    // Load configuration
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Initialize gateway with all components
    var g = try satibot.agent.gateway.Gateway.init(allocator, config);
    defer g.deinit();

    // Run gateway (blocking call)
    try g.run();
}

/// Manage vector database operations
/// Provides commands to list, search, add entries and show statistics
fn runVectorDb(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    // Show usage if no subcommand provided
    if (args.len < 3) {
        std.debug.print("Usage: satibot vector-db <command> [args...]\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  list              List all entries in vector DB\n", .{});
        std.debug.print("  search <query>    Search vector DB with query\n", .{});
        std.debug.print("  add <text>        Add text to vector DB\n", .{});
        std.debug.print("  stats             Show vector DB statistics\n", .{});
        return;
    }

    const subcmd = args[2];
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Get DB path from ~/.bots/vector_db.json
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);
    const db_path = try std.fs.path.join(allocator, &.{ bots_dir, "vector_db.json" });
    defer allocator.free(db_path);

    // Initialize vector store
    var store = satibot.agent.vector_db.VectorStore.init(allocator);
    defer store.deinit();
    // Load existing data or create new store
    store.load(db_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Error loading vector DB: {any}\n", .{err});
            return err;
        }
    };

    // Handle list command - display all entries
    if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("Vector DB Entries ({d} total):\n", .{store.entries.items.len});
        for (store.entries.items, 0..) |entry, i| {
            std.debug.print("{d}. {s}\n", .{ i + 1, entry.text });
            std.debug.print("   Embedding dims: {d}\n", .{entry.embedding.len});
        }
    } else if (std.mem.eql(u8, subcmd, "stats")) {
        // Handle stats command - show database statistics
        std.debug.print("Vector DB Statistics:\n", .{});
        std.debug.print("  Total entries: {d}\n", .{store.entries.items.len});
        if (store.entries.items.len > 0) {
            std.debug.print("  Embedding dimension: {d}\n", .{store.entries.items[0].embedding.len});
        }
        std.debug.print("  DB path: {s}\n", .{db_path});
    } else if (std.mem.eql(u8, subcmd, "search")) {
        // Handle search command - find similar entries
        if (config.agents.defaults.disableRag) {
            std.debug.print("Error: RAG is globally disabled in config.json\n", .{});
            return;
        }
        if (args.len < 4) {
            std.debug.print("Usage: satibot vector-db search <query> [top_k]\n", .{});
            return;
        }
        const query = args[3];
        var top_k: usize = 3;
        if (args.len >= 5) {
            top_k = try std.fmt.parseInt(usize, args[4], 10);
        }

        const emb_model = config.agents.defaults.embeddingModel orelse "local";
        var resp: satibot.providers.base.EmbeddingResponse = undefined;

        if (std.mem.eql(u8, emb_model, "local")) {
            resp = try satibot.agent.local_embeddings.LocalEmbedder.generate(allocator, &.{query});
        } else {
            const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
                std.debug.print("Error: Embedding API key not configured. Set 'embeddingModel': 'local' in config.json for offline mode.\n", .{});
                return error.NoApiKey;
            };
            var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
            defer provider.deinit();
            resp = try provider.embeddings(.{ .input = &.{query}, .model = emb_model });
        }
        defer resp.deinit();

        if (resp.embeddings.len == 0) {
            std.debug.print("Error: No embeddings generated\n", .{});
            return;
        }

        // Search for similar entries
        const results = try store.search(resp.embeddings[0], top_k);
        defer allocator.free(results);

        std.debug.print("Search Results for '{s}' ({d} items):\n", .{ query, results.len });
        for (results, 0..) |res, i| {
            std.debug.print("{d}. {s}\n", .{ i + 1, res.text });
        }
    } else if (std.mem.eql(u8, subcmd, "add")) {
        // Handle add command - add new text entry to vector DB
        if (config.agents.defaults.disableRag) {
            std.debug.print("Error: RAG is globally disabled in config.json\n", .{});
            return;
        }
        if (args.len < 4) {
            std.debug.print("Usage: satibot vector-db add <text>\n", .{});
            return;
        }
        // Combine all remaining args as text (handles spaces)
        var text_len: usize = 0;
        for (args[3..]) |arg| {
            text_len += arg.len + 1; // +1 for space
        }
        var text_buf = try allocator.alloc(u8, text_len);
        defer allocator.free(text_buf);
        var pos: usize = 0;
        for (args[3..], 0..) |arg, i| {
            if (i > 0) {
                text_buf[pos] = ' ';
                pos += 1;
            }
            @memcpy(text_buf[pos .. pos + arg.len], arg);
            pos += arg.len;
        }
        const text = text_buf[0..pos];

        const emb_model = config.agents.defaults.embeddingModel orelse "local";
        var resp: satibot.providers.base.EmbeddingResponse = undefined;

        if (std.mem.eql(u8, emb_model, "local")) {
            resp = try satibot.agent.local_embeddings.LocalEmbedder.generate(allocator, &.{text});
        } else {
            const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
                std.debug.print("Error: Embedding API key not configured. Set 'embeddingModel': 'local' in config.json for offline mode.\n", .{});
                return error.NoApiKey;
            };
            var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
            defer provider.deinit();
            resp = try provider.embeddings(.{ .input = &.{text}, .model = emb_model });
        }
        defer resp.deinit();

        if (resp.embeddings.len == 0) {
            std.debug.print("Error: No embeddings generated\n", .{});
            return;
        }

        // Add to vector store and save
        try store.add(text, resp.embeddings[0]);
        try store.save(db_path);
        std.debug.print("Added to vector DB: {s}\n", .{text});
    } else {
        std.debug.print("Unknown vector-db command: {s}\n", .{subcmd});
    }
}

/// Display system status including:
/// - Default model configuration
/// - Provider configurations (OpenRouter, Anthropic, OpenAI, Groq)
/// - Channel configurations (Telegram, Discord, WhatsApp)
/// - Data directory location
/// - Active cron jobs
fn runStatus(allocator: std.mem.Allocator) !void {
    // Load configuration
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Display header and model info
    std.debug.print("\n--- satibot Status 🐸 ---\n", .{});
    std.debug.print("Default Model: {s}\n", .{config.agents.defaults.model});

    // Display provider status
    std.debug.print("\nProviders:\n", .{});
    std.debug.print("  OpenRouter: {s}\n", .{if (config.providers.openrouter != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  Anthropic:  {s}\n", .{if (config.providers.anthropic != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  OpenAI:     {s}\n", .{if (config.providers.openai != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  Groq:       {s}\n", .{if (config.providers.groq != null) "✅ Configured" else "❌ Not set"});

    // Display channel status
    std.debug.print("\nChannels:\n", .{});
    std.debug.print("  Telegram:   {s}\n", .{if (config.tools.telegram != null) "✅ Enabled" else "❌ Disabled"});
    std.debug.print("  Discord:    {s}\n", .{if (config.tools.discord != null) "✅ Enabled" else "❌ Disabled"});
    std.debug.print("  WhatsApp:   {s}\n", .{if (config.tools.whatsapp != null) "✅ Enabled" else "❌ Disabled"});

    // Display data directory
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);
    std.debug.print("\nData Directory: {s}\n", .{bots_dir});

    // Check and display cron jobs
    const cron_path = try std.fs.path.join(allocator, &.{ bots_dir, "cron_jobs.json" });
    defer allocator.free(cron_path);
    var store = satibot.agent.cron.CronStore.init(allocator);
    defer store.deinit();
    store.load(cron_path) catch {};
    std.debug.print("Cron Jobs:      {d} active\n", .{store.jobs.items.len});

    std.debug.print("------------------------\n", .{});
}

/// Validate configuration based on model type
/// Checks if required API keys are available for the selected model
fn validateConfig(config: satibot.config.Config) !void {
    const model = config.agents.defaults.model;
    // Check for Claude models (require Anthropic API key)
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

/// Self-upgrade function
/// Performs git pull to fetch latest changes and rebuilds the project
fn runUpgrade(allocator: std.mem.Allocator) !void {
    std.debug.print("Checking for updates...\n", .{});

    // 1. git pull - fetch latest changes
    const git_argv = &[_][]const u8{ "git", "pull" };
    var git_proc = std.process.Child.init(git_argv, allocator);
    git_proc.stdout_behavior = .Inherit;
    git_proc.stderr_behavior = .Inherit;

    const term = try git_proc.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Error: git pull failed with code {d}\n", .{code});
                return error.GitPullFailed;
            }
        },
        else => {
            std.debug.print("Error: git pull terminated abnormally\n", .{});
            return error.GitPullFailed;
        },
    }

    std.debug.print("Building new version...\n", .{});

    // 2. zig build -Doptimize=ReleaseSafe - rebuild project
    const build_argv = &[_][]const u8{ "zig", "build", "-Doptimize=ReleaseSafe" };
    var build_proc = std.process.Child.init(build_argv, allocator);
    build_proc.stdout_behavior = .Inherit;
    build_proc.stderr_behavior = .Inherit;

    const build_term = try build_proc.spawnAndWait();
    switch (build_term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Error: build failed with code {d}\n", .{code});
                return error.BuildFailed;
            }
        },
        else => {
            std.debug.print("Error: build terminated abnormally\n", .{});
            return error.BuildFailed;
        },
    }

    std.debug.print("✅ Upgrade complete! Restart satibot to use the new version.\n", .{});
}

/// Auto-create WhatsApp configuration file
/// Creates ~/.bots/whatsapp.json with default template if it doesn't exist
fn autoCreateWhatsAppConfig(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);

    // Create ~/.bots directory if needed
    std.fs.makeDirAbsolute(bots_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ bots_dir, "whatsapp.json" });
    defer allocator.free(config_path);

    // Check if config already exists
    var config_exists = true;
    std.fs.accessAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            config_exists = false;
        } else {
            return err;
        }
    };

    if (!config_exists) {
        // Create default WhatsApp configuration
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        const default_json =
            \\{
            \\  "agents": {
            \\    "defaults": {
            \\      "model": "anthropic/claude-3-5-sonnet-20241022"
            \\    }
            \\  },
            \\  "providers": {
            \\    "openrouter": {
            \\      "apiKey": "sk-or-v1-..."
            \\    }
            \\  },
            \\  "tools": {
            \\    "web": {
            \\      "search": {
            \\        "apiKey": "BSA..."
            \\      }
            \\    },
            \\    "whatsapp": {
            \\      "accessToken": "YOUR_ACCESS_TOKEN_HERE",
            \\      "phoneNumberId": "YOUR_PHONE_NUMBER_ID_HERE",
            \\      "recipientPhoneNumber": "YOUR_PHONE_NUMBER_HERE"
            \\    }
            \\  }
            \\}
        ;
        try file.writeAll(default_json);
        std.debug.print("✅ Created WhatsApp config at {s}\n", .{config_path});
        std.debug.print("📋 Please edit the file and add your Meta API credentials:\n", .{});
        std.debug.print("   1. accessToken - Your Meta WhatsApp API token\n", .{});
        std.debug.print("   2. phoneNumberId - Your WhatsApp phone number ID\n", .{});
        std.debug.print("   3. recipientPhoneNumber - Your test phone number\n", .{});
    } else {
        std.debug.print("⚠️ WhatsApp config already exists at {s}\n", .{config_path});
    }
}

/// Auto-create Telegram configuration file
/// Creates ~/.bots/config.json with Telegram settings if it doesn't exist
fn autoCreateTelegramConfig(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);

    // Create ~/.bots directory if needed
    std.fs.makeDirAbsolute(bots_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ bots_dir, "config.json" });
    defer allocator.free(config_path);

    // Check if config already exists
    var config_exists = true;
    std.fs.accessAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            config_exists = false;
        } else {
            return err;
        }
    };

    if (!config_exists) {
        // Create default Telegram configuration
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        const default_json =
            \\{
            \\  "agents": {
            \\    "defaults": {
            \\      "model": "anthropic/claude-3-5-sonnet-20241022"
            \\    }
            \\  },
            \\  "providers": {
            \\    "openrouter": {
            \\      "apiKey": "sk-or-v1-..."
            \\    }
            \\  },
            \\  "tools": {
            \\    "web": {
            \\      "search": {
            \\        "apiKey": "BSA..."
            \\      }
            \\    },
            \\    "telegram": {
            \\      "botToken": "YOUR_BOT_TOKEN_HERE",
            \\      "chatId": "YOUR_CHAT_ID_HERE"
            \\    }
            \\  }
            \\}
        ;
        try file.writeAll(default_json);
        std.debug.print("✅ Created Telegram config at {s}\n", .{config_path});
        std.debug.print("📋 Please edit the file and add your Telegram credentials:\n", .{});
        std.debug.print("   1. botToken - Get this from @BotFather\n", .{});
        std.debug.print("   2. chatId - Get this from @userinfobot\n", .{});
    } else {
        std.debug.print("⚠️ Config already exists at {s}\n", .{config_path});
    }
}
