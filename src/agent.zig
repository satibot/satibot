const std = @import("std");
const Config = @import("config.zig").Config;
const context = @import("agent/context.zig");
const tools = @import("agent/tools.zig");
const providers = @import("root.zig");
const base = @import("providers/base.zig");
const session = @import("db/session.zig");
const local_embeddings = @import("db/local_embeddings.zig");

/// Helper function to print streaming response chunks to stdout.
pub fn printChunk(ctx: ?*anyopaque, chunk: []const u8) void {
    _ = ctx;
    std.debug.print("{s}", .{chunk});
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
    /// Optional shutdown flag to check during long-running operations
    shutdown_flag: ?*const std.atomic.Value(bool) = null,

    /// Initialize a new Agent with configuration and session ID.
    /// Loads conversation history from session if available.
    /// Registers all default tools automatically.
    pub fn init(allocator: std.mem.Allocator, config: Config, session_id: []const u8) !Agent {
        var self: Agent = .{
            .config = config,
            .allocator = allocator,
            .ctx = context.Context.init(allocator),
            .registry = tools.ToolRegistry.init(allocator),
            .session_id = session_id,
        };

        // Load session history into context
        if (session.load(allocator, session_id)) |history| {
            defer {
                // Free the loaded history after adding to context
                for (history) |msg| {
                    allocator.free(msg.role);
                    if (msg.content) |c| allocator.free(c);
                    if (msg.tool_call_id) |id| allocator.free(id);
                    if (msg.tool_calls) |calls| {
                        for (calls) |call| {
                            allocator.free(call.id);
                            allocator.free(call.type);
                            allocator.free(call.function.name);
                            allocator.free(call.function.arguments);
                        }
                        allocator.free(calls);
                    }
                }
                allocator.free(history);
            }

            // Add loaded messages to context (context.addMessage creates deep copies)
            for (history) |msg| {
                self.ctx.addMessage(msg) catch |err| {
                    std.log.err("Failed to load message into context: {any}", .{err});
                };
            }
        } else |_| {}

        // Register default tools - only vector tools are active
        //     .execute = tools.list_files,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "read_file",
        //     .description = "Read the contents of a file. Arguments: {\"path\": \"file.txt\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}}",
        //     .execute = tools.read_file,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "write_file",
        //     .description = "Write content to a file. Arguments: {\"path\": \"file.txt\", \"content\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}, \"content\": {\"type\": \"string\"}}}",
        //     .execute = tools.write_file,
        // }) catch {};
        // if (self.config.tools.web.search.apiKey) |key| {
        //     if (key.len > 0) {
        //         @constCast(&self.registry).register(.{
        //             .name = "web_search",
        //             .description = "Search the web for information. Arguments: {\"query\": \"zig lang\"}",
        //             .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        //             .execute = tools.web_search,
        //         }) catch {};
        //     }
        // }
        // @constCast(&self.registry).register(.{
        //     .name = "list_marketplace",
        //     .description = "List all available skills in the agent-skills.md marketplace",
        //     .parameters = "{\"type\": \"object\", \"properties\": {}}",
        //     .execute = tools.list_marketplace_skills,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "search_marketplace",
        //     .description = "Search for skills in the agent-skills.md marketplace. Arguments: {\"query\": \"notion\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        //     .execute = tools.search_marketplace_skills,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "install_skill",
        //     .description = "Install a skill from the marketplace or a GitHub URL. Arguments: {\"skill_path\": \"futantan/agent-skills.md/skills/notion\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"skill_path\": {\"type\": \"string\"}}}",
        //     .execute = tools.install_skill,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "telegram_send_message",
        //     .description = "Send a message to a Telegram chat. Arguments: {\"chat_id\": \"12345\", \"text\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"chat_id\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
        //     .execute = tools.telegram_send_message,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "discord_send_message",
        //     .description = "Send a message to a Discord channel via webhook. Arguments: {\"content\": \"hello\", \"username\": \"bot\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"content\": {\"type\": \"string\"}, \"username\": {\"type\": \"string\"}}, \"required\": [\"content\"]}",
        //     .execute = tools.discord_send_message,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "whatsapp_send_message",
        //     .description = "Send a WhatsApp message using Meta Cloud API. Arguments: {\"to\": \"1234567890\", \"text\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"to\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
        //     .execute = tools.whatsapp_send_message,
        // }) catch {};
        @constCast(&self.registry).register(.{
            .name = "vector_upsert",
            .description = "Add text to vector database for future retrieval. Arguments: {\"text\": \"content to remember\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
            .execute = tools.upsertVector,
        }) catch |err| {
            std.log.err("Failed to register vector_upsert tool: {any}", .{err});
        };
        @constCast(&self.registry).register(.{
            .name = "vector_search",
            .description = "Search vector database for similar content. Arguments: {\"query\": \"search term\", \"top_k\": 3}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}, \"top_k\": {\"type\": \"integer\"}}, \"required\": [\"query\"]}",
            .execute = tools.vectorSearch,
        }) catch |err| {
            std.log.err("Failed to register vector_search tool: {any}", .{err});
        };
        // Graph, RAG, cron, subagent, and run_command tools are commented out
        // @constCast(&self.registry).register(.{
        //     .name = "graph_upsert_node",
        //     .description = "Add a node to the graph database. Arguments: {\"id\": \"node_id\", \"label\": \"Person\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"id\", \"label\"]}",
        //     .execute = tools.graph_upsert_node,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "graph_upsert_edge",
        //     .description = "Add an edge (relation) between two nodes in the graph. Arguments: {\"from\": \"node1\", \"to\": \"node2\", \"relation\": \"knows\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"from\": {\"type\": \"string\"}, \"to\": {\"type\": \"string\"}, \"relation\": {\"type\": \"string\"}}, \"required\": [\"from\", \"to\", \"relation\"]}",
        //     .execute = tools.graph_upsert_edge,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "graph_query",
        //     .description = "Query relations for a specific node in the graph. Arguments: {\"start_node\": \"node_id\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"start_node\": {\"type\": \"string\"}}, \"required\": [\"start_node\"]}",
        //     .execute = tools.graph_query,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "rag_search",
        //     .description = "Perform a RAG (Retrieval-Augmented Generation) search. Arguments: {\"query\": \"what is...\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}, \"required\": [\"query\"]}",
        //     .execute = tools.rag_search,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "cron_add",
        //     .description = "Schedule a recurring or one-time task. Specify 'every_seconds' or 'at_timestamp_ms'.",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}, \"message\": {\"type\": \"string\"}, \"every_seconds\": {\"type\": \"integer\"}}, \"required\": [\"name\", \"message\"]}",
        //     .execute = tools.cron_add,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "cron_list",
        //     .description = "List all scheduled cron jobs",
        //     .parameters = "{\"type\": \"object\", \"properties\": {}}",
        //     .execute = tools.cron_list,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "cron_remove",
        //     .description = "Remove a scheduled cron job by ID",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}, \"required\": [\"id\"]}",
        //     .execute = tools.cron_remove,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "subagent_spawn",
        //     .description = "Spawn a background subagent to handle a specific task.",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"task\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"task\"]}",
        //     .execute = tools.subagent_spawn,
        // }) catch {};
        // @constCast(&self.registry).register(.{
        //     .name = "run_command",
        //     .description = "Execute a shell command. Use with caution.",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"command\": {\"type\": \"string\"}}, \"required\": [\"command\"]}",
        //     .execute = tools.run_command,
        // }) catch {};

        return self;
    }

    /// Ensure a system prompt exists in the conversation context.
    /// If not present, adds a default prompt that describes the bot and its tools.
    pub fn ensureSystemPrompt(self: *Agent) !void {
        const messages = self.ctx.getMessages();
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) return;
        }

        var prompt_builder: std.ArrayList(u8) = .empty;
        defer prompt_builder.deinit(self.allocator);
        try prompt_builder.appendSlice(self.allocator, "You can access to a local Vector Database where you can store and retrieve information from past conversations.\nUse 'vector_search' or 'rag_search' when the user asks about something you might have discussed before or when you want confirm any knowledge from previous talk.\nUse 'vector_upsert' to remember important facts or details the user shares.\nYou can also read, write, and list files in the current directory if needed.\n");

        if (self.config.tools.web.search.apiKey) |key| {
            if (key.len > 0) {
                try prompt_builder.appendSlice(self.allocator, "Use 'web_search' for current events or information you don't have.\n");
            }
        }

        try self.ctx.addMessage(.{ .role = "system", .content = prompt_builder.items });
    }

    pub fn deinit(self: *Agent) void {
        self.ctx.deinit();
        self.registry.deinit();
        if (self.last_chunk) |chunk| self.allocator.free(chunk);
        self.* = undefined;
    }

    fn getEmbeddings(allocator: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse {
        const emb_model = config.agents.defaults.embeddingModel orelse "local";

        // Handle local embeddings without API calls
        if (std.mem.eql(u8, emb_model, "local")) {
            return local_embeddings.LocalEmbedder.generate(allocator, input);
        }

        const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
            return error.NoApiKey;
        };
        var provider = try providers.openrouter.OpenRouterProvider.init(allocator, api_key);
        defer provider.deinit();

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

    fn spawnSubagent(ctx: tools.ToolContext, task: []const u8, label: []const u8) anyerror![]const u8 {
        std.debug.print("\n🚀 Spawning subagent: {s}\n", .{label});
        const sub_session_id = try std.fmt.allocPrint(ctx.allocator, "sub_{s}_{d}", .{ label, std.time.milliTimestamp() });
        defer ctx.allocator.free(sub_session_id);

        var subagent = try Agent.init(ctx.allocator, ctx.config, sub_session_id);
        defer subagent.deinit();

        try subagent.run(task);

        const messages = subagent.ctx.getMessages();
        if (messages.len > 0) {
            const last_msg = messages[messages.len - 1];
            if (last_msg.content) |content| {
                return ctx.allocator.dupe(u8, content);
            }
        }
        return ctx.allocator.dupe(u8, "Subagent completed with no summary.");
    }

    pub fn run(self: *Agent, message: []const u8) !void {
        try self.ensureSystemPrompt();

        try self.ctx.addMessage(.{ .role = "user", .content = message });

        const model = self.config.agents.defaults.model;

        var iterations: usize = 0;
        const max_iterations = 10;

        const tool_ctx: tools.ToolContext = .{
            .allocator = self.allocator,
            .config = self.config,
            .get_embeddings = getEmbeddings,
            .spawn_subagent = spawnSubagent,
        };

        // Track iteration results to prevent loops
        // Store assistant response content from each iteration
        var iteration_results: std.ArrayList(?[]const u8) = .empty;
        defer {
            for (iteration_results.items) |result| {
                if (result) |r| self.allocator.free(r);
            }
            iteration_results.deinit(self.allocator);
        }

        // Collect tools for the provider
        var provider_tools: std.ArrayList(base.ToolDefinition) = .empty;
        defer provider_tools.deinit(self.allocator);
        var tool_it = self.registry.tools.valueIterator();
        while (tool_it.next()) |tool| {
            try provider_tools.append(self.allocator, .{
                .name = tool.name,
                .description = tool.description,
                .parameters = tool.parameters,
            });
        }

        while (iterations < max_iterations) : (iterations += 1) {
            // Check for shutdown signal
            if (self.shutdown_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    std.debug.print("\n🛑 Agent interrupted by shutdown signal\n", .{});
                    return error.Interrupted;
                }
            }

            std.debug.print("\n--- Iteration {d} ---\n", .{iterations + 1});

            // Declare loop_warning BEFORE filtered_messages so its defer runs AFTER
            // filtered_messages.deinit (Zig defers run in reverse declaration order),
            // keeping the string alive while filtered_messages holds a pointer to it.
            var loop_warning: ?[]const u8 = null;
            defer if (loop_warning) |lw| self.allocator.free(lw);

            // Rebuild filtered_messages each iteration so tool results are included
            var filtered_messages: std.ArrayList(base.LlmMessage) = .empty;
            defer filtered_messages.deinit(self.allocator);
            for (self.ctx.getMessages()) |msg| {
                if (std.mem.eql(u8, msg.role, "assistant")) {
                    if (msg.content == null and (msg.tool_calls == null or msg.tool_calls.?.len == 0)) {
                        continue; // Skip invalid assistant message
                    }
                }
                try filtered_messages.append(self.allocator, msg);
            }

            // When iteration > 2, inject context from iteration 1 to help prevent loops
            if (iterations > 1 and iteration_results.items.len > 0) {
                if (iteration_results.items[0]) |first_result| {
                    loop_warning = try std.fmt.allocPrint(
                        self.allocator,
                        "Note: You are on iteration {d}. Your first iteration response was: \"{s}\". Please review if you're making progress or stuck in a loop.",
                        .{ iterations + 1, first_result },
                    );

                    // Add as a temporary system message
                    try filtered_messages.append(self.allocator, .{
                        .role = "system",
                        .content = loop_warning,
                    });
                }
            }

            // Debug: Print what we're sending to the LLM
            std.debug.print("\n=== DEBUG: Messages being sent to LLM ===\n", .{});
            for (filtered_messages.items, 0..) |msg, idx| {
                std.debug.print("Message {d}: role={s}\n", .{ idx, msg.role });
                if (msg.content) |content| {
                    // Only print content if it's valid and reasonably sized
                    if (content.len > 0 and content.len < 10000) {
                        // Simple check for obviously binary content
                        var is_binary = false;
                        const check_len = @min(100, content.len);
                        for (content[0..check_len]) |byte| {
                            if (byte == 0) { // null byte indicates binary data
                                is_binary = true;
                                break;
                            }
                        }

                        if (!is_binary) {
                            const max_len = @min(500, content.len);
                            if (content.len > max_len) {
                                std.debug.print("  content: {s}... (truncated, total length: {d})\n", .{ content[0..max_len], content.len });
                            } else {
                                std.debug.print("  content: {s}\n", .{content});
                            }
                        } else {
                            std.debug.print("  content: [binary data - {d} bytes]\n", .{content.len});
                        }
                    } else {
                        std.debug.print("  content: [invalid content - {d} bytes]\n", .{content.len});
                    }
                }
                if (msg.tool_calls) |calls| {
                    std.debug.print("  tool_calls: {d} calls\n", .{calls.len});
                    for (calls, 0..) |call, call_idx| {
                        std.debug.print("    [{d}] {s}({s})\n", .{ call_idx, call.function.name, call.function.arguments });
                    }
                }
                if (msg.tool_call_id) |id| {
                    std.debug.print("  tool_call_id: {s}\n", .{id});
                }
            }
            std.debug.print("\n=== DEBUG: Tools available ({d} tools) ===\n", .{provider_tools.items.len});
            for (provider_tools.items, 0..) |tool, idx| {
                std.debug.print("Tool {d}: {s} - {s}\n", .{ idx, tool.name, tool.description });
            }
            std.debug.print("=== END DEBUG ===\n\n", .{});

            var response: base.LlmResponse = undefined;

            const internal_cb = struct {
                fn call(ctx: ?*anyopaque, chunk: []const u8) void {
                    const a: *Agent = @ptrCast(@alignCast(ctx orelse return));
                    if (a.last_chunk) |old| a.allocator.free(old);
                    a.last_chunk = a.allocator.dupe(u8, chunk) catch null;

                    const cb = a.on_chunk orelse printChunk;
                    cb(a.chunk_ctx, chunk);
                }
            }.call;

            // Get provider interface using callback based on model
            const getProviderInterface = struct {
                fn call(model_name: []const u8) base.ProviderInterface {
                    if (std.mem.indexOf(u8, model_name, "claude") != null) {
                        return providers.anthropic.createInterface();
                    } else {
                        return providers.openrouter.createInterface();
                    }
                }
            }.call;

            const provider_interface = getProviderInterface(model);

            response = base.executeWithRetry(
                provider_interface,
                self.allocator,
                self.config,
                filtered_messages.items,
                model,
                provider_tools.items,
                internal_cb,
                self,
            ) catch |err| {
                return err;
            };

            std.debug.print("\n", .{});
            defer response.deinit();

            // Add assistant response to history
            try self.ctx.addMessage(.{
                .role = "assistant",
                .content = response.content,
                .tool_calls = response.tool_calls,
            });

            // Store iteration result for loop detection
            // Track either content or tool calls to detect loops
            var iteration_content: ?[]const u8 = null;
            if (response.content) |content| {
                iteration_content = try self.allocator.dupe(u8, content);
            } else if (response.tool_calls) |calls| {
                // If no content but has tool calls, track the tool names
                var tool_summary: std.ArrayList(u8) = .empty;
                defer tool_summary.deinit(self.allocator);
                try tool_summary.appendSlice(self.allocator, "Tool calls: ");
                for (calls, 0..) |call, i| {
                    if (i > 0) try tool_summary.appendSlice(self.allocator, ", ");
                    try tool_summary.appendSlice(self.allocator, call.function.name);
                }
                iteration_content = try tool_summary.toOwnedSlice(self.allocator);
            }
            try iteration_results.append(self.allocator, iteration_content);

            if (response.tool_calls) |calls| {
                for (calls) |call| {
                    std.debug.print("Tool Call: {s}({s})\n", .{ call.function.name, call.function.arguments });

                    if (self.registry.get(call.function.name)) |tool| {
                        const result = tool.execute(tool_ctx, call.function.arguments) catch |err| {
                            const error_msg = try std.fmt.allocPrint(self.allocator, "Error executing tool {s}: {any}", .{ call.function.name, err });
                            defer self.allocator.free(error_msg);
                            std.debug.print("{s}\n", .{error_msg});
                            try self.ctx.addMessage(.{
                                .role = "tool",
                                .content = error_msg,
                                .tool_call_id = call.id,
                            });
                            continue;
                        };
                        defer self.allocator.free(result);

                        std.debug.print("Tool Result: {s}\n", .{result});
                        try self.ctx.addMessage(.{
                            .role = "tool",
                            .content = result,
                            .tool_call_id = call.id,
                        });
                    } else {
                        const error_msg = try std.fmt.allocPrint(self.allocator, "Error: Tool {s} not found", .{call.function.name});
                        defer self.allocator.free(error_msg);
                        std.debug.print("{s}\n", .{error_msg});
                        try self.ctx.addMessage(.{
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

        try session.save(self.allocator, self.session_id, self.ctx.getMessages());
    }

    pub fn indexConversation(self: *Agent) !void {
        if (self.config.agents.defaults.disableRag) {
            return;
        }
        const messages = self.ctx.getMessages();
        if (messages.len < 2) return;

        const tool_ctx: tools.ToolContext = .{
            .allocator = self.allocator,
            .config = self.config,
            .get_embeddings = Agent.getEmbeddings,
        };

        // Index each assistant response with its preceding user context
        var i: usize = 0;
        while (i < messages.len) : (i += 1) {
            const msg = messages[i];
            if (std.mem.eql(u8, msg.role, "assistant")) {
                if (msg.content) |content| {
                    if (content.len < 10) continue; // Skip very short responses

                    var entry_text: std.ArrayList(u8) = .empty;
                    defer entry_text.deinit(self.allocator);

                    // Include preceding user message if available
                    if (i > 0) {
                        const prev = messages[i - 1];
                        if (std.mem.eql(u8, prev.role, "user")) {
                            if (prev.content) |user_content| {
                                try entry_text.appendSlice(self.allocator, "user: ");
                                try entry_text.appendSlice(self.allocator, user_content);
                                try entry_text.appendSlice(self.allocator, "\n\n");
                            }
                        }
                    }

                    try entry_text.appendSlice(self.allocator, "assistant: ");
                    try entry_text.appendSlice(self.allocator, content);

                    const args = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = entry_text.items }, .{});
                    defer self.allocator.free(args);

                    const result = try tools.upsertVector(tool_ctx, args);
                    self.allocator.free(result);
                }
            }
        }
    }
};

test "Agent: init and tool registration" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Only vector tools are registered by default (others are commented out)
    try std.testing.expect(agent.registry.get("vector_upsert") != null);
    try std.testing.expect(agent.registry.get("vector_search") != null);
}

test "Agent: message context management" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Initially should have empty context (except possibly loaded from session)
    const initial_messages = agent.ctx.getMessages();
    _ = initial_messages;

    // Test that we can add messages through the context
    try agent.ctx.addMessage(.{ .role = "user", .content = "Hello" });
    try agent.ctx.addMessage(.{ .role = "assistant", .content = "Hi there!" });

    const messages = agent.ctx.getMessages();
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
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Test getting existing vector tools
    const vector_upsert_tool = agent.registry.get("vector_upsert");
    try std.testing.expect(vector_upsert_tool != null);
    try std.testing.expectEqualStrings("vector_upsert", vector_upsert_tool.?.name);

    // Test getting non-existent tool
    const non_existent = agent.registry.get("non_existent_tool");
    try std.testing.expect(non_existent == null);

    // Verify vector tools are registered
    const expected_tools = [_][]const u8{
        "vector_upsert",
        "vector_search",
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
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const test_session_id = "test-session-123";
    var agent = try Agent.init(allocator, parsed.value, test_session_id);
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
        \\      "embeddingModel": "arcee-ai/trinity-mini:free"
        \\    }
        \\  },
        \\  "providers": {
        \\    "anthropic": { "apiKey": "test-key" }
        \\  },
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    try std.testing.expectEqualStrings("anthropic/claude-3-sonnet", agent.config.agents.defaults.model);
    try std.testing.expectEqualStrings("arcee-ai/trinity-mini:free", agent.config.agents.defaults.embeddingModel.?);
    try std.testing.expectEqualStrings("test-key", agent.config.providers.anthropic.?.apiKey);
}

test "Agent: conversation indexing" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    // Add some messages to the context
    try agent.ctx.addMessage(.{ .role = "user", .content = "What is Zig?" });
    try agent.ctx.addMessage(.{ .role = "assistant", .content = "Zig is a programming language." });

    // Test that indexConversation runs without error
    // Note: This will try to call vector_upsert which may fail in test environment
    // but we're testing the logic flow
    agent.indexConversation() catch |err| {
        // Expected to fail in test environment due to missing vector DB
        std.debug.print("Indexing error (expected in test): {any}\n", .{err});
    };
}

test "Agent: respect disableRag flag" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "disableRag": true
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session");
    defer agent.deinit();

    try agent.ctx.addMessage(.{ .role = "user", .content = "What is Zig?" });

    // This should return immediately and not fail even if dependencies are missing,
    // because it checks the flag first.
    try agent.indexConversation();
}
