const std = @import("std");
const Config = @import("../config.zig").Config;

pub const CronScheduleKind = enum {
    at,
    every,
};

pub const CronSchedule = struct {
    kind: CronScheduleKind,
    at_ms: ?i64 = null,
    every_ms: ?i64 = null,
};

pub const CronPayload = struct {
    message: []const u8,
    deliver: bool = false,
    channel: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

pub const CronJobState = struct {
    next_run_at_ms: ?i64 = null,
    last_run_at_ms: ?i64 = null,
    last_status: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
};

pub const CronJob = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    schedule: CronSchedule,
    payload: CronPayload,
    state: CronJobState = .{},
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *CronJob, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.payload.message);
        if (self.payload.channel) |c| allocator.free(c);
        if (self.payload.to) |t| allocator.free(t);
        if (self.state.last_status) |s| allocator.free(s);
        if (self.state.last_error) |e| allocator.free(e);
    }
};

pub const CronStore = struct {
    jobs: std.ArrayList(CronJob),
    allocator: std.mem.Allocator,

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
        return CronJob{
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

    pub fn add_job(self: *CronStore, name: []const u8, schedule: CronSchedule, message: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{std.time.milliTimestamp()});
        const now = std.time.milliTimestamp();

        var next_run: ?i64 = null;
        if (schedule.kind == .every) {
            next_run = now + (schedule.every_ms orelse 0);
        } else if (schedule.kind == .at) {
            next_run = schedule.at_ms;
        }

        const job = CronJob{
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
                    try self.run_job(job, config);
                }
            }
        }
    }

    fn run_job(self: *CronStore, job: *CronJob, config: Config) !void {
        std.debug.print("⏳ Running cron job: {s} ({s})\n", .{ job.name, job.id });

        const now = std.time.milliTimestamp();
        job.state.last_run_at_ms = now;

        // Create a new agent session for this job
        const session_id = try std.fmt.allocPrint(self.allocator, "cron_{s}", .{job.id});
        defer self.allocator.free(session_id);

        const Agent = @import("../agent.zig").Agent;
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
    const schedule = CronSchedule{ .kind = .every, .every_ms = 1000 };

    const id = try store.add_job(job_name, schedule, job_msg);
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
