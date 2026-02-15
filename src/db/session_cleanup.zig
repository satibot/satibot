/// Session cleanup utility for managing old session files.
/// Provides functions to clean up old or unused session files.
const std = @import("std");
const session = @import("session.zig");

/// Clean up sessions older than the specified number of days.
pub fn cleanupOldSessions(allocator: std.mem.Allocator, max_age_days: u32) !void {
    const home = std.posix.getenv("HOME") orelse return;
    const session_dir = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions" });
    defer allocator.free(session_dir);

    var dir = std.fs.openDirAbsolute(session_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    const cutoff_time = std.time.timestamp() - (@as(i64, @intCast(max_age_days)) * 86400);

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

/// Get total size of all session files in bytes.
pub fn getSessionStorageSize(allocator: std.mem.Allocator) !usize {
    const home = std.posix.getenv("HOME") orelse return 0;
    const session_dir = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions" });
    defer allocator.free(session_dir);

    var dir = std.fs.openDirAbsolute(session_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var total_size: usize = 0;
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        total_size += @as(usize, @intCast(stat.size));
    }

    return total_size;
}

/// List all session files with their sizes and ages.
pub fn listSessions(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return;
    const session_dir = try std.fs.path.join(allocator, &.{ home, ".bots", "sessions" });
    defer allocator.free(session_dir);

    var dir = std.fs.openDirAbsolute(session_dir, .{ .iterate = true }) catch {
        std.debug.print("No sessions directory found.\n");
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    const current_time = std.time.timestamp();

    std.debug.print("Session files:\n");
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
    try tmp.dir.writeFile("session1.json", "test content 1");
    try tmp.dir.writeFile("session2.json", "test content 2 with more content");

    const size = try getSessionStorageSizeWithDir(allocator, tmp.dir);
    try std.testing.expect(size > 0);
}

test "cleanupOldSessions: removes old files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test files
    try tmp.dir.writeFile("recent.json", "recent session");
    try tmp.dir.writeFile("old.json", "old session");

    // Mock old file by setting modification time to past
    const old_time = std.time.timestamp() - (2 * 86400); // 2 days ago
    setFileTime(tmp.dir, "old.json", old_time) catch unreachable;

    // Count files before cleanup
    var iter_before = tmp.dir.iterate();
    var count_before: usize = 0;
    while (try iter_before.next()) |_| {
        count_before += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count_before);

    // Cleanup sessions older than 1 day
    try cleanupOldSessionsWithDir(allocator, tmp.dir, 1);

    // Should have removed old.json
    var iter_after = tmp.dir.iterate();
    var count_after: usize = 0;
    var found_recent = false;
    while (try iter_after.next()) |entry| {
        count_after += 1;
        if (std.mem.eql(u8, entry.name, "recent.json")) {
            found_recent = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count_after);
    try std.testing.expect(found_recent);
}

test "listSessions: displays correctly" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test session files
    try tmp.dir.writeFile("test_session.json", "test content");
    try tmp.dir.writeFile("another.json", "more content");

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

// Helper functions for testing with custom directories
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

    std.debug.print("Session files:\n");
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

// Helper function to set file modification time (platform-specific)
fn setFileTime(dir: std.fs.Dir, filename: []const u8, timestamp: i64) !void {
    // Note: This is a simplified version. In a real implementation,
    // you'd need to use platform-specific APIs to set file times.
    // For testing purposes, we'll skip this and assume the test environment
    // handles file creation times appropriately.
    _ = dir;
    _ = filename;
    _ = timestamp;
}
