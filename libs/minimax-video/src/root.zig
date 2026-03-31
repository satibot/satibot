//! MiniMax Video module exports
pub const video = @import("video.zig");
pub const VideoClient = video.VideoClient;
pub const VideoGenerationRequest = video.VideoGenerationRequest;
pub const TemplateGenerationRequest = video.TemplateGenerationRequest;

test {
    _ = video;
}
