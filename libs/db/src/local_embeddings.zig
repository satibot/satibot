const std = @import("std");
const providers = @import("providers");
const base = providers.base;

const vector_size = 1024;

/// Simple Hashing Vectorizer for local embeddings.
/// This provides a basic way to transform text into vectors without external API calls.
/// Note: This is not semantic (like LLM embeddings) but works for basic keyword-based similarity.
pub const LocalEmbedder = struct {
    pub fn generate(allocator: std.mem.Allocator, input: []const []const u8) !base.EmbeddingResponse {
        var embeddings = try allocator.alloc([]const f32, input.len);
        errdefer allocator.free(embeddings);

        for (input, 0..) |text, i| {
            var vector = try allocator.alloc(f32, vector_size);
            @memset(vector, 0);

            // Tokenize and hash
            var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,!?;:()[]{}'\"");
            while (it.next()) |token| {
                const h = std.hash.Wyhash.hash(0, token);
                const index = h % vector_size;
                vector[index] += 1.0;
            }

            // Normalize vector for better cosine similarity results
            normalize(vector);
            embeddings[i] = vector;
        }

        return .{
            .embeddings = embeddings,
            .allocator = allocator,
        };
    }

    fn normalize(vector: []f32) void {
        var sum_sq: f32 = 0;
        for (vector) |v| {
            sum_sq += v * v;
        }
        if (sum_sq > 0) {
            const mag = std.math.sqrt(sum_sq);
            for (vector) |*v| {
                v.* /= mag;
            }
        }
    }
};
