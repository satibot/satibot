const std = @import("std");
const local_embeddings = @import("local_embeddings.zig");

test "LocalEmbedder: VECTOR_SIZE constant" {
    try std.testing.expectEqual(@as(usize, 1024), local_embeddings.LocalEmbedder.vector_size);
}

test "LocalEmbedder: generate single embedding" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"hello world"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Check that vector is normalized (magnitude should be close to 1.0)
    var sum_sq: f32 = 0;
    for (response.embeddings[0]) |v| {
        sum_sq += v * v;
    }
    const magnitude = std.math.sqrt(sum_sq);
    try std.testing.expectApproxEqRel(@as(f32, 1.0), magnitude, 0.001);
}

test "LocalEmbedder: generate multiple embeddings" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{ "first text", "second text", "third text" };

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 3), response.embeddings.len);

    for (response.embeddings) |embedding| {
        try std.testing.expectEqual(@as(usize, 1024), embedding.len);

        // Each vector should be normalized
        var sum_sq: f32 = 0;
        for (embedding) |v| {
            sum_sq += v * v;
        }
        const magnitude = std.math.sqrt(sum_sq);
        try std.testing.expectApproxEqRel(@as(f32, 1.0), magnitude, 0.001);
    }
}

test "LocalEmbedder: empty string input" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{""};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Empty string should result in zero vector (magnitude 0)
    var sum_sq: f32 = 0;
    for (response.embeddings[0]) |v| {
        sum_sq += v * v;
    }
    const magnitude = std.math.sqrt(sum_sq);
    try std.testing.expectEqual(@as(f32, 0.0), magnitude);
}

test "LocalEmbedder: empty input array" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 0), response.embeddings.len);
}

test "LocalEmbedder: tokenization with punctuation" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"Hello, world! This is a test."};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should have non-zero values due to tokens
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}

test "LocalEmbedder: same text produces same embedding" {
    const allocator = std.testing.allocator;

    const input1 = &[_][]const u8{"identical text"};
    const input2 = &[_][]const u8{"identical text"};

    var response1 = try local_embeddings.LocalEmbedder.generate(allocator, input1);
    defer response1.deinit();

    var response2 = try local_embeddings.LocalEmbedder.generate(allocator, input2);
    defer response2.deinit();

    try std.testing.expectEqual(@as(usize, 1), response1.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1), response2.embeddings.len);

    // Vectors should be identical
    for (0..1024) |i| {
        try std.testing.expectEqual(response1.embeddings[0][i], response2.embeddings[0][i]);
    }
}

test "LocalEmbedder: different texts produce different embeddings" {
    const allocator = std.testing.allocator;

    const input1 = &[_][]const u8{"first text"};
    const input2 = &[_][]const u8{"second text"};

    var response1 = try local_embeddings.LocalEmbedder.generate(allocator, input1);
    defer response1.deinit();

    var response2 = try local_embeddings.LocalEmbedder.generate(allocator, input2);
    defer response2.deinit();

    try std.testing.expectEqual(@as(usize, 1), response1.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1), response2.embeddings.len);

    // Vectors should be different
    var differences: usize = 0;
    for (0..1024) |i| {
        if (response1.embeddings[0][i] != response2.embeddings[0][i]) {
            differences += 1;
        }
    }
    try std.testing.expect(differences > 0);
}

test "LocalEmbedder: hash distribution" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"a b c d e f g h i j"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);

    // Should have multiple non-zero values due to different tokens
    var non_zero_count: usize = 0;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            non_zero_count += 1;
        }
    }
    try std.testing.expect(non_zero_count > 1);
    try std.testing.expect(non_zero_count <= 10); // At most number of tokens
}

test "LocalEmbedder: normalization function" {
    const allocator = std.testing.allocator;

    // Test with a simple vector that needs normalization
    const input = &[_][]const u8{"test"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    // Vector should be normalized
    var sum_sq: f32 = 0;
    for (response.embeddings[0]) |v| {
        sum_sq += v * v;
    }
    const magnitude = std.math.sqrt(sum_sq);

    // Should be very close to 1.0 (allowing for floating point precision)
    try std.testing.expectApproxEqRel(@as(f32, 1.0), magnitude, 0.0001);
}

test "LocalEmbedder: special characters" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"hello\nworld\ttest\r\n"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should handle special characters properly
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}

test "LocalEmbedder: very long text" {
    const allocator = std.testing.allocator;

    const long_text = "a " ** 100; // 100 repetitions of "a "
    const input = &[_][]const u8{long_text};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should still be normalized
    var sum_sq: f32 = 0;
    for (response.embeddings[0]) |v| {
        sum_sq += v * v;
    }
    const magnitude = std.math.sqrt(sum_sq);
    try std.testing.expectApproxEqRel(@as(f32, 1.0), magnitude, 0.001);
}

test "LocalEmbedder: unicode characters" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"héllo wörld 🌍"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should handle unicode (though tokenization might not be perfect)
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}

test "LocalEmbedder: numeric tokens" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"123 456 789"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should handle numeric tokens
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}

test "LocalEmbedder: mixed case tokens" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"Hello hello HELLO"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should treat different cases as different tokens
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}

test "LocalEmbedder: single character tokens" {
    const allocator = std.testing.allocator;

    const input = &[_][]const u8{"a b c"};

    var response = try local_embeddings.LocalEmbedder.generate(allocator, input);
    defer response.deinit();

    try std.testing.expectEqual(@as(usize, 1), response.embeddings.len);
    try std.testing.expectEqual(@as(usize, 1024), response.embeddings[0].len);

    // Should handle single character tokens
    var has_non_zero = false;
    for (response.embeddings[0]) |v| {
        if (v != 0.0) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expectEqual(true, has_non_zero);
}
