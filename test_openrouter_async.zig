const std = @import("std");
const testing = std.testing;
const providers = @import("src/providers/openrouter.zig");
const AsyncEventLoop = @import("src/agent/event_loop.zig").AsyncEventLoop;
const Config = @import("src/config.zig").Config;

test "OpenRouterProvider: initWithEventLoop" {
    const allocator = testing.allocator;
    
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{},
    };
    
    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();
    
    var provider = try providers.OpenRouterProvider.initWithEventLoop(allocator, "test-key", &event_loop);
    defer provider.deinit();
    
    try testing.expectEqual(allocator, provider.allocator);
    try testing.expectEqualStrings("test-key", provider.api_key);
    try testing.expect(provider.async_client != null);
    try testing.expect(provider.event_loop != null);
}

test "OpenRouterProvider: chatAsync without initialization" {
    const allocator = testing.allocator;
    
    var provider = try providers.OpenRouterProvider.init(allocator, "test-key");
    defer provider.deinit();
    
    const messages = &[_]providers.base.LLMMessage{
        .{ .role = "user", .content = "Hello" },
    };
    
    const callback = struct {
        fn cb(result: providers.OpenRouterProvider.ChatAsyncResult) void {
            _ = result;
        }
    }.cb;
    
    // Should fail because async_client is null
    const result = provider.chatAsync("test-123", messages, "test-model", callback);
    try testing.expectError(error.AsyncNotInitialized, result);
}

test "OpenRouterProvider: ChatAsyncResult deinit" {
    const allocator = testing.allocator;
    
    // Test success case
    {
        var response = providers.base.LLMResponse{
            .content = try allocator.dupe(u8, "Hello"),
            .tool_calls = null,
            .allocator = allocator,
        };
        
        var result = providers.OpenRouterProvider.ChatAsyncResult{
            .request_id = try allocator.dupe(u8, "test-123"),
            .success = true,
            .response = response,
            .error = null,
        };
        
        result.deinit();
        // Test passes if no memory leak
    }
    
    // Test error case
    {
        var result = providers.OpenRouterProvider.ChatAsyncResult{
            .request_id = try allocator.dupe(u8, "test-456"),
            .success = false,
            .response = null,
            .error = try allocator.dupe(u8, "Test error"),
        };
        
        result.deinit();
        // Test passes if no memory leak
    }
}
