//! Utils module - shared utilities
pub const xev_event_loop = @import("xev_event_loop.zig");
pub const html = @import("html.zig");

test {
    _ = xev_event_loop;
    _ = html;
}
