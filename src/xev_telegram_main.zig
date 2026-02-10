const std = @import("std");
const satibot = @import("root.zig");
const telegram = @import("chat_apps/telegram/telegram.zig");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Run the xev-based Telegram bot
    try telegram.runBot(allocator, config);
}
