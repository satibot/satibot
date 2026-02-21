const std = @import("std");
const web = @import("web");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize web server
    var server = web.Server.init(allocator, .{
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

test "web server initialization" {
    const allocator = std.testing.allocator;
    var server = web.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 0), server.config.port);
    try std.testing.expect(std.mem.eql(u8, "127.0.0.1", server.config.host));
}
