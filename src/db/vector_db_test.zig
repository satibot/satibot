const std = @import("std");
const vector_db = @import("vector_db.zig");

test "VectorEntry: struct creation and access" {
    const embedding = &[_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const entry = vector_db.VectorEntry{
        .text = "test text",
        .embedding = embedding,
    };
    
    try std.testing.expectEqualStrings("test text", entry.text);
    try std.testing.expectEqual(@as(usize, 4), entry.embedding.len);
    try std.testing.expectEqual(@as(f32, 0.1), entry.embedding[0]);
    try std.testing.expectEqual(@as(f32, 0.4), entry.embedding[3]);
}

test "VectorEntry: empty text and zero embedding" {
    const embedding = &[_]f32{0.0, 0.0, 0.0};
    const entry = vector_db.VectorEntry{
        .text = "",
        .embedding = embedding,
    };
    
    try std.testing.expectEqualStrings("", entry.text);
    try std.testing.expectEqual(@as(usize, 3), entry.embedding.len);
    try std.testing.expectEqual(@as(f32, 0.0), entry.embedding[0]);
}

test "VectorStore: init empty store" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
    try std.testing.expectEqual(allocator, store.allocator);
}

test "VectorStore: add single entry" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    const embedding = &[_]f32{ 1.0, 0.0, 0.0 };
    try store.add("test text", embedding);
    
    try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try std.testing.expectEqualStrings("test text", store.entries.items[0].text);
    try std.testing.expectEqual(@as(usize, 3), store.entries.items[0].embedding.len);
    try std.testing.expectEqual(@as(f32, 1.0), store.entries.items[0].embedding[0]);
    try std.testing.expectEqual(@as(f32, 0.0), store.entries.items[0].embedding[1]);
    try std.testing.expectEqual(@as(f32, 0.0), store.entries.items[0].embedding[2]);
}

test "VectorStore: add multiple entries" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("first", &.{ 1.0, 0.0 });
    try store.add("second", &.{ 0.0, 1.0 });
    try store.add("third", &.{ 0.5, 0.5 });
    
    try std.testing.expectEqual(@as(usize, 3), store.entries.items.len);
    try std.testing.expectEqualStrings("first", store.entries.items[0].text);
    try std.testing.expectEqualStrings("second", store.entries.items[1].text);
    try std.testing.expectEqualStrings("third", store.entries.items[2].text);
}

test "VectorStore: cosineSimilarity identical vectors" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("identical", &.{ 1.0, 0.0, 0.0 });
    
    const results = try store.search(&.{ 1.0, 0.0, 0.0 }, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("identical", results[0].text);
}

test "VectorStore: cosineSimilarity orthogonal vectors" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("orthogonal_a", &.{ 1.0, 0.0 });
    try store.add("orthogonal_b", &.{ 0.0, 1.0 });
    
    // Query should be more similar to orthogonal_a
    const results = try store.search(&.{ 0.9, 0.1 }, 2);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("orthogonal_a", results[0].text);
    try std.testing.expectEqualStrings("orthogonal_b", results[1].text);
}

test "VectorStore: cosineSimilarity zero vectors" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("zero_vector", &.{ 0.0, 0.0, 0.0 });
    
    const results = try store.search(&.{ 1.0, 0.0, 0.0 }, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("zero_vector", results[0].text);
}

test "VectorStore: search empty store" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    const results = try store.search(&.{ 1.0, 0.0 }, 5);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "VectorStore: search top_k less than entries" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("entry1", &.{ 1.0, 0.0 });
    try store.add("entry2", &.{ 0.0, 1.0 });
    try store.add("entry3", &.{ 0.5, 0.5 });
    
    const results = try store.search(&.{ 0.8, 0.2 }, 2);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "VectorStore: search top_k greater than entries" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("entry1", &.{ 1.0, 0.0 });
    try store.add("entry2", &.{ 0.0, 1.0 });
    
    const results = try store.search(&.{ 0.5, 0.5 }, 10);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "VectorStore: search with different vector dimensions" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("3d_vector", &.{ 1.0, 0.0, 0.0 });
    
    // Query with 2D vector should still work (cosineSimilarity handles mismatched dimensions)
    const results = try store.search(&.{ 1.0, 0.0 }, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("3d_vector", results[0].text);
}

test "VectorStore: search ranking by similarity" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("very_similar", &.{ 0.9, 0.1 });
    try store.add("somewhat_similar", &.{ 0.5, 0.5 });
    try store.add("not_similar", &.{ 0.1, 0.9 });
    
    const results = try store.search(&.{ 1.0, 0.0 }, 3);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("very_similar", results[0].text);
    try std.testing.expectEqualStrings("somewhat_similar", results[1].text);
    try std.testing.expectEqualStrings("not_similar", results[2].text);
}

test "VectorStore: negative values in vectors" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("negative", &.{ -1.0, 0.0 });
    try store.add("positive", &.{ 1.0, 0.0 });
    
    const results = try store.search(&.{ -0.9, 0.1 }, 2);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("negative", results[0].text);
    try std.testing.expectEqualStrings("positive", results[1].text);
}

test "VectorStore: save and load functionality" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_vectors.json" });
    defer allocator.free(file_path);
    
    // Create and save vector store
    {
        var store = vector_db.VectorStore.init(allocator);
        defer store.deinit();
        
        try store.add("saved_text1", &.{ 1.0, 0.0 });
        try store.add("saved_text2", &.{ 0.0, 1.0 });
        try store.add("saved_text3", &.{ 0.5, 0.5 });
        
        try store.save(file_path);
    }
    
    // Load and verify vector store
    {
        var store = vector_db.VectorStore.init(allocator);
        defer store.deinit();
        
        try store.load(file_path);
        
        try std.testing.expectEqual(@as(usize, 3), store.entries.items.len);
        try std.testing.expectEqualStrings("saved_text1", store.entries.items[0].text);
        try std.testing.expectEqualStrings("saved_text2", store.entries.items[1].text);
        try std.testing.expectEqualStrings("saved_text3", store.entries.items[2].text);
        
        // Verify embeddings were loaded correctly
        try std.testing.expectEqual(@as(f32, 1.0), store.entries.items[0].embedding[0]);
        try std.testing.expectEqual(@as(f32, 0.0), store.entries.items[0].embedding[1]);
        try std.testing.expectEqual(@as(f32, 0.0), store.entries.items[1].embedding[0]);
        try std.testing.expectEqual(@as(f32, 1.0), store.entries.items[1].embedding[1]);
    }
}

test "VectorStore: load non-existent file" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    // This should not error, just do nothing
    try store.load("/non/existent/path.json");
    
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

test "VectorStore: large number of entries" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    // Add many entries
    for (0..100) |i| {
        const text = try std.fmt.allocPrint(allocator, "entry_{d}", .{i});
        defer allocator.free(text);
        const embedding = &[_]f32{ @floatFromInt(i % 10), @floatFromInt((i + 1) % 10) };
        try store.add(text, embedding);
    }
    
    try std.testing.expectEqual(@as(usize, 100), store.entries.items.len);
    
    // Search should still work efficiently
    const results = try store.search(&.{ 5.0, 5.0 }, 10);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 10), results.len);
}

test "VectorStore: high dimensional vectors" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    const high_dim_vector = [_]f32{0.1} ** 100; // 100-dimensional vector
    try store.add("high_dim", &high_dim_vector);
    
    const query_vector = [_]f32{0.1} ** 100;
    const results = try store.search(&query_vector, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("high_dim", results[0].text);
}

test "VectorStore: floating point precision" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("precise", &.{ 0.123456789, 0.987654321 });
    
    const results = try store.search(&.{ 0.123456788, 0.987654320 }, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("precise", results[0].text);
}

test "VectorStore: memory management verification" {
    const allocator = std.testing.allocator;
    
    // Create store with many entries and verify cleanup
    {
        var store = vector_db.VectorStore.init(allocator);
        defer store.deinit();
        
        for (0..50) |i| {
            const text = try std.fmt.allocPrint(allocator, "temp_{d}", .{i});
            defer allocator.free(text);
            const embedding = &[_]f32{ @as(f32, @floatFromInt(i)) / 50.0, 1.0 - @as(f32, @floatFromInt(i)) / 50.0 };
            try store.add(text, embedding);
        }
        
        try std.testing.expectEqual(@as(usize, 50), store.entries.items.len);
    }
    // If deinit works correctly, no memory leaks should occur
}

test "VectorStore: duplicate entries" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("duplicate", &.{ 1.0, 0.0 });
    try store.add("duplicate", &.{ 1.0, 0.0 });
    
    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    
    // Search should return both duplicates
    const results = try store.search(&.{ 1.0, 0.0 }, 5);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("duplicate", results[0].text);
    try std.testing.expectEqualStrings("duplicate", results[1].text);
}

test "VectorStore: very small similarity scores" {
    const allocator = std.testing.allocator;
    var store = vector_db.VectorStore.init(allocator);
    defer store.deinit();
    
    try store.add("small_sim", &.{ 0.001, 0.001 });
    
    const results = try store.search(&.{ 1.0, 0.0 }, 1);
    defer allocator.free(results);
    
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("small_sim", results[0].text);
}
