const std = @import("std");
const print = std.debug.print;
const http = std.http;

/// Simple test to verify LLM API connectivity
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key from environment
    const api_key = std.process.getEnvVarOwned(allocator, "LLM_API_KEY") catch {
        print("Error: LLM_API_KEY environment variable is required\n", .{});
        print("Usage: LLM_API_KEY='your-key' ./test_llm_simple\n", .{});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    print("Testing LLM API connectivity...\n", .{});
    print("API Key: {s}...\n", .{api_key[0..@min(api_key.len, 10)]});
    print("\n", .{});

    // Test HTTP request to Anthropic API
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api.anthropic.com/v1/messages");
    
    var request_body_buffer: [1024]u8 = undefined;
    var request_body = std.ArrayList(u8).initBuffer(&request_body_buffer);
    try request_body.writer(allocator).print(
        \\{{
        \\  "model": "claude-3-haiku-20240307",
        \\  "max_tokens": 10,
        \\  "messages": [
        \\    {{"role": "user", "content": "Say 'Hello'"}}
        \\  ]
        \\}}
    , .{});

    print("Sending request to Anthropic API...\n", .{});
    
    var response_buffer: [4096]u8 = undefined;
    
    const result = try client.open(.POST, uri, .{ .accept_encoding = .{
        .compress = false,
        .gzip = false,
        .deflate = false,
        .zstd = false,
    } });
    defer result.deinit();
    
    try result.headers.append("x-api-key", api_key);
    try result.headers.append("anthropic-version", "2023-06-01");
    try result.headers.append("content-type", "application/json");
    
    try result.send();
    try result.writeAll(request_body.items);
    try result.finish();

    try result.wait();
    
    print("Status: {d}\n", .{result.status});
    if (result.status == .ok) {
        print("✅ API request successful!\n", .{});
        const body = try result.reader().readAll(&response_buffer);
        print("Response: {s}\n", .{body});
    } else {
        print("❌ API request failed!\n", .{});
        const body = try result.reader().readAll(&response_buffer);
        print("Response: {s}\n", .{body});
    }
}
