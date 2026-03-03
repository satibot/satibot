//! MiniMax Music module exports
pub const music = @import("music.zig");
pub const MusicClient = music.MusicClient;
pub const MusicGenerationRequest = music.MusicGenerationRequest;
pub const LyricsGenerationRequest = music.LyricsGenerationRequest;

test {
    _ = music;
}
