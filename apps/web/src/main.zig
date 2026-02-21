const std = @import("std");
const web = @import("web");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize web server
    var server = try web.Server.init(allocator, .{
        .host = "0.0.0.0",
        .port = 3000,
    });
    defer server.deinit();

    std.log.info("Starting web server on http://localhost:3000", .{});

    // Start server
    try server.start();

    // Run event loop
    server.run();
}
