//! X API Authentication - OAuth 1.0a header generation and credential management.
const std = @import("std");

pub const Credentials = struct {
    api_key: []const u8,
    api_secret: []const u8,
    access_token: []const u8,
    access_token_secret: []const u8,
    bearer_token: []const u8,
};

fn percentEncode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    for (s) |c| {
        if (std.ascii.isAlNum(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try buf.append(c);
        } else {
            try buf.append('%');
            try buf.append("0123456789ABCDEF"[c >> 4]);
            try buf.append("0123456789ABCDEF"[c & 0xF]);
        }
    }
    return buf.toOwnedSlice();
}

fn buildAuthHeader(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    creds: *const Credentials,
    params: ?std.StringHashMap([]const u8),
) ![]const u8 {
    const timestamp = std.time.timestamp();
    const nonce = generateNonce(allocator);
    defer allocator.free(nonce);

    var oauth_params = std.StringHashMap([]const u8).init(allocator);
    defer oauth_params.deinit();

    try oauth_params.put("oauth_consumer_key", creds.api_key);
    try oauth_params.put("oauth_nonce", nonce);
    try oauth_params.put("oauth_signature_method", "HMAC-SHA1");
    try oauth_params.put("oauth_timestamp", std.fmt.allocPrint(allocator, "{d}", .{timestamp}) catch unreachable);
    try oauth_params.put("oauth_token", creds.access_token);
    try oauth_params.put("oauth_version", "1.0");

    var all_params = std.StringHashMap([]const u8).init(allocator);
    defer all_params.deinit();

    var iter = oauth_params.iterator();
    while (iter.next()) |entry| {
        try all_params.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    if (params) |p| {
        var p_iter = p.iterator();
        while (p_iter.next()) |entry| {
            try all_params.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    const parsed = std.Uri.parse(url);
    if (parsed.query) |query| {
        var qs_iter = std.mem.split(u8, query, "&");
        while (qs_iter.next()) |pair| {
            if (std.mem.find(u8, pair, "=")) |idx| {
                const key = pair[0..idx];
                const val = if (idx + 1 < pair.len) pair[idx + 1 ..] else "";
                try all_params.put(try allocator.dupe(u8, key), try allocator.dupe(u8, val));
            }
        }
    }

    var sorted_params = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(allocator);
    defer sorted_params.deinit();

    var all_iter = all_params.iterator();
    while (all_iter.next()) |entry| {
        try sorted_params.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    std.sort.sort(struct { key: []const u8, value: []const u8 }, sorted_params.items, {}, struct {
        fn less(_: void, a: struct { key: []const u8, value: []const u8 }, b: struct { key: []const u8, value: []const u8 }) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);

    var param_string = std.ArrayList(u8).init(allocator);
    defer param_string.deinit();

    for (sorted_params.items, 0..) |pair, i| {
        if (i > 0) try param_string.append('&');
        const enc_key = try percentEncode(allocator, pair.key);
        defer allocator.free(enc_key);
        const enc_val = try percentEncode(allocator, pair.value);
        defer allocator.free(enc_val);
        try param_string.appendSlice(enc_key);
        try param_string.append('=');
        try param_string.appendSlice(enc_val);
    }

    const base_url = try std.fmt.allocPrint(allocator, "{s}://{s}/{s}", .{
        if (parsed.scheme) |s| s else "https",
        if (parsed.host) |h| h else "api.x.com",
        if (parsed.path) |p| p[1..] else "2",
    });
    defer allocator.free(base_url);

    const base_string = try std.fmt.allocPrint(allocator, "{s}&{s}&{s}", .{
        method,
        try percentEncode(allocator, base_url),
        try percentEncode(allocator, param_string.items),
    });
    defer allocator.free(base_string);

    const signing_key = try std.fmt.allocPrint(allocator, "{s}&{s}", .{
        creds.api_secret,
        creds.access_token_secret,
    });
    defer allocator.free(signing_key);

    const signature = try hmacSha1(allocator, signing_key, base_string);
    defer allocator.free(signature);

    try oauth_params.put("oauth_signature", signature);

    var oauth_list = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(allocator);
    defer oauth_list.deinit();

    var oauth_iter = oauth_params.iterator();
    while (oauth_iter.next()) |entry| {
        try oauth_list.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    std.sort.sort(struct { key: []const u8, value: []const u8 }, oauth_list.items, {}, struct {
        fn less(_: void, a: struct { key: []const u8, value: []const u8 }, b: struct { key: []const u8, value: []const u8 }) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);

    var header = std.ArrayList(u8).init(allocator);
    defer header.deinit();
    try header.appendSlice("OAuth ");

    for (oauth_list.items, 0..) |pair, i| {
        if (i > 0) try header.appendSlice(", ");
        const enc_key = try percentEncode(allocator, pair.key);
        defer allocator.free(enc_key);
        const enc_val = try percentEncode(allocator, pair.value);
        defer allocator.free(enc_val);
        try header.appendSlice(enc_key);
        try header.appendSlice("=\"");
        try header.appendSlice(enc_val);
        try header.append('"');
    }

    return header.toOwnedSlice();
}

fn generateNonce(_: std.mem.Allocator) []u8 {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return std.fmt.bytesToHex(buf, .lower);
}

fn hmacSha1(_: std.mem.Allocator, key: []const u8, message: []const u8) ![]const u8 {
    var hmac: [20]u8 = undefined;

    var k_ipad: [64]u8 = undefined;
    var k_opad: [64]u8 = undefined;

    @memset(&k_ipad, 0x36);
    @memset(&k_opad, 0x5c);

    const key_len = key.len;
    if (key_len > 64) @panic("HMAC-SHA1 key too long");

    for (0..key_len) |i| {
        k_ipad[i] ^= key[i];
        k_opad[i] ^= key[i];
    }

    var inner_hash: [20]u8 = undefined;
    {
        var ctx = std.crypto.hash.Sha1.init(.{});
        ctx.update(&k_ipad);
        ctx.update(message);
        inner_hash = ctx.final();
    }

    {
        var ctx = std.crypto.hash.Sha1.init(.{});
        ctx.update(&k_opad);
        ctx.update(&inner_hash);
        hmac = ctx.final();
    }

    return std.fmt.bytesToHex(hmac, .lower);
}

pub const Auth = struct {
    pub fn generateOAuthHeader(
        allocator: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        creds: *const Credentials,
    ) ![]const u8 {
        return buildAuthHeader(allocator, method, url, creds, null);
    }
};

test "OAuth header generation" {
    const allocator = std.testing.allocator;
    const creds: Credentials = .{
        .api_key = "test_key",
        .api_secret = "test_secret",
        .access_token = "test_token",
        .access_token_secret = "test_token_secret",
        .bearer_token = "test_bearer",
    };
    const header = try Auth.generateOAuthHeader(allocator, "GET", "https://api.x.com/2/users/me", &creds);
    defer allocator.free(header);
    try std.testing.expect(std.mem.startsWith(u8, header, "OAuth "));
}
