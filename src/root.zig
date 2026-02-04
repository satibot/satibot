pub const config = @import("config.zig");
pub const agent = struct {
    pub const Agent = @import("agent.zig").Agent;
    pub const context = @import("agent/context.zig");
    pub const tools = @import("agent/tools.zig");
    pub const session = @import("agent/session.zig");
    pub const vector_db = @import("agent/vector_db.zig");
    pub const graph_db = @import("agent/graph_db.zig");
};
pub const http = @import("http.zig");
pub const providers = struct {
    pub const base = @import("providers/base.zig");
    pub const openrouter = @import("providers/openrouter.zig");
    pub const anthropic = @import("providers/anthropic.zig");
};

test {
    _ = config;
    _ = agent.Agent;
    _ = agent.context;
    _ = agent.tools;
    _ = agent.session;
    _ = agent.vector_db;
    _ = agent.graph_db;
    _ = http;
    _ = providers.base;
    _ = providers.openrouter;
    _ = providers.anthropic;
}
