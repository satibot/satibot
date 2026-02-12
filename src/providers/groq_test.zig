const std = @import("std");
const groq = @import("groq.zig");
const base = @import("base.zig");

test "GroqProvider: init and deinit" {
    var provider = try groq.GroqProvider.init(std.testing.allocator, "test-api-key");
    defer provider.deinit();

    try std.testing.expectEqual(std.testing.allocator, provider.allocator);
    try std.testing.expectEqualStrings("test-api-key", provider.api_key);
    try std.testing.expectEqualStrings("https://api.groq.com/openai/v1", provider.api_base);
}

test "GroqProvider: empty API key" {
    var provider = try groq.GroqProvider.init(std.testing.allocator, "");
    defer provider.deinit();

    try std.testing.expectEqualStrings("", provider.api_key);
}

test "GroqProvider: transcription request structure" {
    const file_content = "fake audio data";

    const request = groq.TranscriptionRequest{
        .file = file_content,
        .model = "whisper-large-v3",
        .language = "en",
        .response_format = "json",
    };

    try std.testing.expectEqualStrings("fake audio data", request.file);
    try std.testing.expectEqualStrings("whisper-large-v3", request.model);
    try std.testing.expectEqualStrings("en", request.language.?);
    try std.testing.expectEqualStrings("json", request.response_format.?);
}

test "GroqProvider: transcription request without optional fields" {
    const allocator = std.testing.allocator;

    const request = groq.TranscriptionRequest{
        .file = "audio data",
        .model = "whisper-large-v3",
    };

    try std.testing.expectEqualStrings("audio data", request.file);
    try std.testing.expectEqualStrings("whisper-large-v3", request.model);
    try std.testing.expect(request.language == null);
    try std.testing.expect(request.response_format == null);
}

test "GroqProvider: completion response parsing" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "Hello! How can I help you today?"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    // This would normally be parsed by the provider, but we test the structure
    const parsed = try std.json.parseFromSlice(groq.CompletionResponse, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.choices.len);
    try std.testing.expectEqualStrings("assistant", parsed.value.choices[0].message.role);
    try std.testing.expectEqualStrings("Hello! How can I help you today?", parsed.value.choices[0].message.content.?);
}

test "GroqProvider: transcription response parsing" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "text": "Hello, this is a transcription of the audio."
        \\}
    ;

    const parsed = try std.json.parseFromSlice(groq.TranscriptionResponse, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello, this is a transcription of the audio.", parsed.value.text);
}

test "GroqProvider: error response structure" {
    const allocator = std.testing.allocator;

    const error_json =
        \\{
        \\  "error": {
        \\    "message": "Invalid API key provided",
        \\    "type": "invalid_request_error",
        \\    "code": "invalid_api_key"
        \\  }
        \\}
    ;

    const ErrorResponse = struct {
        @"error": struct {
            message: []const u8,
            type: []const u8,
            code: []const u8,
        },
    };

    const parsed = try std.json.parseFromSlice(ErrorResponse, allocator, error_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Invalid API key provided", parsed.value.@"error".message);
    try std.testing.expectEqualStrings("invalid_request_error", parsed.value.@"error".type);
    try std.testing.expectEqualStrings("invalid_api_key", parsed.value.@"error".code);
}
