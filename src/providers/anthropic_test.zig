const std = @import("std");
const anthropic = @import("anthropic.zig");
const base = @import("base.zig");

test "AnthropicProvider: init and deinit" {
    const allocator = std.testing.allocator;

    var provider = try anthropic.AnthropicProvider.init(allocator, "test-api-key");
    defer provider.deinit();

    try std.testing.expectEqual(allocator, provider.allocator);
    try std.testing.expectEqualStrings("test-api-key", provider.api_key);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1", provider.api_base);
}

test "AnthropicProvider: buildRequestBody with system message" {
    const allocator = std.testing.allocator;

    var provider = try anthropic.AnthropicProvider.init(allocator, "test-key");
    defer provider.deinit();

    const messages = &[_]base.LlmMessage{
        .{ .role = "system", .content = "You are a helpful assistant." },
        .{ .role = "user", .content = "Hello!" },
    };

    const body = try provider.buildRequestBody(messages, "claude-3-opus-4-5-20251101", null, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\": \"You are a helpful assistant.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\": \"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\": \"Hello!\"") != null);
}

test "AnthropicProvider: buildRequestBody with streaming" {
    const allocator = std.testing.allocator;

    var provider = try anthropic.AnthropicProvider.init(allocator, "test-key");
    defer provider.deinit();

    const messages = &[_]base.LlmMessage{
        .{ .role = "user", .content = "Stream this" },
    };

    const body = try provider.buildRequestBody(messages, "claude-3-opus-4-5-20251101", null, true);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\": true") != null);
}

test "AnthropicProvider: buildRequestBody with tools" {
    const allocator = std.testing.allocator;

    var provider = try anthropic.AnthropicProvider.init(allocator, "test-key");
    defer provider.deinit();

    const messages = &[_]base.LlmMessage{
        .{ .role = "user", .content = "Use a tool" },
    };

    const tools = &[_]base.ToolDefinition{
        .{
            .name = "search",
            .description = "Search the web",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        },
    };

    const body = try provider.buildRequestBody(messages, "claude-3-opus-4-5-20251101", tools, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\": \"search\"") != null);
}

test "AnthropicProvider: parseResponse with content" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "msg_123",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "text", "text": "Hello world"}
        \\  ],
        \\  "model": "claude-3-opus-4-5-20251101",
        \\  "stop_reason": "end_turn"
        \\}
    ;

    const response = try anthropic.AnthropicProvider.parseResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expectEqualStrings("Hello world", response.content.?);
    try std.testing.expect(response.tool_calls == null);
}

test "AnthropicProvider: parseResponse with tool calls" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "msg_456",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "text", "text": "I'll use a tool"},
        \\    {"type": "tool_use", "id": "tool_123", "name": "search", "input": {"query": "test"}}
        \\  ],
        \\  "model": "claude-3-opus-4-5-20251101",
        \\  "stop_reason": "tool_use"
        \\}
    ;

    const response = try anthropic.AnthropicProvider.parseResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expectEqualStrings("I'll use a tool", response.content.?);
    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("tool_123", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("search", response.tool_calls.?[0].function.name);
}

test "AnthropicProvider: parseResponse with no content" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "msg_789",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [],
        \\  "model": "claude-3-opus-4-5-20251101",
        \\  "stop_reason": "end_turn"
        \\}
    ;

    const response = try anthropic.AnthropicProvider.parseResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expect(response.content == null);
    try std.testing.expect(response.tool_calls == null);
}

test "AnthropicProvider: parseResponse with malformed JSON" {
    const allocator = std.testing.allocator;

    const malformed_json = "{ invalid json }";

    const response = anthropic.AnthropicProvider.parseResponse(allocator, malformed_json);
    try std.testing.expectError(error.InvalidJson, response);
}

test "AnthropicProvider: ContentBlock union behavior" {
    _ = @as(std.mem.Allocator, undefined); // Mark as used

    // Test that ContentBlock can hold different types
    const text_block: anthropic.ContentBlock = .{
        .text = .{ .text = "Hello world" },
    };

    const tool_block: anthropic.ContentBlock = .{
        .tool_use = .{
            .id = "tool_123",
            .name = "search",
            .input = "{\"query\": \"test\"}",
        },
    };

    try std.testing.expectEqualStrings("Hello world", text_block.text.text);
    try std.testing.expectEqualStrings("tool_123", tool_block.tool_use.id);
    try std.testing.expectEqualStrings("search", tool_block.tool_use.name);
}

test "AnthropicProvider: AnthropicMessage structure" {
    _ = @as(std.mem.Allocator, undefined); // Mark as used

    // Test AnthropicMessage structure
    const msg: anthropic.AnthropicMessage = .{
        .role = "user",
        .content = .{
            .text = .{ .text = "Hello" },
        },
    };

    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("Hello", msg.content.text.text);
}

test "AnthropicProvider: MessageResponse structure" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "msg_abc",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "text", "text": "Response"}
        \\  ],
        \\  "model": "claude-3-opus-4-5-20251101",
        \\  "stop_sequence": null,
        \\  "stop_reason": "end_turn"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(anthropic.MessageResponse, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("msg_abc", parsed.value.id);
    try std.testing.expectEqualStrings("assistant", parsed.value.role);
    try std.testing.expectEqualStrings("claude-3-opus-4-5-20251101", parsed.value.model);
    try std.testing.expectEqualStrings("end_turn", parsed.value.stop_reason);
}
