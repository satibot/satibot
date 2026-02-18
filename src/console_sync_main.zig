const std = @import("std");
const satibot = @import("root_console_sync.zig");
const console_sync = @import("agent/console_sync.zig");

pub fn main() !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var rag_enabled = true;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-rag")) {
            rag_enabled = false;
        }
    }

    var parsed_config = try satibot.config.load(allocator);
    defer parsed_config.deinit();
    const config_value = parsed_config.value;

    std.debug.print("RAG: {s}\n", .{if (rag_enabled) "Enabled" else "Disabled"});

    try console_sync.run(allocator, config_value, rag_enabled);
}
