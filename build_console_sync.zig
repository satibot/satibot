const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    const build_time_timestamp = std.time.timestamp();
    build_options.addOption(i64, "build_time", build_time_timestamp);

    const date_output = b.run(&.{ "date", "-u", "+%Y-%m-%d %H:%M:%S" });
    const build_time_str = b.fmt("{s} UTC", .{std.mem.trim(u8, date_output, "\n\r ")});
    build_options.addOption([]const u8, "build_time_str", build_time_str);

    const date_version_output = b.run(&.{ "date", "-u", "+%Y.%m.%d.%H%M" });
    const version = std.mem.trim(u8, date_version_output, "\n\r ");
    build_options.addOption([]const u8, "version", version);

    const tls_mod = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    }).module("tls");

    const mod = b.addModule("satibot", .{
        .root_source_file = b.path("src/root_console_sync.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_opts", .module = build_options.createModule() },
            .{ .name = "tls", .module = tls_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "console-sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/console_sync_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "satibot", .module = mod },
                .{ .name = "tls", .module = tls_mod },
                .{ .name = "build_opts", .module = build_options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run console-sync bot");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
