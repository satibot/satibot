const std = @import("std");
const video = @import("minimax-video").video;
const testing = std.testing;

test "VideoClient: buildVideoRequestBody for text-to-video" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const request: video.VideoGenerationRequest = .{
        .model = "MiniMax-Hailuo-2.3",
        .prompt = "A dancer performing on a beach",
        .duration = 6,
        .resolution = "1080P",
    };

    const body = try client.buildVideoRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"prompt\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"MiniMax-Hailuo-2.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"duration\": 6") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"resolution\": \"1080P\"") != null);
}

test "VideoClient: buildVideoRequestBody for image-to-video" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const request: video.VideoGenerationRequest = .{
        .model = "MiniMax-Hailuo-2.3",
        .prompt = "The dancer moves gracefully",
        .duration = 6,
        .resolution = "1080P",
        .first_frame_image = "https://example.com/image.jpg",
    };

    const body = try client.buildVideoRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"first_frame_image\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "https://example.com/image.jpg") != null);
}

test "VideoClient: buildVideoRequestBody for first-last-frame video" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const request: video.VideoGenerationRequest = .{
        .model = "MiniMax-Hailuo-02",
        .prompt = "A flower blooming",
        .duration = 6,
        .resolution = "1080P",
        .first_frame_image = "https://example.com/start.jpg",
        .last_frame_image = "https://example.com/end.jpg",
    };

    const body = try client.buildVideoRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"first_frame_image\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"last_frame_image\"") != null);
}

test "VideoClient: buildVideoRequestBody for subject-reference video" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const request: video.VideoGenerationRequest = .{
        .model = "S2V-01",
        .prompt = "Person walking in park",
        .duration = 6,
        .resolution = "1080P",
        .subject_reference = .{
            .type = "character",
            .images = &.{"https://example.com/face.jpg"},
        },
    };

    const body = try client.buildVideoRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"subject_reference\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"character\"") != null);
}

test "VideoClient: buildTemplateRequestBody" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const request: video.TemplateGenerationRequest = .{
        .template_id = "393769180141805569",
        .media_inputs = &.{.{ .value = "https://cdn.hailuoai.com/image.jpg" }},
        .text_inputs = &.{.{ .value = "Lion" }},
    };

    const body = try client.buildTemplateRequestBody(request);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"template_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"393769180141805569\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"media_inputs\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"text_inputs\"") != null);
}

test "VideoClient: parseVideoResponse" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json =
        \\{"task_id": "12345", "code": 0, "msg": "success"}
    ;

    const response = try client.parseVideoResponse(response_json);
    try testing.expectEqual(@as(i32, 0), response.code);
    try testing.expectEqualStrings("success", response.msg);
    try testing.expectEqualStrings("12345", response.task_id.?);
}

test "VideoClient: parseQueryResponse success" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json =
        \\{"status": "Success", "file_id": "file_abc123"}
    ;

    const response = try client.parseQueryResponse(response_json);
    try testing.expectEqualStrings("Success", response.status);
    try testing.expectEqualStrings("file_abc123", response.file_id.?);
}

test "VideoClient: parseQueryResponse fail" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json =
        \\{"status": "Fail", "error_message": "Generation failed"}
    ;

    const response = try client.parseQueryResponse(response_json);
    try testing.expectEqualStrings("Fail", response.status);
    try testing.expectEqualStrings("Generation failed", response.error_message.?);
}

test "VideoClient: parseTemplateResponse" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json =
        \\{"task_id": "67890", "code": 0, "msg": "success"}
    ;

    const response = try client.parseTemplateResponse(response_json);
    try testing.expectEqual(@as(i32, 0), response.code);
    try testing.expectEqualStrings("success", response.msg);
    try testing.expectEqualStrings("67890", response.task_id.?);
}

test "VideoClient: parseFileResponse" {
    const allocator = testing.allocator;

    var client = try video.VideoClient.init(allocator, "test-key");
    defer client.deinit();

    const response_json =
        \\{"file": {"download_url": "https://example.com/video.mp4"}}
    ;

    const response = try client.parseFileResponse(response_json);
    try testing.expectEqualStrings("https://example.com/video.mp4", response.download_url.?);
}

test "VideoGenerationRequest: default values" {
    const request: video.VideoGenerationRequest = .{
        .prompt = "Test prompt",
    };

    try testing.expectEqualStrings("MiniMax-Hailuo-2.3", request.model);
    try testing.expectEqual(@as(u8, 6), request.duration);
    try testing.expectEqualStrings("1080P", request.resolution);
    try testing.expectEqual(null, request.first_frame_image);
    try testing.expectEqual(null, request.last_frame_image);
    try testing.expectEqual(null, request.subject_reference);
}

test "SubjectReference: default values" {
    const sr: video.SubjectReference = .{
        .images = &.{"https://example.com/image.jpg"},
    };

    try testing.expectEqualStrings("character", sr.type);
    try testing.expectEqual(@as(usize, 1), sr.images.len);
}
