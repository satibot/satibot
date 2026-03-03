//! MiniMax Music Generation API Implementation
//!
//! This module provides music and lyrics generation capabilities using the MiniMax API.
//!
//! ## Features
//! - Music generation with customizable style, mood, and vocals
//! - Lyrics generation from themes
//! - Configurable audio output settings
//!
//! ## API Endpoints
//! - Base URL: https://api.minimax.io
//! - Music Generation: /v1/music_generation
//! - Lyrics Generation: /v1/lyrics_generation
//! - Authentication: Bearer token in Authorization header

const std = @import("std");
const http = @import("http");

pub const AudioSetting = struct {
    sample_rate: u32 = 44100,
    bitrate: u32 = 256000,
    format: []const u8 = "mp3",
};

pub const MusicGenerationRequest = struct {
    model: []const u8 = "music-2.5",
    prompt: []const u8,
    lyrics: []const u8 = "",
    audio_setting: AudioSetting = .{},
    output_format: []const u8 = "url",
};

pub const LyricsGenerationRequest = struct {
    mode: []const u8 = "write_full_song",
    prompt: []const u8,
};

pub const MusicGenerationResponse = struct {
    allocator: std.mem.Allocator,
    code: i32,
    msg: []const u8,
    data: ?MusicData = null,

    pub fn deinit(self: *MusicGenerationResponse) void {
        if (self.data) |data| {
            if (data.audio) |audio| {
                self.allocator.free(audio);
            }
        }
        self.* = undefined;
    }
};

pub const MusicData = struct {
    audio: ?[]const u8 = null,
    audio_type: ?[]const u8 = null,
};

pub const LyricsGenerationResponse = struct {
    allocator: std.mem.Allocator,
    code: i32,
    msg: []const u8,
    data: ?LyricsData = null,

    pub fn deinit(self: *LyricsGenerationResponse) void {
        if (self.data) |data| {
            if (data.lyrics) |lyrics| {
                self.allocator.free(lyrics);
            }
        }
        self.* = undefined;
    }
};

pub const LyricsData = struct {
    lyrics: ?[]const u8 = null,
};

pub const MusicClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://api.minimax.io",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !MusicClient {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *MusicClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn generateMusic(self: *MusicClient, request: MusicGenerationRequest) !MusicGenerationResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/music_generation", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildMusicRequestBody(request);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("[Minimax Music] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        return self.parseMusicResponse(response.body);
    }

    pub fn generateLyrics(self: *MusicClient, request: LyricsGenerationRequest) !LyricsGenerationResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/lyrics_generation", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildLyricsRequestBody(request);
        defer self.allocator.free(body);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("[Minimax Lyrics] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        return self.parseLyricsResponse(response.body);
    }

    fn buildMusicRequestBody(self: *MusicClient, request: MusicGenerationRequest) ![]u8 {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        const writer = json_buf.writer(self.allocator);

        try writer.writeAll("{");
        try writer.print("\"model\": \"{s}\",", .{request.model});
        try writer.print("\"prompt\": ", .{});
        try self.writeJsonString(writer, request.prompt);
        try writer.writeAll(",");

        if (request.lyrics.len > 0) {
            try writer.print("\"lyrics\": ", .{});
            try self.writeJsonString(writer, request.lyrics);
            try writer.writeAll(",");
        }

        try writer.writeAll("\"audio_setting\": {");
        try writer.print("\"sample_rate\": {d},", .{request.audio_setting.sample_rate});
        try writer.print("\"bitrate\": {d},", .{request.audio_setting.bitrate});
        try writer.print("\"format\": \"{s}\"", .{request.audio_setting.format});
        try writer.writeAll("},");

        try writer.print("\"output_format\": \"{s}\"", .{request.output_format});
        try writer.writeAll("}");

        return json_buf.toOwnedSlice(self.allocator);
    }

    fn buildLyricsRequestBody(self: *MusicClient, request: LyricsGenerationRequest) ![]u8 {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        const writer = json_buf.writer(self.allocator);

        try writer.writeAll("{");
        try writer.print("\"mode\": \"{s}\",", .{request.mode});
        try writer.print("\"prompt\": ", .{});
        try self.writeJsonString(writer, request.prompt);
        try writer.writeAll("}");

        return json_buf.toOwnedSlice(self.allocator);
    }

    fn writeJsonString(_: *MusicClient, writer: anytype, text: []const u8) !void {
        try writer.writeAll("\"");
        for (text) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"");
    }

    fn parseMusicResponse(self: *MusicClient, body: []const u8) !MusicGenerationResponse {
        const Response = struct {
            code: i32,
            msg: []const u8,
            data: ?struct {
                audio: ?[]const u8 = null,
                audio_type: ?[]const u8 = null,
            } = null,
        };

        const parsed = try std.json.parseFromSlice(Response, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var response: MusicGenerationResponse = .{
            .allocator = self.allocator,
            .code = parsed.value.code,
            .msg = try self.allocator.dupe(u8, parsed.value.msg),
        };

        if (parsed.value.data) |data| {
            var music_data: MusicData = .{};
            if (data.audio) |audio| {
                music_data.audio = try self.allocator.dupe(u8, audio);
            }
            if (data.audio_type) |audio_type| {
                music_data.audio_type = try self.allocator.dupe(u8, audio_type);
            }
            response.data = music_data;
        }

        return response;
    }

    fn parseLyricsResponse(self: *MusicClient, body: []const u8) !LyricsGenerationResponse {
        const Response = struct {
            code: i32,
            msg: []const u8,
            data: ?struct {
                lyrics: ?[]const u8 = null,
            } = null,
        };

        const parsed = try std.json.parseFromSlice(Response, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var response: LyricsGenerationResponse = .{
            .allocator = self.allocator,
            .code = parsed.value.code,
            .msg = try self.allocator.dupe(u8, parsed.value.msg),
        };

        if (parsed.value.data) |data| {
            var lyrics_data: LyricsData = .{};
            if (data.lyrics) |lyrics| {
                lyrics_data.lyrics = try self.allocator.dupe(u8, lyrics);
            }
            response.data = lyrics_data;
        }

        return response;
    }
};

test "MusicClient: init and deinit" {
    const allocator = std.testing.allocator;
    var client = try MusicClient.init(allocator, "test-api-key");
    defer client.deinit();

    try std.testing.expectEqual(allocator, client.allocator);
    try std.testing.expectEqualStrings("test-api-key", client.api_key);
    try std.testing.expectEqualStrings("https://api.minimax.io", client.api_base);
}

test "MusicClient: buildMusicRequestBody" {
    const allocator = std.testing.allocator;
    var client = try MusicClient.init(allocator, "test-api-key");
    defer client.deinit();

    const request: MusicGenerationRequest = .{
        .model = "music-2.5",
        .prompt = "Soulful Blues, Rainy Night",
        .lyrics = "[Verse 1]\nTest lyrics",
    };

    const body = try client.buildMusicRequestBody(request);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\": \"music-2.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lyrics\":") != null);
}

test "MusicClient: buildLyricsRequestBody" {
    const allocator = std.testing.allocator;
    var client = try MusicClient.init(allocator, "test-api-key");
    defer client.deinit();

    const request: LyricsGenerationRequest = .{
        .mode = "write_full_song",
        .prompt = "A soulful blues song about a rainy night",
    };

    const body = try client.buildLyricsRequestBody(request);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\": \"write_full_song\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":") != null);
}
