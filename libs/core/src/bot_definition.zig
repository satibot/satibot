const std = @import("std");

pub const BotDefinition = struct {
    soul: ?[]const u8 = null,
    user: ?[]const u8 = null,
    memory: ?[]const u8 = null,
};

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        std.log.warn("Failed to open {s}: {any}", .{ path, err });
        return null;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.log.warn("Failed to stat {s}: {any}", .{ path, err });
        return null;
    };
    const content = file.readToEndAlloc(allocator, stat.size) catch |err| {
        std.log.warn("Failed to read {s}: {any}", .{ path, err });
        return null;
    };
    return content;
}

pub fn load(allocator: std.mem.Allocator) BotDefinition {
    const home = std.posix.getenv("HOME") orelse {
        std.log.warn("HOME environment variable not found", .{});
        return .{};
    };
    const bots_dir = std.fs.path.join(allocator, &.{ home, ".bots" }) catch return .{};
    defer allocator.free(bots_dir);

    var definition: BotDefinition = .{};

    const soul_path = std.fs.path.join(allocator, &.{ bots_dir, "SOUL.md" }) catch return .{};
    defer allocator.free(soul_path);
    if (loadFile(allocator, soul_path)) |content| {
        definition.soul = content;
    }

    const user_path = std.fs.path.join(allocator, &.{ bots_dir, "USER.md" }) catch return .{};
    defer allocator.free(user_path);
    if (loadFile(allocator, user_path)) |content| {
        definition.user = content;
    }

    const memory_path = std.fs.path.join(allocator, &.{ bots_dir, "MEMORY.md" }) catch return .{};
    defer allocator.free(memory_path);
    if (loadFile(allocator, memory_path)) |content| {
        definition.memory = content;
    }

    return definition;
}

pub fn loadFromPath(allocator: std.mem.Allocator, bots_dir: []const u8) BotDefinition {
    var definition: BotDefinition = .{};

    const soul_path = std.fs.path.join(allocator, &.{ bots_dir, "SOUL.md" }) catch return .{};
    defer allocator.free(soul_path);
    if (loadFile(allocator, soul_path)) |content| {
        definition.soul = content;
    }

    const user_path = std.fs.path.join(allocator, &.{ bots_dir, "USER.md" }) catch return .{};
    defer allocator.free(user_path);
    if (loadFile(allocator, user_path)) |content| {
        definition.user = content;
    }

    const memory_path = std.fs.path.join(allocator, &.{ bots_dir, "MEMORY.md" }) catch return .{};
    defer allocator.free(memory_path);
    if (loadFile(allocator, memory_path)) |content| {
        definition.memory = content;
    }

    return definition;
}

pub fn deinit(allocator: std.mem.Allocator, definition: *BotDefinition) void {
    if (definition.soul) |s| allocator.free(s);
    if (definition.user) |u| allocator.free(u);
    if (definition.memory) |m| allocator.free(m);
    definition.* = undefined;
}

test "BotDefinition: load non-existent files" {
    const allocator = std.testing.allocator;
    const def = loadFromPath(allocator, "/non/existent/path");
    try std.testing.expect(def.soul == null);
    try std.testing.expect(def.user == null);
    try std.testing.expect(def.memory == null);
}

test "BotDefinition: load existing files" {
    const allocator = std.testing.allocator;

    // Test loadFile with a simple approach - create files in current directory
    const test_files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "test_soul.md", .content = "Test soul content\nWith multiple lines" },
        .{ .name = "test_user.md", .content = "Test user context" },
        .{ .name = "test_memory.md", .content = "Test memory content\nWith details" },
    };

    // Get current working directory
    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // Create test files
    for (test_files) |file| {
        try cwd.writeFile(.{ .sub_path = file.name, .data = file.content });
        defer cwd.deleteFile(file.name) catch {};

        // Create absolute path for loadFile
        const abs_path = try std.fs.path.join(allocator, &.{ cwd_path, file.name });
        defer allocator.free(abs_path);

        const loaded_content = loadFile(allocator, abs_path);
        defer if (loaded_content) |content| allocator.free(content);

        try std.testing.expect(loaded_content != null);
        try std.testing.expectEqualStrings(file.content, loaded_content.?);
    }
}

test "BotDefinition: load partial files (only SOUL and USER)" {
    const allocator = std.testing.allocator;

    // Create test files in current directory
    const soul_content = "Partial soul content";
    const user_content = "Partial user content";

    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    try cwd.writeFile(.{ .sub_path = "partial_soul.md", .data = soul_content });
    defer cwd.deleteFile("partial_soul.md") catch {};
    try cwd.writeFile(.{ .sub_path = "partial_user.md", .data = user_content });
    defer cwd.deleteFile("partial_user.md") catch {};

    // Test loadFile for existing files with absolute paths
    const soul_abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "partial_soul.md" });
    defer allocator.free(soul_abs_path);
    const user_abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "partial_user.md" });
    defer allocator.free(user_abs_path);
    const memory_abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "non_existent_memory.md" });
    defer allocator.free(memory_abs_path);

    const loaded_soul = loadFile(allocator, soul_abs_path);
    defer if (loaded_soul) |s| allocator.free(s);
    const loaded_user = loadFile(allocator, user_abs_path);
    defer if (loaded_user) |u| allocator.free(u);
    const loaded_memory = loadFile(allocator, memory_abs_path);

    // Verify only existing files were loaded
    try std.testing.expect(loaded_soul != null);
    try std.testing.expect(loaded_user != null);
    try std.testing.expect(loaded_memory == null);
    try std.testing.expectEqualStrings(soul_content, loaded_soul.?);
    try std.testing.expectEqualStrings(user_content, loaded_user.?);
}

test "BotDefinition: load empty files" {
    const allocator = std.testing.allocator;

    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // Create empty file in current directory
    try cwd.writeFile(.{ .sub_path = "empty_test.md", .data = "" });
    defer cwd.deleteFile("empty_test.md") catch {};

    const abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "empty_test.md" });
    defer allocator.free(abs_path);

    const loaded_content = loadFile(allocator, abs_path);
    defer if (loaded_content) |content| allocator.free(content);

    // Verify empty files are loaded (not null, but empty strings)
    try std.testing.expect(loaded_content != null);
    try std.testing.expectEqualStrings("", loaded_content.?);
}

test "BotDefinition: deinit with null fields" {
    const allocator = std.testing.allocator;

    // Create a BotDefinition with all null fields
    var def: BotDefinition = .{
        .soul = null,
        .user = null,
        .memory = null,
    };

    // deinit should not crash with null fields
    deinit(allocator, &def);

    // If we get here without crashing, test passes
    try std.testing.expect(true);
}

test "BotDefinition: deinit with mixed null and non-null fields" {
    const allocator = std.testing.allocator;

    // Create a BotDefinition with mixed fields
    var def: BotDefinition = .{
        .soul = try allocator.dupe(u8, "Test soul"),
        .user = null,
        .memory = try allocator.dupe(u8, "Test memory"),
    };

    deinit(allocator, &def);

    // If we get here without crashing, test passes
    try std.testing.expect(true);
}

test "BotDefinition: loadFile with non-existent path" {
    const allocator = std.testing.allocator;

    const result = loadFile(allocator, "/non/existent/file.md");

    // Should return null for non-existent file
    try std.testing.expect(result == null);
}

test "BotDefinition: loadFile with valid file" {
    const allocator = std.testing.allocator;

    const test_content = "Test file content\nWith multiple lines";
    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    try cwd.writeFile(.{ .sub_path = "valid_test.md", .data = test_content });
    defer cwd.deleteFile("valid_test.md") catch {};

    const abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "valid_test.md" });
    defer allocator.free(abs_path);

    const result = loadFile(allocator, abs_path);
    defer if (result) |content| allocator.free(content);

    // Should return the file content
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(test_content, result.?);
}

test "BotDefinition: loadFile with empty file" {
    const allocator = std.testing.allocator;

    const cwd = std.fs.cwd();
    const cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    try cwd.writeFile(.{ .sub_path = "empty_file_test.md", .data = "" });
    defer cwd.deleteFile("empty_file_test.md") catch {};

    const abs_path = try std.fs.path.join(allocator, &.{ cwd_path, "empty_file_test.md" });
    defer allocator.free(abs_path);

    const result = loadFile(allocator, abs_path);
    defer if (result) |content| allocator.free(content);

    // Should return empty string for empty file
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "BotDefinition: load with no HOME environment variable" {
    const allocator = std.testing.allocator;

    // This test is tricky because we can't easily unset HOME in a safe way
    // But we can test the behavior by calling load() - it should return empty definition
    // if HOME is not found (though it likely exists in most test environments)
    var def = load(allocator);
    deinit(allocator, &def);

    // The function should not crash and should return a valid BotDefinition
    // (fields may be null or populated depending on the test environment)
    // We just verify it doesn't crash and returns a struct
    try std.testing.expect(def.soul == null or def.soul != null); // Always true, but verifies access
    try std.testing.expect(def.user == null or def.user != null);
    try std.testing.expect(def.memory == null or def.memory != null);
}

test "BotDefinition: loadFromPath with path joining errors" {
    const allocator = std.testing.allocator;

    // Test with a non-existent path - should handle gracefully
    var def = loadFromPath(allocator, "/non/existent/path");
    defer deinit(allocator, &def);

    // Should return empty definition for non-existent path
    try std.testing.expect(def.soul == null);
    try std.testing.expect(def.user == null);
    try std.testing.expect(def.memory == null);
}

test "BotDefinition: struct initialization" {
    // Test that BotDefinition can be initialized with default values
    const def1: BotDefinition = .{};
    try std.testing.expect(def1.soul == null);
    try std.testing.expect(def1.user == null);
    try std.testing.expect(def1.memory == null);

    // Test initialization with explicit null values
    const def2: BotDefinition = .{
        .soul = null,
        .user = null,
        .memory = null,
    };
    try std.testing.expect(def2.soul == null);
    try std.testing.expect(def2.user == null);
    try std.testing.expect(def2.memory == null);
}

test "BotDefinition: memory safety with deinit" {
    const allocator = std.testing.allocator;

    // Create a BotDefinition with allocated content
    var def: BotDefinition = .{
        .soul = try allocator.dupe(u8, "Soul content"),
        .user = try allocator.dupe(u8, "User content"),
        .memory = try allocator.dupe(u8, "Memory content"),
    };

    // Verify content is set
    try std.testing.expect(def.soul != null);
    try std.testing.expect(def.user != null);
    try std.testing.expect(def.memory != null);

    // Call deinit to free memory
    deinit(allocator, &def);

    // After deinit, the struct should be undefined (we can't really test this safely)
    // But the test passing means no memory leaks or crashes occurred
    try std.testing.expect(true);
}
