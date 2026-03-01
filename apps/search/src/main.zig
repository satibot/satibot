//! Search CLI Application
//!
//! A command-line tool for searching the web using the Brave Search API.
//! This application provides a simple interface to perform web searches
//! and display results in a formatted, readable way.
//!
//! ## Features
//! - Web search using Brave Search API
//! - URL encoding for safe query transmission
//! - Configuration file support for API key management
//! - Formatted result display with titles, URLs, and descriptions
//! - Error handling for API failures and parsing errors
//!
//! ## Usage
//!
//! Basic usage with API key as argument:
//! ```bash
//! search "zig programming language" "your-brave-api-key"
//! ```
//!
//! Usage with configuration file:
//! ```bash
//! # Create config.json with:
//! # {
//! #   "tools": {
//! #     "web": {
//! #       "search": {
//! #         "apiKey": "your-brave-api-key"
//! #       }
//! #     }
//! #   }
//! # }
//! search "zig programming language"
//! ```
//!
//! ## Configuration
//!
//! The application looks for a `config.json` file in the current directory
//! when no API key is provided as an argument. The configuration should
//! follow the SatiBot configuration format with the web.search.apiKey field.
//!
//! ## API Integration
//!
//! - Endpoint: https://api.search.brave.com/res/v1/web/search
//! - Authentication: X-Subscription-Token header
//! - Response format: JSON with web results array
//!
//! ## Output Format
//!
//! Results are displayed in a numbered list format:
//! ```
//! 1. Result Title
//!    URL: https://example.com
//!    Description of the result...
//!
//! 2. Another Result
//!    URL: https://another-example.com
//!    Another description...
//! ```

const std = @import("std");
const http = @import("http");

pub fn main() !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <query> [api_key]\n", .{args[0]});
        std.debug.print("\nSearch the web using Brave Search API.\n", .{});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  query     Search query string\n", .{});
        std.debug.print("  api_key   Brave Search API key (optional, uses config if not provided)\n", .{});
        return;
    }

    const query = args[1];
    const api_key = if (args.len > 2) args[2] else null;

    if (api_key == null) {
        const config_path = "config.json";
        const config_file = std.fs.cwd().openFile(config_path, .{}) catch null;
        if (config_file) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(content);

            const parsed = std.json.parseFromSlice(
                struct { tools: struct { web: struct { search: struct { apiKey: ?[]const u8 } } } },
                allocator,
                content,
                .{},
            ) catch null;

            if (parsed) |p| {
                defer p.deinit();
                if (p.value.tools.web.search.apiKey) |key| {
                    try doSearch(allocator, query, key);
                    return;
                }
            }
        }

        std.debug.print("Error: No API key provided and no config.json found with web.search.apiKey\n", .{});
        return;
    }

    try doSearch(allocator, query, api_key.?);
}

fn doSearch(allocator: std.mem.Allocator, query: []const u8, api_key: []const u8) !void {
    var client = try http.Client.init(allocator);
    defer client.deinit();

    var encoded_query: std.ArrayList(u8) = .empty;
    defer encoded_query.deinit(allocator);

    for (query) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try encoded_query.append(allocator, c);
            },
            else => {
                try encoded_query.append(allocator, '%');
                try encoded_query.append(allocator, "0123456789ABCDEF"[c >> 4]);
                try encoded_query.append(allocator, "0123456789ABCDEF"[c & 0xF]);
            },
        }
    }

    const url = try std.fmt.allocPrint(allocator, "https://api.search.brave.com/res/v1/web/search?q={s}", .{encoded_query.items});
    defer allocator.free(url);

    const headers = &[_]std.http.Header{
        .{ .name = "X-Subscription-Token", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "SatiBot-Search/1.0" },
    };

    std.debug.print("Searching for: {s}\n", .{query});
    std.debug.print("URL: {s}\n\n", .{url});

    var response = client.get(url, headers) catch |err| {
        std.debug.print("Error performing search: {any}\n", .{err});
        return;
    };
    defer response.deinit();

    if (response.status != .ok) {
        std.debug.print("Error: Search API returned status {d}\n", .{@intFromEnum(response.status)});
        if (response.body.len > 0) {
            std.debug.print("Response: {s}\n", .{response.body});
        }
        return;
    }

    const parsed = std.json.parseFromSlice(
        BraveResponse,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("Error parsing response: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value.web) |web| {
        if (web.results.len == 0) {
            std.debug.print("No results found.\n", .{});
            return;
        }

        std.debug.print("Found {d} results:\n\n", .{web.results.len});

        for (web.results, 0..) |result, i| {
            std.debug.print("{d}. {s}\n", .{ i + 1, result.title });
            std.debug.print("   URL: {s}\n", .{result.url});
            if (result.description.len > 0) {
                std.debug.print("   {s}\n", .{result.description});
            }
            std.debug.print("\n", .{});
        }
    } else {
        std.debug.print("No web results in response.\n", .{});
    }
}

const BraveResponse = struct {
    web: ?struct {
        results: []struct {
            title: []const u8,
            description: []const u8,
            url: []const u8,
        },
    } = null,
};
