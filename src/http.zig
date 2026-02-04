const std = @import("std");

/// A simple wrapper around std.http.Client
pub const Client = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
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

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var body_buf: [4096]u8 = undefined;
        var body_writer = try req.sendBody(&body_buf);
        try body_writer.writer.writeAll(body);
        // Equivalent to end() or similar if available, actually end() is often used in BodyWriter
        // Wait, let's check BodyWriter.end() or finish()
        // Looking at 0.15.2 source, BodyWriter has `end()` and `finish()`.
        try body_writer.end();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var response_body_buf: [4096]u8 = undefined;
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
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        var response_body_buf: [4096]u8 = undefined;
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
        var req = try self.client.request(.POST, uri, .{ .extra_headers = headers });
        errdefer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var body_buf: [4096]u8 = undefined;
        var body_writer = try req.sendBody(&body_buf);
        try body_writer.writer.writeAll(body);
        try body_writer.end();

        return req;
    }
};

test "Client: init and deinit" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();
    try std.testing.expect(client.allocator.ptr == allocator.ptr);
}
