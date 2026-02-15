const std = @import("std");

// Memory-optimized build configuration
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Force ReleaseSmall optimization for minimal memory footprint
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const build_options = b.addOptions();
    const build_time_timestamp = std.time.timestamp();
    build_options.addOption(i64, "build_time", build_time_timestamp);

    // Get build time in UTC, format: YYYY-MM-DD HH:MM:SS
    const date_output = b.run(&.{ "date", "-u", "+%Y-%m-%d %H:%M:%S" });
    // Add UTC suffix to build time string
    const build_time_str = b.fmt("{s} UTC", .{std.mem.trim(u8, date_output, "\n\r ")});
    build_options.addOption([]const u8, "build_time_str", build_time_str);

    // Get build version in UTC, format: YYYY.MM.DD.HHMM
    const date_version_output = b.run(&.{ "date", "-u", "+%Y.%m.%d.%H%M" });
    build_options.addOption([]const u8, "version", date_version_output);

    // Create minimal module with only essential dependencies
    const mod = b.addModule("satibot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Remove xev dependency for console mode to save memory
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "tls", .module = b.dependency("tls", .{
                .target = target,
                .optimize = optimize,
            }).module("tls") },
        },
    });

    // Memory-optimized executable
    const exe = b.addExecutable(.{
        .name = "sati-memory-optimized",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "satibot", .module = mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    // Aggressive memory optimization settings
    exe.strip = true;
    exe.root_module.strip = true;
    exe.want_lto = true; // Link-time optimization
    exe.single_threaded = true; // Disable threading for minimal memory usage

    // Reduce stack size for main thread
    exe.stack_size = 256 * 1024; // 256KB main stack

    b.installArtifact(exe);

    // Create a run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run-memory-optimized", "Run memory-optimized sati");
    run_step.dependOn(&run_cmd.step);
}
