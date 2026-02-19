const std = @import("std");
const agent = @import("agent");
const telegram = @import("telegram");

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try agent.config.load(allocator);
    defer parsed_config.deinit();
    const cfg = parsed_config.value;

    // Run the xev-based Telegram bot
    try telegram.runBot(allocator, cfg);
}
