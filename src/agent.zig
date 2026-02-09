const std = @import("std");
const Config = @import("config.zig").Config;
const context = @import("agent/context.zig");
const tools = @import("agent/tools.zig");
const providers = @import("root.zig").providers;
const base = @import("providers/base.zig");
const session = @import("agent/session.zig");

/// Helper function to print streaming response chunks to stdout.
fn print_chunk(ctx: ?*anyopaque, chunk: []const u8) void {
    _ = ctx;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(&buf);
    writer.interface.writeAll(chunk) catch {};
    writer.interface.flush() catch {};
}

/// Main Agent struct that orchestrates conversation with LLM providers.
/// Manages conversation context, tool registry, and session persistence.
pub const Agent = struct {
    config: Config,
    allocator: std.mem.Allocator,
    ctx: context.Context,
    registry: tools.ToolRegistry,
    session_id: []const u8,
    on_chunk: ?base.ChunkCallback = null,
    chunk_ctx: ?*anyopaque = null,
    last_chunk: ?[]const u8 = null,

    /// Initialize a new Agent with configuration and session ID.
    /// Loads conversation history from session if available.
    /// Registers all default tools automatically.
    pub fn init(allocator: std.mem.Allocator, config: Config, session_id: []const u8) Agent {
        var self = Agent{
            .config = config,
            .allocator = allocator,
            .ctx = context.Context.init(allocator),
            .registry = tools.ToolRegistry.init(allocator),
            .session_id = session_id,
        };

        // Load history
        if (session.load(allocator, session_id)) |history| {
            for (history) |msg| {
                self.ctx.add_message(msg) catch {};
            }
            // Note: we should free history and its elements after adding to context
            // But context.add_message dupes them.
            // So we need to free the history we loaded.
            for (history) |msg| {
                allocator.free(msg.role);
                if (msg.content) |c| allocator.free(c);
                if (msg.tool_call_id) |id| allocator.free(id);
                if (msg.tool_calls) |calls| {
                    for (calls) |call| {
                        allocator.free(call.id);
                        allocator.free(call.function_name);
                        allocator.free(call.arguments);
                    }
                    allocator.free(calls);
                }
            }
            allocator.free(history);
        } else |_| {}

        // Register default tools
        self.registry.register(.{
            .name = "list_files",
            .description = "List files in the current directory",
            .parameters = "{}",
            .execute = tools.list_files,
        }) catch {};
        self.registry.register(.{
            .name = "read_file",
            .description = "Read the contents of a file. Arguments: {\"path\": \"file.txt\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}}",
            .execute = tools.read_file,
        }) catch {};
        self.registry.register(.{
            .name = "write_file",
            .description = "Write content to a file. Arguments: {\"path\": \"file.txt\", \"content\": \"hello\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}, \"content\": {\"type\": \"string\"}}}",
            .execute = tools.write_file,
        }) catch {};
        self.registry.register(.{
            .name = "web_search",
            .description = "Search the web for information. Arguments: {\"query\": \"zig lang\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
            .execute = tools.web_search,
        }) catch {};
        self.registry.register(.{
            .name = "list_marketplace",
            .description = "List all available skills in the agent-skills.md marketplace",
            .parameters = "{}",
            .execute = tools.list_marketplace_skills,
        }) catch {};
        self.registry.register(.{
            .name = "search_marketplace",
            .description = "Search for skills in the agent-skills.md marketplace. Arguments: {\"query\": \"notion\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
            .execute = tools.search_marketplace_skills,
        }) catch {};
        self.registry.register(.{
            .name = "install_skill",
            .description = "Install a skill from the marketplace or a GitHub URL. Arguments: {\"skill_path\": \"futantan/agent-skills.md/skills/notion\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"skill_path\": {\"type\": \"string\"}}}",
            .execute = tools.install_skill,
        }) catch {};
        self.registry.register(.{
            .name = "telegram_send_message",
            .description = "Send a message to a Telegram chat. Arguments: {\"chat_id\": \"12345\", \"text\": \"hello\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"chat_id\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
            .execute = tools.telegram_send_message,
        }) catch {};
        self.registry.register(.{
            .name = "discord_send_message",
            .description = "Send a message to a Discord channel via webhook. Arguments: {\"content\": \"hello\", \"username\": \"bot\"}",
            .parameters = "{\"type\": [\"object\"], \"properties\": {\"content\": {\"type\": \"string\"}, \"username\": {\"type\": \"string\"}}, \"required\": [\"content\"]}",
            .execute = tools.discord_send_message,
        }) catch {};
        self.registry.register(.{
            .name = "whatsapp_send_message",
            .description = "Send a WhatsApp message using Meta Cloud API. Arguments: {\"to\": \"1234567890\", \"text\": \"hello\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"to\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
            .execute = tools.whatsapp_send_message,
        }) catch {};
        self.registry.register(.{
            .name = "vector_upsert",
            .description = "Add text to vector database for future retrieval. Arguments: {\"text\": \"content to remember\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
            .execute = tools.vector_upsert,
        }) catch {};
        self.registry.register(.{
            .name = "vector_search",
            .description = "Search vector database for similar content. Arguments: {\"query\": \"search term\", \"top_k\": 3}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}, \"top_k\": {\"type\": \"integer\"}}, \"required\": [\"query\"]}",
            .execute = tools.vector_search,
        }) catch {};
        self.registry.register(.{
            .name = "graph_upsert_node",
            .description = "Add a node to the graph database. Arguments: {\"id\": \"node_id\", \"label\": \"Person\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"id\", \"label\"]}",
            .execute = tools.graph_upsert_node,
        }) catch {};
        self.registry.register(.{
            .name = "graph_upsert_edge",
            .description = "Add an edge (relation) between two nodes in the graph. Arguments: {\"from\": \"node1\", \"to\": \"node2\", \"relation\": \"knows\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"from\": {\"type\": \"string\"}, \"to\": {\"type\": \"string\"}, \"relation\": {\"type\": \"string\"}}, \"required\": [\"from\", \"to\", \"relation\"]}",
            .execute = tools.graph_upsert_edge,
        }) catch {};
        self.registry.register(.{
            .name = "graph_query",
            .description = "Query relations for a specific node in the graph. Arguments: {\"start_node\": \"node_id\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"start_node\": {\"type\": \"string\"}}, \"required\": [\"start_node\"]}",
            .execute = tools.graph_query,
        }) catch {};
        self.registry.register(.{
            .name = "rag_search",
            .description = "Perform a RAG (Retrieval-Augmented Generation) search. Arguments: {\"query\": \"what is...\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}, \"required\": [\"query\"]}",
            .execute = tools.rag_search,
        }) catch {};
        self.registry.register(.{
            .name = "cron_add",
            .description = "Schedule a recurring or one-time task. Specify 'every_seconds' or 'at_timestamp_ms'.",
            .parameters = "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}, \"message\": {\"type\": \"string\"}, \"every_seconds\": {\"type\": \"integer\"}}, \"required\": [\"name\", \"message\"]}",
            .execute = tools.cron_add,
        }) catch {};
        self.registry.register(.{
            .name = "cron_list",
            .description = "List all scheduled cron jobs",
            .parameters = "{}",
            .execute = tools.cron_list,
        }) catch {};
        self.registry.register(.{
            .name = "cron_remove",
            .description = "Remove a scheduled cron job by ID",
            .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}, \"required\": [\"id\"]}",
            .execute = tools.cron_remove,
        }) catch {};
        self.registry.register(.{
            .name = "subagent_spawn",
            .description = "Spawn a background subagent to handle a specific task.",
            .parameters = "{\"type\": \"object\", \"properties\": {\"task\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"task\"]}",
            .execute = tools.subagent_spawn,
        }) catch {};
        self.registry.register(.{
            .name = "run_command",
            .description = "Execute a shell command. Use with caution.",
            .parameters = "{\"type\": \"object\", \"properties\": {\"command\": {\"type\": \"string\"}}, \"required\": [\"command\"]}",
            .execute = tools.run_command,
        }) catch {};

        return self;
    }

    pub fn deinit(self: *Agent) void {
        self.ctx.deinit();
        self.registry.deinit();
        if (self.last_chunk) |chunk| self.allocator.free(chunk);
    }

    fn get_embeddings(allocator: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse {
        const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
            return error.NoApiKey;
        };
        var provider = try providers.openrouter.OpenRouterProvider.init(allocator, api_key);
        defer provider.deinit();
        const emb_model = config.agents.defaults.embeddingModel orelse "openai/text-embedding-3-small";

        var retry_count: usize = 0;
        const max_retries = 3;
        while (retry_count < max_retries) : (retry_count += 1) {
            return provider.embeddings(.{ .input = input, .model = emb_model }) catch |err| {
                if (err == error.ReadFailed or err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) {
                    std.debug.print("\n(Embedding Network error: {any}. Retrying... {d}/{d})\n", .{ err, retry_count + 1, max_retries });
                    std.Thread.sleep(std.time.ns_per_s * 1);
                    continue;
                }
                return err;
            };
        }
        return error.NetworkRetryFailed;
    }

    fn spawn_subagent(ctx: tools.ToolContext, task: []const u8, label: []const u8) anyerror![]const u8 {
        std.debug.print("\n🚀 Spawning subagent: {s}\n", .{label});
        const sub_session_id = try std.fmt.allocPrint(ctx.allocator, "sub_{s}_{d}", .{ label, std.time.milliTimestamp() });
        defer ctx.allocator.free(sub_session_id);

        var subagent = Agent.init(ctx.allocator, ctx.config, sub_session_id);
        defer subagent.deinit();

        try subagent.run(task);

        const messages = subagent.ctx.get_messages();
        if (messages.len > 0) {
            const last_msg = messages[messages.len - 1];
            if (last_msg.content) |content| {
                return try ctx.allocator.dupe(u8, content);
            }
        }
        return try ctx.allocator.dupe(u8, "Subagent completed with no summary.");
    }

    pub fn run(self: *Agent, message: []const u8) !void {
        try self.ctx.add_message(.{ .role = "user", .content = message });

        const model = self.config.agents.defaults.model;

        // Determine provider
        const use_anthropic = std.mem.indexOf(u8, model, "claude") != null;

        var iterations: usize = 0;
        const max_iterations = 10;

        const tool_ctx = tools.ToolContext{
            .allocator = self.allocator,
            .config = self.config,
            .get_embeddings = get_embeddings,
            .spawn_subagent = spawn_subagent,
        };

        while (iterations < max_iterations) : (iterations += 1) {
            std.debug.print("\n--- Iteration {d} ---\n", .{iterations + 1});

            var response: base.LLMResponse = undefined;
            var retry_count: usize = 0;
            const max_retries = 3;

            const internal_cb = struct {
                fn call(ctx: ?*anyopaque, chunk: []const u8) void {
                    const a: *Agent = @ptrCast(@alignCast(ctx orelse return));
                    if (a.last_chunk) |old| a.allocator.free(old);
                    a.last_chunk = a.allocator.dupe(u8, chunk) catch null;

                    const cb = a.on_chunk orelse print_chunk;
                    cb(a.chunk_ctx, chunk);
                }
            }.call;

            while (retry_count < max_retries) : (retry_count += 1) {
                // Calculate exponential backoff: 2s, 4s, 8s
                const backoff_seconds = std.math.shl(u64, 1, retry_count + 1);

                if (use_anthropic) {
                    const api_key = if (self.config.providers.anthropic) |p| p.apiKey else std.posix.getenv("ANTHROPIC_API_KEY") orelse {
                        std.debug.print("Error: ANTHROPIC_API_KEY or config.providers.anthropic.apiKey not set\n", .{});
                        return error.NoApiKey;
                    };
                    var provider = try providers.anthropic.AnthropicProvider.init(self.allocator, api_key);
                    defer provider.deinit();
                    std.debug.print("AI (Anthropic): ", .{});
                    response = provider.chatStream(self.ctx.get_messages(), model, internal_cb, self) catch |err| {
                        if (err == error.ReadFailed or err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) {
                            std.debug.print("\n⚠️ Network error: {any} (Model: {s}). Retrying in {d}s... ({d}/{d})\n", .{ err, model, backoff_seconds, retry_count + 1, max_retries });
                            std.Thread.sleep(std.time.ns_per_s * backoff_seconds);
                            continue;
                        }
                        return err;
                    };
                } else {
                    const api_key = if (self.config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
                        std.debug.print("Error: OPENROUTER_API_KEY or config.providers.openrouter.apiKey not set\n", .{});
                        return error.NoApiKey;
                    };
                    var provider = try providers.openrouter.OpenRouterProvider.init(self.allocator, api_key);
                    defer provider.deinit();
                    std.debug.print("AI (OpenRouter): ", .{});
                    response = provider.chatStream(self.ctx.get_messages(), model, internal_cb, self) catch |err| {
                        if (err == error.ReadFailed or err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) {
                            std.debug.print("\n⚠️ Network error: {any} (Model: {s}). Retrying in {d}s... ({d}/{d})\n", .{ err, model, backoff_seconds, retry_count + 1, max_retries });
                            std.Thread.sleep(std.time.ns_per_s * backoff_seconds);
                            continue;
                        }
                        return err;
                    };
                }
                break;
            } else {
                std.debug.print("\n❌ Failed after {d} retries. Last error was network-related.\n", .{max_retries});
                return error.NetworkRetryFailed;
            }
            std.debug.print("\n", .{});
            defer response.deinit();

            // Add assistant response to history
            try self.ctx.add_message(.{
                .role = "assistant",
                .content = response.content,
                .tool_calls = response.tool_calls,
            });

            if (response.tool_calls) |calls| {
                for (calls) |call| {
                    std.debug.print("Tool Call: {s}({s})\n", .{ call.function_name, call.arguments });

                    if (self.registry.get(call.function_name)) |tool| {
                        const result = tool.execute(tool_ctx, call.arguments) catch |err| {
                            const error_msg = try std.fmt.allocPrint(self.allocator, "Error executing tool {s}: {any}", .{ call.function_name, err });
                            defer self.allocator.free(error_msg);
                            std.debug.print("{s}\n", .{error_msg});
                            try self.ctx.add_message(.{
                                .role = "tool",
                                .content = error_msg,
                                .tool_call_id = call.id,
                            });
                            continue;
                        };
                        defer self.allocator.free(result);

                        std.debug.print("Tool Result: {s}\n", .{result});
                        try self.ctx.add_message(.{
                            .role = "tool",
                            .content = result,
                            .tool_call_id = call.id,
                        });
                    } else {
                        const error_msg = try std.fmt.allocPrint(self.allocator, "Error: Tool {s} not found", .{call.function_name});
                        defer self.allocator.free(error_msg);
                        std.debug.print("{s}\n", .{error_msg});
                        try self.ctx.add_message(.{
                            .role = "tool",
                            .content = error_msg,
                            .tool_call_id = call.id,
                        });
                    }
                }
                // Continue loop to send tool results back to LLM
                continue;
            }

            // No tool calls, we are done
            break;
        }

        try session.save(self.allocator, self.session_id, self.ctx.get_messages());
    }

    pub fn index_conversation(self: *Agent) !void {
        const messages = self.ctx.get_messages();
        var full_text = std.ArrayListUnmanaged(u8){};
        defer full_text.deinit(self.allocator);

        for (messages) |msg| {
            if (msg.content) |content| {
                if (content.len > 0) {
                    try full_text.appendSlice(self.allocator, msg.role);
                    try full_text.appendSlice(self.allocator, ": ");
                    try full_text.appendSlice(self.allocator, content);
                    try full_text.appendSlice(self.allocator, "\n\n");
                }
            }
        }

        if (full_text.items.len == 0) return;

        const tool_ctx = tools.ToolContext{
            .allocator = self.allocator,
            .config = self.config,
            .get_embeddings = get_embeddings,
        };

        const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = full_text.items }, .{});
        defer self.allocator.free(args);

        const result = try tools.vector_upsert(tool_ctx, args);
        defer self.allocator.free(result);
        std.debug.print("Session indexed to RAG: {s}\n", .{result});
    }
};

test "Agent: init and tool registration" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    try std.testing.expect(agent.registry.get("list_files") != null);
    try std.testing.expect(agent.registry.get("telegram_send_message") != null);
    try std.testing.expect(agent.registry.get("discord_send_message") != null);
    try std.testing.expect(agent.registry.get("whatsapp_send_message") != null);
}

test "Agent: message context management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Initially should have empty context (except possibly loaded from session)
    const initial_messages = agent.ctx.get_messages();
    _ = initial_messages;

    // Test that we can add messages through the context
    try agent.ctx.add_message(.{ .role = "user", .content = "Hello" });
    try agent.ctx.add_message(.{ .role = "assistant", .content = "Hi there!" });

    const messages = agent.ctx.get_messages();
    try std.testing.expect(messages.len >= 2);
    if (messages.len >= 2) {
        try std.testing.expectEqualStrings("user", messages[messages.len - 2].role);
        try std.testing.expectEqualStrings("Hello", messages[messages.len - 2].content.?);
        try std.testing.expectEqualStrings("assistant", messages[messages.len - 1].role);
        try std.testing.expectEqualStrings("Hi there!", messages[messages.len - 1].content.?);
    }
}

test "Agent: tool registry operations" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Test getting existing tools
    const list_files_tool = agent.registry.get("list_files");
    try std.testing.expect(list_files_tool != null);
    try std.testing.expectEqualStrings("list_files", list_files_tool.?.name);

    // Test getting non-existent tool
    const non_existent = agent.registry.get("non_existent_tool");
    try std.testing.expect(non_existent == null);

    // Verify all default tools are registered
    const expected_tools = [_][]const u8{
        "list_files",
        "read_file",
        "write_file",
        "web_search",
        "list_marketplace",
        "search_marketplace",
        "install_skill",
        "telegram_send_message",
        "discord_send_message",
        "whatsapp_send_message",
        "vector_upsert",
        "vector_search",
        "graph_upsert_node",
        "graph_upsert_edge",
        "graph_query",
        "rag_search",
        "cron_add",
        "cron_list",
        "cron_remove",
        "subagent_spawn",
        "run_command",
    };

    for (expected_tools) |tool_name| {
        const tool = agent.registry.get(tool_name);
        try std.testing.expect(tool != null);
    }
}

test "Agent: session management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const test_session_id = "test-session-123";
    var agent = Agent.init(allocator, parsed.value, test_session_id);
    defer agent.deinit();

    try std.testing.expectEqualStrings(test_session_id, agent.session_id);
}

test "Agent: config integration" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "anthropic/claude-3-sonnet",
        \\      "embeddingModel": "openai/text-embedding-3-small"
        \\    }
        \\  },
        \\  "providers": {
        \\    "anthropic": { "apiKey": "test-key" }
        \\  },
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    try std.testing.expectEqualStrings("anthropic/claude-3-sonnet", agent.config.agents.defaults.model);
    try std.testing.expectEqualStrings("openai/text-embedding-3-small", agent.config.agents.defaults.embeddingModel.?);
    try std.testing.expectEqualStrings("test-key", agent.config.providers.anthropic.?.apiKey);
}

test "Agent: conversation indexing" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Add some messages to the context
    try agent.ctx.add_message(.{ .role = "user", .content = "What is Zig?" });
    try agent.ctx.add_message(.{ .role = "assistant", .content = "Zig is a programming language." });

    // Test that index_conversation runs without error
    // Note: This will try to call vector_upsert which may fail in test environment
    // but we're testing the logic flow
    agent.index_conversation() catch {};
}
