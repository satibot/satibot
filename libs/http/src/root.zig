//! HTTP module exports
pub const Client = @import("http.zig").Client;
pub const fetch = @import("http.zig").fetch;
pub const RequestOptions = @import("http.zig").RequestOptions;
pub const Request = @import("http.zig").Request;
pub const Response = @import("http.zig").Response;
pub const HttpError = @import("http.zig").HttpError;

// Namespace access for compatibility
pub const http = @import("http.zig");
pub const http_async = @import("http_async.zig");

test {
    _ = @import("http.zig");
    _ = @import("http_async.zig");
}
