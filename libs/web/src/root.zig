//! Web module - HTTP API endpoints using zap web framework
const std = @import("std");
const zap = @import("zap");

/// Web server configuration
pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3000,
    max_connections: usize = 1000,
    max_request_size: usize = 1048576, // 1MB
};

/// Simple request handler function type
pub const Handler = *const fn (req: zap.Request) anyerror!void;

/// Web server state
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,

    /// Initialize the web server
    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Deinitialize the web server
    pub fn deinit(self: *Server) void {
        self.* = undefined;
        // Cleanup is handled by zap
    }

    /// Start the web server with a simple endpoint
    pub fn start(self: *Server) !void {

        // Create HTTP listener
        var listener = zap.HttpListener.init(.{
            .port = self.config.port,
            .on_request = handleRoot,
            .max_clients = @intCast(self.config.max_connections),
            .max_body_size = self.config.max_request_size,
        });

        try listener.listen();

        std.log.info("Web server listening on http://localhost:{d}", .{
            self.config.port,
        });
    }

    /// Run the event loop
    pub fn run(self: *Server) void {
        _ = self;
        zap.start(.{
            .threads = 4,
            .workers = 0,
        });
    }
};

/// Handle root endpoint
fn handleRoot(req: zap.Request) anyerror!void {
    req.sendJson("{\"status\":\"ok\",\"message\":\"SatiBot API\"}") catch |err| {
        std.log.err("Failed to send response: {any}", .{err});
    };
}

/// API router for handling HTTP requests
pub const Router = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
        };
    }

    /// Handle health check request
    pub fn health(_: *Router, req: zap.Request) anyerror!void {
        req.sendJson("{\"status\":\"ok\"}") catch |err| {
            std.log.err("Failed to send health response: {any}", .{err});
        };
    }

    /// Handle agent chat request
    pub fn chat(self: *Router, req: zap.Request) anyerror!void {
        _ = self;
        // TODO: Implement chat endpoint
        req.sendJson("{\"error\":\"Not implemented\"}") catch |err| {
            std.log.err("Failed to send chat response: {any}", .{err});
        };
    }
};

test "web server config" {
    const config: Config = .{
        .port = 8080,
    };
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqual(@as(usize, 1000), config.max_connections);
    try std.testing.expectEqual(@as(usize, 1048576), config.max_request_size); // 1024 * 1024
}

test "Server initialization" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .port = 4000 });
    defer server.deinit();
    try std.testing.expectEqual(@as(u16, 4000), server.config.port);
}

test "Router initialization" {
    const allocator = std.testing.allocator;
    const router = Router.init(allocator);
    try std.testing.expectEqual(allocator, router.allocator);
}
