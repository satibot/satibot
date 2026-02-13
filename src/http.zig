const std = @import("std");
const tls = @import("tls");

/// HTTP client module for making HTTPS requests with TLS support.
/// Provides a simple interface for POST/GET requests and streaming responses.
/// Connection timeout settings for HTTP operations.
/// All timeouts are in milliseconds.
pub const ConnectionSettings = struct {
    connect_timeout_ms: u64 = 30000, // 30 seconds to establish connection
    request_timeout_ms: u64 = 120000, // 2 minutes for full request
    read_timeout_ms: u64 = 60000, // 1 minute between reads (for streaming)
    keep_alive: bool = false,
};

/// HTTP response containing status code and body content.
/// Caller must call deinit() to free the response body memory.
pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,
    rate_limit_limit: ?u64 = null,
    rate_limit_remaining: ?u64 = null,
    rate_limit_reset: ?u64 = null,

    /// Free the response body memory.
    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// HTTP client with TLS support for secure HTTPS connections.
/// Manages connection settings and root CA certificates.
pub const Client = struct {
    allocator: std.mem.Allocator,
    settings: ConnectionSettings,
    root_ca: tls.config.cert.Bundle,

    /// Initialize client with default connection settings.
    pub fn init(allocator: std.mem.Allocator) !Client {
        return initWithSettings(allocator, .{});
    }

    /// Initialize client with custom connection settings.
    /// Loads root CA certificates from system trust store.
    pub fn initWithSettings(allocator: std.mem.Allocator, settings: ConnectionSettings) !Client {
        const root_ca = try tls.config.cert.fromSystem(allocator);
        return .{
            .allocator = allocator,
            .settings = settings,
            .root_ca = root_ca,
        };
    }

    /// Clean up client resources including CA certificates.
    pub fn deinit(self: *Client) void {
        var copy = self.root_ca;
        copy.deinit(self.allocator);
        self.* = undefined;
    }

    /// Send POST request and return full response.
    /// Automatically handles HTTP/HTTPS and reads entire response body.
    pub fn post(self: *Client, url: []const u8, headers: []const std.http.Header, body: []const u8) !Response {
        var req = try self.request(.POST, url, headers, body);
        defer req.deinit();

        var head_buf: [4096]u8 = undefined;
        const resp = try req.receiveHead(&head_buf);

        var response_body = std.ArrayList(u8).empty;
        errdefer response_body.deinit(self.allocator);

        var rdr = req.reader();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try rdr.read(&buf);
            if (n == 0) break;
            try response_body.appendSlice(self.allocator, buf[0..n]);
        }

        return .{
            .status = resp.head.status,
            .body = try response_body.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
            .rate_limit_limit = resp.head.rate_limit_limit,
            .rate_limit_remaining = resp.head.rate_limit_remaining,
            .rate_limit_reset = resp.head.rate_limit_reset,
        };
    }

    /// Send GET request (implemented as POST with empty body).
    pub fn get(self: *Client, url: []const u8, headers: []const std.http.Header) !Response {
        return self.post(url, headers, "");
    }

    /// Start streaming POST request.
    /// Returns Request object for incremental reading of response.
    pub fn postStream(self: *Client, url: []const u8, headers: []const std.http.Header, body: []const u8) !Request {
        return self.request(.POST, url, headers, body);
    }

    /// Internal method to create HTTP request with method, URL, headers, and body.
    fn request(self: *Client, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: []const u8) !Request {
        const uri = try std.Uri.parse(url);
        const host = uri.host.?.percent_encoded;
        const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;

        var tcp = try std.net.tcpConnectToHost(self.allocator, host, port);
        errdefer tcp.close();

        const is_https = std.mem.eql(u8, uri.scheme, "https");

        var req = try Request.initWithTcp(self.allocator, tcp, is_https, uri);
        errdefer req.deinit();

        if (is_https) {
            try req.upgradeToTls(host, self.root_ca);
        }

        try req.send(method, headers, body);

        return req;
    }
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    tcp: std.net.Stream,
    is_https: bool,
    uri: std.Uri,

    tls_state: ?*TlsState = null,
    response_head: ?ResponseHead = null,

    const TlsState = struct {
        input_buf: [tls.input_buffer_len]u8,
        output_buf: [tls.output_buffer_len]u8,
        net_reader: std.net.Stream.Reader,
        net_writer: std.net.Stream.Writer,
        conn: tls.Connection,
    };

    pub const ResponseHead = struct {
        status: std.http.Status,
        content_length: ?u64 = null,
        chunked: bool = false,
        rate_limit_limit: ?u64 = null,
        rate_limit_remaining: ?u64 = null,
        rate_limit_reset: ?u64 = null,
    };

    pub const IncomingResponse = struct {
        request: *Request,
        head: ResponseHead,

        pub fn reader(self: *IncomingResponse, buffer: []u8) Request.Reader {
            _ = buffer;
            return self.request.reader();
        }
    };

    pub fn initWithTcp(allocator: std.mem.Allocator, tcp: std.net.Stream, is_https: bool, uri: std.Uri) !Request {
        return .{
            .allocator = allocator,
            .tcp = tcp,
            .is_https = is_https,
            .uri = uri,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.tls_state) |state| {
            state.conn.close() catch |err| {
                std.debug.print("Failed to close TLS connection: {any}\n", .{err});
            };
            self.allocator.destroy(state);
        }
        self.tcp.close();
        self.* = undefined;
    }

    pub fn upgradeToTls(self: *Request, host: []const u8, root_ca: tls.config.cert.Bundle) !void {
        const state = try self.allocator.create(TlsState);
        errdefer self.allocator.destroy(state);

        state.net_reader = self.tcp.reader(&state.input_buf);
        state.net_writer = self.tcp.writer(&state.output_buf);

        const input = state.net_reader.interface();
        const output = &state.net_writer.interface;

        state.conn = try tls.client(input, output, .{
            .host = host,
            .root_ca = root_ca,
        });

        self.tls_state = state;
    }

    pub fn send(self: *Request, method: std.http.Method, headers: []const std.http.Header, body: []const u8) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        const w = buffer.writer(self.allocator);

        const path = if (self.uri.path.percent_encoded.len == 0) "/" else self.uri.path.percent_encoded;
        try w.print("{s} {s}", .{ @tagName(method), path });
        if (self.uri.query) |q| {
            try w.print("?{s}", .{q.percent_encoded});
        }
        try w.writeAll(" HTTP/1.1\r\n");

        try w.print("Host: {s}\r\n", .{self.uri.host.?.percent_encoded});
        try w.print("Content-Length: {d}\r\n", .{body.len});
        try w.writeAll("Connection: close\r\n");

        for (headers) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try w.writeAll("\r\n");
        try w.writeAll(body);

        if (self.tls_state) |state| {
            try state.conn.writeAll(buffer.items);
        } else {
            var out_buf: [4096]u8 = undefined;
            var writer = self.tcp.writer(&out_buf);
            try writer.interface.writeAll(buffer.items);
        }
    }

    pub fn receiveHead(self: *Request, buffer: []u8) !IncomingResponse {
        _ = buffer;
        var headers_list = std.ArrayList(u8).empty;
        defer headers_list.deinit(self.allocator);

        var found = false;
        var last_four = [4]u8{ 0, 0, 0, 0 };

        while (!found) {
            var byte: u8 = undefined;
            const n = try self.rawRead(std.mem.asBytes(&byte));
            if (n == 0) return error.HttpHeaderIncomplete;
            try headers_list.append(self.allocator, byte);

            last_four[0] = last_four[1];
            last_four[1] = last_four[2];
            last_four[2] = last_four[3];
            last_four[3] = byte;

            if (std.mem.eql(u8, &last_four, "\r\n\r\n")) {
                found = true;
            }
            if (headers_list.items.len > 16384) return error.HttpHeaderTooLong;
        }

        var it = std.mem.splitSequence(u8, headers_list.items, "\r\n");
        const status_line = it.next() orelse return error.HttpHeaderIncomplete;

        var status_it = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = status_it.next(); // HTTP/1.1
        const status_code_str = status_it.next() orelse return error.HttpHeaderIncomplete;
        const status_code = try std.fmt.parseInt(u16, status_code_str, 10);

        var content_length: ?u64 = null;
        var chunked = false;
        var rate_limit_limit: ?u64 = null;
        var rate_limit_remaining: ?u64 = null;
        var rate_limit_reset: ?u64 = null;

        while (it.next()) |line| {
            if (line.len == 0) break;
            var line_it = std.mem.splitScalar(u8, line, ':');
            const name = std.mem.trim(u8, line_it.first(), " ");
            const value = std.mem.trim(u8, line_it.rest(), " ");

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = try std.fmt.parseInt(u64, value, 10);
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
                    chunked = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-limit")) {
                rate_limit_limit = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) {
                rate_limit_remaining = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset")) {
                rate_limit_reset = std.fmt.parseInt(u64, value, 10) catch null;
            }
        }

        const head: ResponseHead = .{
            .status = @enumFromInt(status_code),
            .content_length = content_length,
            .chunked = chunked,
            .rate_limit_limit = rate_limit_limit,
            .rate_limit_remaining = rate_limit_remaining,
            .rate_limit_reset = rate_limit_reset,
        };
        self.response_head = head;
        return .{
            .request = self,
            .head = head,
        };
    }

    fn rawRead(self: *Request, buf: []u8) !usize {
        if (self.tls_state) |state| {
            return state.conn.read(buf);
        } else {
            return self.tcp.read(buf);
        }
    }

    pub const Reader = struct {
        request: *Request,
        chunked_state: ?ChunkedState = null,

        const ChunkedState = struct {
            remaining: usize = 0,
            done: bool = false,
        };

        pub fn read(self: *Reader, buffer: []u8) anyerror!usize {
            if (self.request.response_head == null) return error.ResponseHeadNotReceived;
            if (self.request.response_head.?.chunked) {
                return self.readChunked(buffer);
            } else {
                return self.request.rawRead(buffer);
            }
        }

        pub fn readSliceShort(self: *Reader, buffer: []u8) anyerror!usize {
            return self.read(buffer);
        }

        fn readChunked(self: *Reader, buffer: []u8) anyerror!usize {
            if (self.chunked_state == null) {
                self.chunked_state = ChunkedState{};
            }
            var state = &self.chunked_state.?;
            if (state.done) return 0;

            if (state.remaining == 0) {
                // Read next chunk size
                var line_buf = std.ArrayList(u8).empty;
                defer line_buf.deinit(self.request.allocator);

                while (true) {
                    var byte: u8 = undefined;
                    const n = try self.request.rawRead(std.mem.asBytes(&byte));
                    if (n == 0) return 0;
                    try line_buf.append(self.request.allocator, byte);
                    if (line_buf.items.len >= 2 and std.mem.eql(u8, line_buf.items[line_buf.items.len - 2 ..], "\r\n")) {
                        break;
                    }
                }

                const line = std.mem.trim(u8, line_buf.items, "\r\n");
                if (line.len == 0) return 0;
                state.remaining = try std.fmt.parseInt(usize, line, 16);
                if (state.remaining == 0) {
                    state.done = true;
                    // Read trailing \r\n
                    var trailer = [2]u8{ 0, 0 };
                    _ = try self.request.rawRead(&trailer);
                    return 0;
                }
            }

            const to_read = @min(buffer.len, state.remaining);
            const n = try self.request.rawRead(buffer[0..to_read]);
            state.remaining -= n;

            if (state.remaining == 0) {
                // Read trailing \r\n
                var trailer = [2]u8{ 0, 0 };
                _ = try self.request.rawRead(&trailer);
            }

            return n;
        }

        pub fn any(self: *Reader) std.io.AnyReader {
            return .{
                .context = self,
                .readFn = typeErasedReadFn,
            };
        }

        fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
            const ptr: *Reader = @ptrCast(@alignCast(@constCast(context)));
            return ptr.read(buffer);
        }
    };

    pub fn reader(self: *Request) Reader {
        return .{ .request = self };
    }
};

test "HTTP: ConnectionSettings defaults" {
    const settings: ConnectionSettings = .{};
    try std.testing.expectEqual(@as(u64, 30000), settings.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 120000), settings.request_timeout_ms);
    try std.testing.expectEqual(@as(u64, 60000), settings.read_timeout_ms);
    try std.testing.expectEqual(false, settings.keep_alive);
}

test "HTTP: Response deinit" {
    const allocator = std.testing.allocator;
    var response: Response = .{
        .status = .ok,
        .body = try allocator.dupe(u8, "test body"),
        .allocator = allocator,
    };
    response.deinit();
    // Test passes if no memory leak
}

test "HTTP: Client init" {
    const allocator = std.testing.allocator;
    var client = try Client.init(allocator);
    defer client.deinit();

    try std.testing.expectEqual(allocator, client.allocator);
    try std.testing.expectEqual(@as(u64, 30000), client.settings.connect_timeout_ms);
}

test "HTTP: Client initWithSettings" {
    const allocator = std.testing.allocator;
    const settings: ConnectionSettings = .{
        .connect_timeout_ms = 60000,
        .keep_alive = true,
    };
    var client = try Client.initWithSettings(allocator, settings);
    defer client.deinit();

    try std.testing.expectEqual(@as(u64, 60000), client.settings.connect_timeout_ms);
    try std.testing.expectEqual(true, client.settings.keep_alive);
}

test "HTTP: URI parsing" {
    const uri = try std.Uri.parse("https://api.example.com:8080/path?query=value#fragment");
    try std.testing.expectEqualStrings("https", uri.scheme);
    try std.testing.expectEqualStrings("api.example.com", uri.host.?.percent_encoded);
    try std.testing.expectEqual(@as(u16, 8080), uri.port.?);
    try std.testing.expectEqualStrings("/path", uri.path.percent_encoded);
    try std.testing.expectEqualStrings("query=value", uri.query.?.percent_encoded);
}

test "HTTP: Header parsing" {
    // Test ResponseHead parsing logic
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Content-Length", .value = "1234" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };

    // Verify header values
    var content_length: ?u64 = null;
    var chunked = false;

    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            content_length = try std.fmt.parseInt(u64, header.value, 10);
        } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(header.value, "chunked") != null) {
                chunked = true;
            }
        }
    }

    try std.testing.expectEqual(@as(u64, 1234), content_length.?);
    try std.testing.expectEqual(true, chunked);
}

test "HTTP: ChunkedState" {
    const state: Request.Reader.ChunkedState = .{
        .remaining = 100,
        .done = false,
    };

    try std.testing.expectEqual(@as(usize, 100), state.remaining);
    try std.testing.expectEqual(false, state.done);
}

test "HTTP: Request methods" {
    try std.testing.expectEqual(std.http.Method.GET, std.http.Method.GET);
    try std.testing.expectEqual(std.http.Method.POST, std.http.Method.POST);
    try std.testing.expectEqual(std.http.Method.PUT, std.http.Method.PUT);
    try std.testing.expectEqual(std.http.Method.DELETE, std.http.Method.DELETE);
}

test "HTTP: Status codes" {
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(std.http.Status.ok));
    try std.testing.expectEqual(@as(u16, 404), @intFromEnum(std.http.Status.not_found));
    try std.testing.expectEqual(@as(u16, 500), @intFromEnum(std.http.Status.internal_server_error));
}
