// For testing TLS connections

const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const host = "api.anthropic.com";
    const port = 443;

    std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });
    var tcp = try std.net.tcpConnectToHost(allocator, host, port);
    defer tcp.close();

    var root_ca = try tls.config.cert.fromSystem(allocator);
    defer root_ca.deinit(allocator);

    std.debug.print("Upgrading to TLS...\n", .{});
    var conn = try tls.clientFromStream(tcp, .{
        .host = host,
        .root_ca = root_ca,
    });
    defer conn.deinit();

    const request = "GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nConnection: close\r\n\r\n";
    try conn.writeAll(request);

    var buffer: [4096]u8 = undefined;
    const bytes_read = try conn.read(&buffer);
    std.debug.print("Read {d} bytes:\n{s}\n", .{ bytes_read, buffer[0..bytes_read] });
}
