const std = @import("std");
const web = @import("web");
const agent = @import("agent");
const core = @import("core");

var allow_origin: []const u8 = "*";

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
            req.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS") catch |e| {
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

const openapi = @import("openapi.zig");
