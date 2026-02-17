const std = @import("std");
const Config = @import("config.zig").Config;
const context = @import("agent/context.zig");
const tools = @import("agent/tools.zig");
const providers = @import("root.zig");
const base = @import("providers/base.zig");
const OpenRouterError = @import("providers/openrouter.zig").OpenRouterError;
const session = @import("db/session.zig");
const opencode_control = @import("agent/opencode_control.zig");

/// Helper function to print streaming response chunks to stdout.
pub fn printChunk(ctx: ?*anyopaque, chunk: []const u8) void {
    _ = ctx;
    std.debug.print("{s}", .{chunk});
}

/// Agent specialized for OpenCode control.
pub const Agent = struct {
    config: Config,
    allocator: std.mem.Allocator,
    ctx: context.Context,
    registry: tools.ToolRegistry,
    session_id: []const u8,
    on_chunk: ?base.ChunkCallback = null,
    chunk_ctx: ?*anyopaque = null,
    last_chunk: ?[]const u8 = null,
    shutdown_flag: ?*const std.atomic.Value(bool) = null,
    last_error: ?[]const u8 = null,
    has_system_prompt: bool = false,

    /// Initialize a new OpenCode Agent.
    pub fn init(allocator: std.mem.Allocator, config: Config, session_id: []const u8) !Agent {
        var self: Agent = .{
            .config = config,
            .allocator = allocator,
            .ctx = context.Context.init(allocator),
            .registry = tools.ToolRegistry.init(allocator),
            .session_id = session_id,
            .last_error = null,
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

                const max_messages = config.agents.defaults.maxChatHistory;
                const start_idx = if (history.len > max_messages) history.len - max_messages else 0;
                const limited_history = history[start_idx..];

                std.debug.print("--- Loading {d} of {d} available chat history messages ---\n", .{ limited_history.len, history.len });

                for (limited_history) |msg| {
                    self.ctx.addMessage(msg) catch |err| {
                        std.log.err("Failed to load message into context: {any}", .{err});
                    };
                }
            } else |_| {
                // No history found, which is fine
            }
        }

        // Register OpenCode control tools
        if (opencode_control.OpenCodeControl.isAvailable()) {
            @constCast(&self.registry).register(.{
                .name = "opencode_send_message",
                .description = "Send a message to OpenCode and get response. Arguments: {\"message\": \"your message\"}",
                .parameters = "{\"type\": \"object\", \"properties\": {\"message\": {\"type\": \"string\"}}, \"required\": [\"message\"]}",
                .execute = struct {
                    fn exec(ctx: tools.ToolContext, args: []const u8) ![]const u8 {
                        const parsed = try std.json.parseFromSlice(struct { message: []const u8 }, ctx.allocator, args, .{});
                        defer parsed.deinit();

                        const opencode = opencode_control.OpenCodeControl.init(ctx.allocator);
                        return opencode.sendMessage(parsed.value.message);
                    }
                }.exec,
            }) catch |err| {
                std.log.err("Failed to register opencode_send_message tool: {any}", .{err});
            };

            @constCast(&self.registry).register(.{
                .name = "opencode_start_server",
                .description = "Start OpenCode server. Arguments: {\"port\": 3000}",
                .parameters = "{\"type\": \"object\", \"properties\": {\"port\": {\"type\": \"integer\"}}}",
                .execute = struct {
                    fn exec(ctx: tools.ToolContext, args: []const u8) ![]const u8 {
                        const parsed = try std.json.parseFromSlice(struct { port: ?u16 = null }, ctx.allocator, args, .{});
                        defer parsed.deinit();

                        const opencode = opencode_control.OpenCodeControl.init(ctx.allocator);
                        try opencode.startServer(parsed.value.port);
                        return try std.fmt.allocPrint(ctx.allocator, "OpenCode server started", .{});
                    }
                }.exec,
            }) catch |err| {
                std.log.err("Failed to register opencode_start_server tool: {any}", .{err});
            };
        } else {
            std.log.warn("OpenCode tools not available (opencode command not found)", .{});
        }

        return self;
    }

    /// Ensure a system prompt exists in the conversation context.
    pub fn ensureSystemPrompt(self: *Agent) !void {
        if (self.has_system_prompt) return;

        for (self.ctx.getMessages()) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) {
                self.has_system_prompt = true;
                return;
            }
        }

        const prompt = "You are an agent capable of controlling OpenCode. Use 'opencode_send_message' to interact with the environment and 'opencode_start_server' if needed to start the server.\n";
        try self.ctx.addMessage(.{ .role = "system", .content = prompt });
        self.has_system_prompt = true;
    }

    pub fn deinit(self: *Agent) void {
        self.ctx.deinit();
        self.registry.deinit();
        if (self.last_chunk) |chunk| self.allocator.free(chunk);
        if (self.last_error) |err| self.allocator.free(err);
        self.* = undefined;
    }

    // Dummy implementation as we don't support embeddings in this specialized agent
    fn getEmbeddings(allocator: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse {
        _ = allocator;
        _ = config;
        _ = input;
        return error.NotSupported;
    }

    fn spawnSubagent(ctx: tools.ToolContext, task: []const u8, label: []const u8) anyerror![]const u8 {
        _ = ctx;
        _ = task;
        _ = label;
        return error.NotSupported;
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

        // Track iteration results
        var iteration_results: std.ArrayList(?[]const u8) = .empty;
        defer {
            for (iteration_results.items) |result| {
                if (result) |r| self.allocator.free(r);
            }
            iteration_results.deinit(self.allocator);
        }

        // Collect tools
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
            if (self.shutdown_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    std.debug.print("\n🛑 Agent interrupted by shutdown signal\n", .{});
                    return error.Interrupted;
                }
            }

            std.debug.print("\n--- Iteration {d} ---\n", .{iterations + 1});

            var loop_warning: ?[]const u8 = null;
            defer if (loop_warning) |lw| self.allocator.free(lw);

            var filtered_messages: std.ArrayList(base.LlmMessage) = .empty;
            defer filtered_messages.deinit(self.allocator);
            for (self.ctx.getMessages()) |msg| {
                if (std.mem.eql(u8, msg.role, "assistant")) {
                    if (msg.content == null and (msg.tool_calls == null or msg.tool_calls.?.len == 0)) {
                        continue;
                    }
                }
                try filtered_messages.append(self.allocator, msg);
            }

            if (iterations > 1 and iteration_results.items.len > 0) {
                if (iteration_results.items[0]) |first_result| {
                    loop_warning = try std.fmt.allocPrint(
                        self.allocator,
                        "Note: You are on iteration {d}. Your first iteration response was: \"{s}\". Please review if you're making progress or stuck in a loop.",
                        .{ iterations + 1, first_result },
                    );

                    try filtered_messages.append(self.allocator, .{
                        .role = "system",
                        .content = loop_warning,
                    });
                }
            }

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

            try self.ctx.addMessage(.{
                .role = "assistant",
                .content = response.content,
                .tool_calls = response.tool_calls,
            });

            var iteration_content: ?[]const u8 = null;
            if (response.content) |content| {
                iteration_content = try self.allocator.dupe(u8, content);
            } else if (response.tool_calls) |calls| {
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
                continue;
            }

            break;
        }

        try session.save(self.allocator, self.session_id, self.ctx.getMessages());
    }
};

/// Validate OpenCode prompt - rejects special characters that could be dangerous
/// Returns error.InvalidPrompt if the prompt contains special characters
pub fn validateOpenCodePrompt(prompt: []const u8) !void {
    for (prompt) |byte| {
        switch (byte) {
            // Shell operators and dangerous characters
            '|',
            '&',
            ';',
            '$',
            '`',
            '\\',
            '"',
            '\'',
            '<',
            '>',
            '(',
            ')',
            '{',
            '}',
            '[',
            ']',
            '*',
            '~',
            '#',
            // Control characters
            '\n',
            '\r',
            '\t',
            '\x00',
            => {
                return error.InvalidPrompt;
            },
            else => {},
        }
    }
}

/// Send message to OpenCode and return the result
/// This is a core function that can be used by different interfaces (Telegram, CLI, etc.)
pub fn sendOpenCodeMessage(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    // Validate prompt - reject special characters
    try validateOpenCodePrompt(message);

    if (!opencode_control.OpenCodeControl.isAvailable()) {
        return error.OpenCodeNotAvailable;
    }

    var opencode = opencode_control.OpenCodeControl.init(allocator);
    return opencode.sendMessage(message);
}
