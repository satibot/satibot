/// Vector database module for semantic search using embeddings.
/// Stores text with vector embeddings and supports similarity search.
const std = @import("std");
const Config = @import("../config.zig").Config;

/// Entry containing text and its vector embedding.
pub const VectorEntry = struct {
    text: []const u8,
    embedding: []const f32,
};

/// In-memory vector store with cosine similarity search.
pub const VectorStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(VectorEntry) = .{},

    /// Initialize an empty vector store.
    pub fn init(allocator: std.mem.Allocator) VectorStore {
        return .{
            .allocator = allocator,
        };
    }

    /// Free all entries and the store itself.
    pub fn deinit(self: *VectorStore) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.embedding);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add a text entry with its embedding vector.
    pub fn add(self: *VectorStore, text: []const u8, embedding: []const f32) !void {
        try self.entries.append(self.allocator, .{
            .text = try self.allocator.dupe(u8, text),
            .embedding = try self.allocator.dupe(f32, embedding),
        });
    }

    /// Search for top_k most similar entries using cosine similarity.
    pub fn search(self: *VectorStore, query_embedding: []const f32, top_k: usize) ![]const VectorEntry {
        // Simple linear search with Cosine Similarity
        const Result = struct {
            entry: VectorEntry,
            score: f32,
        };
        var results = try self.allocator.alloc(Result, self.entries.items.len);
        defer self.allocator.free(results);

        for (self.entries.items, 0..) |entry, i| {
            results[i] = .{
                .entry = entry,
                .score = cosineSimilarity(query_embedding, entry.embedding),
            };
        }

        // Sort results by score descending
        std.mem.sort(Result, results, {}, struct {
            fn lessThan(_: void, a: Result, b: Result) bool {
                return a.score > b.score;
            }
        }.lessThan);

        const count = @min(top_k, results.len);
        const final_results = try self.allocator.alloc(VectorEntry, count);
        for (0..count) |i| {
            // Create deep copies of search results to prevent dangling pointers
            final_results[i] = .{
                .text = try self.allocator.dupe(u8, results[i].entry.text),
                .embedding = try self.allocator.dupe(f32, results[i].entry.embedding),
            };
        }
        return final_results;
    }

    /// Free search results allocated by search function
    pub fn freeSearchResults(self: *VectorStore, results: []const VectorEntry) void {
        for (results) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.embedding);
        }
        self.allocator.free(results);
    }

    fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
        if (a.len != b.len) return 0;
        var dot_product: f32 = 0;
        var norm_a: f32 = 0;
        var norm_b: f32 = 0;
        for (a, 0..) |_, i| {
            dot_product += a[i] * b[i];
            norm_a += a[i] * a[i];
            norm_b += b[i] * b[i];
        }
        if (norm_a == 0 or norm_b == 0) return 0;
        return dot_product / (std.math.sqrt(norm_a) * std.math.sqrt(norm_b));
    }

    pub fn save(self: *VectorStore, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(self.entries.items, .{}, &out.writer);
        try file.writeAll(out.written());
    }

    pub fn load(self: *VectorStore, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 104857600); // 100 * 1024 * 1024
        defer self.allocator.free(content);

        // Handle empty file - nothing to load
        if (content.len == 0) return;

        const parsed = try std.json.parseFromSlice([]VectorEntry, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value) |entry| {
            try self.add(entry.text, entry.embedding);
        }
    }
};

test "VectorStore: add and search" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    try store.add("apple", &.{ 1.0, 0.0, 0.0 });
    try store.add("banana", &.{ 0.0, 1.0, 0.0 });
    try store.add("orange", &.{ 0.0, 0.0, 1.0 });

    const results = try store.search(&.{ 0.9, 0.1, 0.0 }, 1);
    defer store.freeSearchResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("apple", results[0].text);
}

test "VectorStore: cosineSimilarity calculation" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    // Add entries with orthogonal vectors
    try store.add("vector_a", &.{ 1.0, 0.0, 0.0 });
    try store.add("vector_b", &.{ 0.0, 1.0, 0.0 });
    try store.add("vector_c", &.{ 0.0, 0.0, 1.0 });

    // Search with a query close to vector_a
    const results = try store.search(&.{ 0.9, 0.1, 0.0 }, 3);
    defer store.freeSearchResults(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("vector_a", results[0].text);
}

test "VectorStore: empty store search" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    const results = try store.search(&.{ 1.0, 0.0 }, 5);
    defer store.freeSearchResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "VectorStore: search with top_k larger than entries" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    try store.add("entry1", &.{ 1.0, 0.0 });
    try store.add("entry2", &.{ 0.0, 1.0 });

    // Request top 10 but only have 2 entries
    const results = try store.search(&.{ 1.0, 0.0 }, 10);
    defer store.freeSearchResults(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "VectorStore: VectorEntry struct" {
    const entry: VectorEntry = .{
        .text = "test text",
        .embedding = &.{ 0.1, 0.2, 0.3 },
    };
    try std.testing.expectEqualStrings("test text", entry.text);
    try std.testing.expectEqual(@as(usize, 3), entry.embedding.len);
    try std.testing.expectEqual(@as(f32, 0.1), entry.embedding[0]);
}

test "VectorStore: init and deinit empty" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "VectorStore: multiple add operations" {
    const allocator = std.testing.allocator;
    var store = VectorStore.init(allocator);
    defer store.deinit();

    try store.add("item1", &.{ 1.0, 0.0 });
    try store.add("item2", &.{ 0.0, 1.0 });
    try store.add("item3", &.{ 0.5, 0.5 });
    try store.add("item4", &.{ 0.8, 0.2 });

    try std.testing.expectEqual(@as(usize, 4), store.entries.items.len);
    try std.testing.expectEqualStrings("item1", store.entries.items[0].text);
    try std.testing.expectEqualStrings("item2", store.entries.items[1].text);
    try std.testing.expectEqualStrings("item3", store.entries.items[2].text);
    try std.testing.expectEqualStrings("item4", store.entries.items[3].text);
}
