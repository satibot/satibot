//! MiniMax Speech module exports
pub const speech = @import("speech.zig");
pub const SpeechClient = speech.SpeechClient;
pub const AsyncSpeechRequest = speech.AsyncSpeechRequest;
pub const AsyncSpeechQueryResponse = speech.AsyncSpeechQueryResponse;

test {
    _ = speech;
}
