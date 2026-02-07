/// Heartbeat service for periodic background task checking.
/// Monitors a HEARTBEAT.md file in the workspace for tasks that need attention.
const std = @import("std");

/// Service that periodically checks for and executes background tasks.
/// Runs every 30 minutes (1800 seconds) by default.
pub const HeartbeatService = struct {
    allocator: std.mem.Allocator,
    interval_s: u64 = 1800, // 30 minutes * 60 seconds = 1800 seconds
    last_tick_ms: i64 = 0,
    workspace_path: []const u8,

    /// Initialize heartbeat service with workspace path.
    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8) HeartbeatService {
        return .{
            .allocator = allocator,
            .workspace_path = workspace_path,
        };
    }

    /// Check if enough time has passed since last tick to trigger heartbeat.
    pub fn should_tick(self: *HeartbeatService) bool {
        const now = std.time.milliTimestamp();
        if (self.last_tick_ms == 0) {
            self.last_tick_ms = now;
            return false; // Don't tick immediately on startup
        }
        return (now - self.last_tick_ms) >= (@as(i64, @intCast(self.interval_s)) * 1000);
    }

    /// Get the prompt for heartbeat processing.
    /// Reads HEARTBEAT.md from workspace if it exists and has content.
    pub fn get_prompt(self: *HeartbeatService) !?[]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.workspace_path, "HEARTBEAT.md" });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1048576) catch |err| {
            std.log.err("Failed to read HEARTBEAT.md file: {}", .{err});
            return err;
        }; // 1MB buffer (1024 * 1024)

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
    // Example: Testing the heartbeat service's timing and file reading capabilities
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the temporary directory path for testing
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var service = HeartbeatService.init(allocator, tmp_path);
    service.interval_s = 1; // Override to 1 second for faster testing

    // First call to should_tick initializes last_tick_ms and returns false
    // This prevents immediate tick on service startup
    try std.testing.expect(!service.should_tick());

    // Wait longer than the 1-second interval to trigger next tick
    // Using 1.1 seconds to ensure we exceed the interval
    std.Thread.sleep(std.time.ns_per_s + std.time.ns_per_ms * 100);
    try std.testing.expect(service.should_tick());

    // Example: Test get_prompt with empty HEARTBEAT.md file
    // An empty file should return null (no prompt needed)
    const hb_file = try tmp.dir.createFile("HEARTBEAT.md", .{});
    hb_file.close();
    try std.testing.expect((try service.get_prompt()) == null);

    // Example: Test get_prompt with content in HEARTBEAT.md
    // A file with content should return a prompt string
    const hb_file2 = try tmp.dir.createFile("HEARTBEAT.md", .{});
    try hb_file2.writeAll("Do something\n");
    hb_file2.close();
    const prompt = try service.get_prompt();
    try std.testing.expect(prompt != null);
    allocator.free(prompt.?); // Clean up allocated prompt string
}
