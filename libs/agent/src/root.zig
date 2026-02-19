const std = @import("std");
pub const build_opts = @import("build_opts");

// Core agent exports
pub const Agent = @import("agent.zig").Agent;
pub const context = @import("agent/context.zig");
pub const tools = @import("agent/tools.zig");
pub const messages = @import("agent/messages.zig");
pub const console = @import("agent/console.zig");
pub const console_sync = @import("agent/console_sync.zig");
pub const telegram_bot_sync = @import("agent/telegram_bot_sync.zig");

// WhatsApp support (conditional)
const whatsapp_bot_real = @import("agent/whatsapp_bot.zig");
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

// Services
pub const cron = @import("agent/cron.zig");
pub const heartbeat = @import("agent/heartbeat.zig");
pub const gateway = @import("agent/gateway.zig");
pub const xev_event_loop = @import("utils").xev_event_loop;

// Config and constants (from core module)
pub const config = @import("core").config;
pub const constants = @import("core").constants;

// External module imports (passed via build.zig imports)
pub const session = @import("db");
pub const vector_db = @import("db").vector_db;
pub const local_embeddings = @import("db").local_embeddings;
pub const graph_db = @import("db").graph_db;
pub const http = @import("http");
pub const base = @import("providers");
pub const openrouter = @import("providers").openrouter;
pub const anthropic = @import("providers").anthropic;
pub const groq = @import("providers").groq;

test {
    _ = config;
    _ = Agent;
    _ = context;
    _ = tools;
    _ = console;
    _ = console_sync;
    _ = telegram_bot_sync;
    if (build_opts.include_whatsapp) {
        _ = whatsapp_bot;
    }
    _ = cron;
    _ = heartbeat;
    _ = gateway;
    _ = http;
    _ = base;
}
