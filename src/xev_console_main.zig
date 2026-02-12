const std = @import("std");
const satibot = @import("root.zig");
const console = @import("agent/console.zig");

pub fn main() !void {
    // Initialize allocator
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Initialize and run the Console bot
    var bot = try console.MockBot.init(allocator, config);
    defer bot.deinit();

    try bot.run();
}
