/// Heartbeat service for periodic background task checking.
/// Monitors a HEARTBEAT.md file in the workspace for tasks that need attention.
const std = @import("std");

/// Service that periodically checks for and executes background tasks.
/// Runs every 30 minutes (1800 seconds) by default.
pub const HeartbeatService = struct {
    allocator: std.mem.Allocator,
    interval_s: u32 = 1800, // 30 minutes * 60 seconds = 1800 seconds
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
    pub fn shouldTick(self: *HeartbeatService) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        if (self.last_tick_ms == 0) {
            self.last_tick_ms = now;
            return false; // Don't tick immediately on startup
        }
        return (now - self.last_tick_ms) >= (@as(i64, @intCast(self.interval_s)) * 1000);
    }

    /// Get the prompt for heartbeat processing.
    /// Reads HEARTBEAT.md from workspace if it exists and has content.
    pub fn getPrompt(self: *HeartbeatService) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.workspace_path, "HEARTBEAT.md" });
        defer self.allocator.free(path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return self.allocator.dupe(u8, "");
            return err;
        };
        defer file.close(io);

        // Read file content up to 0.5MB (524288 = 1024 * 512)
        var reader_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &reader_buf);
        const content = reader.interface.allocRemaining(self.allocator, .limited(524288)) catch |err| {
            std.log.err("Failed to read HEARTBEAT.md file: {}", .{err});
            return err;
        };

        defer self.allocator.free(content);

        if (self.isEmpty(content)) return self.allocator.dupe(u8, "");

        return self.allocator.dupe(u8,
            \\Read HEARTBEAT.md in your workspace.
            \\Follow any instructions or tasks listed there.
            \\If nothing needs attention, reply with just: HEARTBEAT_OK
        );
    }

    fn isEmpty(self: *HeartbeatService, content: []const u8) bool {
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

    pub fn recordTick(self: *HeartbeatService) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.last_tick_ms = std.Io.Clock.real.now(io).toMilliseconds();
    }
};

test "HeartbeatService: tick logic and prompt" {
    // Example: Testing the heartbeat service's timing and file reading capabilities
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the temporary directory path for testing
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var service = HeartbeatService.init(allocator, tmp_path);
    service.interval_s = 1; // Override to 1 second for faster testing

    // First call to should_tick initializes last_tick_ms and returns false
    // This prevents immediate tick on service startup
    try std.testing.expect(!service.shouldTick());

    // Wait longer than the 1-second interval to trigger next tick
    // Using 1.1 seconds to ensure we exceed the interval
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1100), .real) catch |err| std.log.warn("sleep failed: {any}", .{err});
    try std.testing.expect(service.shouldTick());

    // Example: Test get_prompt with empty HEARTBEAT.md file
    // An empty file should return null (no prompt needed)
    const hb_file = try tmp.dir.createFile(std.testing.io, "HEARTBEAT.md", .{});
    hb_file.close(std.testing.io);
    const prompt = try service.getPrompt();
    try std.testing.expectEqualStrings("", prompt);
    allocator.free(prompt); // Clean up allocated prompt string

    // Example: Test get_prompt with content in HEARTBEAT.md
    // A file with content should return a prompt string
    const hb_file2 = try tmp.dir.createFile(std.testing.io, "HEARTBEAT.md", .{});
    try hb_file2.writeStreamingAll(std.testing.io, "Do something\n");
    hb_file2.close(std.testing.io);
    const prompt2 = try service.getPrompt();
    try std.testing.expect(prompt2.len > 0);
    allocator.free(prompt2); // Clean up allocated prompt string
}
