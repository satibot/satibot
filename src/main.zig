const std = @import("std");
const satibot = @import("satibot");
const build_options = @import("build_options");

pub fn main() !void {
    std.debug.print("--- satibot 🐸 (build: {s}) ---\n", .{build_options.build_time_str});

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
        try runOnboard(allocator);
    } else if (std.mem.eql(u8, command, "test-llm")) {
        try runTestLlm(allocator);
    } else if (std.mem.eql(u8, command, "telegram")) {
        try runTelegramBot(allocator, args);
    } else if (std.mem.eql(u8, command, "gateway")) {
        try runGateway(allocator);
    } else if (std.mem.eql(u8, command, "vector-db")) {
        try runVectorDb(allocator, args);
    } else if (std.mem.eql(u8, command, "status")) {
        try runStatus(allocator);
    } else if (std.mem.eql(u8, command, "upgrade")) {
        try runUpgrade(allocator);
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
    std.debug.print("  gateway              Run Telegram bot, Cron, and Heartbeat collectively\n", .{});
    std.debug.print("  vector-db <cmd>    Test vector DB operations (list, search, add)\n", .{});
    std.debug.print("  status               Show system status\n", .{});
    std.debug.print("  onboard              Initialize configuration\n", .{});
    std.debug.print("  upgrade              Self-upgrade (git pull & rebuild)\n", .{});
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
        std.debug.print("Entering interactive mode. Type 'exit' or 'quit' to end.\n", .{});
        var agent = satibot.agent.Agent.init(allocator, config, session_id);
        defer agent.deinit();

        const stdin = std.fs.File.stdin();
        var buf: [4096]u8 = undefined;

        while (true) {
            std.debug.print("\n> ", .{});
            const n = try stdin.read(&buf);
            if (n == 0) break;

            const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

            agent.run(trimmed) catch |err| {
                std.debug.print("Error: {any}\n", .{err});
            };

            if (save_to_rag) {
                agent.index_conversation() catch |err| {
                    std.debug.print("Index Error: {any}\n", .{err});
                };
            }
        }
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

fn runGateway(allocator: std.mem.Allocator) !void {
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var g = try satibot.agent.gateway.Gateway.init(allocator, config);
    defer g.deinit();

    try g.run();
}

fn runOnboard(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);

    std.fs.makeDirAbsolute(bots_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ bots_dir, "config.json" });
    defer allocator.free(config_path);

    std.fs.accessAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
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
                \\    }
                \\  }
                \\}
            ;
            try file.writeAll(default_json);
            std.debug.print("✅ Created default config at {s}\n", .{config_path});
        }
    };

    const sessions_dir = try std.fs.path.join(allocator, &.{ bots_dir, "sessions" });
    defer allocator.free(sessions_dir);
    std.fs.makeDirAbsolute(sessions_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const heartbeat_path = try std.fs.path.join(allocator, &.{ bots_dir, "HEARTBEAT.md" });
    defer allocator.free(heartbeat_path);
    std.fs.accessAbsolute(heartbeat_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const file = try std.fs.createFileAbsolute(heartbeat_path, .{});
            defer file.close();
            try file.writeAll("# HEARTBEAT.md\n\nAdd tasks here for the agent to pick up periodically.\n");
            std.debug.print("✅ Created {s}\n", .{heartbeat_path});
        }
    };

    std.debug.print("🐸 satibot onboarding complete!\n", .{});
}

fn runUpgrade(allocator: std.mem.Allocator) !void {
    std.debug.print("Checking for updates...\n", .{});

    // 1. git pull
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

    // 2. zig build -Doptimize=ReleaseSafe
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

fn runVectorDb(allocator: std.mem.Allocator, args: [][:0]u8) !void {
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

    // Get DB path
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);
    const db_path = try std.fs.path.join(allocator, &.{ bots_dir, "vector_db.json" });
    defer allocator.free(db_path);

    var store = satibot.agent.vector_db.VectorStore.init(allocator);
    defer store.deinit();
    store.load(db_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Error loading vector DB: {any}\n", .{err});
            return err;
        }
    };

    if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("Vector DB Entries ({d} total):\n", .{store.entries.items.len});
        for (store.entries.items, 0..) |entry, i| {
            std.debug.print("{d}. {s}\n", .{ i + 1, entry.text });
            std.debug.print("   Embedding dims: {d}\n", .{entry.embedding.len});
        }
    } else if (std.mem.eql(u8, subcmd, "stats")) {
        std.debug.print("Vector DB Statistics:\n", .{});
        std.debug.print("  Total entries: {d}\n", .{store.entries.items.len});
        if (store.entries.items.len > 0) {
            std.debug.print("  Embedding dimension: {d}\n", .{store.entries.items[0].embedding.len});
        }
        std.debug.print("  DB path: {s}\n", .{db_path});
    } else if (std.mem.eql(u8, subcmd, "search")) {
        if (args.len < 4) {
            std.debug.print("Usage: satibot vector-db search <query> [top_k]\n", .{});
            return;
        }
        const query = args[3];
        var top_k: usize = 3;
        if (args.len >= 5) {
            top_k = try std.fmt.parseInt(usize, args[4], 10);
        }

        // Get embeddings for query
        const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
            std.debug.print("Error: OpenRouter API key not configured\n", .{});
            return error.NoApiKey;
        };

        var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
        defer provider.deinit();

        const emb_model = config.agents.defaults.embeddingModel orelse "openai/text-embedding-3-small";
        var resp = try provider.embeddings(.{ .input = &.{query}, .model = emb_model });
        defer resp.deinit();

        if (resp.embeddings.len == 0) {
            std.debug.print("Error: No embeddings generated\n", .{});
            return;
        }

        const results = try store.search(resp.embeddings[0], top_k);
        defer allocator.free(results);

        std.debug.print("Search Results for '{s}' ({d} items):\n", .{ query, results.len });
        for (results, 0..) |res, i| {
            std.debug.print("{d}. {s}\n", .{ i + 1, res.text });
        }
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (args.len < 4) {
            std.debug.print("Usage: satibot vector-db add <text>\n", .{});
            return;
        }
        // Combine all remaining args as text
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

        // Get embeddings
        const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
            std.debug.print("Error: OpenRouter API key not configured\n", .{});
            return error.NoApiKey;
        };

        var provider = try satibot.providers.openrouter.OpenRouterProvider.init(allocator, api_key);
        defer provider.deinit();

        const emb_model = config.agents.defaults.embeddingModel orelse "openai/text-embedding-3-small";
        var resp = try provider.embeddings(.{ .input = &.{text}, .model = emb_model });
        defer resp.deinit();

        if (resp.embeddings.len == 0) {
            std.debug.print("Error: No embeddings generated\n", .{});
            return;
        }

        try store.add(text, resp.embeddings[0]);
        try store.save(db_path);
        std.debug.print("Added to vector DB: {s}\n", .{text});
    } else {
        std.debug.print("Unknown vector-db command: {s}\n", .{subcmd});
    }
}

fn runStatus(allocator: std.mem.Allocator) !void {
    const parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    std.debug.print("\n--- satibot Status 🐸 ---\n", .{});
    std.debug.print("Default Model: {s}\n", .{config.agents.defaults.model});

    std.debug.print("\nProviders:\n", .{});
    std.debug.print("  OpenRouter: {s}\n", .{if (config.providers.openrouter != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  Anthropic:  {s}\n", .{if (config.providers.anthropic != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  OpenAI:     {s}\n", .{if (config.providers.openai != null) "✅ Configured" else "❌ Not set"});
    std.debug.print("  Groq:       {s}\n", .{if (config.providers.groq != null) "✅ Configured" else "❌ Not set"});

    std.debug.print("\nChannels:\n", .{});
    std.debug.print("  Telegram:   {s}\n", .{if (config.tools.telegram != null) "✅ Enabled" else "❌ Disabled"});
    std.debug.print("  Discord:    {s}\n", .{if (config.tools.discord != null) "✅ Enabled" else "❌ Disabled"});
    std.debug.print("  WhatsApp:   {s}\n", .{if (config.tools.whatsapp != null) "✅ Enabled" else "❌ Disabled"});

    const home = std.posix.getenv("HOME") orelse "/tmp";
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);
    std.debug.print("\nData Directory: {s}\n", .{bots_dir});

    // Check Cron jobs
    const cron_path = try std.fs.path.join(allocator, &.{ bots_dir, "cron_jobs.json" });
    defer allocator.free(cron_path);
    var store = satibot.agent.cron.CronStore.init(allocator);
    defer store.deinit();
    store.load(cron_path) catch {};
    std.debug.print("Cron Jobs:      {d} active\n", .{store.jobs.items.len});

    std.debug.print("------------------------\n", .{});
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
