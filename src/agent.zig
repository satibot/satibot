const std = @import("std");
const Config = @import("config.zig").Config;
const context = @import("agent/context.zig");
const tools = @import("agent/tools.zig");
const providers = @import("root.zig").providers;
const base = @import("providers/base.zig");
const session = @import("agent/session.zig");

fn print_chunk(chunk: []const u8) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(&buf);
    writer.interface.writeAll(chunk) catch {};
    writer.interface.flush() catch {};
}

pub const Agent = struct {
    config: Config,
    allocator: std.mem.Allocator,
    ctx: context.Context,
    registry: tools.ToolRegistry,
    session_id: []const u8,

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

        return self;
    }

    pub fn deinit(self: *Agent) void {
        self.ctx.deinit();
        self.registry.deinit();
    }

    fn get_embeddings(allocator: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse {
        const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
            return error.NoApiKey;
        };
        var provider = providers.openrouter.OpenRouterProvider.init(allocator, api_key);
        defer provider.deinit();
        const emb_model = config.agents.defaults.embeddingModel orelse "openai/text-embedding-3-small";
        return try provider.embeddings(.{ .input = input, .model = emb_model });
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
        };

        while (iterations < max_iterations) : (iterations += 1) {
            std.debug.print("\n--- Iteration {d} ---\n", .{iterations + 1});

            var response: base.LLMResponse = undefined;
            if (use_anthropic) {
                const api_key = if (self.config.providers.anthropic) |p| p.apiKey else std.posix.getenv("ANTHROPIC_API_KEY") orelse {
                    std.debug.print("Error: ANTHROPIC_API_KEY or config.providers.anthropic.apiKey not set\n", .{});
                    return error.NoApiKey;
                };
                var provider = providers.anthropic.AnthropicProvider.init(self.allocator, api_key);
                defer provider.deinit();
                std.debug.print("AI (Anthropic): ", .{});
                response = try provider.chatStream(self.ctx.get_messages(), model, print_chunk);
            } else {
                const api_key = if (self.config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
                    std.debug.print("Error: OPENROUTER_API_KEY or config.providers.openrouter.apiKey not set\n", .{});
                    return error.NoApiKey;
                };
                var provider = providers.openrouter.OpenRouterProvider.init(self.allocator, api_key);
                defer provider.deinit();
                std.debug.print("AI (OpenRouter): ", .{});
                response = try provider.chatStream(self.ctx.get_messages(), model, print_chunk);
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
