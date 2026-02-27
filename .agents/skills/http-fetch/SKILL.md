---
name: satibot-http-fetch
description: Fetch website content via HTTP/HTTPS requests in SatiBot. Use this when the bot needs to retrieve web content, scrape pages, or call external APIs.
---

# HTTP Fetch Skill

This skill documents how to make HTTP requests in SatiBot using the built-in HTTP client.

## When to Use This Skill

Use this when:

- Fetching content from URLs
- Calling external APIs
- Scraping web pages
- The user asks to fetch or retrieve web content

## HTTP Client

SatiBot provides an HTTP client in `libs/http/src/http.zig`:

```zig
const http = @import("http");
```

### Basic Usage

```zig
var client = try http.Client.init(allocator);
defer client.deinit();

// GET request
var response = try client.get(url, &[_]std.http.Header{});
defer response.deinit();

// POST request
var response = try client.post(url, headers, body);
defer response.deinit();
```

### Response Structure

```zig
const response: http.Response = .{
    .status: std.http.Status,
    .body: []u8,  // Caller must free this
    .allocator: std.mem.Allocator,
};
```

Check status with:

```zig
if (response.status == .ok) {
    // Success
}
```

### Headers

```zig
const headers = &[_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Authorization", .value = "Bearer token" },
};
```

### Connection Settings

```zig
const settings = http.ConnectionSettings{
    .connect_timeout_ms = 30000,
    .request_timeout_ms = 120000,
    .read_timeout_ms = 60000,
    .keep_alive = false,
};

var client = try http.Client.initWithSettings(allocator, settings);
```

## Fetch HTML Example

```zig
fn fetchHtml(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = try http.Client.init(allocator);
    defer client.deinit();

    var response = try client.get(url, &[_]std.http.Header{
        .{ .name = "User-Agent", .value = "SatiBot/1.0" },
    });
    defer response.deinit();

    if (response.status != .ok) {
        return error.HttpError;
    }

    return try allocator.dupe(u8, response.body);
}
```

## Common Status Codes

| Status | Meaning |
|--------|---------|
| `.ok` | 200 - Success |
| `.not_found` | 404 - Resource not found |
| `.too_many_requests` | 429 - Rate limited |
| `.internal_server_error` | 500 - Server error |

## Best Practices

1. Always call `defer client.deinit()` after init
2. Always call `defer response.deinit()` after getting response
3. Use appropriate timeouts for the operation
4. Set User-Agent header for identification
5. Handle non-2xx status codes explicitly
6. Use `allocator.dupe()` if you need to keep the body after response is freed
