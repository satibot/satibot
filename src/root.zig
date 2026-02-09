pub const config = @import("config.zig");
pub const agent = struct {
    pub const Agent = @import("agent.zig").Agent;
    pub const context = @import("agent/context.zig");
    pub const tools = @import("agent/tools.zig");
    pub const session = @import("agent/session.zig");
    pub const vector_db = @import("db/vector_db.zig");
    pub const graph_db = @import("db/graph_db.zig");
    pub const xev_telegram_bot = @import("agent/xev_telegram_bot.zig");
    pub const telegram_bot = @import("agent/xev_telegram_bot.zig");
    pub const whatsapp_bot = @import("agent/whatsapp_bot.zig");
    pub const cron = @import("agent/cron.zig");
    pub const heartbeat = @import("agent/heartbeat.zig");
    pub const gateway = @import("agent/gateway.zig");
    pub const event_loop = @import("agent/event_loop.zig");
    pub const telegram_handlers = @import("agent/telegram_handlers.zig");
};
pub const http = @import("http.zig");
pub const providers = struct {
    pub const base = @import("providers/base.zig");
    pub const openrouter = @import("providers/openrouter.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const groq = @import("providers/groq.zig");
};

test {
    _ = config;
    _ = agent.Agent;
    _ = agent.context;
    _ = agent.tools;
    _ = agent.session;
    _ = agent.vector_db;
    _ = agent.graph_db;
    _ = agent.telegram_bot;
    _ = agent.whatsapp_bot;
    _ = agent.cron;
    _ = agent.heartbeat;
    _ = agent.gateway;
    _ = http;
    _ = providers.base;
    _ = providers.openrouter;
    _ = providers.anthropic;
}
