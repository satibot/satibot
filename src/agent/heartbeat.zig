const std = @import("std");

pub const HeartbeatService = struct {
    allocator: std.mem.Allocator,
    interval_s: u64 = 1800, // 30 * 60
    last_tick_ms: i64 = 0,
    workspace_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) HeartbeatService {
        return .{
            .allocator = allocator,
            .workspace_path = workspace_path,
        };
    }

    pub fn should_tick(self: *HeartbeatService) bool {
        const now = std.time.milliTimestamp();
        if (self.last_tick_ms == 0) {
            self.last_tick_ms = now;
            return false; // Don't tick immediately on startup
        }
        return (now - self.last_tick_ms) >= (@as(i64, @intCast(self.interval_s)) * 1000);
    }

    pub fn get_prompt(self: *HeartbeatService) !?[]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.workspace_path, "HEARTBEAT.md" });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1048576); // 1024 * 1024
        defer self.allocator.free(content);

        if (self.is_empty(content)) return null;

        return try self.allocator.dupe(u8,
            \\Read HEARTBEAT.md in your workspace.
            \\Follow any instructions or tasks listed there.
            \\If nothing needs attention, reply with just: HEARTBEAT_OK
        );
    }

    fn is_empty(self: *HeartbeatService, content: []const u8) bool {
        _ = self;
        var iter = std.mem.tokenizeScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.startsWith(u8, trimmed, "<!--")) continue;
            return false;
        }
        return true;
    }

    pub fn record_tick(self: *HeartbeatService) void {
        self.last_tick_ms = std.time.milliTimestamp();
    }
};

test "HeartbeatService: tick logic and prompt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var service = HeartbeatService.init(allocator, tmp_path);
    service.interval_s = 1; // 1 second for testing

    // First call to should_tick sets last_tick_ms and returns false
    try std.testing.expect(!service.should_tick());

    // Wait 1.1s
    std.Thread.sleep(std.time.ns_per_s + std.time.ns_per_ms * 100);
    try std.testing.expect(service.should_tick());

    // Test get_prompt with empty file
    const hb_file = try tmp.dir.createFile("HEARTBEAT.md", .{});
    hb_file.close();
    try std.testing.expect((try service.get_prompt()) == null);

    // Test get_prompt with content
    const hb_file2 = try tmp.dir.createFile("HEARTBEAT.md", .{});
    try hb_file2.writeAll("Do something\n");
    hb_file2.close();
    const prompt = try service.get_prompt();
    try std.testing.expect(prompt != null);
    allocator.free(prompt.?);
}
