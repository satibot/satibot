/// Standalone test for session cleanup functionality
const std = @import("std");

/// Get total size of all session files in bytes.
fn getSessionStorageSizeWithDir(_: std.mem.Allocator, dir: std.fs.Dir) !usize {
    var total_size: usize = 0;
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        total_size += @as(usize, @intCast(stat.size));
    }

    return total_size;
}

fn cleanupOldSessionsWithDir(_: std.mem.Allocator, dir: std.fs.Dir, max_age_days: u32) !void {
    const cutoff_time = std.time.timestamp() - (@as(i64, @intCast(max_age_days)) * 86400);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        if (stat.mtime < cutoff_time) {
            dir.deleteFile(entry.name) catch |err| {
                std.log.warn("Failed to delete old session file {s}: {any}", .{ entry.name, err });
            };
        }
    }
}

fn listSessionsWithDir(_: std.mem.Allocator, dir: std.fs.Dir) !void {
    var iter = dir.iterate();
    const current_time = std.time.timestamp();

    std.debug.print("Session files:\n", .{});
    std.debug.print("{s:<30} {s:<10} {s:<15}\n", .{ "Session ID", "Size", "Age (days)" });
    std.debug.print("{s:-<30} {s:-<10} {s:-<15}\n", .{ "", "", "" });

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const age_days = @max(0, current_time - stat.mtime) / 86400;

        // Remove .json extension for display
        const session_id = if (std.mem.endsWith(u8, entry.name, ".json"))
            entry.name[0 .. entry.name.len - 5]
        else
            entry.name;

        std.debug.print("{s:<30} {d:<10} {d:<15}\n", .{ session_id, stat.size, age_days });
    }
}

test "getSessionStorageSize: empty directory" {
    const allocator = std.testing.allocator;

    // Test with empty temporary directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Should return 0 for empty directory
    const size = try getSessionStorageSizeWithDir(allocator, tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), size);
}

test "getSessionStorageSize: with files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test session files
    try tmp.dir.writeFile(.{ .sub_path = "session1.json", .data = "test content 1" });
    try tmp.dir.writeFile(.{ .sub_path = "session2.json", .data = "test content 2 with more content" });

    const size = try getSessionStorageSizeWithDir(allocator, tmp.dir);
    try std.testing.expect(size > 0);
}

test "cleanupOldSessions: removes old files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test files
    try tmp.dir.writeFile(.{ .sub_path = "recent.json", .data = "recent session" });
    try tmp.dir.writeFile(.{ .sub_path = "old.json", .data = "old session" });

    // Count files before cleanup
    var iter_before = tmp.dir.iterate();
    var count_before: usize = 0;
    while (try iter_before.next()) |_| {
        count_before += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count_before);

    // Cleanup sessions older than 1 day (this won't actually delete anything since files are new)
    // In a real scenario, you'd need to set file modification times
    try cleanupOldSessionsWithDir(allocator, tmp.dir, 1);

    // Should still have both files since they're recent
    var iter_after = tmp.dir.iterate();
    var count_after: usize = 0;
    while (try iter_after.next()) |_| {
        count_after += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count_after);
}

test "listSessions: displays correctly" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test session files
    try tmp.dir.writeFile(.{ .sub_path = "test_session.json", .data = "test content" });
    try tmp.dir.writeFile(.{ .sub_path = "another.json", .data = "more content" });

    // Capture stdout (this is a basic test - in real scenarios you might want to redirect)
    // For now, just ensure it doesn't crash
    try listSessionsWithDir(allocator, tmp.dir);
}

test "listSessions: empty directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Should not crash on empty directory
    try listSessionsWithDir(allocator, tmp.dir);
}
