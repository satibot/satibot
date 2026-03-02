const std = @import("std");

const log = std.log.scoped(.memory);

pub const MemoryDoc = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .base_path = base_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    fn getDocPath(self: *const Self, id: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.base_path, id });
    }

    fn parseFrontmatter(content: []const u8, allocator: std.mem.Allocator) !struct { meta: std.StringHashMap([]const u8), body: []const u8 } {
        var meta = std.StringHashMap([]const u8).init(allocator);
        errdefer meta.deinit();

        if (!std.mem.startsWith(u8, content, "---")) {
            return .{ .meta = meta, .body = content };
        }

        const end_marker = std.mem.indexOf(u8, content[3..], "---") orelse {
            return .{ .meta = meta, .body = content };
        };

        const frontmatter = content[3 .. end_marker + 3];
        var lines = std.mem.splitScalar(u8, frontmatter, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const colon_idx = std.mem.indexOf(u8, trimmed, ":") orelse continue;
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t\"");

            try meta.put(key, value);
        }

        const body_start = end_marker + 6;
        const body = if (body_start < content.len) std.mem.trim(u8, content[body_start..], "\n ") else "";

        return .{ .meta = meta, .body = body };
    }

    fn generateMarkdown(self: *const Self, doc: *const MemoryDoc) ![]const u8 {
        const header = std.fmt.allocPrint(self.allocator, "---\nid: {s}\ntitle: {s}\ncreated_at: {d}\nupdated_at: {d}\n---\n\n", .{ doc.id, doc.title, doc.created_at, doc.updated_at }) catch unreachable;
        defer self.allocator.free(header);
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ header, doc.content });
    }

    pub fn create(self: *Self, title: []const u8, content: []const u8) !MemoryDoc {
        const id = try generateId(self.allocator);
        defer self.allocator.free(id);

        const now = std.time.timestamp();

        const doc: MemoryDoc = .{
            .id = id,
            .title = title,
            .content = content,
            .created_at = now,
            .updated_at = now,
        };

        try self.saveDoc(&doc);

        return doc;
    }

    pub fn read(self: *const Self, id: []const u8) !?MemoryDoc {
        const path = try self.getDocPath(id);
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 1048576);
        defer self.allocator.free(file_content);

        var parsed = try parseFrontmatter(file_content, self.allocator);
        defer parsed.meta.deinit();

        const title = parsed.meta.get("title") orelse "Untitled";
        const created_at = std.fmt.parseInt(i64, parsed.meta.get("created_at") orelse "0", 10) catch 0;
        const updated_at = std.fmt.parseInt(i64, parsed.meta.get("updated_at") orelse "0", 10) catch 0;

        const id_copy = try self.allocator.dupe(u8, id);
        const title_copy = try self.allocator.dupe(u8, title);
        const content_copy = try self.allocator.dupe(u8, parsed.body);

        return MemoryDoc{
            .id = id_copy,
            .title = title_copy,
            .content = content_copy,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    }

    pub fn update(self: *Self, id: []const u8, title: ?[]const u8, content: ?[]const u8) !?MemoryDoc {
        const existing = try self.read(id) orelse return null;

        const new_title = if (title) |t| t else existing.title;
        const new_content = if (content) |c| c else existing.content;

        const doc: MemoryDoc = .{
            .id = existing.id,
            .title = new_title,
            .content = new_content,
            .created_at = existing.created_at,
            .updated_at = std.time.timestamp(),
        };

        try self.saveDoc(&doc);

        return doc;
    }

    pub fn delete(self: *Self, id: []const u8) !bool {
        const path = try self.getDocPath(id);
        defer self.allocator.free(path);

        std.fs.deleteFileAbsolute(path) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };

        return true;
    }

    pub fn list(self: *const Self) ![]MemoryDoc {
        var docs: std.ArrayList(MemoryDoc) = .empty;

        const dir = std.fs.openDirAbsolute(self.base_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try std.fs.cwd().makePath(self.base_path);
                return docs.items;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const doc = self.read(entry.name[0 .. entry.name.len - 3]) catch continue;
            if (doc) |d| {
                try docs.append(self.allocator, d);
            }
        }

        return docs.items;
    }

    fn saveDoc(self: *const Self, doc: *const MemoryDoc) !void {
        try std.fs.cwd().makePath(self.base_path);

        const path = try self.getDocPath(doc.id);
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();

        const markdown = try self.generateMarkdown(doc);
        defer self.allocator.free(markdown);

        try file.writeAll(markdown);
    }

    fn generateId(allocator: std.mem.Allocator) ![]const u8 {
        const timestamp = std.time.timestamp();
        var random: u32 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&random));
        return std.fmt.allocPrint(allocator, "{d}-{x}", .{ timestamp, random });
    }
};

test "MemoryStore create and read" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ tmp.dir.realpathAlloc(allocator, ".") catch unreachable, "memory" });
    defer allocator.free(path);

    var store = MemoryStore.init(allocator, path);
    defer store.deinit();

    const doc = try store.create("Test Doc", "# Hello\nThis is a test.");
    defer {
        allocator.free(doc.id);
        allocator.free(doc.title);
        allocator.free(doc.content);
    }

    try std.testing.expect(doc.title.len > 0);
    try std.testing.expect(doc.content.len > 0);

    const read_doc = try store.read(doc.id);
    try std.testing.expect(read_doc != null);
    defer {
        if (read_doc) |d| {
            allocator.free(d.id);
            allocator.free(d.title);
            allocator.free(d.content);
        }
    }
}

test "MemoryStore update" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ tmp.dir.realpathAlloc(allocator, ".") catch unreachable, "memory" });
    defer allocator.free(path);

    var store = MemoryStore.init(allocator, path);
    defer store.deinit();

    const doc = try store.create("Original", "Original content");
    const original_id = doc.id;
    defer allocator.free(doc.id);

    const updated = try store.update(original_id, "Updated", "New content");
    try std.testing.expect(updated != null);

    const read_updated = try store.read(original_id);
    try std.testing.expect(read_updated != null);
    defer if (read_updated) |d| {
        allocator.free(d.id);
        allocator.free(d.title);
        allocator.free(d.content);
    };
}

test "MemoryStore delete" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ tmp.dir.realpathAlloc(allocator, ".") catch unreachable, "memory" });
    defer allocator.free(path);

    var store = MemoryStore.init(allocator, path);
    defer store.deinit();

    const doc = try store.create("To Delete", "Content");
    const id = doc.id;
    defer allocator.free(doc.id);

    const deleted = try store.delete(id);
    try std.testing.expect(deleted == true);

    const not_found = try store.read(id);
    try std.testing.expect(not_found == null);
}
