//! X (Twitter) API v2 client library with OAuth 1.0a and Bearer token auth.
pub const api = @import("x/api.zig");
pub const auth = @import("x/auth.zig");

test {
    _ = api;
    _ = auth;
}
