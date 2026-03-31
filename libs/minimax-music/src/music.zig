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
    model: []const u8 = "music-2.5+",
    prompt: []const u8,
    lyrics: []const u8 = "",
    audio_setting: AudioSetting = .{},
    output_format: []const u8 = "hex",
    /// Auto-generate lyrics from prompt (default: false)
    lyrics_optimizer: bool = false,
    /// Generate instrumental music (default: false, music-2.5+ only)
    is_instrumental: bool = false,
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
    trace_id: ?[]const u8 = null,
    extra_info: ?ExtraInfo = null,
    analysis_info: ?std.json.Value = null,

    pub fn deinit(self: *MusicGenerationResponse) void {
        if (self.data) |data| {
            if (data.audio) |audio| {
                self.allocator.free(audio);
            }
        }
        if (self.trace_id) |trace_id| {
            self.allocator.free(trace_id);
        }
        self.* = undefined;
    }
};

pub const MusicData = struct {
    audio: ?[]const u8 = null,
    audio_type: ?[]const u8 = null,
    status: ?i32 = null,
};

pub const ExtraInfo = struct {
    music_duration: ?i64 = null,
    music_sample_rate: ?i32 = null,
    music_channel: ?i32 = null,
    bitrate: ?i32 = null,
    music_size: ?i64 = null,
};

pub const LyricsGenerationResponse = struct {
    allocator: std.mem.Allocator,
    code: i32,
    msg: []const u8,
    data: ?LyricsData = null,
    song_title: ?[]const u8 = null,
    style_tags: ?[]const u8 = null,

    pub fn deinit(self: *LyricsGenerationResponse) void {
        if (self.data) |data| {
            if (data.lyrics) |lyrics| {
                self.allocator.free(lyrics);
            }
        }
        if (self.song_title) |title| {
            self.allocator.free(title);
        }
        if (self.style_tags) |tags| {
            self.allocator.free(tags);
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
        // Validate request parameters
        try self.validateMusicRequest(request);

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

        try writer.print("\"lyrics\": ", .{});
        try self.writeJsonString(writer, request.lyrics);
        try writer.writeAll(",");

        try writer.writeAll("\"audio_setting\": {");
        try writer.print("\"sample_rate\": {d},", .{request.audio_setting.sample_rate});
        try writer.print("\"bitrate\": {d},", .{request.audio_setting.bitrate});
        try writer.print("\"format\": \"{s}\"", .{request.audio_setting.format});
        try writer.writeAll("},");

        try writer.print("\"output_format\": \"{s}\"", .{request.output_format});
        if (request.lyrics_optimizer) {
            try writer.writeAll(",\"lyrics_optimizer\": true");
        }
        if (request.is_instrumental) {
            try writer.writeAll(",\"is_instrumental\": true");
        }
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

    fn validateMusicRequest(_: *MusicClient, request: MusicGenerationRequest) !void {
        // Validate prompt length (max 2000 characters)
        if (request.prompt.len > 2000) {
            return error.PromptTooLong;
        }

        // For non-instrumental music, lyrics are required (1-3500 characters)
        if (!request.is_instrumental) {
            if (request.lyrics.len == 0 and !request.lyrics_optimizer) {
                return error.LyricsRequired;
            }
            if (request.lyrics.len > 3500) {
                return error.LyricsTooLong;
            }
        }

        // Validate audio settings
        if (request.audio_setting.sample_rate != 16000 and
            request.audio_setting.sample_rate != 24000 and
            request.audio_setting.sample_rate != 32000 and
            request.audio_setting.sample_rate != 44100)
        {
            return error.InvalidSampleRate;
        }

        if (request.audio_setting.bitrate != 32000 and
            request.audio_setting.bitrate != 64000 and
            request.audio_setting.bitrate != 128000 and
            request.audio_setting.bitrate != 256000)
        {
            return error.InvalidBitrate;
        }

        if (!std.mem.eql(u8, request.audio_setting.format, "mp3") and
            !std.mem.eql(u8, request.audio_setting.format, "wav") and
            !std.mem.eql(u8, request.audio_setting.format, "pcm"))
        {
            return error.InvalidAudioFormat;
        }

        // Validate model
        if (!std.mem.eql(u8, request.model, "music-2.5") and
            !std.mem.eql(u8, request.model, "music-2.5+"))
        {
            return error.InvalidModel;
        }

        // Validate output format
        if (!std.mem.eql(u8, request.output_format, "url") and
            !std.mem.eql(u8, request.output_format, "hex"))
        {
            return error.InvalidOutputFormat;
        }
    }

    fn parseMusicResponse(self: *MusicClient, body: []const u8) !MusicGenerationResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) {
            return error.InvalidResponse;
        }

        // Check for base_resp which contains error information
        if (parsed.value.object.get("base_resp")) |base_resp| {
            if (base_resp == .object) {
                if (base_resp.object.get("status_code")) |status_code| {
                    const code = @as(i32, @intCast(status_code.integer));
                    if (code != 0) {
                        const msg = if (base_resp.object.get("status_msg")) |msg_val|
                            msg_val.string
                        else
                            "Unknown error";
                        std.debug.print("API Error ({d}): {s}\n", .{ code, msg });
                        return error.ApiRequestFailed;
                    }
                }
            }
        }

        var response: MusicGenerationResponse = .{
            .allocator = self.allocator,
            .code = if (parsed.value.object.get("code")) |code_val| @intCast(code_val.integer) else 0,
            .msg = if (parsed.value.object.get("msg")) |msg_val| try self.allocator.dupe(u8, msg_val.string) else "",
        };

        // Parse trace_id
        if (parsed.value.object.get("trace_id")) |trace_id_val| {
            if (trace_id_val == .string) {
                response.trace_id = try self.allocator.dupe(u8, trace_id_val.string);
            }
        }

        // Parse extra_info
        if (parsed.value.object.get("extra_info")) |extra_info_val| {
            if (extra_info_val == .object) {
                var info: ExtraInfo = .{};
                if (extra_info_val.object.get("music_duration")) |val| {
                    info.music_duration = @as(i64, @intCast(val.integer));
                }
                if (extra_info_val.object.get("music_sample_rate")) |val| {
                    info.music_sample_rate = @as(i32, @intCast(val.integer));
                }
                if (extra_info_val.object.get("music_channel")) |val| {
                    info.music_channel = @as(i32, @intCast(val.integer));
                }
                if (extra_info_val.object.get("bitrate")) |val| {
                    info.bitrate = @as(i32, @intCast(val.integer));
                }
                if (extra_info_val.object.get("music_size")) |val| {
                    info.music_size = @as(i64, @intCast(val.integer));
                }
                response.extra_info = info;
            }
        }

        // Parse analysis_info (keep as JSON value for flexibility)
        if (parsed.value.object.get("analysis_info")) |analysis_info_val| {
            response.analysis_info = analysis_info_val;
        }

        if (parsed.value.object.get("data")) |data_val| {
            if (data_val == .object) {
                var music_data: MusicData = .{};
                if (data_val.object.get("audio")) |audio_val| {
                    if (audio_val == .string) {
                        music_data.audio = try self.allocator.dupe(u8, audio_val.string);
                    }
                }
                if (data_val.object.get("audio_type")) |audio_type_val| {
                    if (audio_type_val == .string) {
                        music_data.audio_type = try self.allocator.dupe(u8, audio_type_val.string);
                    }
                }
                if (data_val.object.get("status")) |status_val| {
                    music_data.status = @as(i32, @intCast(status_val.integer));
                }
                response.data = music_data;
            }
        }

        return response;
    }

    fn parseLyricsResponse(self: *MusicClient, body: []const u8) !LyricsGenerationResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) {
            return error.InvalidResponse;
        }

        // Check for base_resp which contains error information
        if (parsed.value.object.get("base_resp")) |base_resp| {
            if (base_resp == .object) {
                if (base_resp.object.get("status_code")) |status_code| {
                    const code = @as(i32, @intCast(status_code.integer));
                    if (code != 0) {
                        const msg = if (base_resp.object.get("status_msg")) |msg_val|
                            msg_val.string
                        else
                            "Unknown error";
                        std.debug.print("API Error ({d}): {s}\n", .{ code, msg });
                        return error.ApiRequestFailed;
                    }
                }
            }
        }

        var response: LyricsGenerationResponse = .{
            .allocator = self.allocator,
            .code = if (parsed.value.object.get("base_resp")) |base_resp|
                if (base_resp.object.get("status_code")) |status_code|
                    @as(i32, @intCast(status_code.integer))
                else
                    0
            else
                0,
            .msg = if (parsed.value.object.get("base_resp")) |base_resp|
                if (base_resp.object.get("status_msg")) |msg_val|
                    try self.allocator.dupe(u8, msg_val.string)
                else
                    ""
            else
                "",
        };

        // The lyrics are directly in the response, not in a data object
        if (parsed.value.object.get("lyrics")) |lyrics_val| {
            if (lyrics_val == .string) {
                var lyrics_data: LyricsData = .{};
                lyrics_data.lyrics = try self.allocator.dupe(u8, lyrics_val.string);
                response.data = lyrics_data;
            }
        }

        // Parse song_title
        if (parsed.value.object.get("song_title")) |title_val| {
            if (title_val == .string) {
                response.song_title = try self.allocator.dupe(u8, title_val.string);
            }
        }

        // Parse style_tags
        if (parsed.value.object.get("style_tags")) |tags_val| {
            if (tags_val == .string) {
                response.style_tags = try self.allocator.dupe(u8, tags_val.string);
            }
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
        .model = "music-2.5+",
        .prompt = "Soulful Blues, Rainy Night",
        .lyrics = "[Verse 1]\nTest lyrics",
        .lyrics_optimizer = true,
        .is_instrumental = false,
    };

    const body = try client.buildMusicRequestBody(request);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\": \"music-2.5+\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lyrics\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lyrics_optimizer\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_instrumental\"") == null);
}

test "MusicClient: buildMusicRequestBody with instrumental" {
    const allocator = std.testing.allocator;
    var client = try MusicClient.init(allocator, "test-api-key");
    defer client.deinit();

    const request: MusicGenerationRequest = .{
        .model = "music-2.5",
        .prompt = "Electronic Dance Music",
        .lyrics = "",
        .lyrics_optimizer = false,
        .is_instrumental = true,
    };

    const body = try client.buildMusicRequestBody(request);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\": \"music-2.5+\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_instrumental\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"lyrics_optimizer\"") == null);
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
