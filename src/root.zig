const std = @import("std");
pub const build_opts = @import("build_opts");
const whatsapp_bot_real = @import("agent/whatsapp_bot.zig");

pub const Agent = @import("agent.zig").Agent;
pub const context = @import("agent/context.zig");
pub const tools = @import("agent/tools.zig");
pub const session = @import("db/session.zig");
pub const vector_db = @import("db/vector_db.zig");
pub const local_embeddings = @import("db/local_embeddings.zig");
pub const graph_db = @import("db/graph_db.zig");
pub const console = @import("agent/console.zig");
pub const console_sync = @import("agent/console_sync.zig");
// chat apps
pub const telegram = @import("chat_apps/telegram/telegram.zig");
pub const telegram_handlers = @import("chat_apps/telegram/telegram_handlers.zig");
// agent
pub const telegram_bot_sync = @import("agent/telegram_bot_sync.zig");

const whatsapp_bot_impl = if (build_opts.include_whatsapp) whatsapp_bot_real else struct {
    pub const WhatsAppBot = struct {
        pub fn init(allocator: std.mem.Allocator, cfg: anytype) !void {
            _ = allocator;
            _ = cfg;
            return error.WhatsAppDisabled;
        }
        pub fn deinit(self: *WhatsAppBot) void {
            self.* = undefined;
        }
        pub fn run(allocator: std.mem.Allocator, cfg: anytype) !void {
            _ = allocator;
            _ = cfg;
            return error.WhatsAppDisabled;
        }
    };
};

pub const whatsapp_bot = whatsapp_bot_impl;
pub const cron = @import("agent/cron.zig");
pub const heartbeat = @import("agent/heartbeat.zig");
pub const gateway = @import("agent/gateway.zig");

pub const config = @import("config.zig");
pub const constants = @import("constants.zig");
pub const http = @import("http.zig");
// providers
pub const base = @import("providers/base.zig");
pub const openrouter = @import("providers/openrouter.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const groq = @import("providers/groq.zig");

test {
    _ = config;
    _ = Agent;
    _ = context;
    _ = tools;
    _ = session;
    _ = vector_db;
    _ = graph_db;
    _ = telegram;
    if (build_opts.include_whatsapp) {
        _ = whatsapp_bot;
    }
    _ = cron;
    _ = heartbeat;
    _ = gateway;
    _ = http;
    _ = base;
    _ = openrouter;
    _ = anthropic;
}
