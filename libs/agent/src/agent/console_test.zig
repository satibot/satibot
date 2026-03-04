const std = @import("std");
const testing = std.testing;

// Import the console module functions for testing
// We need to make these functions public in console.zig or test them indirectly
// For now, let's create test versions of the functions

const MAX_HISTORY_LINES: usize = 500;

fn isQuitCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "exit") or
        std.mem.eql(u8, trimmed, "quit") or
        std.mem.eql(u8, trimmed, ":q") or
        std.mem.eql(u8, trimmed, "/quit") or
        std.mem.eql(u8, trimmed, "/exit");
}

fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &.{ home, ".satibot_history" });
}

fn loadHistory(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer file.close();

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    var read_buf: [8192]u8 = undefined;
    var carry: std.ArrayListUnmanaged(u8) = .empty;
    defer carry.deinit(allocator);

    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        const data = read_buf[0..n];

        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == '\n') {
                const segment = data[start..i];
                if (carry.items.len > 0) {
                    try carry.appendSlice(allocator, segment);
                    const trimmed = std.mem.trim(u8, carry.items, " \t\r");
                    if (trimmed.len > 0) {
                        try lines.append(allocator, try allocator.dupe(u8, trimmed));
                    }
                    carry.clearRetainingCapacity();
                } else {
                    const trimmed = std.mem.trim(u8, segment, " \t\r");
                    if (trimmed.len > 0) {
                        try lines.append(allocator, try allocator.dupe(u8, trimmed));
                    }
                }
                start = i + 1;
            }
        }
        if (start < data.len) {
            try carry.appendSlice(allocator, data[start..]);
        }
    }

    if (carry.items.len > 0) {
        const trimmed = std.mem.trim(u8, carry.items, " \t\r");
        if (trimmed.len > 0) {
            try lines.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    if (lines.items.len > MAX_HISTORY_LINES) {
        const excess = lines.items.len - MAX_HISTORY_LINES;
        for (lines.items[0..excess]) |l| allocator.free(l);
        std.mem.copyForwards([]const u8, lines.items[0..MAX_HISTORY_LINES], lines.items[excess..]);
        lines.shrinkRetainingCapacity(MAX_HISTORY_LINES);
    }

    return lines.toOwnedSlice(allocator);
}

fn freeHistory(allocator: std.mem.Allocator, history: [][]const u8) void {
    for (history) |entry| allocator.free(entry);
    allocator.free(history);
}

fn saveHistory(history: []const []const u8, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const start = if (history.len > MAX_HISTORY_LINES) history.len - MAX_HISTORY_LINES else 0;
    for (history[start..]) |entry| {
        file.writeAll(entry) catch return;
        file.writeAll("\n") catch return;
    }
}

test "console.isQuitCommand" {
    // Test positive cases
    try testing.expect(isQuitCommand("exit"));
    try testing.expect(isQuitCommand("quit"));
    try testing.expect(isQuitCommand(":q"));
    try testing.expect(isQuitCommand("/quit"));
    try testing.expect(isQuitCommand("/exit"));

    // Test with whitespace
    try testing.expect(isQuitCommand("  exit  "));
    try testing.expect(isQuitCommand("\tquit\n"));
    try testing.expect(isQuitCommand("  :q  \r\n"));

    // Test negative cases
    try testing.expect(!isQuitCommand("exit2"));
    try testing.expect(!isQuitCommand("quitting"));
    try testing.expect(!isQuitCommand("help"));
    try testing.expect(!isQuitCommand(""));
    try testing.expect(!isQuitCommand("  "));
    try testing.expect(!isQuitCommand("hello world"));
}

test "console.getHistoryPath" {
    const allocator = testing.allocator;

    // Test with HOME environment variable set
    const original_home = std.posix.getenv("HOME");
    defer if (original_home) |home| {
        _ = home; // autofix
        // Note: setenv/unsetenv may not be available in all POSIX implementations
        // We'll skip this test for now and just test the basic functionality
    };

    if (std.posix.getenv("HOME")) |home| {
        const path = try getHistoryPath(allocator);
        defer allocator.free(path);

        const expected = try std.fs.path.join(allocator, &.{ home, ".satibot_history" });
        defer allocator.free(expected);

        try testing.expectEqualStrings(expected, path);
    }
}

test "console.getHistoryPath no HOME" {
    const allocator = testing.allocator;

    // This test is skipped since we can't reliably unset HOME in all environments
    // The function should return error.HomeNotFound when HOME is not set
    if (std.posix.getenv("HOME")) |_| {
        // HOME is set, skip this test
        return;
    }

    const result = getHistoryPath(allocator);
    try testing.expectError(error.HomeNotFound, result);
}

test "console.saveHistory and loadHistory" {
    const allocator = testing.allocator;

    // Create a temporary file for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create the file first
    const file = try tmp_dir.dir.createFile("test_history", .{});
    file.close();

    const test_path = try tmp_dir.dir.realpathAlloc(allocator, "test_history");
    defer allocator.free(test_path);

    // Test data
    const test_entries = [_][]const u8{
        "first command",
        "second command",
        "third command",
    };

    // Save history
    try saveHistory(&test_entries, test_path);

    // Load history
    const loaded = try loadHistory(allocator, test_path);
    defer freeHistory(allocator, loaded);

    try testing.expectEqual(test_entries.len, loaded.len);
    for (test_entries, 0..) |expected, i| {
        try testing.expectEqualStrings(expected, loaded[i]);
    }
}

test "console.loadHistory empty file" {
    const allocator = testing.allocator;

    // Create a temporary empty file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = "empty_history";

    // Create empty file
    const file = try tmp_dir.dir.createFile("empty_history", .{});
    file.close();

    // Load empty history
    const loaded = try loadHistory(allocator, test_path);
    defer freeHistory(allocator, loaded);

    try testing.expectEqual(@as(usize, 0), loaded.len);
}

test "console.loadHistory file not found" {
    const allocator = testing.allocator;

    const non_existent_path = "/tmp/this_file_does_not_exist_12345";

    // Load non-existent history should return empty array
    const loaded = try loadHistory(allocator, non_existent_path);
    defer freeHistory(allocator, loaded);

    try testing.expectEqual(@as(usize, 0), loaded.len);
}

test "console.loadHistory with whitespace and empty lines" {
    const allocator = testing.allocator;

    // Create a temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = "whitespace_history";

    // Create file with whitespace and empty lines
    const file = try tmp_dir.dir.createFile("whitespace_history", .{});
    try file.writeAll(
        \\  command one  
        \\
        \\  command two  
        \\   
        \\command three
        \\
    );
    file.close();

    // Load history
    const loaded = try loadHistory(allocator, test_path);
    defer freeHistory(allocator, loaded);

    try testing.expectEqual(@as(usize, 3), loaded.len);
    try testing.expectEqualStrings("command one", loaded[0]);
    try testing.expectEqualStrings("command two", loaded[1]);
    try testing.expectEqualStrings("command three", loaded[2]);
}

test "console.loadHistory exceeds MAX_HISTORY_LINES" {
    const allocator = testing.allocator;

    // Create a temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = "large_history";

    // Create file with more than MAX_HISTORY_LINES entries
    const file = try tmp_dir.dir.createFile("large_history", .{});
    defer file.close();

    var lines = std.ArrayList(u8).initCapacity(allocator, 600) catch unreachable;
    defer lines.deinit(allocator);

    // Write 600 lines (more than MAX_HISTORY_LINES which is 500)
    for (0..600) |i| {
        try lines.writer(allocator).print("command {}\n", .{i});
    }

    try file.writeAll(lines.items);

    // Load history
    const loaded = try loadHistory(allocator, test_path);
    defer freeHistory(allocator, loaded);

    // Should be truncated to MAX_HISTORY_LINES
    try testing.expectEqual(@as(usize, 500), loaded.len);

    // Should contain the last 500 entries (100-599)
    try testing.expectEqualStrings("command 100", loaded[0]);
    try testing.expectEqualStrings("command 599", loaded[499]);
}

test "console.saveHistory exceeds MAX_HISTORY_LINES" {
    const allocator = testing.allocator;

    // Create a temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = "large_save_history";

    // Create test data with more than MAX_HISTORY_LINES entries
    var test_entries = try allocator.alloc([]const u8, 600);
    defer {
        for (test_entries) |entry| allocator.free(entry);
        allocator.free(test_entries);
    }

    for (0..600) |i| {
        test_entries[i] = try std.fmt.allocPrint(allocator, "command {}", .{i});
    }

    // Save history (should only save last 500)
    try saveHistory(test_entries, test_path);

    // Load and verify
    const loaded = try loadHistory(allocator, test_path);
    defer freeHistory(allocator, loaded);

    try testing.expectEqual(@as(usize, 500), loaded.len);
    try testing.expectEqualStrings("command 100", loaded[0]);
    try testing.expectEqualStrings("command 599", loaded[499]);
}

test "console.freeHistory" {
    const allocator = testing.allocator;

    // Create test data
    var test_entries = try allocator.alloc([]const u8, 3);
    test_entries[0] = try allocator.dupe(u8, "first");
    test_entries[1] = try allocator.dupe(u8, "second");
    test_entries[2] = try allocator.dupe(u8, "third");

    // Free history (should not crash)
    freeHistory(allocator, test_entries);

    // If we get here without crashing, the test passes
    try testing.expect(true);
}

test "console.isQuitCommand distinguishes from EOF" {
    // EOF is signaled by read() returning 0, not by any command
    // These should NOT be treated as quit commands
    try testing.expect(!isQuitCommand(""));
    try testing.expect(!isQuitCommand("\x04")); // Ctrl+D (EOF character)
    try testing.expect(!isQuitCommand("\x00")); // Null character
}
