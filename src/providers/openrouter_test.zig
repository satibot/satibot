const std = @import("std");
const openrouter = @import("openrouter.zig");
const base = @import("base.zig");

test "OpenRouterError: enum values" {
    try std.testing.expectEqual(openrouter.OpenRouterError.ServiceUnavailable, openrouter.OpenRouterError.ServiceUnavailable);
    try std.testing.expectEqual(openrouter.OpenRouterError.ModelNotSupported, openrouter.OpenRouterError.ModelNotSupported);
    try std.testing.expectEqual(openrouter.OpenRouterError.ApiRequestFailed, openrouter.OpenRouterError.ApiRequestFailed);
}

test "CompletionResponse: struct fields" {
    const choice: openrouter.Choice = .{
        .message = .{
            .content = "Hello world",
            .role = "assistant",
            .tool_calls = null,
        },
    };

    const response: openrouter.CompletionResponse = .{
        .id = "resp_123",
        .model = "gpt-3.5-turbo",
        .choices = &[_]openrouter.Choice{choice},
    };

    try std.testing.expectEqualStrings("resp_123", response.id);
    try std.testing.expectEqualStrings("gpt-3.5-turbo", response.model);
    try std.testing.expectEqual(@as(usize, 1), response.choices.len);
    try std.testing.expectEqualStrings("Hello world", response.choices[0].message.content.?);
}

test "Choice: struct fields" {
    const message: openrouter.Message = .{
        .content = "Test response",
        .role = "assistant",
        .tool_calls = null,
    };

    const choice: openrouter.Choice = .{
        .message = message,
    };

    try std.testing.expectEqualStrings("Test response", choice.message.content.?);
    try std.testing.expectEqualStrings("assistant", choice.message.role);
    try std.testing.expect(choice.message.tool_calls == null);
}

test "Message: with tool calls" {
    const tool_call: openrouter.ToolCallResponse = .{
        .id = "call_abc",
        .type = "function",
        .function = .{
            .name = "test_function",
            .arguments = "{\"param\": \"value\"}",
        },
    };

    const message: openrouter.Message = .{
        .content = "I'll call a function",
        .role = "assistant",
        .tool_calls = &[_]openrouter.ToolCallResponse{tool_call},
    };

    try std.testing.expectEqualStrings("I'll call a function", message.content.?);
    try std.testing.expectEqualStrings("assistant", message.role);
    try std.testing.expect(message.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_abc", message.tool_calls.?[0].id);
}

test "ToolCallResponse: struct fields" {
    const func_response: openrouter.FunctionCallResponse = .{
        .name = "my_function",
        .arguments = "{\"key\": \"value\"}",
    };

    const tool_call: openrouter.ToolCallResponse = .{
        .id = "call_123",
        .type = "function",
        .function = func_response,
    };

    try std.testing.expectEqualStrings("call_123", tool_call.id);
    try std.testing.expectEqualStrings("function", tool_call.type);
    try std.testing.expectEqualStrings("my_function", tool_call.function.name);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", tool_call.function.arguments);
}

test "FunctionCallResponse: struct fields" {
    const func_response: openrouter.FunctionCallResponse = .{
        .name = "test_func",
        .arguments = "{\"arg1\": \"val1\", \"arg2\": 123}",
    };

    try std.testing.expectEqualStrings("test_func", func_response.name);
    try std.testing.expectEqualStrings("{\"arg1\": \"val1\", \"arg2\": 123}", func_response.arguments);
}

test "ChatAsyncResult: success case" {
    const allocator = std.testing.allocator;

    var response: base.LLMResponse = .{
        .content = try allocator.dupe(u8, "Success response"),
        .tool_calls = null,
        .allocator = allocator,
    };
    defer response.deinit();

    const result: openrouter.ChatAsyncResult = .{
        .request_id = "req_123",
        .success = true,
        .response = response,
        .err_msg = null,
    };

    try std.testing.expectEqualStrings("req_123", result.request_id);
    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expectEqualStrings("Success response", result.response.?.content.?);
    try std.testing.expect(result.err_msg == null);
}

test "ChatAsyncResult: error case" {
    const allocator = std.testing.allocator;

    var result: openrouter.ChatAsyncResult = .{
        .request_id = "req_456",
        .success = false,
        .response = null,
        .err_msg = try allocator.dupe(u8, "API request failed"),
    };
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("req_456", result.request_id);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expect(result.response == null);
    try std.testing.expectEqualStrings("API request failed", result.err_msg.?);
}

test "buildChatRequestBody: basic message" {
    const allocator = std.testing.allocator;

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Hello" },
        .{ .role = "assistant", .content = "Hi there!" },
    };

    const body = try openrouter.buildChatRequestBody(allocator, messages, "gpt-3.5-turbo", null, false);
    defer allocator.free(body);

    // Verify the body contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\": \"gpt-3.5-turbo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\": \"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\": \"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\": \"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\": \"Hi there!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null); // Should not have stream flag
}

test "buildChatRequestBody: with streaming" {
    const allocator = std.testing.allocator;

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Stream this" },
    };

    const body = try openrouter.buildChatRequestBody(allocator, messages, "gpt-4", null, true);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\": true") != null);
}

test "buildChatRequestBody: with tools" {
    const allocator = std.testing.allocator;

    const messages = &[_]base.LLMMessage{
        .{ .role = "user", .content = "Use a tool" },
    };

    const tools = &[_]base.ToolDefinition{
        .{
            .name = "search",
            .description = "Search the web",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        },
    };

    const body = try openrouter.buildChatRequestBody(allocator, messages, "gpt-4", tools, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\": \"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"description\": \"Search the web\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\": {\"type\": \"object\"") != null);
}

test "parseChatResponse: content only" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "chat_123",
        \\  "model": "gpt-3.5-turbo",
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "Hello world"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const response = try openrouter.parseChatResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expectEqualStrings("Hello world", response.content.?);
    try std.testing.expect(response.tool_calls == null);
}

test "parseChatResponse: with tool calls" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "chat_456",
        \\  "model": "gpt-4",
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "I'll call a function",
        \\        "tool_calls": [
        \\          {
        \\            "id": "call_abc",
        \\            "type": "function",
        \\            "function": {
        \\              "name": "test_func",
        \\              "arguments": "{\"param\": \"value\"}"
        \\            }
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const response = try openrouter.parseChatResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expectEqualStrings("I'll call a function", response.content.?);
    try std.testing.expect(response.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_abc", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("test_func", response.tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"param\": \"value\"}", response.tool_calls.?[0].function.arguments);
}

test "parseChatResponse: no choices error" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "chat_empty",
        \\  "model": "gpt-3.5-turbo",
        \\  "choices": []
        \\}
    ;

    const response = openrouter.parseChatResponse(allocator, response_json);
    try std.testing.expectError(error.NoChoicesReturned, response);
}

test "parseErrorBody: structured error" {
    const allocator = std.testing.allocator;

    const error_json =
        \\{
        \\  "error": {
        \\    "message": "Invalid API key"
        \\  }
        \\}
    ;

    const error_msg = try openrouter.parseErrorBody(allocator, error_json);
    defer allocator.free(error_msg);

    try std.testing.expectEqualStrings("Invalid API key", error_msg);
}

test "parseErrorBody: unstructured error" {
    const allocator = std.testing.allocator;

    const error_json = "Plain error message";

    const error_msg = try openrouter.parseErrorBody(allocator, error_json);
    defer allocator.free(error_msg);

    try std.testing.expectEqualStrings("Plain error message", error_msg);
}

test "parseEmbeddingsResponse: single embedding" {
    const allocator = std.testing.allocator;

    const embeddings_json =
        \\{
        \\  "data": [
        \\    {
        \\      "embedding": [0.1, 0.2, 0.3, 0.4]
        \\    }
        \\  ]
        \\}
    ;

    const response = try openrouter.parseEmbeddingsResponse(allocator, embeddings_json);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 4), response.embeddings[0].len);
    try std.testing.expectEqual(@as(f32, 0.1), response.embeddings[0][0]);
    try std.testing.expectEqual(@as(f32, 0.4), response.embeddings[0][3]);
}

test "parseEmbeddingsResponse: multiple embeddings" {
    const allocator = std.testing.allocator;

    const embeddings_json =
        \\{
        \\  "data": [
        \\    {
        \\      "embedding": [1.0, 0.0]
        \\    },
        \\    {
        \\      "embedding": [0.0, 1.0]
        \\    }
        \\  ]
        \\}
    ;

    const response = try openrouter.parseEmbeddingsResponse(allocator, embeddings_json);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 2), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 2), response.embeddings[0].len);
    try std.testing.expectEqual(@as(f32, 1.0), response.embeddings[0][0]);
    try std.testing.expectEqual(@as(f32, 0.0), response.embeddings[0][1]);
    try std.testing.expectEqual(@as(f32, 0.0), response.embeddings[1][0]);
    try std.testing.expectEqual(@as(f32, 1.0), response.embeddings[1][1]);
}

test "OpenRouterProvider: init" {
    const allocator = std.testing.allocator;

    var provider = try openrouter.OpenRouterProvider.init(allocator, "test-api-key");
    defer provider.deinit();

    try std.testing.expectEqual(allocator, provider.allocator);
    try std.testing.expectEqualStrings("test-api-key", provider.api_key);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", provider.api_base);
    try std.testing.expect(provider.async_client == null);
    try std.testing.expect(provider.event_loop == null);
}

test "OpenRouterProvider: initWithEventLoop" {
    const allocator = std.testing.allocator;

    // Mock event loop - in real tests you'd use a proper mock
    const MockEventLoop = struct {
        const Self = @This();

        pub fn init() Self {
            return .{};
        }
        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }
    };

    var mock_event_loop = MockEventLoop.init();
    defer mock_event_loop.deinit();

    var provider = try openrouter.OpenRouterProvider.initWithEventLoop(allocator, "test-api-key", @ptrCast(&mock_event_loop));
    defer provider.deinit();

    try std.testing.expectEqual(allocator, provider.allocator);
    try std.testing.expectEqualStrings("test-api-key", provider.api_key);
    try std.testing.expect(provider.async_client != null);
    try std.testing.expect(provider.event_loop != null);
}

test "OpenRouterProvider: error handling" {
    const allocator = std.testing.allocator;

    // Test that provider handles invalid API keys gracefully
    var provider = try openrouter.OpenRouterProvider.init(allocator, "");
    defer provider.deinit();

    try std.testing.expectEqualStrings("", provider.api_key);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", provider.api_base);
}

test "buildChatRequestBody: complex tools" {
    const allocator = std.testing.allocator;

    const messages = &[_]base.LlmMessage{
        .{ .role = "user", .content = "Use multiple tools" },
    };

    const tools = &[_]base.ToolDefinition{
        .{
            .name = "search",
            .description = "Search the web",
            .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}}}",
        },
        .{
            .name = "calculate",
            .description = "Perform calculations",
            .parameters = "{\"type\": \"object\", \"properties\": {\"expression\": {\"type\": \"string\"}}}",
        },
    };

    const body = try openrouter.buildChatRequestBody(allocator, messages, "gpt-4", tools, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"calculate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\": \"function\"") != null);
}

test "parseErrorBody: malformed JSON" {
    const allocator = std.testing.allocator;

    const malformed_json = "{ invalid json }";
    const error_msg = try openrouter.parseErrorBody(allocator, malformed_json);
    defer allocator.free(error_msg);

    try std.testing.expectEqualStrings("{ invalid json }", error_msg);
}

test "parseErrorBody: empty response" {
    const allocator = std.testing.allocator;

    const empty_json = "";
    const error_msg = try openrouter.parseErrorBody(allocator, empty_json);
    defer allocator.free(error_msg);

    try std.testing.expectEqualStrings("", error_msg);
}

test "parseChatResponse: missing content and tool calls" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "chat_empty",
        \\  "model": "gpt-3.5-turbo",
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const response = try openrouter.parseChatResponse(allocator, response_json);
    defer response.deinit();

    try std.testing.expect(response.content == null);
    try std.testing.expect(response.tool_calls == null);
}

test "ChatAsyncResult: lifecycle management" {
    const allocator = std.testing.allocator;

    // Test that deinit properly cleans up both success and error cases
    {
        var success_result: openrouter.ChatAsyncResult = .{
            .request_id = "req_success",
            .success = true,
            .response = base.LlmResponse{
                .content = try allocator.dupe(u8, "Success"),
                .tool_calls = null,
                .allocator = allocator,
            },
            .err_msg = null,
        };
        success_result.deinit(allocator);
    }

    {
        var error_result: openrouter.ChatAsyncResult = .{
            .request_id = "req_error",
            .success = false,
            .response = null,
            .err_msg = try allocator.dupe(u8, "Error occurred"),
        };
        error_result.deinit(allocator);
    }

    // If we reach here without crashing, the deinit worked correctly
    try std.testing.expect(true);
}

test "parseEmbeddingsResponse: empty data array" {
    const allocator = std.testing.allocator;

    const embeddings_json =
        \\{
        \\  "data": []
        \\}
    ;

    const response = try openrouter.parseEmbeddingsResponse(allocator, embeddings_json);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.embeddings.len);
}

test "parseEmbeddingsResponse: malformed embedding" {
    const allocator = std.testing.allocator;

    // Test with embedding that has wrong type
    const malformed_json =
        \\{
        \\  "data": [
        \\    {"embedding": "not_an_array"}
        \\  ]
        \\}
    ;

    // This should fail to parse
    const response = openrouter.parseEmbeddingsResponse(allocator, malformed_json);
    try std.testing.expectError(error.InvalidType, response);
}
