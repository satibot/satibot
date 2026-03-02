const std = @import("std");
const facebook = @import("../src/facebook.zig");

test "urlEncode encodes alphanumeric characters" {
    const allocator = std.testing.allocator;
    const result = try facebook.urlEncode(allocator, "hello");
    defer allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, result, "hello"));
}

test "urlEncode encodes special characters" {
    const allocator = std.testing.allocator;
    const result = try facebook.urlEncode(allocator, "hello world!");
    defer allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, result, "hello%20world%21"));
}

test "urlEncode encodes unicode characters" {
    const allocator = std.testing.allocator;
    const result = try facebook.urlEncode(allocator, "café");
    defer allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, result, "caf%C3%A9"));
}

test "urlEncode handles empty string" {
    const allocator = std.testing.allocator;
    const result = try facebook.urlEncode(allocator, "");
    defer allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, result, ""));
}

test "urlEncode handles special URL characters" {
    const allocator = std.testing.allocator;
    const result = try facebook.urlEncode(allocator, "a=b&c=d");
    defer allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, result, "a%3Db%26c%3Dd"));
}

test "Client config creation" {
    const config: facebook.Config = .{
        .access_token = "test_token",
        .app_secret = "test_secret",
        .page_id = "12345",
    };

    try std.testing.expect(std.mem.eql(u8, config.access_token, "test_token"));
    try std.testing.expect(config.app_secret != null);
    try std.testing.expect(config.page_id != null);
}

test "Client config with minimal fields" {
    const config: facebook.Config = .{
        .access_token = "token_only",
    };

    try std.testing.expect(std.mem.eql(u8, config.access_token, "token_only"));
    try std.testing.expect(config.app_secret == null);
    try std.testing.expect(config.page_id == null);
}
