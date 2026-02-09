const std = @import("std");
const tls = @import("tls");

/// Async HTTP client module for making non-blocking HTTPS requests.
/// Integrates with the event loop for efficient I/O operations.

/// Async HTTP response containing status code and body content.
pub const AsyncResponse = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    /// Free the response body memory.
    pub fn deinit(self: *AsyncResponse) void {
        self.allocator.free(self.body);
    }
};

/// Async HTTP client with TLS support for secure HTTPS connections.
/// Uses non-blocking I/O and integrates with event loops.
pub const AsyncClient = struct {
    allocator: std.mem.Allocator,
    root_ca: tls.config.cert.Bundle,

    /// Initialize async client.
    pub fn init(allocator: std.mem.Allocator) !AsyncClient {
        const root_ca = try tls.config.cert.fromSystem(allocator);
        return .{
            .allocator = allocator,
            .root_ca = root_ca,
        };
    }

    /// Clean up client resources including CA certificates.
    pub fn deinit(self: *AsyncClient) void {
        var copy = self.root_ca;
        copy.deinit(self.allocator);
    }

    /// Structure representing an in-flight async HTTP request
    pub const AsyncRequest = struct {
        id: []const u8,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        body: []const u8,
        callback: *const fn (result: AsyncResult) void,
        allocator: std.mem.Allocator,
        
        // Internal state
        tcp_stream: ?std.net.Stream = null,
        tls_state: ?*TlsState = null,
        request_sent: bool = false,
        response_headers_received: bool = false,
        content_length: ?u64 = null,
        chunked: bool = false,
        response_body: std.ArrayList(u8),
        
        const TlsState = struct {
            input_buf: [tls.input_buffer_len]u8,
            output_buf: [tls.output_buffer_len]u8,
            net_reader: std.net.Stream.Reader,
            net_writer: std.net.Stream.Writer,
            conn: tls.Connection,
        };
    };

    /// Result of an async HTTP operation
    pub const AsyncResult = struct {
        request_id: []const u8,
        success: bool,
        response: ?AsyncResponse = null,
        err_msg: ?[]const u8 = null,
        
        pub fn deinit(self: *AsyncResult) void {
            if (self.response) |resp| {
                resp.deinit();
            }
            if (self.err_msg) |_| {
                // Error is owned by caller
            }
        }
    };

    /// Start an async HTTP POST request
    pub fn postAsync(self: *AsyncClient, request_id: []const u8, url: []const u8, headers: []const std.http.Header, body: []const u8, callback: *const fn (result: AsyncResult) void, allocator: std.mem.Allocator) !void {
        const request = try allocator.create(AsyncRequest);
        request.* = .{
            .id = try allocator.dupe(u8, request_id),
            .method = .POST,
            .url = try allocator.dupe(u8, url),
            .headers = try allocator.dupe(std.http.Header, headers),
            .body = try allocator.dupe(u8, body),
            .callback = callback,
            .allocator = allocator,
            .response_body = std.ArrayList(u8).init(allocator),
        };
        
        // In a real implementation, we would:
        // 1. Add the request to an async I/O queue
        // 2. Use non-blocking connect
        // 3. Register with the event loop for readiness notifications
        // 4. Process the request in chunks when ready
        
        // For now, we'll simulate the async behavior
        // This would be handled by the event loop in a real implementation
        // For demonstration, we'll process it synchronously but call the callback
        self.processRequestSync(request) catch |err| {
            const error_result = AsyncResult{
                .request_id = request.id,
                .success = false,
                .err_msg = try std.fmt.allocPrint(allocator, "Request failed: {any}", .{err}),
            };
            callback(error_result);
            cleanupRequest(request);
        };
    }

    /// Process request synchronously (for demonstration)
    fn processRequestSync(self: *AsyncClient, request: *AsyncRequest) !void {
        // Parse URL
        const uri = try std.Uri.parse(request.url);
        const host = uri.host.?.percent_encoded;
        const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;

        // Connect
        request.tcp_stream = try std.net.tcpConnectToHost(request.allocator, host, port);
        
        const is_https = std.mem.eql(u8, uri.scheme, "https");
        
        if (is_https) {
            try self.upgradeToTls(request, host);
        }
        
        // Send request
        try sendRequest(request, uri);
        
        // Receive response
        const response = try receiveResponse(request);
        
        // Create success result
        const result = AsyncResult{
            .request_id = request.id,
            .success = true,
            .response = response,
        };
        
        request.callback(result);
        cleanupRequest(request);
    }

    /// Upgrade connection to TLS
    fn upgradeToTls(self: *AsyncClient, request: *AsyncRequest, host: []const u8) !void {
        const state = try request.allocator.create(AsyncRequest.TlsState);
        errdefer request.allocator.destroy(state);

        state.net_reader = request.tcp_stream.?.reader(&state.input_buf);
        state.net_writer = request.tcp_stream.?.writer(&state.output_buf);

        const input = state.net_reader.interface();
        const output = &state.net_writer.interface;

        state.conn = try tls.client(input, output, .{
            .host = host,
            .root_ca = self.root_ca,
        });

        request.tls_state = state;
    }

    /// Send HTTP request
    fn sendRequest(request: *AsyncRequest, uri: std.Uri) !void {
        var buffer = std.ArrayList(u8).init(request.allocator);
        defer buffer.deinit();
        const w = buffer.writer();

        const path = if (uri.path.percent_encoded.len == 0) "/" else uri.path.percent_encoded;
        try w.print("{s} {s}", .{ @tagName(request.method), path });
        if (uri.query) |q| {
            try w.print("?{s}", .{q.percent_encoded});
        }
        try w.writeAll(" HTTP/1.1\r\n");

        try w.print("Host: {s}\r\n", .{uri.host.?.percent_encoded});
        try w.print("Content-Length: {d}\r\n", .{request.body.len});
        try w.writeAll("Connection: close\r\n");

        for (request.headers) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try w.writeAll("\r\n");
        try w.writeAll(request.body);

        if (request.tls_state) |state| {
            try state.conn.writeAll(buffer.items);
        } else {
            var out_buf: [4096]u8 = undefined;
            var writer = request.tcp_stream.?.writer(&out_buf);
            try writer.interface.writeAll(buffer.items);
        }
        
        request.request_sent = true;
    }

    /// Receive HTTP response
    fn receiveResponse(request: *AsyncRequest) !AsyncResponse {
        // Read headers
        var headers_received = false;
        var header_data = std.ArrayList(u8).init(request.allocator);
        defer header_data.deinit();

        while (!headers_received) {
            var byte: [1]u8 = undefined;
            const n = try readRaw(request, &byte);
            if (n == 0) return error.ConnectionClosed;
            
            try header_data.append(byte[0]);
            
            // Check for end of headers
            if (header_data.items.len >= 4) {
                const last_four = header_data.items[header_data.items.len - 4..];
                if (std.mem.eql(u8, last_four, "\r\n\r\n")) {
                    headers_received = true;
                }
            }
        }
        
        // Parse headers
        var it = std.mem.splitSequence(u8, header_data.items, "\r\n");
        const status_line = it.next() orelse return error.InvalidResponse;
        
        var status_it = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = status_it.next(); // HTTP/1.1
        const status_code_str = status_it.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(u16, status_code_str, 10);
        
        // Parse content-length and transfer-encoding
        while (it.next()) |line| {
            if (line.len == 0) break;
            var line_it = std.mem.splitScalar(u8, line, ':');
            const name = std.mem.trim(u8, line_it.first(), " ");
            const value = std.mem.trim(u8, line_it.rest(), " ");
            
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                request.content_length = try std.fmt.parseInt(u64, value, 10);
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
                    request.chunked = true;
                }
            }
        }
        
        // Read body
        if (request.chunked) {
            try readChunkedBody(request);
        } else if (request.content_length) |len| {
            try readFixedBody(request, len);
        }
        
        return AsyncResponse{
            .status = @enumFromInt(status_code),
            .body = try request.response_body.toOwnedSlice(),
            .allocator = request.allocator,
        };
    }

    /// Read raw data from connection
    fn readRaw(request: *AsyncRequest, buf: []u8) !usize {
        if (request.tls_state) |state| {
            return try state.conn.read(buf);
        } else {
            var in_buf: [4096]u8 = undefined;
            var reader_struct = request.tcp_stream.?.reader(&in_buf);
            const rdr = reader_struct.interface();
            var bufs = [1][]u8{buf};
            return try rdr.readVec(&bufs);
        }
    }

    /// Read chunked response body
    fn readChunkedBody(request: *AsyncRequest) !void {
        while (true) {
            // Read chunk size line
            var size_line = std.ArrayList(u8).init(request.allocator);
            defer size_line.deinit();
            
            while (true) {
                var byte: [1]u8 = undefined;
                const n = try readRaw(request, &byte);
                if (n == 0) return error.ConnectionClosed;
                
                try size_line.append(byte[0]);
                
                if (size_line.items.len >= 2 and 
                    std.mem.eql(u8, size_line.items[size_line.items.len - 2..], "\r\n")) {
                    break;
                }
            }
            
            const size_str = std.mem.trim(u8, size_line.items, "\r\n");
            if (size_str.len == 0) break;
            
            const chunk_size = try std.fmt.parseInt(usize, size_str, 16);
            if (chunk_size == 0) {
                // Read trailing \r\n
                var trailer: [2]u8 = undefined;
                _ = try readRaw(request, &trailer);
                break;
            }
            
            // Read chunk data
            var chunk_buf: [4096]u8 = undefined;
            var remaining = chunk_size;
            
            while (remaining > 0) {
                const to_read = @min(remaining, chunk_buf.len);
                const n = try readRaw(request, chunk_buf[0..to_read]);
                if (n == 0) return error.ConnectionClosed;
                
                try request.response_body.appendSlice(chunk_buf[0..n]);
                remaining -= n;
            }
            
            // Read trailing \r\n
            var trailer: [2]u8 = undefined;
            _ = try readRaw(request, &trailer);
        }
    }

    /// Read fixed-length response body
    fn readFixedBody(request: *AsyncRequest, length: u64) !void {
        var buf: [4096]u8 = undefined;
        var remaining = length;
        
        while (remaining > 0) {
            const to_read = @min(remaining, buf.len);
            const n = try readRaw(request, buf[0..to_read]);
            if (n == 0) return error.ConnectionClosed;
            
            try request.response_body.appendSlice(buf[0..n]);
            remaining -= n;
        }
    }

    /// Clean up request resources
    fn cleanupRequest(request: *AsyncRequest) void {
        // Free allocated strings
        request.allocator.free(request.id);
        request.allocator.free(request.url);
        request.allocator.free(request.headers);
        request.allocator.free(request.body);
        request.response_body.deinit();
        
        // Close connection
        if (request.tls_state) |state| {
            state.conn.close() catch {};
            request.allocator.destroy(state);
        }
        if (request.tcp_stream) |stream| {
            stream.close();
        }
        
        // Free the request structure
        request.allocator.destroy(request);
    }
};
