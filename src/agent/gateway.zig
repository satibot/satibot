const std = @import("std");
const Config = @import("../config.zig").Config;
const TelegramBot = @import("telegram_bot.zig").TelegramBot;
const CronStore = @import("cron.zig").CronStore;
const HeartbeatService = @import("heartbeat.zig").HeartbeatService;
const Agent = @import("../agent.zig").Agent;

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    config: Config,
    tg_bot: ?TelegramBot = null,
    cron: CronStore,
    heartbeat: HeartbeatService,

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

        const tg_bot = if (config.tools.telegram != null) try TelegramBot.init(allocator, config) else null;

        return .{
            .allocator = allocator,
            .config = config,
            .tg_bot = tg_bot,
            .cron = cron,
            .heartbeat = HeartbeatService.init(allocator, bots_dir),
        };
    }

    pub fn deinit(self: *Gateway) void {
        if (self.tg_bot) |*bot| bot.deinit();
        self.cron.deinit();
    }

    pub fn run(self: *Gateway) !void {
        std.debug.print("🐸 satibot Gateway started\n", .{});
        if (self.tg_bot != null) std.debug.print("✅ Telegram bot enabled\n", .{});
        std.debug.print("✅ Cron service enabled ({d} jobs)\n", .{self.cron.jobs.items.len});
        std.debug.print("✅ Heartbeat service enabled (every 30m)\n", .{});

        while (true) {
            // 1. Tick Telegram
            if (self.tg_bot) |*bot| {
                bot.tick() catch |err| {
                    std.debug.print("Error in Telegram tick: {any}\n", .{err});
                };
            }

            // 2. Tick Cron
            self.cron.tick(self.config) catch |err| {
                std.debug.print("Error in Cron tick: {any}\n", .{err});
            };

            // 3. Tick Heartbeat
            if (self.heartbeat.should_tick()) {
                if (try self.heartbeat.get_prompt()) |prompt| {
                    std.debug.print("💓 Heartbeat tick: checking for tasks...\n", .{});
                    var agent = Agent.init(self.allocator, self.config, "context:heartbeat");
                    defer agent.deinit();

                    agent.run(prompt) catch |err| {
                        std.debug.print("Error in Heartbeat run: {any}\n", .{err});
                    };

                    const messages = agent.ctx.get_messages();
                    if (messages.len > 0) {
                        const last_msg = messages[messages.len - 1];
                        if (last_msg.content) |content| {
                            if (std.mem.indexOf(u8, content, "HEARTBEAT_OK") != null) {
                                std.debug.print("💓 Heartbeat: OK (no action needed)\n", .{});
                            } else {
                                std.debug.print("💓 Heartbeat: task completed\n", .{});
                            }
                        }
                    }
                }
                self.heartbeat.record_tick();
            }

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

    try std.testing.expect(g.tg_bot == null);
}
