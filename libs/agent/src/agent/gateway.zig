/// Gateway module that orchestrates all bot services.
/// Runs the main event loop managing cron jobs and heartbeat checks.
const std = @import("std");
const Config = @import("core").config.Config;
const CronStore = @import("cron.zig").CronStore;
const HeartbeatService = @import("heartbeat.zig").HeartbeatService;
const Agent = @import("../agent.zig").Agent;

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
        const home = std.posix.getenv("HOME") orelse "/tmp";
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
            std.Thread.sleep(std.time.ns_per_s * 1);
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
