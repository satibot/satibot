const std = @import("std");
const speech = @import("minimax-speech").speech;
const testing = std.testing;

test "SpeechClient: buildSpeechRequestBody with text" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const request: speech.AsyncSpeechRequest = .{
        .model = "speech-2.8-hd",
        .text = "Hello, world!",
        .voice_setting = .{
            .voice_id = "English_expressive_narrator",
            .speed = 1.0,
            .vol = 1.0,
            .pitch = 0,
        },
        .audio_setting = .{
            .audio_sample_rate = 32000,
            .bitrate = 128000,
            .format = "mp3",
            .channel = 1,
        },
    };

    const body = try client.buildSpeechRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"speech-2.8-hd\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"voice_setting\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"audio_setting\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"speed\": 1") != null);
}

test "SpeechClient: buildSpeechRequestBody with custom voice settings" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const request: speech.AsyncSpeechRequest = .{
        .model = "speech-2.6-turbo",
        .text = "Custom speech",
        .voice_setting = .{
            .voice_id = "Chinese_neural",
            .speed = 1.5,
            .vol = 0.8,
            .pitch = 2.0,
        },
        .audio_setting = .{
            .audio_sample_rate = 44100,
            .bitrate = 256000,
            .format = "wav",
            .channel = 2,
        },
    };

    const body = try client.buildSpeechRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"Chinese_neural\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"speed\": 1.5") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"format\": \"wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"channel\": 2") != null);
}

test "SpeechClient: buildSpeechRequestBody with pronunciation dict" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const request: speech.AsyncSpeechRequest = .{
        .model = "speech-2.8-hd",
        .text = "omg it's so beautiful",
        .voice_setting = .{
            .voice_id = "English_expressive_narrator",
            .speed = 1.0,
            .vol = 1.0,
            .pitch = 0,
        },
        .audio_setting = .{
            .audio_sample_rate = 32000,
            .bitrate = 128000,
            .format = "mp3",
            .channel = 1,
        },
        .pronunciation_dict = .{
            .tone = &.{"omg/oh my god"},
        },
    };

    const body = try client.buildSpeechRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"pronunciation_dict\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "omg/oh my god") != null);
}

test "SpeechClient: buildSpeechRequestBody with voice modify" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const request: speech.AsyncSpeechRequest = .{
        .model = "speech-2.8-hd",
        .text = "Speech with effects",
        .voice_setting = .{
            .voice_id = "English_expressive_narrator",
            .speed = 1.0,
            .vol = 1.0,
            .pitch = 0,
        },
        .audio_setting = .{
            .audio_sample_rate = 32000,
            .bitrate = 128000,
            .format = "mp3",
            .channel = 1,
        },
        .voice_modify = .{
            .pitch = 5,
            .intensity = 3,
            .timbre = 2,
            .sound_effects = "spacious_echo",
        },
    };

    const body = try client.buildSpeechRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"voice_modify\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"spacious_echo\"") != null);
}

test "SpeechClient: parseCreateResponse success" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json = "{\"task_id\": \"task_12345\", \"code\": 0, \"msg\": \"success\"}";

    const response = try client.parseCreateResponse(response_json);
    try testing.expectEqual(@as(i32, 0), response.code);
    try testing.expectEqualStrings("success", response.msg);
    try testing.expectEqualStrings("task_12345", response.task_id.?);
}

test "SpeechClient: parseCreateResponse error" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json = "{\"code\": 1004, \"msg\": \"Invalid API key\"}";

    const response = try client.parseCreateResponse(response_json);
    try testing.expectEqual(@as(i32, 1004), response.code);
    try testing.expectEqualStrings("Invalid API key", response.msg);
    try testing.expect(response.task_id == null);
}

test "SpeechClient: parseQueryResponse success" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json = "{\"status\": \"Success\", \"task_id\": \"task_12345\", \"audio_duration\": 125.5, \"audio_size\": 5000000, \"file_id\": \"file_abc123\"}";

    const response = try client.parseQueryResponse(response_json);
    try testing.expectEqualStrings("Success", response.status);
    try testing.expectEqualStrings("task_12345", response.task_id.?);
    try testing.expectEqualStrings("file_abc123", response.file_id.?);
}

test "SpeechClient: parseQueryResponse fail" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json = "{\"status\": \"Fail\", \"task_id\": \"task_12345\", \"error_message\": \"Text contains invalid characters\"}";

    const response = try client.parseQueryResponse(response_json);
    try testing.expectEqualStrings("Fail", response.status);
    try testing.expectEqualStrings("Text contains invalid characters", response.error_message.?);
}

test "SpeechClient: parseQueryResponse pending" {
    const allocator = testing.allocator;

    var client = try speech.SpeechClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json = "{\"status\": \"Pending\", \"task_id\": \"task_12345\"}";

    const response = try client.parseQueryResponse(response_json);
    try testing.expectEqualStrings("Pending", response.status);
    try testing.expect(response.file_id == null);
    try testing.expect(response.error_message == null);
}

test "AsyncSpeechRequest: default values" {
    const request: speech.AsyncSpeechRequest = .{
        .text = "Test",
    };

    try testing.expectEqualStrings("speech-2.8-hd", request.model);
    try testing.expectEqualStrings("English_expressive_narrator", request.voice_setting.voice_id);
    try testing.expectEqual(@as(f32, 1.0), request.voice_setting.speed);
    try testing.expectEqual(@as(u32, 32000), request.audio_setting.audio_sample_rate);
    try testing.expectEqualStrings("mp3", request.audio_setting.format);
}

test "VoiceSetting: default values" {
    const voice: speech.VoiceSetting = .{};

    try testing.expectEqualStrings("English_expressive_narrator", voice.voice_id);
    try testing.expectEqual(@as(f32, 1.0), voice.speed);
    try testing.expectEqual(@as(f32, 1.0), voice.vol);
    try testing.expectEqual(@as(f32, 0), voice.pitch);
    try testing.expectEqual(false, voice.english_normalization);
}

test "AudioSetting: default values" {
    const audio: speech.AudioSetting = .{};

    try testing.expectEqual(@as(u32, 32000), audio.audio_sample_rate);
    try testing.expectEqual(@as(u32, 128000), audio.bitrate);
    try testing.expectEqualStrings("mp3", audio.format);
    try testing.expectEqual(@as(u32, 1), audio.channel);
}
