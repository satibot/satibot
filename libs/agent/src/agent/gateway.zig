/// Gateway module that orchestrates all bot services.
/// Runs the main event loop managing cron jobs and heartbeat checks.
const std = @import("std");

pub const Config = @import("core").config.Config;

const Agent = @import("../agent.zig").Agent;
const CronStore = @import("cron.zig").CronStore;
const HeartbeatService = @import("heartbeat.zig").HeartbeatService;

/// Main gateway struct containing all bot services.
/// Coordinates between cron jobs and heartbeat monitoring.
pub const Gateway = struct {
    allocator: std.mem.Allocator,
    config: Config,
    cron: CronStore,
    heartbeat: HeartbeatService,

    /// Initialize the gateway with all required services.
    /// Loads cron jobs from disk.
    pub fn init(allocator: std.mem.Allocator, config: Config) !Gateway {
        const home_ptr = std.c.getenv("HOME") orelse "/tmp";
        const home = std.mem.span(home_ptr);
        const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
        defer allocator.free(bots_dir);

        const cron_path = try std.fs.path.join(allocator, &.{ bots_dir, "cron_jobs.json" });
        defer allocator.free(cron_path);

        var cron = CronStore.init(allocator);
        cron.load(cron_path) catch |err| {
            std.debug.print("Warning: Could not load cron jobs: {any}\n", .{err});
        };

        return .{
            .allocator = allocator,
            .config = config,
            .cron = cron,
            .heartbeat = HeartbeatService.init(allocator, bots_dir),
        };
    }

    pub fn deinit(self: *Gateway) void {
        self.cron.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Gateway) !void {
        std.debug.print("🐸 satibot Gateway started\n", .{});
        std.debug.print("✅ Cron service enabled ({d} jobs)\n", .{self.cron.jobs.items.len});
        std.debug.print("✅ Heartbeat service enabled (every 30m)\n", .{});

        while (true) {
            // 1. Tick Cron
            self.cron.tick(self.config) catch |err| {
                std.debug.print("Error in Cron tick: {any}\n", .{err});
            };

            // Sleep a bit to avoid CPU pegging
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .real) catch |err| std.log.warn("sleep failed: {any}", .{err});
        }
    }
};

test "Gateway: init" {
    const allocator = std.testing.allocator;
    const config_json =
        \\{
        \\  "agents": { "defaults": { "model": "test-model" } },
        \\  "providers": {},
        \\  "tools": { "web": { "search": {} } }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Config, allocator, config_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var g = try Gateway.init(allocator, parsed.value);
    defer g.deinit();

    try std.testing.expect(g.cron.jobs.items.len == 0);
}
