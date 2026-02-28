//! HTML utilities for parsing and processing HTML content
const std = @import("std");

/// Check if HTML tag at position starts with given prefix (case-insensitive)
/// Used for HTML tag detection and parsing
pub fn isTagStartWith(html: []const u8, start: usize, prefix: []const u8) bool {
    if (start + prefix.len > html.len) return false;
    for (0..prefix.len) |j| {
        const c = html[start + j];
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const prefix_lower = if (prefix[j] >= 'A' and prefix[j] <= 'Z') prefix[j] + 32 else prefix[j];
        if (lower != prefix_lower) return false;
    }
    return true;
}

test "isTagStartWith basic functionality" {
    const html = "<div>Hello</div>";

    try std.testing.expect(isTagStartWith(html, 0, "<div"));
    try std.testing.expect(isTagStartWith(html, 0, "<d"));
    try std.testing.expect(isTagStartWith(html, 0, "<"));

    try std.testing.expect(!isTagStartWith(html, 0, "<span"));
    try std.testing.expect(!isTagStartWith(html, 1, "<div"));

    // Test case insensitivity
    const html_upper = "<DIV>Hello</DIV>";
    try std.testing.expect(isTagStartWith(html_upper, 0, "<div"));
    try std.testing.expect(isTagStartWith(html_upper, 0, "<DIV"));
}

test "isTagStartWith bounds checking" {
    const html = "<div>";

    try std.testing.expect(!isTagStartWith(html, 0, "<div>extra"));
    try std.testing.expect(!isTagStartWith(html, 3, "<div"));
}
