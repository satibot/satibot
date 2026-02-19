//! Core module - shared configuration and constants
pub const config = @import("config.zig");
pub const constants = @import("constants.zig");

test {
    _ = config;
    _ = constants;
}
