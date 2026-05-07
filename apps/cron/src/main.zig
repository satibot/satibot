//! s-cron CLI: Schedule recurring tasks using cron expressions.
//! Usage: s-cron --schedule "0 9 * * *" --message "Daily summary"
const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.args.toSlice(allocator);

    var schedule_str: ?[]const u8 = null;
    var message_str: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--schedule") and i + 1 < args.len) {
            schedule_str = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--message") and i + 1 < args.len) {
            message_str = args[i + 1];
            i += 2;
        } else {
            i += 1;
        }
    }

    if (schedule_str == null or message_str == null) {
        const usage =
            \\Usage: s-cron --schedule <cron_expr> --message <text>
            \\Example: s-cron --schedule "0 9 * * *" --message "Daily summary"
        ;
        std.debug.print("{s}\n", .{usage});
        return;
    }

    // Use std.c.getenv to avoid requiring libc explicitly. link_libc is set in build.zig.
    const home_ptr = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse "/tmp";
    const home = std.mem.span(home_ptr);

    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    const cron_path = try std.fs.path.join(allocator, &.{ bots_dir, "cron_jobs.json" });

    // Create the ~/.bots directory if it does not exist yet.
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(io, bots_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var store = agent.cron.CronStore.init(allocator);
    defer store.deinit();

    // Load existing jobs; tolerate missing file on first run.
    store.load(cron_path) catch |err| {
        std.debug.print("Note: no existing cron_jobs.json found, creating new ({any})\n", .{err});
    };

    const schedule: agent.cron.CronSchedule = .{
        .kind = .cron,
        .cron_expr = schedule_str.?,
    };

    // Generate a simple unique ID using a counter based on the number of existing jobs.
    const job_name = try std.fmt.allocPrint(allocator, "cli_job_{d}", .{store.jobs.items.len + 1});

    const id = try store.addJob(job_name, schedule, message_str.?);
    std.debug.print("Added task '{s}' with schedule '{s}'\n", .{ id, schedule_str.? });

    try store.save(cron_path);
    std.debug.print("Saved to {s}\n", .{cron_path});
}
