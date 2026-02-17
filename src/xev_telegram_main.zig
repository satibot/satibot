const std = @import("std");
const satibot = @import("satibot");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Run the xev-based Telegram bot
    try satibot.telegram.runBot(allocator, config);
}
