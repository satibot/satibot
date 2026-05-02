//! MiniMax Async Speech Generation API Implementation
//!
//! This module provides async text-to-speech synthesis using the MiniMax API.
//!
//! ## Features
//! - Long-form text-to-speech (up to 1M characters)
//! - Multiple voice models support
//! - Customizable voice settings (speed, pitch, volume)
//! - Audio settings (sample rate, bitrate, format, channel)
//! - Pronunciation dictionary support
//! - Voice modification effects
//! - Task polling and status checking
//! - File retrieval for completed audio
//!
//! ## API Endpoints
//! - Base URL: https://api.minimax.io
//! - Create Task: POST /v1/t2a_async_v2
//! - Query Status: GET /v1/query/t2a_async_query_v2
//! - Retrieve File: GET /v1/files/retrieve_content
//! - Authentication: Bearer token in Authorization header

const std = @import("std");

const http = @import("http");

pub const SpeechModel = struct {
    name: []const u8,
    description: []const u8,
};

pub const DEFAULT_MODEL = "speech-2.8-hd";
pub const DEFAULT_VOICE = "English_expressive_narrator";

pub const VoiceSetting = struct {
    voice_id: []const u8 = DEFAULT_VOICE,
    speed: f32 = 1.0,
    vol: f32 = 1.0,
    pitch: f32 = 0,
    english_normalization: bool = false,
};

pub const AudioSetting = struct {
    audio_sample_rate: u32 = 32000,
    bitrate: u32 = 128000,
    format: []const u8 = "mp3",
    channel: u32 = 1,
};

pub const VoiceModify = struct {
    pitch: f32 = 0,
    intensity: f32 = 0,
    timbre: f32 = 0,
    sound_effects: []const u8 = "",
};

pub const PronunciationDict = struct {
    tone: []const []const u8 = &.{},
};

pub const AsyncSpeechRequest = struct {
    model: []const u8 = DEFAULT_MODEL,
    text: []const u8 = "",
    text_file_id: ?[]const u8 = null,
    language_boost: []const u8 = "auto",
    voice_setting: VoiceSetting = .{},
    audio_setting: AudioSetting = .{},
    voice_modify: ?VoiceModify = null,
    pronunciation_dict: ?PronunciationDict = null,
};

pub const AsyncSpeechResponse = struct {
    task_id: ?[]const u8 = null,
    code: i32 = 0,
    msg: []const u8 = "",
};

pub const AsyncSpeechQueryResponse = struct {
    status: []const u8 = "",
    task_id: ?[]const u8 = null,
    audio_duration: ?f32 = null,
    audio_size: ?i64 = null,
    file_id: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const SpeechClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://api.minimax.io",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !SpeechClient {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *SpeechClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn createSpeechTask(self: *SpeechClient, request: AsyncSpeechRequest) !AsyncSpeechResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/t2a_async_v2", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildSpeechRequestBody(request);
        defer self.allocator.free(body);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            return error.ApiRequestFailed;
        }

        return self.parseCreateResponse(response.body);
    }

    pub fn queryTaskStatus(self: *SpeechClient, task_id: []const u8) !AsyncSpeechQueryResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/query/t2a_async_query_v2", .{self.api_base});
        defer self.allocator.free(url);

        const task_id_param = try std.fmt.allocPrint(self.allocator, "task_id={s}", .{task_id});
        defer self.allocator.free(task_id_param);

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ url, task_id_param });
        defer self.allocator.free(full_url);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var response = try self.client.get(full_url, headers);
        defer response.deinit();

        if (response.status != .ok) {
            return error.ApiRequestFailed;
        }

        return self.parseQueryResponse(response.body);
    }

    pub fn retrieveFileUrl(self: *SpeechClient, file_id: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/files/retrieve_content", .{self.api_base});
        defer self.allocator.free(url);

        const file_id_param = try std.fmt.allocPrint(self.allocator, "file_id={s}", .{file_id});
        defer self.allocator.free(file_id_param);

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ url, file_id_param });
        defer self.allocator.free(full_url);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var response = try self.client.get(full_url, headers);
        defer response.deinit();

        if (response.status != .ok) {
            return error.ApiRequestFailed;
        }

        return response.body;
    }

    fn buildSpeechRequestBody(self: *SpeechClient, request: AsyncSpeechRequest) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{");
        try writer.print("\"model\": \"{s}\",", .{request.model});

        if (request.text.len > 0) {
            try writer.print("\"text\": ", .{});
            try self.writeJsonString(writer, request.text);
            try writer.writeAll(",");
        }

        if (request.text_file_id) |file_id| {
            try writer.print("\"text_file_id\": ", .{});
            try self.writeJsonString(writer, file_id);
            try writer.writeAll(",");
        }

        try writer.print("\"language_boost\": \"{s}\",", .{request.language_boost});

        try writer.writeAll("\"voice_setting\": {");
        try writer.print("\"voice_id\": \"{s}\",", .{request.voice_setting.voice_id});
        try writer.print("\"speed\": {d},", .{request.voice_setting.speed});
        try writer.print("\"vol\": {d},", .{request.voice_setting.vol});
        try writer.print("\"pitch\": {d},", .{request.voice_setting.pitch});
        try writer.print("\"english_normalization\": {}", .{request.voice_setting.english_normalization});
        try writer.writeAll("},");

        try writer.writeAll("\"audio_setting\": {");
        try writer.print("\"audio_sample_rate\": {d},", .{request.audio_setting.audio_sample_rate});
        try writer.print("\"bitrate\": {d},", .{request.audio_setting.bitrate});
        try writer.print("\"format\": \"{s}\",", .{request.audio_setting.format});
        try writer.print("\"channel\": {d}", .{request.audio_setting.channel});
        try writer.writeAll("}");

        if (request.voice_modify) |modify| {
            try writer.writeAll(",\"voice_modify\": {");
            try writer.print("\"pitch\": {d},", .{modify.pitch});
            try writer.print("\"intensity\": {d},", .{modify.intensity});
            try writer.print("\"timbre\": {d}", .{modify.timbre});
            try writer.writeAll("}");
        }

        if (request.pronunciation_dict) |dict| {
            try writer.writeAll(",\"pronunciation_dict\": {");
            try writer.writeAll("\"tone\": [");
            for (dict.tone, 0..) |entry, i| {
                if (i > 0) try writer.writeAll(",");
                try self.writeJsonString(writer, entry);
            }
            try writer.writeAll("]");
            try writer.writeAll("}");
        }

        try writer.writeAll("}");

        return aw.toOwnedSlice();
    }

    fn writeJsonString(_: *SpeechClient, writer: anytype, text: []const u8) !void {
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

    fn parseCreateResponse(self: *SpeechClient, body: []const u8) !AsyncSpeechResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return .{
            .code = if (obj.get("code")) |v| @as(i32, @truncate(v.integer)) else 0,
            .msg = if (obj.get("msg")) |v| v.string else "",
            .task_id = if (obj.get("task_id")) |v| v.string else null,
        };
    }

    fn parseQueryResponse(self: *SpeechClient, body: []const u8) !AsyncSpeechQueryResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return .{
            .status = if (obj.get("status")) |v| v.string else "",
            .task_id = if (obj.get("task_id")) |v| v.string else null,
            .audio_duration = if (obj.get("audio_duration")) |v| @as(f32, @floatFromInt(v.integer)) else null,
            .audio_size = if (obj.get("audio_size")) |v| v.integer else null,
            .file_id = if (obj.get("file_id")) |v| v.string else null,
            .error_message = if (obj.get("error_message")) |v| v.string else null,
        };
    }
};
