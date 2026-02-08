const std = @import("std");
const print = std.debug.print;
const testing = std.testing;

// Import the necessary modules
const anthropic = @import("src/providers/anthropic.zig");
const base = @import("src/providers/base.zig");

/// Test LLM functionality without Telegram/chat dependencies
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key from environment
    const api_key = std.process.getEnvVarOwned(allocator, "LLM_API_KEY") catch {
        print("Error: LLM_API_KEY environment variable is required\n", .{});
        print("Usage: LLM_API_KEY='your-key' ./test_llm_standalone\n", .{});
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    // Get model from environment or use default
    const model = std.process.getEnvVarOwned(allocator, "LLM_MODEL") catch "claude-3-haiku-20240307";
    defer allocator.free(model);

    print("Testing Anthropic LLM provider\n", .{});
    print("Model: {s}\n", .{model});
    print("==========================================\n\n", .{});

    // Initialize the provider
    var provider = try anthropic.AnthropicProvider.init(allocator, api_key);
    defer provider.deinit();

    // Test 1: Simple completion
    try testSimpleCompletion(allocator, &provider, model);

    // Test 2: Conversation with context
    try testConversationWithContext(allocator, &provider, model);

    // Test 3: Error handling with invalid model
    try testErrorHandling(allocator, &provider);

    print("\n✅ All tests completed!\n", .{});
}

fn testSimpleCompletion(allocator: std.mem.Allocator, provider: *anthropic.AnthropicProvider, model: []const u8) !void {
    _ = allocator;
    print("Test 1: Simple completion\n", .{});
    print("------------------------\n", .{});

    const messages = [_]base.LLMMessage{
        .{ .role = "user", .content = "Say 'Hello World' in exactly two words." },
    };

    const response = try provider.chat(&messages, model);
    defer response.deinit();

    print("Prompt: Say 'Hello World' in exactly two words.\n", .{});
    if (response.content) |content| {
        print("Response: {s}\n", .{content});
    } else {
        print("Response: (no content)\n", .{});
    }
    print("\n", .{});
}

fn testConversationWithContext(allocator: std.mem.Allocator, provider: *anthropic.AnthropicProvider, model: []const u8) !void {
    _ = allocator;
    print("Test 2: Conversation with context\n", .{});
    print("--------------------------------\n", .{});

    const messages = [_]base.LLMMessage{
        .{ .role = "user", .content = "You are a helpful assistant who loves cats. What is your favorite animal?" },
    };

    const response = try provider.chat(&messages, model);
    defer response.deinit();

    print("User: You are a helpful assistant who loves cats. What is your favorite animal?\n", .{});
    if (response.content) |content| {
        print("Assistant: {s}\n", .{content});
    } else {
        print("Assistant: (no content)\n", .{});
    }
    print("\n", .{});
}

fn testErrorHandling(allocator: std.mem.Allocator, provider: *anthropic.AnthropicProvider) !void {
    _ = allocator;
    print("Test 3: Error handling\n", .{});
    print("---------------------\n", .{});

    const messages = [_]base.LLMMessage{
        .{ .role = "user", .content = "This should fail with invalid model" },
    };

    provider.chat(&messages, "invalid-model-name-12345") catch |err| {
        print("✅ Expected error caught: {}\n", .{err});
        return;
    };

    print("❌ Error: Expected request to fail with invalid model name\n", .{});
}

// Unit tests
test "provider initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const provider = try anthropic.AnthropicProvider.init(allocator, "test-key");
    defer provider.deinit();

    try testing.expect(provider != null);
}

test "message structure" {
    const msg = base.LLMMessage{
        .role = "user",
        .content = "Hello",
    };

    try testing.expectEqualStrings("user", msg.role);
    try testing.expectEqualStrings("Hello", msg.content.?);
}
