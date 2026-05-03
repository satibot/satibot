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

const log = std.log.scoped(.search);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);

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
        const content = readFileAlloc(allocator, config_path) catch |err| {
            log.err("Failed to read config file '{s}': {any}", .{ config_path, err });
            return;
        };
        if (content) |buf| {
            defer allocator.free(buf);
            const parsed = std.json.parseFromSlice(
                struct { tools: struct { web: struct { search: struct { apiKey: ?[]const u8 } } } },
                allocator,
                buf,
                .{},
            ) catch |err| {
                log.err("Failed to parse config JSON: {any}", .{err});
                return;
            };

            defer parsed.deinit();
            if (parsed.value.tools.web.search.apiKey) |key| {
                try doSearch(allocator, query, key);
                return;
            }
        }

        log.warn("No API key provided and no config.json found with web.search.apiKey", .{});
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
        log.err("Search request failed: {any}", .{err});
        std.debug.print("Error performing search: {any}\n", .{err});
        return;
    };
    defer response.deinit();

    if (response.status != .ok) {
        log.err("Search API returned non-OK status: {d}", .{@intFromEnum(response.status)});
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
        log.err("Failed to parse search response: {any}", .{err});
        std.debug.print("Error parsing response: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value.web) |web| {
        if (web.results.len == 0) {
            log.warn("Search returned no results for query", .{});
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

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse {
        log.warn("Config file not found or cannot be opened: {s}", .{path});
        return null;
    };
    defer _ = std.c.fclose(file);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(allocator, temp[0..n]);
    }
    const result = try buf.toOwnedSlice(allocator);
    return result;
}
