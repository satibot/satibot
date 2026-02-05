const std = @import("std");

// Connection and timeout settings for HTTP client
pub const ConnectionSettings = struct {
    connect_timeout_ms: u64 = 30000, // 30 seconds to establish connection
    request_timeout_ms: u64 = 120000, // 2 minutes for full request
    read_timeout_ms: u64 = 60000, // 1 minute between reads (for streaming)
    keep_alive: bool = false,
};

// 65536 = 64 * 1024
const BUFFER_SIZE = 65536;

/// A simple wrapper around std.http.Client with timeout configuration
pub const Client = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    settings: ConnectionSettings,

    pub fn init(allocator: std.mem.Allocator) Client {
        return initWithSettings(allocator, .{});
    }

    pub fn initWithSettings(allocator: std.mem.Allocator, settings: ConnectionSettings) Client {
        return .{
            .allocator = allocator,
            .client = std.http.Client{
                .allocator = allocator,
            },
            .settings = settings,
        };
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }

    pub const Response = struct {
        status: std.http.Status,
        body: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    pub fn post(self: *Client, url: []const u8, headers: []const std.http.Header, body: []const u8) !Response {
        const uri = try std.Uri.parse(url);

        std.debug.print("[HTTP] POST to {s} (body: {d} bytes)...\n", .{ url, body.len });

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
            .keep_alive = self.settings.keep_alive,
            .version = .@"HTTP/1.1",
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var body_buf: [4096]u8 = undefined;
        var body_writer = try req.sendBody(&body_buf);
        try body_writer.writer.writeAll(body);
        try body_writer.end();

        std.debug.print("[HTTP] Waiting for response headers...\n", .{});

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            std.debug.print("[HTTP] POST receiveHead error: {any} for {s}\n", .{ err, url });
            return err;
        };

        std.debug.print("[HTTP] Response status: {d} {s}\n", .{ @intFromEnum(response.head.status), @tagName(response.head.status) });

        var response_body_buf: [BUFFER_SIZE]u8 = undefined;
        var response_reader = response.reader(&response_body_buf);
        const response_body = try response_reader.allocRemaining(self.allocator, .limited(10 * 1024 * 1024)); // 10MB limit

        return Response{
            .status = response.head.status,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    pub fn get(self: *Client, url: []const u8, headers: []const std.http.Header) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = headers,
            .version = .@"HTTP/1.1",
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var response_body_buf: [BUFFER_SIZE]u8 = undefined;
        var response_reader = response.reader(&response_body_buf);
        const response_body = try response_reader.allocRemaining(self.allocator, .limited(10 * 1024 * 1024)); // 10MB limit

        return Response{
            .status = response.head.status,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    pub fn postStream(self: *Client, url: []const u8, headers: []const std.http.Header, body: []const u8) !std.http.Client.Request {
        const uri = try std.Uri.parse(url);

        std.debug.print("[HTTP] POST stream to {s} (body: {d} bytes)...\n", .{ url, body.len });

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
            .keep_alive = self.settings.keep_alive,
            .version = .@"HTTP/1.1",
        });
        errdefer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var body_buf: [4096]u8 = undefined;
        var body_writer = try req.sendBody(&body_buf);
        try body_writer.writer.writeAll(body);
        try body_writer.end();

        std.debug.print("[HTTP] Stream request sent, awaiting response headers...\n", .{});

        return req;
    }
};

test "Client: init and deinit" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();
    try std.testing.expect(client.allocator.ptr == allocator.ptr);
}
