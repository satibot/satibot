/// Mock LLM provider for debugging and testing
/// Provides deterministic responses without requiring real API calls
const std = @import("std");
const base = @import("../providers/base.zig");
const Config = @import("../config.zig").Config;

pub const MockProvider = struct {
    allocator: std.mem.Allocator,
    response_count: u32,

    pub fn init(allocator: std.mem.Allocator) MockProvider {
        return .{
            .allocator = allocator,
            .response_count = 0,
        };
    }

    pub fn createInterface(self: *MockProvider) base.ProviderInterface {
        return .{
            .ctx = @as(*anyopaque, @ptrCast(self)),
            .getApiKey = getApiKey,
            .initProvider = initProvider,
            .deinitProvider = deinitProvider,
            .chatStream = chatStream,
            .getProviderName = getProviderName,
        };
    }

    fn getApiKey(ctx: *anyopaque, config: Config) ?[]const u8 {
        _ = ctx;
        _ = config;
        // Mock provider doesn't need a real API key
        return "mock-api-key";
    }

    fn initProvider(allocator: std.mem.Allocator, api_key: []const u8) !*anyopaque {
        _ = allocator;
        _ = api_key;
        // For mock provider, we don't need to initialize anything
        return @as(*anyopaque, @ptrCast(&mock_provider_instance));
    }

    fn deinitProvider(provider: *anyopaque) void {
        _ = provider;
        // Nothing to clean up for mock provider
    }

    fn chatStream(
        provider: *anyopaque,
        messages: []const base.LlmMessage,
        model: []const u8,
        tools: []const base.ToolDefinition,
        chunk_callback: base.ChunkCallback,
        callback_ctx: ?*anyopaque,
    ) !base.LlmResponse {
        const self = @as(*MockProvider, @ptrCast(@alignCast(provider)));
        _ = messages;
        _ = model;
        _ = tools;

        // Simulate streaming response
        const mock_chunks = [_][]const u8{
            "🤖 ",
            "Mock ",
            "response: ",
            "This ",
            "is ",
            "a ",
            "debug ",
            "response ",
            "from ",
            "the ",
            "mock ",
            "LLM ",
            "provider. ",
            "No ",
            "real ",
            "API ",
            "call ",
            "was ",
            "made.",
        };

        for (mock_chunks) |chunk| {
            chunk_callback(callback_ctx, chunk);
            // Small delay to simulate streaming
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        self.response_count += 1;

        // Use allocator to demonstrate it's needed
        const debug_info = try std.fmt.allocPrint(self.allocator, " [Mock call #{d}]", .{self.response_count});
        defer self.allocator.free(debug_info);

        const full_response = try std.fmt.allocPrint(self.allocator, "🤖 Mock response: This is a debug response from the mock LLM provider. No real API call was made.{s}", .{debug_info});
        return .{
            .content = full_response,
            .tool_calls = null,
            .allocator = self.allocator,
        };
    }

    fn getProviderName() []const u8 {
        return "Mock";
    }
};

/// Global mock provider instance
var mock_provider_instance: MockProvider = undefined;

/// Get mock provider interface
pub fn getMockInterface(allocator: std.mem.Allocator) base.ProviderInterface {
    mock_provider_instance = MockProvider.init(allocator);
    return mock_provider_instance.createInterface();
}
