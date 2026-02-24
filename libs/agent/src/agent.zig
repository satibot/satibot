const std = @import("std");
pub const Config = @import("core").config.Config;
const bot_definition = @import("core").bot_definition;
const context = @import("agent/context.zig");
const tools = @import("agent/tools.zig");
const providers = @import("providers");
const openrouter = providers.openrouter;
const anthropic = providers.anthropic;
const base = providers.base;
const OpenRouterError = openrouter.OpenRouterError;
const db = @import("db");
const session = db.session;
const local_embeddings = db.local_embeddings;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;

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
    rag_enabled: bool,
    bot_definition: bot_definition.BotDefinition,
    on_chunk: ?base.ChunkCallback = null,
    chunk_ctx: ?*anyopaque = null,
    last_chunk: ?[]const u8 = null,
    /// Optional shutdown flag to check during long-running operations
    shutdown_flag: ?*const std.atomic.Value(bool) = null,
    /// Stores the last error message from provider for display to user
    last_error: ?[]const u8 = null,
    has_system_prompt: bool = false,
    /// Observability observer for tracking events and metrics
    observer: Observer,
    /// Start time for tracking agent duration
    agent_start_time: i64 = 0,

    /// Initialize a new Agent with configuration and session ID.
    /// Loads conversation history from session if available.
    /// Registers all default tools automatically.
    pub fn init(allocator: std.mem.Allocator, config: Config, session_id: []const u8, rag_enabled: bool) !Agent {
        var noop_obs: observability.NoopObserver = .{};
        return initWithObserver(allocator, config, session_id, rag_enabled, noop_obs.observer());
    }

    /// Initialize a new Agent with custom observer.
    pub fn initWithObserver(allocator: std.mem.Allocator, config: Config, session_id: []const u8, rag_enabled: bool, observer: Observer) !Agent {
        const bot_def = bot_definition.load(allocator);

        var self: Agent = .{
            .config = config,
            .allocator = allocator,
            .ctx = context.Context.init(allocator),
            .registry = tools.ToolRegistry.init(allocator),
            .session_id = session_id,
            .rag_enabled = rag_enabled,
            .bot_definition = bot_def,
            .last_error = null,
            .observer = observer,
        };

        // Load session history into context if enabled
        if (config.agents.defaults.loadChatHistory) {
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

                // Limit the number of messages to load based on maxChatHistory
                const max_messages = config.agents.defaults.maxChatHistory;
                const start_idx = if (history.len > max_messages) history.len - max_messages else 0;
                const limited_history = history[start_idx..];

                std.debug.print("--- Loading {d} of {d} available chat history messages (maxChatHistory: {d}) ---\n", .{ limited_history.len, history.len, max_messages });

                // Add loaded messages to context (context.addMessage creates deep copies)
                for (limited_history) |msg| {
                    self.ctx.addMessage(msg) catch |err| {
                        std.log.err("Failed to load message into context: {any}", .{err});
                    };
                }
            } else |_| {
                std.debug.print("Chat history loading is enabled, but no existing session found for '{s}'\n", .{session_id});
            }
        } else {
            std.debug.print("Chat history loading is disabled in configuration\n", .{});
        }

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
        // Only register vector tools when RAG is enabled
        if (self.rag_enabled) {
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
        }

        // Register file reading tool
        @constCast(&self.registry).register(.{
            .name = "read_file",
            .description = "Read contents of a local file. Arguments: {\"path\": \"/path/to/file.txt\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}, \"required\": [\"path\"]}",
            .execute = tools.readFile,
        }) catch |err| {
            std.log.err("Failed to register read_file tool: {any}", .{err});
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
        if (self.has_system_prompt) return;

        for (self.ctx.getMessages()) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                self.has_system_prompt = true;
                return;
            }
        }

        var prompt_builder: std.ArrayList(u8) = .empty;
        defer prompt_builder.deinit(self.allocator);

        if (self.bot_definition.soul) |soul| {
            try prompt_builder.appendSlice(self.allocator, soul);
        }

        if (self.bot_definition.user) |user| {
            try prompt_builder.appendSlice(self.allocator, user);
        }

        if (self.bot_definition.memory) |memory| {
            try prompt_builder.appendSlice(self.allocator, memory);
        }

        // Only add vector database prompts when RAG is enabled
        if (self.rag_enabled) {
            try prompt_builder.appendSlice(self.allocator, "You can access to a local Vector Database where you can store and retrieve information from past conversations.\nUse 'vector_search' or 'rag_search' when the user asks about something you might have discussed before or when you want confirm any knowledge from previous talk.\nUse 'vector_upsert' to remember important facts or details the user shares.\nYou can also read, write, and list files in the current directory if needed.\n");
        } else {
            try prompt_builder.appendSlice(self.allocator, "You can read, write, and list files in the current directory if needed.\n");
        }

        if (self.config.tools.web.search.apiKey) |key| {
            if (key.len > 0) {
                try prompt_builder.appendSlice(self.allocator, "Use 'web_search' for current events or information you don't have.\n");
            }
        }

        try self.ctx.addMessage(.{ .role = "system", .content = prompt_builder.items });
        self.has_system_prompt = true;
    }

    pub fn deinit(self: *Agent) void {
        bot_definition.deinit(self.allocator, &self.bot_definition);
        self.ctx.deinit();
        self.registry.deinit();
        if (self.last_chunk) |chunk| self.allocator.free(chunk);
        if (self.last_error) |err| self.allocator.free(err);
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
        var provider = try openrouter.OpenRouterProvider.init(allocator, api_key);
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

        var subagent = try Agent.init(ctx.allocator, ctx.config, sub_session_id, true);
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
        self.agent_start_time = std.time.milliTimestamp();

        // Record agent start event
        const provider_name: []const u8 = if (self.config.providers.openrouter != null) "openrouter" else "unknown";
        const start_event: ObserverEvent = .{ .agent_start = .{
            .provider = provider_name,
            .model = model,
        } };
        self.observer.recordEvent(&start_event);

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
                        return anthropic.createInterface();
                    } else {
                        return openrouter.createInterface();
                    }
                }
            }.call;

            const provider_interface = getProviderInterface(model);

            // Record LLM request event
            const timer_start = std.time.milliTimestamp();
            const req_event: ObserverEvent = .{ .llm_request = .{
                .provider = "openrouter",
                .model = model,
                .messages_count = filtered_messages.items.len,
            } };
            self.observer.recordEvent(&req_event);

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
                // Record failed LLM response event
                const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - timer_start));
                const fail_event: ObserverEvent = .{ .llm_response = .{
                    .provider = "openrouter",
                    .model = model,
                    .duration_ms = duration_ms,
                    .success = false,
                    .error_message = @errorName(err),
                } };
                self.observer.recordEvent(&fail_event);

                // Capture error message for display to user
                const err_msg = switch (err) {
                    error.NetworkRetryFailed => "Service unavailable after multiple retries",
                    error.NoApiKey => "No API key configured",
                    OpenRouterError.RateLimitExceeded => "[OpenRouter] API request failed with status 429 (Rate Limit Exceeded)",
                    else => @errorName(err),
                };
                self.last_error = self.allocator.dupe(u8, err_msg) catch null;
                return err;
            };

            std.debug.print("\n", .{});
            defer response.deinit();

            // Record successful LLM response event
            const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - timer_start));
            const resp_event: ObserverEvent = .{ .llm_response = .{
                .provider = "openrouter",
                .model = model,
                .duration_ms = duration_ms,
                .success = true,
                .error_message = null,
            } };
            self.observer.recordEvent(&resp_event);

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

                    // Record tool start event
                    const tool_start_event: ObserverEvent = .{ .tool_call_start = .{ .tool = call.function.name } };
                    self.observer.recordEvent(&tool_start_event);

                    const tool_timer_start = std.time.milliTimestamp();

                    if (self.registry.get(call.function.name)) |tool| {
                        const result = tool.execute(tool_ctx, call.function.arguments) catch |err| {
                            // Record tool failure event
                            const tool_duration: u64 = @intCast(@max(0, std.time.milliTimestamp() - tool_timer_start));
                            const tool_fail_event: ObserverEvent = .{ .tool_call = .{
                                .tool = call.function.name,
                                .duration_ms = tool_duration,
                                .success = false,
                            } };
                            self.observer.recordEvent(&tool_fail_event);

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

                        // Record tool success event
                        const tool_duration: u64 = @intCast(@max(0, std.time.milliTimestamp() - tool_timer_start));
                        const tool_event: ObserverEvent = .{ .tool_call = .{
                            .tool = call.function.name,
                            .duration_ms = tool_duration,
                            .success = true,
                        } };
                        self.observer.recordEvent(&tool_event);

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
            // Record turn complete event
            const complete_event: ObserverEvent = .{ .turn_complete = {} };
            self.observer.recordEvent(&complete_event);

            break;
        }

        try session.save(self.allocator, self.session_id, self.ctx.getMessages());

        // Record agent end event
        const duration_ms: u64 = if (self.agent_start_time > 0)
            @intCast(std.time.milliTimestamp() - self.agent_start_time)
        else
            0;
        const end_event: ObserverEvent = .{ .agent_end = .{
            .duration_ms = duration_ms,
            .tokens_used = null,
        } };
        self.observer.recordEvent(&end_event);
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

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
    defer agent.deinit();

    // Check that vector tools are registered when RAG is enabled
    try std.testing.expect(agent.registry.get("vector_upsert") != null);
    try std.testing.expect(agent.registry.get("vector_search") != null);

    // Check that read_file tool is always registered
    const read_file_tool = agent.registry.get("read_file");
    try std.testing.expect(read_file_tool != null);
    try std.testing.expectEqualStrings("read_file", read_file_tool.?.name);
    try std.testing.expectEqualStrings("Read contents of a local file. Arguments: {\"path\": \"/path/to/file.txt\"}", read_file_tool.?.description);
}

test "Agent: read_file tool registration without RAG" {
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

    // Initialize agent with RAG disabled
    var agent = try Agent.init(allocator, parsed.value, "test-session", false);
    defer agent.deinit();

    // Vector tools should not be registered when RAG is disabled
    try std.testing.expect(agent.registry.get("vector_upsert") == null);
    try std.testing.expect(agent.registry.get("vector_search") == null);

    // But read_file tool should still be registered
    const read_file_tool = agent.registry.get("read_file");
    try std.testing.expect(read_file_tool != null);
    try std.testing.expectEqualStrings("read_file", read_file_tool.?.name);
    try std.testing.expectEqualStrings("Read contents of a local file. Arguments: {\"path\": \"/path/to/file.txt\"}", read_file_tool.?.description);
    try std.testing.expectEqualStrings("{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}, \"required\": [\"path\"]}", read_file_tool.?.parameters);
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

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
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

test "Agent: RAG flag system prompt generation" {
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

    // Test with RAG enabled
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-enabled", true);
        defer agent.deinit();

        try agent.ensureSystemPrompt();
        const messages = agent.ctx.getMessages();
        try std.testing.expect(messages.len == 1);
        try std.testing.expectEqualStrings("system", messages[0].role);

        const content = messages[0].content.?;
        try std.testing.expect(std.mem.indexOf(u8, content, "Vector Database") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "vector_search") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "vector_upsert") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "read, write, and list files") != null);
    }

    // Test with RAG disabled
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-disabled", false);
        defer agent.deinit();

        try agent.ensureSystemPrompt();
        const messages = agent.ctx.getMessages();
        try std.testing.expect(messages.len == 1);
        try std.testing.expectEqualStrings("system", messages[0].role);

        const content = messages[0].content.?;
        try std.testing.expect(std.mem.indexOf(u8, content, "Vector Database") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "vector_search") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "vector_upsert") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "read, write, and list files") != null);
    }
}

test "Agent: RAG flag with web search" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "test-api-key" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test with RAG enabled and web search
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-web-enabled", true);
        defer agent.deinit();

        try agent.ensureSystemPrompt();
        const messages = agent.ctx.getMessages();
        try std.testing.expect(messages.len == 1);

        const content = messages[0].content.?;
        try std.testing.expect(std.mem.indexOf(u8, content, "Vector Database") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "web_search") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "read, write, and list files") != null);
    }

    // Test with RAG disabled but web search enabled
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-disabled-web-enabled", false);
        defer agent.deinit();

        try agent.ensureSystemPrompt();
        const messages = agent.ctx.getMessages();
        try std.testing.expect(messages.len == 1);

        const content = messages[0].content.?;
        try std.testing.expect(std.mem.indexOf(u8, content, "Vector Database") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "web_search") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "read, write, and list files") != null);
    }
}

test "Agent: rag_enabled field initialization" {
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

    // Test with RAG enabled
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-field-true", true);
        defer agent.deinit();
        try std.testing.expect(agent.rag_enabled == true);
    }

    // Test with RAG disabled
    {
        var agent = try Agent.init(allocator, parsed.value, "test-rag-field-false", false);
        defer agent.deinit();
        try std.testing.expect(agent.rag_enabled == false);
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

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
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

test "Agent: loadChatHistory disabled" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "loadChatHistory": false
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const test_session_id = "test-session-no-history";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    // Should start with empty context (no system prompt yet, no loaded history)
    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
}

test "Agent: loadChatHistory enabled with no existing session" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "loadChatHistory": true
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const test_session_id = "test-session-nonexistent";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    // Should start with empty context (no existing session to load)
    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
}

test "Agent: maxChatHistory limits loaded messages" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "loadChatHistory": true,
        \\      "maxChatHistory": 2
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test that maxChatHistory is parsed correctly
    try std.testing.expect(parsed.value.agents.defaults.maxChatHistory == 2);

    const test_session_id = "test-session-max-history";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    // Should start with empty context (no existing session to load)
    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
}

test "Agent: maxChatHistory default value" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "loadChatHistory": true
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test that maxChatHistory defaults to 2 when not specified
    try std.testing.expect(parsed.value.agents.defaults.maxChatHistory == 2);

    const test_session_id = "test-session-default-max";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
}

test "Agent: maxChatHistory custom value" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model",
        \\      "loadChatHistory": true,
        \\      "maxChatHistory": 5
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test that custom maxChatHistory value is parsed correctly
    try std.testing.expect(parsed.value.agents.defaults.maxChatHistory == 5);

    const test_session_id = "test-session-custom-max";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
}

test "Agent: loadChatHistory default behavior" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model"
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Test that default is false (no loadChatHistory field specified)
    try std.testing.expect(parsed.value.agents.defaults.loadChatHistory == false);

    const test_session_id = "test-session-default";
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    // Should start with empty context (default is disabled)
    const messages = agent.ctx.getMessages();
    try std.testing.expect(messages.len == 0);
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
    var agent = try Agent.init(allocator, parsed.value, test_session_id, true);
    defer agent.deinit();

    try std.testing.expectEqualStrings(test_session_id, agent.session_id);
}

test "Agent.init: creates agent with default configuration" {
    const allocator = std.testing.allocator;

    const config: Config = .{
        .agents = .{
            .defaults = .{
                .model = "test-model",
                .embeddingModel = null,
                .disableRag = false,
                .loadChatHistory = false,
                .maxChatHistory = 2,
            },
        },
        .providers = .{
            .openrouter = null,
            .anthropic = null,
            .openai = null,
            .groq = null,
        },
        .tools = .{
            .web = .{
                .search = .{ .apiKey = null },
                .server = null,
            },
            .telegram = null,
            .discord = null,
            .whatsapp = null,
        },
    };

    var agent = try Agent.init(allocator, config, "test-session", false);
    defer agent.deinit();

    try std.testing.expect(std.mem.eql(u8, agent.session_id, "test-session"));
    try std.testing.expect(agent.rag_enabled == false);
    try std.testing.expect(agent.has_system_prompt == false);
    try std.testing.expect(agent.last_error == null);
    try std.testing.expect(agent.last_chunk == null);
    try std.testing.expect(agent.shutdown_flag == null);
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

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
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

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
    defer agent.deinit();

    try agent.ctx.addMessage(.{ .role = "user", .content = "What is Zig?" });

    // This should return immediately and not fail even if dependencies are missing,
    // because it checks the flag first.
    try agent.indexConversation();
}

test "Agent: last_error field initialization and handling" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model"
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
    defer agent.deinit();

    // Test that last_error is initialized to null
    try std.testing.expect(agent.last_error == null);

    // Test that we can set last_error
    const error_msg = "Test error message";
    agent.last_error = try allocator.dupe(u8, error_msg);

    try std.testing.expect(agent.last_error != null);
    try std.testing.expectEqualStrings(error_msg, agent.last_error.?);
}

test "Agent: last_error field is preserved during operations" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model"
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);
    defer agent.deinit();

    // Set an error message
    const error_msg = "Preserved error message";
    agent.last_error = try allocator.dupe(u8, error_msg);

    // Add a message to context (this should not clear last_error)
    try agent.ctx.addMessage(.{ .role = "user", .content = "Test message" });

    // Verify last_error is still preserved
    try std.testing.expect(agent.last_error != null);
    try std.testing.expectEqualStrings(error_msg, agent.last_error.?);
}

test "Agent: last_error field cleanup on deinit" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { 
        \\    "defaults": { 
        \\      "model": "test-model"
        \\    } 
        \\  },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var agent = try Agent.init(allocator, parsed.value, "test-session", true);

    // Set an error message
    const error_msg = "Error to be cleaned up";
    agent.last_error = try allocator.dupe(u8, error_msg);

    try std.testing.expect(agent.last_error != null);

    // Deinit should clean up the last_error memory
    agent.deinit();

    // If we reach here without memory leaks, cleanup worked properly
}

/// Calculate memory usage of a context
fn calculateContextMemoryUsage(ctx: *context.Context) usize {
    var total: usize = 0;
    const context_messages = ctx.getMessages();

    for (context_messages) |msg| {
        total += msg.role.len;
        if (msg.content) |c| total += c.len;
        if (msg.tool_call_id) |id| total += id.len;
        if (msg.tool_calls) |calls| {
            for (calls) |call| {
                total += call.id.len;
                total += call.type.len;
                total += call.function.name.len;
                total += call.function.arguments.len;
            }
        }
    }

    // Add ArrayList overhead
    total += context_messages.len * @sizeOf(base.LlmMessage);

    return total;
}

test "Chat memory: Context memory increases with more messages" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Measure initial memory
    const initial_memory = calculateContextMemoryUsage(&ctx);
    std.debug.print("Initial context memory: {d} bytes\n", .{initial_memory});

    // Add first message
    try ctx.addMessage(.{ .role = "user", .content = "Hello" });
    const after_first = calculateContextMemoryUsage(&ctx);
    std.debug.print("After first message: {d} bytes (+{d})\n", .{ after_first, after_first - initial_memory });

    // Add second message
    try ctx.addMessage(.{ .role = "assistant", .content = "Hi there! How can I help you today?" });
    const after_second = calculateContextMemoryUsage(&ctx);
    std.debug.print("After second message: {d} bytes (+{d})\n", .{ after_second, after_second - after_first });

    // Add third message with longer content
    try ctx.addMessage(.{ .role = "user", .content = "I need help with understanding memory management in Zig programming language. Can you explain how memory allocation works, especially with allocators, and what are the best practices for avoiding memory leaks?" });
    const after_third = calculateContextMemoryUsage(&ctx);
    std.debug.print("After third message: {d} bytes (+{d})\n", .{ after_third, after_third - after_second });

    // Verify memory increases with each message
    try std.testing.expect(after_first > initial_memory);
    try std.testing.expect(after_second > after_first);
    try std.testing.expect(after_third > after_second);

    // Verify proportional growth - longer message should use more memory
    const first_increment = after_first - initial_memory;
    const third_increment = after_third - after_second;
    try std.testing.expect(third_increment > first_increment);
}

test "Chat memory: Agent memory usage during conversation simulation" {
    const allocator = std.testing.allocator;

    // Create a minimal config for testing
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": { "apiKey": "dummy" } } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const session_id = "memory-test-session";
    var agent = try Agent.init(allocator, parsed.value, session_id, true);
    defer agent.deinit();

    // Measure initial agent memory (context + registry)
    const initial_context_memory = calculateContextMemoryUsage(&agent.ctx);
    std.debug.print("Initial agent context memory: {d} bytes\n", .{initial_context_memory});

    // Simulate adding messages to context (without actually running LLM)
    const conversation = [_]struct { role: []const u8, content: []const u8 }{
        .{ .role = "user", .content = "Hello" },
        .{ .role = "assistant", .content = "Hi there!" },
        .{ .role = "user", .content = "How are you?" },
        .{ .role = "assistant", .content = "I'm doing well, thanks for asking!" },
        .{ .role = "user", .content = "Can you help me with something?" },
        .{ .role = "assistant", .content = "Of course! I'm here to help. What do you need assistance with?" },
    };

    var previous_memory = initial_context_memory;
    for (conversation, 0..) |turn, i| {
        try agent.ctx.addMessage(.{ .role = turn.role, .content = turn.content });
        const current_memory = calculateContextMemoryUsage(&agent.ctx);
        const increment = current_memory - previous_memory;

        std.debug.print("After turn {d} ({s}): {d} bytes (+{d})\n", .{ i + 1, turn.role, current_memory, increment });

        // Memory should increase with each message
        try std.testing.expect(current_memory > previous_memory);
        previous_memory = current_memory;
    }

    // Verify total growth
    const final_memory = calculateContextMemoryUsage(&agent.ctx);
    const total_growth = final_memory - initial_context_memory;
    std.debug.print("Total memory growth: {d} bytes\n", .{total_growth});

    try std.testing.expect(total_growth > 0);
}

test "Chat memory: Tool calls memory overhead" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Add a message without tool calls
    try ctx.addMessage(.{ .role = "assistant", .content = "I'll help you with that." });
    const without_tools = calculateContextMemoryUsage(&ctx);

    // Add a message with tool calls
    const tool_calls = &[_]base.ToolCall{
        .{ .id = "call_1", .type = "function", .function = .{ .name = "vector_search", .arguments = "{\"query\": \"memory management\", \"top_k\": 5}" } },
        .{ .id = "call_2", .type = "function", .function = .{ .name = "vector_upsert", .arguments = "{\"text\": \"Memory management is important in Zig\"}" } },
    };

    try ctx.addMessage(.{
        .role = "assistant",
        .content = "Let me search for information and remember this.",
        .tool_calls = tool_calls,
    });
    const with_tools = calculateContextMemoryUsage(&ctx);

    std.debug.print("Message without tools: {d} bytes\n", .{without_tools});
    std.debug.print("Message with tools: {d} bytes\n", .{with_tools});
    std.debug.print("Tool calls overhead: {d} bytes\n", .{with_tools - without_tools});

    // Tool calls should add significant memory overhead
    try std.testing.expect(with_tools > without_tools);
    const tool_overhead = with_tools - without_tools;
    try std.testing.expect(tool_overhead > 100); // At least 100 bytes for tool call data
}

test "Chat memory: Memory leak detection - proper cleanup" {
    const allocator = std.testing.allocator;

    // Test that Context properly cleans up all memory
    {
        var ctx = context.Context.init(allocator);

        // Add many messages with various content
        for (0..100) |i| {
            const content = try std.fmt.allocPrint(allocator, "Message {d} with some content to allocate memory", .{i});
            defer allocator.free(content);

            try ctx.addMessage(.{ .role = if (i % 2 == 0) "user" else "assistant", .content = content });
        }

        const before_cleanup = calculateContextMemoryUsage(&ctx);
        std.debug.print("Before cleanup: {d} bytes\n", .{before_cleanup});

        // Context.deinit() should free all memory
        ctx.deinit();
        // After deinit, we can't measure memory since ctx is undefined
    }

    // If we reach here without memory leaks detected by the test allocator,
    // the cleanup is working properly
}

test "Chat memory: Large message memory impact" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    // Create a large message (simulating a long conversation or code)
    var large_content = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
    defer large_content.deinit(allocator);

    try large_content.appendSlice(allocator, "This is a large message containing multiple lines.\n");
    for (0..1000) |i| {
        try large_content.appendSlice(allocator, "Line ");
        try large_content.writer(allocator).print("{d}: This is some sample content to increase memory usage.\n", .{i});
    }

    const initial_memory = calculateContextMemoryUsage(&ctx);

    // Add the large message
    try ctx.addMessage(.{ .role = "assistant", .content = large_content.items });

    const after_large = calculateContextMemoryUsage(&ctx);
    const large_increment = after_large - initial_memory;

    std.debug.print("Initial memory: {d} bytes\n", .{initial_memory});
    std.debug.print("After large message: {d} bytes\n", .{after_large});
    std.debug.print("Large message increment: {d} bytes\n", .{large_increment});

    // The increment should be approximately the size of the large content
    try std.testing.expect(large_increment > large_content.items.len - 100); // Allow some overhead
    try std.testing.expect(large_increment < large_content.items.len + 1000); // But not too much overhead
}

test "Chat memory: Memory growth pattern analysis" {
    const allocator = std.testing.allocator;
    var ctx = context.Context.init(allocator);
    defer ctx.deinit();

    var memory_measurements: [10]usize = undefined;
    var measurement_count: usize = 0;

    // Add messages and measure memory at each step
    const test_messages = [_][]const u8{
        "Hi",
        "Hello there!",
        "How are you doing today?",
        "I'm doing great, thanks for asking! How about you?",
        "I'm doing well too. I wanted to ask you about something.",
        "Sure, feel free to ask anything you'd like to know!",
        "Can you explain memory management in programming?",
        "Memory management is the process of controlling and coordinating computer memory, assigning portions called blocks to various running programs to optimize overall system performance.",
        "That's helpful. Can you give me a specific example?",
        "Certainly! In languages like C, you use malloc() to allocate memory and free() to deallocate it. In Zig, you use allocators that provide a more structured approach.",
    };

    for (test_messages) |content| {
        const role: []const u8 = if (measurement_count % 2 == 0) "user" else "assistant";
        try ctx.addMessage(.{ .role = role, .content = content });

        memory_measurements[measurement_count] = calculateContextMemoryUsage(&ctx);
        measurement_count += 1;
    }

    // Analyze growth pattern
    std.debug.print("Memory growth pattern:\n", .{});
    var previous_memory: usize = 0;
    for (memory_measurements[0..measurement_count], 0..) |memory, i| {
        const increment = if (i == 0) memory else memory - previous_memory;
        std.debug.print("  Message {d}: {d} bytes (+{d})\n", .{ i + 1, memory, increment });
        previous_memory = memory;
    }

    // Verify consistent growth pattern
    for (1..measurement_count) |i| {
        try std.testing.expect(memory_measurements[i] > memory_measurements[i - 1]);
    }

    // Calculate average growth per message
    const total_growth = memory_measurements[measurement_count - 1] - memory_measurements[0];
    const avg_growth = total_growth / (measurement_count - 1);
    std.debug.print("Average growth per message: {d} bytes\n", .{avg_growth});

    // Average growth should be reasonable (not too small, not too large)
    try std.testing.expect(avg_growth > 10); // At least 10 bytes per message
    try std.testing.expect(avg_growth < 1000); // But not excessively large
}
