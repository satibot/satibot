//! MiniMax Video Generation API Implementation
//!
//! This module provides video generation capabilities using the MiniMax API.
//!
//! ## Features
//! - Text-to-Video generation
//! - Image-to-Video generation
//! - First-and-Last-Frame-to-Video generation
//! - Subject-Reference-to-Video generation
//! - Template-based video generation
//! - Async task polling with automatic status checking
//!
//! ## API Endpoints
//! - Base URL: https://api.minimax.io
//! - Video Generation: POST /v1/video_generation
//! - Query Video Status: GET /v1/query/video_generation
//! - Template Generation: POST /v1/video_template_generation
//! - Query Template Status: GET /v1/query/video_template_generation
//! - Retrieve File: GET /v1/files/retrieve
//! - Authentication: Bearer token in Authorization header

const std = @import("std");

const http = @import("http");

pub const VideoGenerationRequest = struct {
    model: []const u8 = "MiniMax-Hailuo-2.3",
    prompt: []const u8,
    duration: u8 = 6,
    resolution: []const u8 = "1080P",
    first_frame_image: ?[]const u8 = null,
    last_frame_image: ?[]const u8 = null,
    subject_reference: ?SubjectReference = null,
};

pub const SubjectReference = struct {
    type: []const u8 = "character",
    images: []const []const u8,
};

pub const VideoGenerationResponse = struct {
    task_id: ?[]const u8 = null,
    code: i32 = 0,
    msg: []const u8 = "",
};

pub const VideoQueryResponse = struct {
    status: []const u8,
    file_id: ?[]const u8 = null,
    video_url: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const FileRetrieveResponse = struct {
    download_url: ?[]const u8 = null,
};

pub const TemplateGenerationRequest = struct {
    template_id: []const u8,
    media_inputs: []const MediaInput = &.{},
    text_inputs: []const TextInput = &.{},
};

pub const MediaInput = struct {
    value: []const u8,
};

pub const TextInput = struct {
    value: []const u8,
};

pub const TemplateGenerationResponse = struct {
    task_id: ?[]const u8 = null,
    code: i32 = 0,
    msg: []const u8 = "",
};

pub const VideoClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://api.minimax.io",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !VideoClient {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *VideoClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn generateVideo(self: *VideoClient, request: VideoGenerationRequest) !VideoGenerationResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/video_generation", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildVideoRequestBody(request);
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

        return self.parseVideoResponse(response.body);
    }

    pub fn generateTemplateVideo(self: *VideoClient, request: TemplateGenerationRequest) !TemplateGenerationResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/video_template_generation", .{self.api_base});
        defer self.allocator.free(url);

        const body = try self.buildTemplateRequestBody(request);
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

        return self.parseTemplateResponse(response.body);
    }

    pub fn queryVideoStatus(self: *VideoClient, task_id: []const u8) !VideoQueryResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/query/video_generation", .{self.api_base});
        defer self.allocator.free(url);

        const task_id_param = try std.fmt.allocPrint(self.allocator, "task_id={s}", .{task_id});
        defer self.allocator.free(task_id_param);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var response = try self.client.get(url, headers);
        defer response.deinit();

        if (response.status != .ok) {
            return error.ApiRequestFailed;
        }

        return self.parseQueryResponse(response.body);
    }

    pub fn queryTemplateVideoStatus(self: *VideoClient, task_id: []const u8) !VideoQueryResponse {
        const base_url = try std.fmt.allocPrint(self.allocator, "{s}/v1/query/video_template_generation", .{self.api_base});
        defer self.allocator.free(base_url);

        const task_id_param = try std.fmt.allocPrint(self.allocator, "task_id={s}", .{task_id});
        defer self.allocator.free(task_id_param);

        const url = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ base_url, task_id_param });
        defer self.allocator.free(url);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var response = try self.client.get(url, headers);
        defer response.deinit();

        if (response.status != .ok) {
            return error.ApiRequestFailed;
        }

        return self.parseQueryResponse(response.body);
    }

    pub fn retrieveFile(self: *VideoClient, file_id: []const u8) !FileRetrieveResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/files/retrieve", .{self.api_base});
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

        return self.parseFileResponse(response.body);
    }

    fn buildVideoRequestBody(self: *VideoClient, request: VideoGenerationRequest) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{");
        try writer.print("\"model\": \"{s}\",", .{request.model});
        try writer.print("\"prompt\": ", .{});
        try self.writeJsonString(writer, request.prompt);
        try writer.writeAll(",");
        try writer.print("\"duration\": {d},", .{request.duration});
        try writer.print("\"resolution\": \"{s}\"", .{request.resolution});

        if (request.first_frame_image) |img| {
            try writer.writeAll(",");
            try writer.print("\"first_frame_image\": ", .{});
            try self.writeJsonString(writer, img);
        }

        if (request.last_frame_image) |img| {
            try writer.writeAll(",");
            try writer.print("\"last_frame_image\": ", .{});
            try self.writeJsonString(writer, img);
        }

        if (request.subject_reference) |sr| {
            try writer.writeAll(",\"subject_reference\": [");
            try writer.writeAll("{");
            try writer.print("\"type\": \"{s}\",", .{sr.type});
            try writer.writeAll("\"image\": [");
            for (sr.images, 0..) |img, i| {
                if (i > 0) try writer.writeAll(",");
                try self.writeJsonString(writer, img);
            }
            try writer.writeAll("]");
            try writer.writeAll("}]");
        }

        try writer.writeAll("}");

        return aw.toOwnedSlice();
    }

    fn buildTemplateRequestBody(self: *VideoClient, request: TemplateGenerationRequest) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{");
        try writer.print("\"template_id\": \"{s}\",", .{request.template_id});

        try writer.writeAll("\"media_inputs\": [");
        for (request.media_inputs, 0..) |input, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"value\": ", .{});
            try self.writeJsonString(writer, input.value);
            try writer.writeAll("}");
        }
        try writer.writeAll("],");

        try writer.writeAll("\"text_inputs\": [");
        for (request.text_inputs, 0..) |input, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"value\": ", .{});
            try self.writeJsonString(writer, input.value);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll("}");

        return aw.toOwnedSlice();
    }

    fn writeJsonString(_: *VideoClient, writer: anytype, text: []const u8) !void {
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

    fn parseVideoResponse(self: *VideoClient, body: []const u8) !VideoGenerationResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return .{
            .code = if (obj.get("code")) |v| @as(i32, @truncate(v.integer)) else 0,
            .msg = if (obj.get("msg")) |v| v.string else "",
            .task_id = if (obj.get("task_id")) |v| v.string else null,
        };
    }

    fn parseTemplateResponse(self: *VideoClient, body: []const u8) !TemplateGenerationResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return .{
            .code = if (obj.get("code")) |v| @as(i32, @truncate(v.integer)) else 0,
            .msg = if (obj.get("msg")) |v| v.string else "",
            .task_id = if (obj.get("task_id")) |v| v.string else null,
        };
    }

    fn parseQueryResponse(self: *VideoClient, body: []const u8) !VideoQueryResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return .{
            .status = if (obj.get("status")) |v| v.string else "",
            .file_id = if (obj.get("file_id")) |v| v.string else null,
            .video_url = if (obj.get("video_url")) |v| v.string else null,
            .error_message = if (obj.get("error_message")) |v| v.string else null,
        };
    }

    fn parseFileResponse(self: *VideoClient, body: []const u8) !FileRetrieveResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const file_obj = obj.get("file") orelse return .{ .download_url = null };
        return .{
            .download_url = if (file_obj.object.get("download_url")) |v| v.string else null,
        };
    }
};
