const std = @import("std");
const web = @import("web");
const agent = @import("agent");
const core = @import("core");
const memory = @import("memory");

var allow_origin: []const u8 = "*";
var memory_store: ?memory.memory.MemoryStore = null;

pub fn main() !void {
    // Allocates memory directly from the operating system using page mappings
    // Direct OS allocation avoids fragmentation issues
    // Suitable for long-running applications like web servers
    const allocator = std.heap.page_allocator;

    // Load configuration
    const parsed_config = try core.config.load(allocator);
    defer parsed_config.deinit();

    // Set CORS allow origin from config
    if (parsed_config.value.tools.web.server) |s| {
        if (s.allowOrigin) |origin| {
            allow_origin = origin;
        }
    }

    // Initialize memory store
    const home = std.posix.getenv("HOME") orelse ".";
    const memory_path = try std.fs.path.join(allocator, &.{ home, ".bots", "memory" });
    defer allocator.free(memory_path);
    memory_store = memory.memory.MemoryStore.init(allocator, memory_path);

    var server = web.Server.init(allocator, .{
        .host = "0.0.0.0",
        .port = 8080,
        .allow_origin = allow_origin,
    });
    defer server.deinit();

    server.on_request = handleRequest;

    std.log.info("Starting web server on http://localhost:8080", .{});

    try server.start();

    // Run event loop
    server.run();
}

fn handleRequest(req: web.zap.Request) anyerror!void {
    handleRequestInternal(req) catch |err| {
        std.log.err("Request handler error: {any}", .{err});
        req.sendJson("{\"error\":\"Internal Server Error\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    };
}

fn handleRequestInternal(req: web.zap.Request) anyerror!void {
    // Handle CORS preflight
    if (req.method) |method| {
        if (std.mem.eql(u8, method, "OPTIONS")) {
            req.setHeader("Access-Control-Allow-Origin", allow_origin) catch |e| {
                std.log.err("Failed to set CORS header: {any}", .{e});
            };
            req.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS") catch |e| {
                std.log.err("Failed to set CORS methods: {any}", .{e});
            };
            req.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization") catch |e| {
                std.log.err("Failed to set CORS headers: {any}", .{e});
            };
            req.setStatus(.no_content);
            return;
        }
    }

    req.setHeader("Access-Control-Allow-Origin", allow_origin) catch |e| {
        std.log.err("Failed to set CORS header: {any}", .{e});
    };

    if (req.path) |path| {
        if (std.mem.eql(u8, path, "/api/chat")) {
            return handleChat(req);
        }
        if (std.mem.eql(u8, path, "/api/memory")) {
            return handleMemoryList(req);
        }
        if (std.mem.eql(u8, path, "/api/system/ram")) {
            return handleSystemRam(req);
        }
        if (std.mem.eql(u8, path, "/api/config")) {
            if (req.method) |method| {
                if (std.mem.eql(u8, method, "GET")) {
                    return handleConfigGet(req);
                } else if (std.mem.eql(u8, method, "PUT")) {
                    return handleConfigUpdate(req);
                }
            }
        }
        if (std.mem.startsWith(u8, path, "/api/memory/")) {
            const id = path[12..];
            if (req.method) |method| {
                if (std.mem.eql(u8, method, "GET")) {
                    return handleMemoryGet(req, id);
                } else if (std.mem.eql(u8, method, "POST")) {
                    return handleMemoryCreate(req);
                } else if (std.mem.eql(u8, method, "PUT")) {
                    return handleMemoryUpdate(req, id);
                } else if (std.mem.eql(u8, method, "DELETE")) {
                    return handleMemoryDelete(req, id);
                }
            }
        }
        if (std.mem.eql(u8, path, "/openapi.json")) {
            return openapi.handleOpenApi(req);
        }
    }

    req.sendJson("{\"status\":\"ok\",\"message\":\"SatiBot API\"}") catch |err| {
        std.log.err("Failed to send response: {any}", .{err});
    };
}

fn handleChat(req: web.zap.Request) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("Handling chat request", .{});

    if (req.body) |body| {
        const ChatRequest = struct {
            messages: []agent.base.base.LlmMessage,
        };

        const parsed = std.json.parseFromSlice(ChatRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("Failed to parse chat request: {any}", .{err});
            req.sendJson("{\"error\":\"Invalid JSON\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        if (parsed.value.messages.len == 0) {
            req.sendJson("{\"error\":\"No messages provided\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        }

        const parsed_config = core.config.load(allocator) catch |err| {
            std.log.err("Failed to load config: {any}", .{err});
            req.sendJson("{\"error\":\"Configuration error\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        var config = parsed_config.value;
        config.agents.defaults.loadChatHistory = false;

        const session_id = "web-session";
        var bot = try agent.Agent.init(allocator, config, session_id, !config.agents.defaults.disableRag);
        defer bot.deinit();

        const messages = parsed.value.messages;
        const last_msg = messages[messages.len - 1];
        const history = messages[0 .. messages.len - 1];

        // Fill history
        for (history) |msg| {
            bot.ctx.addMessage(msg) catch |err| {
                std.log.err("Failed to add message: {any}", .{err});
            };
        }

        // Run agent with last message
        bot.run(last_msg.content orelse "") catch |err| {
            std.log.err("Agent run error: {any}", .{err});
            const err_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"Agent failed: {any}\"}}", .{err});
            req.sendJson(err_msg) catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        // Get last assistant message
        const bot_messages = bot.ctx.getMessages();
        if (bot_messages.len > 0) {
            const assistant_msg = bot_messages[bot_messages.len - 1];
            if (assistant_msg.content) |content| {
                var aw: std.io.Writer.Allocating = .init(allocator);
                defer aw.deinit();
                try std.json.Stringify.value(content, .{}, &aw.writer);
                const response_json = try std.fmt.allocPrint(allocator, "{{\"content\":{s}}}", .{aw.written()});
                req.sendJson(response_json) catch |e| {
                    std.log.err("Failed to send response: {any}", .{e});
                };
                return;
            }
        }

        req.sendJson("{\"error\":\"No response from agent\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    } else {
        req.sendJson("{\"error\":\"Empty body\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn handleMemoryList(req: web.zap.Request) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (memory_store) |*store| {
        const docs = store.list() catch |err| {
            std.log.err("Failed to list memory docs: {any}", .{err});
            req.sendJson("{\"error\":\"Failed to list docs\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };
        defer {
            for (docs) |doc| {
                allocator.free(doc.id);
                allocator.free(doc.title);
                allocator.free(doc.content);
            }
            allocator.free(docs);
        }

        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try std.json.Stringify.value(docs, .{}, &aw.writer);
        const response_json = try std.fmt.allocPrint(allocator, "{{\"docs\":{s}}}", .{aw.written()});
        req.sendJson(response_json) catch |e| {
            std.log.err("Failed to send response: {any}", .{e});
        };
    } else {
        req.sendJson("{\"error\":\"Memory store not initialized\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn handleMemoryGet(req: web.zap.Request, id: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (memory_store) |*store| {
        const doc = store.read(id) catch |err| {
            std.log.err("Failed to read memory doc: {any}", .{err});
            req.sendJson("{\"error\":\"Failed to read doc\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        if (doc) |d| {
            defer {
                allocator.free(d.id);
                allocator.free(d.title);
                allocator.free(d.content);
            }

            var aw: std.io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try std.json.Stringify.value(d, .{}, &aw.writer);
            const response_json = try std.fmt.allocPrint(allocator, "{{\"doc\":{s}}}", .{aw.written()});
            req.sendJson(response_json) catch |e| {
                std.log.err("Failed to send response: {any}", .{e});
            };
        } else {
            req.sendJson("{\"error\":\"Doc not found\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
        }
    } else {
        req.sendJson("{\"error\":\"Memory store not initialized\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn handleMemoryCreate(req: web.zap.Request) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (req.body) |body| {
        const CreateRequest = struct {
            title: []const u8,
            content: []const u8,
        };

        const parsed = std.json.parseFromSlice(CreateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("Failed to parse create request: {any}", .{err});
            req.sendJson("{\"error\":\"Invalid JSON\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        if (memory_store) |*store| {
            const doc = store.create(parsed.value.title, parsed.value.content) catch |err| {
                std.log.err("Failed to create memory doc: {any}", .{err});
                req.sendJson("{\"error\":\"Failed to create doc\"}") catch |e| {
                    std.log.err("Failed to send error response: {any}", .{e});
                };
                return;
            };

            defer {
                allocator.free(doc.id);
                allocator.free(doc.title);
                allocator.free(doc.content);
            }

            var aw: std.io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try std.json.Stringify.value(doc, .{}, &aw.writer);
            const response_json = try std.fmt.allocPrint(allocator, "{{\"doc\":{s}}}", .{aw.written()});
            req.sendJson(response_json) catch |e| {
                std.log.err("Failed to send response: {any}", .{e});
            };
        } else {
            req.sendJson("{\"error\":\"Memory store not initialized\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
        }
    } else {
        req.sendJson("{\"error\":\"Empty body\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn handleMemoryUpdate(req: web.zap.Request, id: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (req.body) |body| {
        const UpdateRequest = struct {
            title: ?[]const u8 = null,
            content: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(UpdateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("Failed to parse update request: {any}", .{err});
            req.sendJson("{\"error\":\"Invalid JSON\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        if (memory_store) |*store| {
            const doc = store.update(id, parsed.value.title, parsed.value.content) catch |err| {
                std.log.err("Failed to update memory doc: {any}", .{err});
                req.sendJson("{\"error\":\"Failed to update doc\"}") catch |e| {
                    std.log.err("Failed to send error response: {any}", .{e});
                };
                return;
            };

            if (doc) |d| {
                defer {
                    allocator.free(d.id);
                    allocator.free(d.title);
                    allocator.free(d.content);
                }

                var aw: std.io.Writer.Allocating = .init(allocator);
                defer aw.deinit();
                try std.json.Stringify.value(d, .{}, &aw.writer);
                const response_json = try std.fmt.allocPrint(allocator, "{{\"doc\":{s}}}", .{aw.written()});
                req.sendJson(response_json) catch |e| {
                    std.log.err("Failed to send response: {any}", .{e});
                };
            } else {
                req.sendJson("{\"error\":\"Doc not found\"}") catch |e| {
                    std.log.err("Failed to send error response: {any}", .{e});
                };
            }
        } else {
            req.sendJson("{\"error\":\"Memory store not initialized\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
        }
    } else {
        req.sendJson("{\"error\":\"Empty body\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn handleMemoryDelete(req: web.zap.Request, id: []const u8) anyerror!void {
    if (memory_store) |*store| {
        const deleted = store.delete(id) catch |err| {
            std.log.err("Failed to delete memory doc: {any}", .{err});
            req.sendJson("{\"error\":\"Failed to delete doc\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        if (deleted) {
            req.sendJson("{\"success\":true}") catch |e| {
                std.log.err("Failed to send response: {any}", .{e});
            };
        } else {
            req.sendJson("{\"error\":\"Doc not found\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
        }
    } else {
        req.sendJson("{\"error\":\"Memory store not initialized\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

// Get current process RAM usage
fn handleSystemRam(req: web.zap.Request) anyerror!void {
    const allocator = std.heap.c_allocator;

    // Get current process info - use platform-specific approach
    const pid = std.posix.getpid();

    // For macOS, use `ps` command to get memory info
    // For Linux, would read /proc/[pid]/status
    const ps_cmd = try std.fmt.allocPrint(allocator, "ps -o rss,vsz -p {d}", .{pid});
    defer allocator.free(ps_cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", ps_cmd },
    }) catch |err| {
        std.log.err("Failed to run ps command: {any}", .{err});
        req.sendJson("{\"error\":\"Failed to read process memory\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.stderr.len > 0) {
        std.log.err("ps command stderr: {s}", .{result.stderr});
    }

    // Parse ps output
    // Format: " RSS  VSZ\n1234 5678\n"
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    _ = lines.next(); // Skip header line

    var rss_kb: u64 = 0;
    var vsz_kb: u64 = 0;

    if (lines.next()) |data_line| {
        var parts = std.mem.tokenizeScalar(u8, data_line, ' ');
        if (parts.next()) |rss_str| {
            rss_kb = try std.fmt.parseInt(u64, std.mem.trim(u8, rss_str, " \t"), 10);
        }
        if (parts.next()) |vsz_str| {
            vsz_kb = try std.fmt.parseInt(u64, std.mem.trim(u8, vsz_str, " \t"), 10);
        }
    }

    // Convert KB to MB
    const used_mb = rss_kb / 1024;
    const total_mb = vsz_kb / 1024;
    const percentage = if (total_mb > 0) @as(u32, @intCast((used_mb * 100) / total_mb)) else 0;

    const response = try std.fmt.allocPrint(allocator, "{{" ++
        "\"used\":{d}," ++
        "\"total\":{d}," ++
        "\"percentage\":{d}," ++
        "\"timestamp\":{d}," ++
        "\"process\":\"sati\"" ++
        "}}", .{ used_mb, total_mb, percentage, std.time.timestamp() });
    defer allocator.free(response);

    req.sendJson(response) catch |e| {
        std.log.err("Failed to send RAM response: {any}", .{e});
    };
}

fn handleConfigGet(req: web.zap.Request) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_config = core.config.load(allocator) catch |err| {
        std.log.err("Failed to load config: {any}", .{err});
        req.sendJson("{\"error\":\"Failed to load config\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
        return;
    };
    defer parsed_config.deinit();

    const config = parsed_config.value;

    const sanitized: SanitizedConfig = .{
        .agents = .{
            .defaults = config.agents.defaults,
        },
        .providers = .{
            .openrouter = if (config.providers.openrouter) |_| .{} else null,
            .anthropic = if (config.providers.anthropic) |_| .{} else null,
            .openai = if (config.providers.openai) |_| .{} else null,
            .groq = if (config.providers.groq) |_| .{} else null,
            .minimax = if (config.providers.minimax) |_| .{} else null,
        },
        .tools = config.tools,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(sanitized, .{}, &aw.writer);
    const response_json = try std.fmt.allocPrint(allocator, "{{\"config\":{s}}}", .{aw.written()});
    req.sendJson(response_json) catch |e| {
        std.log.err("Failed to send config response: {any}", .{e});
    };
}

fn handleConfigUpdate(req: web.zap.Request) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (req.body) |body| {
        const parsed = std.json.parseFromSlice(core.config.Config, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("Failed to parse config update: {any}", .{err});
            req.sendJson("{\"error\":\"Invalid JSON\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        const existing_config = core.config.load(allocator) catch |err| {
            std.log.err("Failed to load existing config: {any}", .{err});
            core.config.save(allocator, parsed.value) catch |e| {
                std.log.err("Failed to save config: {any}", .{e});
                req.sendJson("{\"error\":\"Failed to save config\"}") catch |fe| {
                    std.log.err("Failed to send error response: {any}", .{fe});
                };
            };
            return;
        };
        defer existing_config.deinit();

        const merged = mergeConfig(existing_config.value, parsed.value);

        core.config.save(allocator, merged) catch |err| {
            std.log.err("Failed to save config: {any}", .{err});
            req.sendJson("{\"error\":\"Failed to save config\"}") catch |e| {
                std.log.err("Failed to send error response: {any}", .{e});
            };
            return;
        };

        req.sendJson("{\"success\":true}") catch |e| {
            std.log.err("Failed to send response: {any}", .{e});
        };
    } else {
        req.sendJson("{\"error\":\"Empty body\"}") catch |e| {
            std.log.err("Failed to send error response: {any}", .{e});
        };
    }
}

fn mergeConfig(existing: core.config.Config, update: core.config.Config) core.config.Config {
    return .{
        .agents = .{
            .defaults = if (update.agents.defaults.model.len > 0)
                update.agents.defaults
            else
                existing.agents.defaults,
        },
        .providers = .{
            .openrouter = mergeProvider(existing.providers.openrouter, update.providers.openrouter),
            .anthropic = mergeProvider(existing.providers.anthropic, update.providers.anthropic),
            .openai = mergeProvider(existing.providers.openai, update.providers.openai),
            .groq = mergeProvider(existing.providers.groq, update.providers.groq),
            .minimax = mergeProvider(existing.providers.minimax, update.providers.minimax),
        },
        .tools = .{
            .web = .{
                .search = .{
                    .apiKey = if (update.tools.web.search.apiKey) |key|
                        if (key.len > 0) key else existing.tools.web.search.apiKey
                    else
                        existing.tools.web.search.apiKey,
                },
                .server = update.tools.web.server,
            },
            .telegram = if (update.tools.telegram) |t| .{
                .botToken = if (t.botToken.len > 0) t.botToken else existing.tools.telegram.?.botToken,
                .chatId = t.chatId,
            } else existing.tools.telegram,
            .discord = if (update.tools.discord) |d| .{
                .webhookUrl = if (d.webhookUrl.len > 0) d.webhookUrl else existing.tools.discord.?.webhookUrl,
            } else existing.tools.discord,
            .whatsapp = if (update.tools.whatsapp) |w| .{
                .accessToken = if (w.accessToken.len > 0) w.accessToken else existing.tools.whatsapp.?.accessToken,
                .phoneNumberId = if (w.phoneNumberId.len > 0) w.phoneNumberId else existing.tools.whatsapp.?.phoneNumberId,
                .recipientPhoneNumber = w.recipientPhoneNumber,
            } else existing.tools.whatsapp,
        },
    };
}

fn mergeProvider(existing: ?core.config.ProviderConfig, update: ?core.config.ProviderConfig) ?core.config.ProviderConfig {
    if (update) |u| {
        if (u.apiKey.len > 0) {
            return u;
        }
    }
    return existing;
}

const SanitizedConfig = struct {
    agents: struct {
        defaults: core.config.DefaultAgentConfig,
    },
    providers: struct {
        openrouter: ?struct {} = null,
        anthropic: ?struct {} = null,
        openai: ?struct {} = null,
        groq: ?struct {} = null,
        minimax: ?struct {} = null,
    },
    tools: core.config.ToolsConfig,
};

const openapi = @import("openapi.zig");
