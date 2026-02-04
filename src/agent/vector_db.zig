const std = @import("std");
const base = @import("../providers/base.zig");
const Config = @import("../config.zig").Config;

pub const VectorEntry = struct {
    text: []const u8,
    embedding: []const f32,
};

pub const VectorStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(VectorEntry) = .{},

    pub fn init(allocator: std.mem.Allocator) VectorStore {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorStore) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.embedding);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *VectorStore, text: []const u8, embedding: []const f32) !void {
        try self.entries.append(self.allocator, .{
            .text = try self.allocator.dupe(u8, text),
            .embedding = try self.allocator.dupe(f32, embedding),
        });
    }

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
            final_results[i] = results[i].entry;
        }
        return final_results;
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

        const content = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(content);

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
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("apple", results[0].text);
}

test "VectorStore: save and load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "vector_test.json" });
    defer allocator.free(file_path);

    {
        var store = VectorStore.init(allocator);
        defer store.deinit();
        try store.add("test", &.{ 0.5, 0.5 });
        try store.save(file_path);
    }

    {
        var store = VectorStore.init(allocator);
        defer store.deinit();
        try store.load(file_path);
        try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
        try std.testing.expectEqualStrings("test", store.entries.items[0].text);
        try std.testing.expectEqual(@as(f32, 0.5), store.entries.items[0].embedding[0]);
    }
}
