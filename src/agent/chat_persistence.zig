const std = @import("std");

/// Save last_chat_id to file for persistence across restarts
///
/// File location: ~/.bots/last_chat_id.txt
///
/// # Parameters
/// - chat_id: The chat ID to persist
///
/// # Example
/// ```zig
/// saveLastChatId(6496574212); // Saves "6496574212" to file
/// ```
pub fn saveLastChatId(chat_id: i64) void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const file_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt" }) catch return;
    defer std.heap.page_allocator.free(file_path);

    // Ensure directory exists
    const bots_dir = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots" }) catch return;
    defer std.heap.page_allocator.free(bots_dir);
    std.fs.makeDirAbsolute(bots_dir) catch {};

    // Write chat_id to file (atomically - write to temp then rename)
    const temp_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt.tmp" }) catch return;
    defer std.heap.page_allocator.free(temp_path);

    const file = std.fs.createFileAbsolute(temp_path, .{ .truncate = true }) catch |err| {
        std.debug.print("Warning: Failed to create last_chat_id temp file: {any}\n", .{err});
        return;
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const chat_id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
    file.writeAll(chat_id_str) catch |err| {
        std.debug.print("Warning: Failed to write last_chat_id: {any}\n", .{err});
        return;
    };

    // Atomic rename for durability
    std.fs.renameAbsolute(temp_path, file_path) catch |err| {
        std.debug.print("Warning: Failed to rename last_chat_id file: {any}\n", .{err});
    };
}

/// Read last_chat_id from file
///
/// # Returns
/// - The persisted chat ID if found, otherwise null
///
/// # Example
/// ```zig
/// if (readLastChatId()) |chat_id| {
///     std.debug.print("Restored chat ID: {d}\n", .{chat_id});
/// }
/// ```
pub fn readLastChatId() ?i64 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const file_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt" }) catch return null;
    defer std.heap.page_allocator.free(file_path);

    const file = std.fs.openFileAbsolute(file_path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;

    // Trim whitespace/newlines
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;

    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// Clear the persisted last_chat_id
///
/// Deletes the file, useful for testing or when starting fresh.
pub fn clearLastChatId() void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const file_path = std.fs.path.join(std.heap.page_allocator, &.{ home, ".bots", "last_chat_id.txt" }) catch return;
    defer std.heap.page_allocator.free(file_path);

    std.fs.deleteFileAbsolute(file_path) catch |err| {
        std.debug.print("Note: Failed to clear last_chat_id file (may not exist): {any}\n", .{err});
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "save and read last_chat_id" {
    const allocator = std.testing.allocator;
    _ = allocator; // Not used, but kept for consistency

    // Clear any existing file
    clearLastChatId();

    // Test save
    saveLastChatId(123456789);

    // Test read
    const chat_id = readLastChatId();
    try std.testing.expect(chat_id != null);
    try std.testing.expectEqual(@as(i64, 123456789), chat_id.?);

    // Clean up
    clearLastChatId();
}

test "readLastChatId returns null when file doesn't exist" {
    // Clear any existing file
    clearLastChatId();

    // Should return null
    const chat_id = readLastChatId();
    try std.testing.expect(chat_id == null);
}

test "saveLastChatId overwrites existing value" {
    // Clear and set initial value
    clearLastChatId();
    saveLastChatId(111111111);

    // Overwrite with new value
    saveLastChatId(999999999);

    // Should have new value
    const chat_id = readLastChatId();
    try std.testing.expect(chat_id != null);
    try std.testing.expectEqual(@as(i64, 999999999), chat_id.?);

    // Clean up
    clearLastChatId();
}
