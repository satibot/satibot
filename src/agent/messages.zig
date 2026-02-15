/// Functional message processing module
/// Pure functions for processing messages without state mutation
const std = @import("std");
const Config = @import("../config.zig").Config;
const context = @import("context.zig");
const tools = @import("tools.zig");
const providers = @import("../root.zig");
const base = @import("../providers/base.zig");
const session = @import("../db/session.zig");

/// Message structure - pure data
pub const Message = struct {
    role: []const u8,
    content: ?[]const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
};

/// Tool call structure
pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

/// Session history - pure data structure
pub const SessionHistory = struct {
    messages: std.ArrayList(Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionHistory {
        return .{
            .messages = std.ArrayList(Message).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionHistory) void {
        // Free all message content
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    self.allocator.free(call.id);
                    self.allocator.free(call.type);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addMessage(self: *SessionHistory, msg: Message) !void {
        try self.messages.append(self.allocator, msg);
    }

    pub fn getMessages(self: *SessionHistory) []Message {
        return self.messages.items;
    }
};

/// Global tool registry - initialized once
var global_tools: ?tools.ToolRegistry = null;
var tools_initialized = false;

/// Get or initialize the global tool registry
fn getTools(allocator: std.mem.Allocator, config: Config) !*tools.ToolRegistry {
    _ = config; // Currently unused since only vector tools are registered
    if (!tools_initialized) {
        const registry = try allocator.create(tools.ToolRegistry);
        registry.* = tools.ToolRegistry.init(allocator);

        // Register all default tools
        // Only register vector tools - all other tools are commented out
        // try registry.register(.{
        //     .name = "list_files",
        //     .description = "List files in the current directory",
        //     .parameters = "{\"type\": \"object\", \"properties\": {}}",
        //     .execute = tools.list_files,
        // });
        // try registry.register(.{
        //     .name = "read_file",
        //     .description = "Read the contents of a file. Arguments: {\"path\": \"file.txt\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}}",
        //     .execute = tools.read_file,
        // });
        // try registry.register(.{
        //     .name = "write_file",
        //     .description = "Write content to a file. Arguments: {\"path\": \"file.txt\", \"content\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}, \"content\": {\"type\": \"string\"}}}",
        //     .execute = tools.write_file,
        // });
        // if (config.tools.web.search.apiKey) |key| {
        //     if (key.len > 0) {
        //         try registry.register(.{
        //             .name = "web_search",
        //             .description = "Search the web for information. Arguments: {\"query\": \"zig lang\"}",
        //             .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        //             .execute = tools.web_search,
        //         });
        //     }
        // }
        // try registry.register(.{
        //     .name = "list_marketplace",
        //     .description = "List all available skills in the agent-skills.md marketplace",
        //     .parameters = "{\"type\": \"object\", \"properties\": {}}",
        //     .execute = tools.list_marketplace_skills,
        // });
        // try registry.register(.{
        //     .name = "search_marketplace",
        //     .description = "Search for skills in the agent-skills.md marketplace. Arguments: {\"query\": \"notion\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        //     .execute = tools.search_marketplace_skills,
        // });
        // try registry.register(.{
        //     .name = "install_skill",
        //     .description = "Install a skill from the marketplace or a GitHub URL. Arguments: {\"skill_path\": \"futantan/agent-skills.md/skills/notion\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"skill_path\": {\"type\": \"string\"}}}",
        //     .execute = tools.install_skill,
        // });
        // try registry.register(.{
        //     .name = "telegram_send_message",
        //     .description = "Send a message to a Telegram chat. Arguments: {\"chat_id\": \"12345\", \"text\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"chat_id\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
        //     .execute = tools.telegram_send_message,
        // });
        // try registry.register(.{
        //     .name = "discord_send_message",
        //     .description = "Send a message to a Discord channel via webhook. Arguments: {\"content\": \"hello\", \"username\": \"bot\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"content\": {\"type\": \"string\"}, \"username\": {\"type\": \"string\"}}, \"required\": [\"content\"]}",
        //     .execute = tools.discord_send_message,
        // });
        // try registry.register(.{
        //     .name = "whatsapp_send_message",
        //     .description = "Send a WhatsApp message using Meta Cloud API. Arguments: {\"to\": \"1234567890\", \"text\": \"hello\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"to\": {\"type\": \"string\"}, \"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
        //     .execute = tools.whatsapp_send_message,
        // });
        try registry.register(.{
            .name = "vector_upsert",
            .description = "Add text to vector database for future retrieval. Arguments: {\"text\": \"content to remember\"}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
            .execute = tools.upsertVector,
        });
        try registry.register(.{
            .name = "vector_search",
            .description = "Search vector database for similar content. Arguments: {\"query\": \"search term\", \"top_k\": 3}",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}, \"top_k\": {\"type\": \"integer\"}}, \"required\": [\"query\"]}",
            .execute = tools.vectorSearch,
        });
        // Graph and cron tools are commented out
        // try registry.register(.{
        //     .name = "graph_upsert_node",
        //     .description = "Add a node to the graph database. Arguments: {\"id\": \"node_id\", \"label\": \"Person\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"id\", \"label\"]}",
        //     .execute = tools.graph_upsert_node,
        // });
        // try registry.register(.{
        //     .name = "graph_upsert_edge",
        //     .description = "Add an edge to the graph database. Arguments: {\"from\": \"node1\", \"to\": \"node2\", \"label\": \"knows\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"from\": {\"type\": \"string\"}, \"to\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"from\", \"to\", \"label\"]}",
        //     .execute = tools.graph_upsert_edge,
        // });
        // try registry.register(.{
        //     .name = "graph_query",
        //     .description = "Query the graph database. Arguments: {\"cypher\": \"MATCH (n) RETURN n\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"cypher\": {\"type\": \"string\"}}, \"required\": [\"cypher\"]}",
        //     .execute = tools.graph_query,
        // });
        // try registry.register(.{
        //     .name = "cron_add",
        //     .description = "Add a scheduled cron job. Arguments: {\"cron_expr\": \"0 9 * * *\", \"task\": \"Morning report\", \"label\": \"daily\"}",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"cron_expr\": {\"type\": \"string\"}, \"task\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"cron_expr\", \"task\"]}",
        //     .execute = tools.cron_add,
        // });
        // try registry.register(.{
        //     .name = "cron_list",
        //     .description = "List all scheduled cron jobs",
        //     .parameters = "{\"type\": \"object\", \"properties\": {}}",
        //     .execute = tools.cron_list,
        // });
        // try registry.register(.{
        //     .name = "cron_remove",
        //     .description = "Remove a scheduled cron job by ID",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}, \"required\": [\"id\"]}",
        //     .execute = tools.cron_remove,
        // });
        // try registry.register(.{
        //     .name = "subagent_spawn",
        //     .description = "Spawn a background subagent to handle a specific task.",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"task\": {\"type\": \"string\"}, \"label\": {\"type\": \"string\"}}, \"required\": [\"task\"]}",
        //     .execute = tools.subagent_spawn,
        // });
        // try registry.register(.{
        //     .name = "run_command",
        //     .description = "Execute a shell command. Use with caution.",
        //     .parameters = "{\"type\": \"object\", \"properties\": {\"command\": {\"type\": \"string\"}}, \"required\": [\"command\"]}",
        //     .execute = tools.run_command,
        // });

        global_tools = registry.*;
        tools_initialized = true;
    }

    return &global_tools.?;
}

/// Ensure a system prompt exists in the session history
fn ensureSystemPrompt(history: *SessionHistory, config: Config, rag_enabled: bool) !void {
    for (history.messages.items) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) return;
    }

    var prompt_builder: std.ArrayList(u8) = .empty;
    defer prompt_builder.deinit(history.allocator);

    // Always include file operations prompt
    try prompt_builder.appendSlice(history.allocator, "You can read, write, and list files in the current directory if needed.\n");

    // Add web search prompt if available
    if (config.tools.web.search.apiKey != null and config.tools.web.search.apiKey.?.len > 0) {
        try prompt_builder.appendSlice(history.allocator, "Use 'web_search' for current events or information you don't have.\n");
    }

    // Add vector database prompt if RAG is enabled
    if (rag_enabled) {
        try prompt_builder.appendSlice(history.allocator, "You can access to a local Vector Database where you can store and retrieve information from past conversations.\nUse 'vector_search' or 'rag_search' when the user asks about something you might have discussed before or when you want confirm any knowledge from previous talk.\nUse 'upsertVector' to remember important facts or details the user shares.\n");
    }

    try history.addMessage(.{
        .role = "system",
        .content = prompt_builder.items,
    });
}

/// Load session history from storage
fn loadSessionHistory(allocator: std.mem.Allocator, session_id: []const u8) !SessionHistory {
    var history = SessionHistory.init(allocator);

    if (session.load(allocator, session_id)) |loaded_messages| {
        for (loaded_messages) |msg| {
            const new_msg: Message = .{
                .role = msg.role,
                .content = msg.content,
                .tool_call_id = msg.tool_call_id,
                .tool_calls = if (msg.tool_calls) |calls| blk: {
                    const new_calls = try allocator.alloc(ToolCall, calls.len);
                    for (calls, 0..) |call, i| {
                        new_calls[i] = .{
                            .id = call.id,
                            .type = call.type,
                            .function = .{
                                .name = call.function.name,
                                .arguments = call.function.arguments,
                            },
                        };
                    }
                    break :blk new_calls;
                } else null,
            };
            try history.addMessage(new_msg);
        }

        allocator.free(loaded_messages);
    } else |_| {}

    return history;
}

/// Save session history to storage
fn saveSessionHistory(history: *SessionHistory, session_id: []const u8) !void {
    const allocator = history.allocator;

    const save_messages = try allocator.alloc(base.LlmMessage, history.messages.items.len);
    defer allocator.free(save_messages);

    for (history.messages.items, 0..) |msg, i| {
        save_messages[i] = .{
            .role = msg.role,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls = if (msg.tool_calls) |calls| blk: {
                const new_calls = try allocator.alloc(base.ToolCall, calls.len);
                for (calls, 0..) |call, j| {
                    new_calls[j] = .{
                        .id = call.id,
                        .type = if (call.type.len > 0) call.type else "function",
                        .function = .{
                            .name = call.function.name,
                            .arguments = call.function.arguments,
                        },
                    };
                }
                break :blk new_calls;
            } else null,
        };
    }

    session.save(allocator, session_id, save_messages) catch |err| {
        std.debug.print("Warning: Failed to save session: {any}\n", .{err});
    };
}

/// Process a message - pure functional approach
/// Returns the updated session history and response
pub fn processMessage(
    allocator: std.mem.Allocator,
    config: Config,
    session_id: []const u8,
    user_message: []const u8,
    rag_enabled: bool,
) !struct { history: SessionHistory, response: ?[]const u8, error_msg: ?[]const u8 } {
    // Load session history
    var history = try loadSessionHistory(allocator, session_id);
    errdefer history.deinit();

    // Ensure system prompt
    try ensureSystemPrompt(&history, config, rag_enabled);

    // Add user message
    const user_msg: Message = .{
        .role = "user",
        .content = user_message,
    };
    try history.addMessage(user_msg);

    // Get tools
    const tool_registry = try getTools(allocator, config);

    // Create a temporary context for LLM call
    var temp_ctx = context.Context.init(allocator);
    defer temp_ctx.deinit();

    // Copy messages to temp context
    for (history.messages.items) |msg| {
        try temp_ctx.addMessage(.{
            .role = msg.role,
            .content = msg.content,
            .tool_call_id = msg.tool_call_id,
            .tool_calls = if (msg.tool_calls) |calls| blk: {
                const new_calls = try allocator.alloc(base.ToolCall, calls.len);
                for (calls, 0..) |call, i| {
                    new_calls[i] = .{
                        .id = call.id,
                        .type = call.type,
                        .function = .{
                            .name = call.function.name,
                            .arguments = call.function.arguments,
                        },
                    };
                }
                break :blk new_calls;
            } else null,
        });
    }

    // Get provider interface and process with LLM
    const getProviderInterface = struct {
        fn call(model_name: []const u8) base.ProviderInterface {
            _ = model_name; // Default to OpenRouter for now
            return providers.openrouter.createInterface();
        }
    }.call;

    const provider_interface = getProviderInterface("openrouter");

    // Chunk callback to collect response
    var response_chunks: std.ArrayList(u8) = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
    defer response_chunks.deinit(allocator);

    const CallbackContext = struct {
        allocator: std.mem.Allocator,
        chunks: *std.ArrayList(u8),
    };

    var callback_ctx: CallbackContext = .{
        .allocator = allocator,
        .chunks = &response_chunks,
    };

    const chunk_callback = struct {
        fn call(ctx: ?*anyopaque, chunk: []const u8) void {
            const cb_ctx = @as(*CallbackContext, @ptrCast(@alignCast(ctx.?)));
            cb_ctx.chunks.appendSlice(cb_ctx.allocator, chunk) catch |err| {
                std.debug.print("Warning: Failed to append chunk: {any}\n", .{err});
            };
        }
    }.call;

    // Convert tool registry to expected format
    var provider_tools: std.ArrayList(base.ToolDefinition) = std.ArrayList(base.ToolDefinition).initCapacity(allocator, 10) catch unreachable;
    defer provider_tools.deinit(allocator);
    var tool_it = tool_registry.tools.iterator();
    while (tool_it.next()) |entry| {
        try provider_tools.append(allocator, .{
            .name = entry.value_ptr.name,
            .description = entry.value_ptr.description,
            .parameters = entry.value_ptr.parameters,
        });
    }

    const response = base.executeWithRetry(
        provider_interface,
        allocator,
        config,
        temp_ctx.getMessages(),
        "openrouter", // Default model
        provider_tools.items,
        chunk_callback,
        &callback_ctx,
    ) catch |err| {
        std.debug.print("Error processing message: {any}\n", .{err});
        const error_msg = try std.fmt.allocPrint(allocator, "❌ Error: Failed to process message\n\nPlease try again.", .{});
        return .{ .history = history, .response = null, .error_msg = error_msg };
    };
    defer @constCast(&response).deinit();

    // Add assistant response to history
    const assistant_msg: Message = .{
        .role = "assistant",
        .content = if (response.content) |c| try allocator.dupe(u8, c) else null,
    };
    try history.addMessage(assistant_msg);

    return .{ .history = history, .response = if (response.content) |c| try allocator.dupe(u8, c) else null, .error_msg = null };
}

/// Index conversation for RAG - pure function
pub fn indexConversation(history: *SessionHistory, session_id: []const u8) !void {
    // Simple implementation - save to session storage
    saveSessionHistory(history, session_id) catch |err| {
        std.debug.print("Warning: Failed to index conversation: {any}\n", .{err});
    };
}
