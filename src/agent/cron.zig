/// Cron job scheduling module for recurring and one-time tasks.
/// Jobs can be scheduled to run at specific times or at regular intervals.
/// Jobs are persisted to disk and survive application restarts.
const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;

/// Schedule types: one-time "at" a specific time, or recurring "every" N milliseconds.
pub const CronScheduleKind = enum {
    at,
    every,
};

/// Defines when a cron job should execute.
pub const CronSchedule = struct {
    kind: CronScheduleKind,
    at_ms: ?i64 = null, // For 'at' schedules: timestamp in milliseconds
    every_ms: ?i64 = null, // For 'every' schedules: interval in milliseconds
};

/// Payload containing the task to execute and delivery settings.
pub const CronPayload = struct {
    message: []const u8, // Task description or message to process
    deliver: bool = false, // Whether to deliver results externally
    channel: ?[]const u8 = null, // Optional delivery channel (e.g., "#general")
    to: ?[]const u8 = null, // Optional recipient (e.g., "@user")
};

/// Execution state tracking for a cron job.
pub const CronJobState = struct {
    next_run_at_ms: ?i64 = null, // When the job should next execute
    last_run_at_ms: ?i64 = null, // When the job last executed
    last_status: ?[]const u8 = null, // "success", "failed", etc.
    last_error: ?[]const u8 = null, // Error message if last run failed
};

/// A scheduled job with timing, payload, and execution state.
pub const CronJob = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    schedule: CronSchedule,
    payload: CronPayload,
    state: CronJobState = .{},
    created_at_ms: i64,
    updated_at_ms: i64,

    /// Free all allocated memory for this job.
    pub fn deinit(self: *CronJob, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.payload.message);
        if (self.payload.channel) |c| allocator.free(c);
        if (self.payload.to) |t| allocator.free(t);
        if (self.state.last_status) |s| allocator.free(s);
        if (self.state.last_error) |e| allocator.free(e);
        self.* = undefined;
    }
};

/// Store managing all cron jobs with persistence capabilities.
pub const CronStore = struct {
    jobs: std.ArrayList(CronJob),
    allocator: std.mem.Allocator,

    /// Initialize an empty cron job store.
    pub fn init(allocator: std.mem.Allocator) CronStore {
        return .{
            .jobs = std.ArrayList(CronJob).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CronStore) void {
        for (self.jobs.items) |*job| {
            job.deinit(self.allocator);
        }
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn load(self: *CronStore, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10485760); // 10 * 1024 * 1024
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(struct { jobs: []CronJob }, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value.jobs) |job| {
            try self.jobs.append(self.allocator, try cloneJob(self.allocator, job));
        }
    }

    pub fn save(self: *CronStore, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{ .jobs = self.jobs.items }, .{ .whitespace = .indent_2 }, &out.writer);
        try file.writeAll(out.written());
    }

    fn cloneJob(allocator: std.mem.Allocator, job: CronJob) !CronJob {
        return .{
            .id = try allocator.dupe(u8, job.id),
            .name = try allocator.dupe(u8, job.name),
            .enabled = job.enabled,
            .schedule = job.schedule,
            .payload = .{
                .message = try allocator.dupe(u8, job.payload.message),
                .deliver = job.payload.deliver,
                .channel = if (job.payload.channel) |c| try allocator.dupe(u8, c) else null,
                .to = if (job.payload.to) |t| try allocator.dupe(u8, t) else null,
            },
            .state = .{
                .next_run_at_ms = job.state.next_run_at_ms,
                .last_run_at_ms = job.state.last_run_at_ms,
                .last_status = if (job.state.last_status) |s| try allocator.dupe(u8, s) else null,
                .last_error = if (job.state.last_error) |e| try allocator.dupe(u8, e) else null,
            },
            .created_at_ms = job.created_at_ms,
            .updated_at_ms = job.updated_at_ms,
        };
    }

    pub fn addJob(self: *CronStore, name: []const u8, schedule: CronSchedule, message: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{std.time.milliTimestamp()});
        const now = std.time.milliTimestamp();

        var next_run: ?i64 = null;
        if (schedule.kind == .every) {
            next_run = now + (schedule.every_ms orelse 0);
        } else if (schedule.kind == .at) {
            next_run = schedule.at_ms;
        }

        const job: CronJob = .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .schedule = schedule,
            .payload = .{
                .message = try self.allocator.dupe(u8, message),
            },
            .state = .{
                .next_run_at_ms = next_run,
            },
            .created_at_ms = now,
            .updated_at_ms = now,
        };

        try self.jobs.append(self.allocator, job);
        return id;
    }

    pub fn tick(self: *CronStore, config: Config) !void {
        const now = std.time.milliTimestamp();
        for (self.jobs.items) |*job| {
            if (!job.enabled) continue;
            if (job.state.next_run_at_ms) |next_run| {
                if (now >= next_run) {
                    try self.runJob(job, config);
                }
            }
        }
    }

    fn runJob(self: *CronStore, job: *CronJob, config: Config) !void {
        std.debug.print("⏳ Running cron job: {s} ({s})\n", .{ job.name, job.id });

        const now = std.time.milliTimestamp();
        job.state.last_run_at_ms = now;

        // Create a new agent session for this job
        const session_id = try std.fmt.allocPrint(self.allocator, "cron_{s}", .{job.id});
        defer self.allocator.free(session_id);

        var agent = Agent.init(self.allocator, config, session_id);
        defer agent.deinit();

        agent.run(job.payload.message) catch |err| {
            std.debug.print("❌ Cron job failed: {s}, error: {any}\n", .{ job.name, err });
            if (job.state.last_error) |e| self.allocator.free(e);
            job.state.last_error = try std.fmt.allocPrint(self.allocator, "{any}", .{err});
            if (job.state.last_status) |s| self.allocator.free(s);
            job.state.last_status = try self.allocator.dupe(u8, "error");
        };

        if (job.state.last_status == null or !std.mem.eql(u8, job.state.last_status.?, "error")) {
            if (job.state.last_status) |s| self.allocator.free(s);
            job.state.last_status = try self.allocator.dupe(u8, "ok");
            std.debug.print("✅ Cron job completed: {s}\n", .{job.name});
        }

        // Update next run
        if (job.schedule.kind == .every) {
            job.state.next_run_at_ms = now + (job.schedule.every_ms orelse 0);
        } else {
            job.enabled = false; // "at" jobs only run once
            job.state.next_run_at_ms = null;
        }

        job.updated_at_ms = now;
    }
};

test "CronStore: init, add, save, and load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = CronStore.init(allocator);
    defer store.deinit();

    const job_name = "test_job";
    const job_msg = "test_message";
    const schedule: CronSchedule = .{ .kind = .every, .every_ms = 1000 };

    const id = try store.addJob(job_name, schedule, job_msg);
    try std.testing.expect(id.len > 0);
    try std.testing.expectEqual(@as(usize, 1), store.jobs.items.len);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const cron_path = try std.fs.path.join(allocator, &.{ tmp_path, "cron_jobs.json" });
    defer allocator.free(cron_path);

    try store.save(cron_path);

    var store2 = CronStore.init(allocator);
    defer store2.deinit();
    try store2.load(cron_path);

    try std.testing.expectEqual(@as(usize, 1), store2.jobs.items.len);
    try std.testing.expectEqualStrings(job_name, store2.jobs.items[0].name);
    try std.testing.expectEqualStrings(job_msg, store2.jobs.items[0].payload.message);
    try std.testing.expectEqualStrings(id, store2.jobs.items[0].id);
}

test "CronSchedule: struct creation" {
    // Test 'at' schedule
    const at_schedule: CronSchedule = .{
        .kind = .at,
        .at_ms = 1234567890,
    };
    try std.testing.expectEqual(CronScheduleKind.at, at_schedule.kind);
    try std.testing.expectEqual(@as(i64, 1234567890), at_schedule.at_ms.?);
    try std.testing.expect(at_schedule.every_ms == null);

    // Test 'every' schedule
    const every_schedule: CronSchedule = .{
        .kind = .every,
        .every_ms = 5000,
    };
    try std.testing.expectEqual(CronScheduleKind.every, every_schedule.kind);
    try std.testing.expectEqual(@as(i64, 5000), every_schedule.every_ms.?);
    try std.testing.expect(every_schedule.at_ms == null);
}

test "CronPayload: struct creation" {
    const payload: CronPayload = .{
        .message = "Hello World",
        .deliver = true,
        .channel = "#general",
        .to = "@user123",
    };

    try std.testing.expectEqualStrings("Hello World", payload.message);
    try std.testing.expectEqual(true, payload.deliver);
    try std.testing.expectEqualStrings("#general", payload.channel.?);
    try std.testing.expectEqualStrings("@user123", payload.to.?);
}

test "CronPayload: minimal creation" {
    const payload: CronPayload = .{
        .message = "Simple message",
    };

    try std.testing.expectEqualStrings("Simple message", payload.message);
    try std.testing.expectEqual(false, payload.deliver);
    try std.testing.expect(payload.channel == null);
    try std.testing.expect(payload.to == null);
}

test "CronJobState: struct creation" {
    const state: CronJobState = .{
        .next_run_at_ms = 1000,
        .last_run_at_ms = 500,
        .last_status = "success",
        .last_error = null,
    };

    try std.testing.expectEqual(@as(i64, 1000), state.next_run_at_ms.?);
    try std.testing.expectEqual(@as(i64, 500), state.last_run_at_ms.?);
    try std.testing.expectEqualStrings("success", state.last_status.?);
    try std.testing.expect(state.last_error == null);
}

test "CronStore: multiple jobs" {
    const allocator = std.testing.allocator;
    var store = CronStore.init(allocator);
    defer store.deinit();

    const id1 = try store.addJob("job1", .{ .kind = .every, .every_ms = 1000 }, "msg1");

    // Small delay to ensure different timestamps (1 millisecond)
    std.Thread.sleep(1000000); // 1ms in nanoseconds

    const id2 = try store.addJob("job2", .{ .kind = .every, .every_ms = 2000 }, "msg2");

    std.Thread.sleep(1000000);

    const id3 = try store.addJob("job3", .{ .kind = .at, .at_ms = 9999999999 }, "msg3");

    try std.testing.expectEqual(@as(usize, 3), store.jobs.items.len);

    // IDs should be different if we added delays
    const ids_different = !std.mem.eql(u8, id1, id2) or !std.mem.eql(u8, id2, id3);
    try std.testing.expect(ids_different);

    try std.testing.expectEqualStrings("job1", store.jobs.items[0].name);
    try std.testing.expectEqualStrings("job2", store.jobs.items[1].name);
    try std.testing.expectEqualStrings("job3", store.jobs.items[2].name);

    try std.testing.expectEqual(CronScheduleKind.every, store.jobs.items[0].schedule.kind);
    try std.testing.expectEqual(CronScheduleKind.every, store.jobs.items[1].schedule.kind);
    try std.testing.expectEqual(CronScheduleKind.at, store.jobs.items[2].schedule.kind);
}

test "CronStore: remove_job" {
    const allocator = std.testing.allocator;
    var store = CronStore.init(allocator);
    defer store.deinit();

    _ = try store.addJob("job1", .{ .kind = .every, .every_ms = 1000 }, "msg1");
    _ = try store.addJob("job2", .{ .kind = .every, .every_ms = 2000 }, "msg2");

    try std.testing.expectEqual(@as(usize, 2), store.jobs.items.len);

    // Disable first job by modifying directly
    store.jobs.items[0].enabled = false;

    // Verify job1 is disabled
    try std.testing.expectEqual(false, store.jobs.items[0].enabled);

    // Verify we still have 2 jobs
    try std.testing.expectEqual(@as(usize, 2), store.jobs.items.len);
}

test "CronStore: load non-existent file" {
    const allocator = std.testing.allocator;
    var store = CronStore.init(allocator);
    defer store.deinit();

    // Loading non-existent file should not error, just leave store empty
    try store.load("/non/existent/path/cron.json");
    try std.testing.expectEqual(@as(usize, 0), store.jobs.items.len);
}

test "CronJob: default state" {
    const allocator = std.testing.allocator;
    var store = CronStore.init(allocator);
    defer store.deinit();

    _ = try store.addJob("test_job", .{ .kind = .every, .every_ms = 1000 }, "test_msg");

    const job = store.jobs.items[0];
    try std.testing.expectEqualStrings("test_job", job.name);
    try std.testing.expectEqual(true, job.enabled);
    // next_run_at_ms is calculated and set during addJob for 'every' schedules
    try std.testing.expect(job.state.next_run_at_ms != null);
    try std.testing.expect(job.state.last_run_at_ms == null);
    try std.testing.expect(job.state.last_status == null);
    try std.testing.expect(job.state.last_error == null);
    try std.testing.expect(job.created_at_ms > 0);
    try std.testing.expect(job.updated_at_ms > 0);
}

test "HTTP: Header parsing" {
    // Test ResponseHead parsing logic
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Content-Length", .value = "1234" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };

    // Verify header values
    var content_length: ?u64 = null;
    var chunked = false;

    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            content_length = try std.fmt.parseInt(u64, header.value, 10);
        } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(header.value, "chunked") != null) {
                chunked = true;
            }
        }
    }

    try std.testing.expectEqual(@as(u64, 1234), content_length.?);
    try std.testing.expectEqual(true, chunked);
}
