//! SQLite-backed persistent memory store

const std = @import("std");
const build_options = @import("build_opts");

const log = std.log.scoped(.memory_sqlite);

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;
const BUSY_TIMEOUT_MS: c_int = 5000;

pub const MemoryDoc = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const SqliteMemoryStore = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        if (db) |d| {
            _ = c.sqlite3_busy_timeout(d, BUSY_TIMEOUT_MS);
        }

        var self_ = Self{ .db = db, .allocator = allocator };
        try self_.configurePragmas();
        try self_.migrate();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) !void {
        const pragmas = [_][:0]const u8{
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous  = NORMAL;",
            "PRAGMA temp_store   = MEMORY;",
            "PRAGMA cache_size   = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            const rc = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (rc != c.SQLITE_OK) {
                if (err_msg) |msg| c.sqlite3_free(msg);
            }
        }
    }

    fn migrate(self: *Self) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS memories (
            \\  id         TEXT PRIMARY KEY,
            \\  key        TEXT NOT NULL UNIQUE,
            \\  title      TEXT NOT NULL,
            \\  content    TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_memories_key ON memories(key);
        ;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.warn("migration failed: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }
    }

    fn logExecFailure(self: *Self, context: []const u8, sql: []const u8, rc: c_int, err_msg: [*c]u8) void {
        if (err_msg) |msg| {
            const msg_text = std.mem.span(msg);
            log.warn("sqlite {s} failed (rc={d}, sql={s}): {s}", .{ context, rc, sql, msg_text });
            return;
        }
        if (self.db) |db| {
            const msg_text = std.mem.span(c.sqlite3_errmsg(db));
            log.warn("sqlite {s} failed (rc={d}, sql={s}): {s}", .{ context, rc, sql, msg_text });
            return;
        }
        log.warn("sqlite {s} failed (rc={d}, sql={s})", .{ context, rc, sql });
    }

    pub fn create(self: *Self, title: []const u8, content: []const u8) !MemoryDoc {
        const id = try self.generateId();
        const now = std.time.timestamp();

        const sql = "INSERT INTO memories (id, key, title, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        _ = c.sqlite3_bind_text(stmt, 1, id_copy.ptr, @intCast(id_copy.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, id_copy.ptr, @intCast(id_copy.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, title.ptr, @intCast(title.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, content.ptr, @intCast(content.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        _ = c.sqlite3_bind_int64(stmt, 6, now);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            return error.InsertFailed;
        }

        return MemoryDoc{
            .id = id_copy,
            .title = try self.allocator.dupe(u8, title),
            .content = try self.allocator.dupe(u8, content),
            .created_at = now,
            .updated_at = now,
        };
    }

    pub fn read(self: *const Self, id: []const u8) !?MemoryDoc {
        const sql = "SELECT id, key, title, content, created_at, updated_at FROM memories WHERE id = ? OR key = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const title_ptr = c.sqlite3_column_text(stmt, 2);
            const content_ptr = c.sqlite3_column_text(stmt, 3);
            const created_at = c.sqlite3_column_int64(stmt, 4);
            const updated_at = c.sqlite3_column_int64(stmt, 5);

            return MemoryDoc{
                .id = try self.allocator.dupe(u8, std.mem.span(id_ptr)),
                .title = try self.allocator.dupe(u8, std.mem.span(title_ptr)),
                .content = try self.allocator.dupe(u8, std.mem.span(content_ptr)),
                .created_at = created_at,
                .updated_at = updated_at,
            };
        }

        return null;
    }

    pub fn update(self: *Self, id: []const u8, title: ?[]const u8, content: ?[]const u8) !?MemoryDoc {
        const existing = try self.read(id) orelse return null;
        const now = std.time.timestamp();

        const new_title = title orelse existing.title;
        const new_content = content orelse existing.content;

        const sql = "UPDATE memories SET title = ?, content = ?, updated_at = ? WHERE id = ? OR key = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, new_title.ptr, @intCast(new_title.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, new_content.ptr, @intCast(new_content.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 3, now);
        _ = c.sqlite3_bind_text(stmt, 4, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, id.ptr, @intCast(id.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            return error.UpdateFailed;
        }

        return MemoryDoc{
            .id = existing.id,
            .title = try self.allocator.dupe(u8, new_title),
            .content = try self.allocator.dupe(u8, new_content),
            .created_at = existing.created_at,
            .updated_at = now,
        };
    }

    pub fn delete(self: *Self, id: []const u8) !bool {
        const sql = "DELETE FROM memories WHERE id = ? OR key = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        const changes = c.sqlite3_changes(self.db);
        return changes > 0;
    }

    pub fn list(self: *Self) ![]MemoryDoc {
        var docs: std.ArrayList(MemoryDoc) = .empty;

        const sql = "SELECT id, key, title, content, created_at, updated_at FROM memories ORDER BY updated_at DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const title_ptr = c.sqlite3_column_text(stmt, 2);
            const content_ptr = c.sqlite3_column_text(stmt, 3);
            const created_at = c.sqlite3_column_int64(stmt, 4);
            const updated_at = c.sqlite3_column_int64(stmt, 5);

            const doc = MemoryDoc{
                .id = try self.allocator.dupe(u8, std.mem.span(id_ptr)),
                .title = try self.allocator.dupe(u8, std.mem.span(title_ptr)),
                .content = try self.allocator.dupe(u8, std.mem.span(content_ptr)),
                .created_at = created_at,
                .updated_at = updated_at,
            };
            try docs.append(self.allocator, doc);
        }

        return docs.items;
    }

    fn generateId(self: *Self) ![]const u8 {
        const timestamp = std.time.timestamp();
        var random: u32 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&random));
        return std.fmt.allocPrint(self.allocator, "{d}-{x}", .{ timestamp, random });
    }
};

test "SqliteMemoryStore create and read" {
    const allocator = std.testing.allocator;
    var store = try SqliteMemoryStore.init(allocator, ":memory:");
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

test "SqliteMemoryStore update" {
    const allocator = std.testing.allocator;
    var store = try SqliteMemoryStore.init(allocator, ":memory:");
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

test "SqliteMemoryStore delete" {
    const allocator = std.testing.allocator;
    var store = try SqliteMemoryStore.init(allocator, ":memory:");
    defer store.deinit();

    const doc = try store.create("To Delete", "Content");
    const id = doc.id;
    defer allocator.free(doc.id);

    const deleted = try store.delete(id);
    try std.testing.expect(deleted == true);

    const not_found = try store.read(id);
    try std.testing.expect(not_found == null);
}
