const std = @import("std");
const music = @import("minimax-music").music;
const testing = std.testing;

// Import the saveHexAsMp3 function from main.zig
// Since it's't exported, we'll need to test it through integration tests
// or make it exportable. For now, let's test the music library functionality.

test "MusicClient: parseMusicResponse with URL audio type" {
    const allocator = testing.allocator;

    const url_response_json =
        \\{
        \\  "code": 0,
        \\  "msg": "success",
        \\  "data": {
        \\    "audio": "https://example.com/music.mp3",
        \\    "audio_type": "url",
        \\    "status": 1
        \\  }
        \\}
    ;

    var client = try music.MusicClient.init(allocator, "test-key");
    defer client.deinit();

    var url_response = try client.parseMusicResponse(url_response_json);
    defer url_response.deinit();

    try testing.expectEqual(@as(i32, 0), url_response.code);
    try testing.expect(url_response.data != null);
    try testing.expect(url_response.data.?.audio != null);
    try testing.expect(url_response.data.?.audio_type != null);
    try testing.expectEqualStrings("url", url_response.data.?.audio_type.?);
    try testing.expectEqualStrings("https://example.com/music.mp3", url_response.data.?.audio.?);
}

test "MusicClient: parseMusicResponse with hex audio type" {
    const allocator = testing.allocator;

    const hex_response_json =
        \\{
        \\  "code": 0,
        \\  "msg": "success",
        \\  "data": {
        \\    "audio": "48656c6c6f20576f726c64",
        \\    "audio_type": "hex",
        \\    "status": 1
        \\  }
        \\}
    ;

    var client = try music.MusicClient.init(allocator, "test-key");
    defer client.deinit();

    var hex_response = try client.parseMusicResponse(hex_response_json);
    defer hex_response.deinit();

    try testing.expectEqual(@as(i32, 0), hex_response.code);
    try testing.expect(hex_response.data != null);
    try testing.expect(hex_response.data.?.audio != null);
    try testing.expect(hex_response.data.?.audio_type != null);
    try testing.expectEqualStrings("hex", hex_response.data.?.audio_type.?);
    try testing.expectEqualStrings("48656c6c6f20576f726c64", hex_response.data.?.audio.?);
}

test "MusicClient: buildMusicRequestBody with instrumental mode" {
    const allocator = testing.allocator;

    var client = try music.MusicClient.init(allocator, "test-key");
    defer client.deinit();

    const request: music.MusicGenerationRequest = .{
        .prompt = "Electronic Dance Music",
        .lyrics = "",
        .is_instrumental = true,
        .lyrics_optimizer = false,
    };

    const body = try client.buildMusicRequestBody(request);
    defer allocator.free(body);

    // Verify the request contains is_instrumental: true
    try testing.expect(std.mem.indexOf(u8, body, "\"is_instrumental\": true") != null);
    // Verify lyrics_optimizer is not present
    try testing.expect(std.mem.indexOf(u8, body, "\"lyrics_optimizer\"") == null);
}

test "MusicClient: buildMusicRequestBody with lyrics optimizer" {
    const allocator = testing.allocator;

    var client = try music.MusicClient.init(allocator, "test-key");
    defer client.deinit();

    const request: music.MusicGenerationRequest = .{
        .prompt = "Pop song about summer",
        .lyrics = "",
        .is_instrumental = false,
        .lyrics_optimizer = true,
    };

    const body = try client.buildMusicRequestBody(request);
    defer allocator.free(body);

    // Verify the request contains lyrics_optimizer: true
    try testing.expect(std.mem.indexOf(u8, body, "\"lyrics_optimizer\": true") != null);
    // Verify is_instrumental is not present
    try testing.expect(std.mem.indexOf(u8, body, "\"is_instrumental\"") == null);
}

test "hex to binary conversion logic" {
    // Test the hex conversion logic that saveHexAsMp3 uses
    const hex_data = "48656c6c6f"; // "Hello" in hex
    const expected = "Hello";

    const binary_size = hex_data.len / 2;
    var binary_data: [binary_size]u8 = undefined;

    for (0..binary_size) |i| {
        const high_byte = std.fmt.charToDigit(hex_data[i * 2], 16) catch unreachable;
        const low_byte = std.fmt.charToDigit(hex_data[i * 2 + 1], 16) catch unreachable;
        binary_data[i] = @as(u8, @intCast(high_byte * 16 + low_byte));
    }

    try testing.expectEqualStrings(expected, &binary_data);
}

test "hex to binary with odd length" {
    // Test that odd length hex data is handled gracefully
    const hex_data = "48656c6c6"; // Odd length - last character should be ignored
    const expected = "Hell"; // Only 4 bytes from 9 hex characters

    const binary_size = hex_data.len / 2;
    var binary_data: [binary_size]u8 = undefined;

    for (0..binary_size) |i| {
        const high_byte = std.fmt.charToDigit(hex_data[i * 2], 16) catch continue;
        const low_byte = std.fmt.charToDigit(hex_data[i * 2 + 1], 16) catch continue;
        binary_data[i] = @as(u8, @intCast(high_byte * 16 + low_byte));
    }

    try testing.expectEqualStrings(expected, &binary_data);
}
