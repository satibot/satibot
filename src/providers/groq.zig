const std = @import("std");
const http = @import("../http.zig");
const base = @import("base.zig");

/// GroqProvider implements the LLM and specific service interface for Groq.
/// Groq is used primarily for its ultra-fast inference and efficient audio transcription (Whisper).
/// This implementation follows Groq's API which is compatible with OpenAI's API format.
pub const GroqProvider = struct {
    allocator: std.mem.Allocator,

    // The HTTP client instance used for making API requests.
    // We use a wrapper around the standard HTTP client to handle connection reuse and TLS consistently.
    client: http.Client,

    // The API key for authenticating with Groq services.
    api_key: []const u8,

    // The base URL for the API. Defaults to Groq's OpenAI-compatible endpoint.
    api_base: []const u8 = "https://api.groq.com/openai/v1",

    /// Initialize the GroqProvider.
    ///
    /// Arguments:
    /// - allocator: used for memory allocation throughout the provider's lifetime.
    /// - api_key: Groq API key string.
    ///
    /// Returns: A new instance of GroqProvider or an error if initialization (like HTTP client) fails.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !GroqProvider {
        return .{
            .allocator = allocator,
            // Initialize the HTTP client. This involves setting up root certificates for TLS.
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    /// Clean up resources held by the provider.
    /// This should be called when the provider is no longer needed to free the HTTP client resources.
    pub fn deinit(self: *GroqProvider) void {
        self.client.deinit();
    }

    /// Transcribe an audio file using Groq's Whisper model implementation.
    ///
    /// Why this is needed:
    /// Telegram voice messages are downloaded as binary files (OGG/OGA). To process them with an LLM,
    /// we first need to convert this audio to text. Groq offers extremely fast Whisper transcription.
    ///
    /// Arguments:
    /// - file_content: The binary content of the audio file.
    /// - filename: The name of the file. Essential because the API infers the file format/extension from this.
    ///
    /// Returns: The transcribed text string. Caller owns the memory.
    pub fn transcribe(self: *GroqProvider, file_content: []const u8, filename: []const u8) ![]const u8 {
        // Construct the full endpoint URL for transcriptions.
        const url = try std.fmt.allocPrint(self.allocator, "{s}/audio/transcriptions", .{self.api_base});
        defer self.allocator.free(url);

        // Define a multipart boundary.
        // We use a distinct string to separate different parts of the form data (fields, files).
        // It must not appear inside the file content, though this simple one is generally safe for typical usage.
        const boundary = "----SatibotBoundary" ++ "0123456789ABCDEF";

        // We construct the multipart/form-data body manually to have full control.
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);

        // Usage of a writer allows convenient formatted printing into the ArrayList.
        const w = body.writer(self.allocator);

        // --- PART 1: Model Field ---
        // Groq requires specifying the model. We use "whisper-large-v3" for the best accuracy.
        // Format:
        // --BOUNDARY
        // Content-Disposition: form-data; name="field_name"
        //
        // value
        try w.print("--{s}\r\n", .{boundary});
        try w.writeAll("Content-Disposition: form-data; name=\"model\"\r\n\r\n");
        try w.writeAll("whisper-large-v3\r\n");

        // --- PART 2: File Field ---
        // This contains the actual audio data.
        // We specify filename so the server knows it's an audio file (e.g., .oga, .mp3).
        // Content-Type is set to application/octet-stream as generic binary data.
        try w.print("--{s}\r\n", .{boundary});
        try w.print("Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n", .{filename});
        try w.writeAll("Content-Type: application/octet-stream\r\n\r\n");
        try w.writeAll(file_content);

        // End the body with the boundary followed by two dashes.
        try w.print("\r\n--{s}--\r\n", .{boundary});

        // Prepare the Authorization header with the Bearer token.
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        // Prepare the Content-Type header manually to include the boundary parameter.
        // This tells the server how to parse the multipart body.
        const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(content_type);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = content_type },
        };

        // Send the HTTP POST request.
        const response = try self.client.post(url, headers, body.items);
        // Important: deinit the response to free the response body memory.
        defer @constCast(&response).deinit();

        // Check for success (HTTP 200 OK).
        // If failed, print the error body for debugging and return an error.
        if (response.status != .ok) {
            std.debug.print("[Groq] Transcription failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.TranscriptionFailed;
        }

        // Define a temporary struct to parse just the "text" field from the JSON response.
        const ParsedResponse = struct {
            text: []const u8,
        };

        // Parse the JSON. ignore_unknown_fields is true because the API might return extra metadata we don't need.
        const parsed = try std.json.parseFromSlice(ParsedResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Duplicate the text string.
        // Why: 'parsed.value.text' is a slice referencing 'response.body'.
        // Since 'response.body' will be freed when this function returns (via defer response.deinit),
        // we must create a copy of the text to return to the caller safely.
        return try self.allocator.dupe(u8, parsed.value.text);
    }

    /// Perform a standard chat completion request.
    ///
    /// Arguments:
    /// - messages: A list of messages (system, user, assistant) forming the conversation history.
    /// - model: The identifier of the model to use (e.g., "llama3-70b-8192").
    ///
    /// Returns: A base.LLMResponse containing the assistant's reply.
    pub fn chat(self: *GroqProvider, messages: []const base.LLMMessage, model: []const u8) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        // Construct the JSON payload structure.
        const payload = .{
            .model = model,
            .messages = messages,
        };

        // Serialize the payload to a JSON string.
        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        // Send the HTTP POST request.
        const response = try self.client.post(url, headers, body);
        // Ensure response body is freed.
        // Note: Used @constCast(&response).deinit() for consistency with transcribe(), assuming http.Response has deinit().
        defer @constCast(&response).deinit();

        if (response.status != .ok) {
            std.debug.print("[Groq] API request failed with status {d}: {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        // Reusing OpenRouter/OpenAI response structures as Groq is OpenAI compatible.
        // We only map the fields we care about (choices -> message -> content).
        const CompletionResponse = struct {
            choices: []const struct {
                message: struct {
                    content: ?[]const u8 = null,
                    role: []const u8,
                },
            },
        };

        // Parse the JSON response.
        const parsed = try std.json.parseFromSlice(CompletionResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) return error.NoChoicesReturned;

        const msg = parsed.value.choices[0].message;

        // Construct the generic LLMResponse.
        return base.LLMResponse{
            // Duplicate the content if it exists, otherwise null.
            // Again, duplication is necessary because 'msg.content' points to 'response.body' memory.
            .content = if (msg.content) |c| try self.allocator.dupe(u8, c) else null,
            .tool_calls = null, // Groq tool calling not implemented here yet
            .allocator = self.allocator,
        };
    }
};
