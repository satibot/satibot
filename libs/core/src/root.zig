//! Core module - shared configuration and constants
pub const config = @import("config.zig");
pub const constants = @import("constants.zig");
pub const bot_definition = @import("bot_definition.zig");

test {
    _ = config;
    _ = constants;
    _ = bot_definition;
}
