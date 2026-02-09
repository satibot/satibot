const std = @import("std");
const satibot = @import("root.zig");
const xev_mock_bot = @import("agent/xev_mock_bot.zig");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Initialize and run the mock bot
    var bot = try xev_mock_bot.MockBot.init(allocator, config);
    defer bot.deinit();

    try bot.run();
}
