//! Console application entry point for the satibot framework.
//! Initializes the allocator, loads configuration, and runs the console bot.

const std = @import("std");
const satibot = @import("satibot");

pub fn main() !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();

    // Initialize console bot with interactive mode enabled
    var bot = try satibot.console.MockBot.init(allocator, parsed_config.value, true);
    defer bot.deinit();

    // Run the main bot event loop
    try bot.run();
}
