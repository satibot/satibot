const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const build_options = b.addOptions();
    const build_time_timestamp = std.time.timestamp();
    build_options.addOption(i64, "build_time", build_time_timestamp);

    const date_output = b.run(&.{ "date", "-u", "+%Y-%m-%d %H:%M:%S" });
    const build_time_str = b.fmt("{s} UTC", .{std.mem.trim(u8, date_output, "\n\r ")});
    build_options.addOption([]const u8, "build_time_str", build_time_str);

    const date_version_output = b.run(&.{ "date", "-u", "+%Y.%m.%d.%H%M" });
    const version = std.mem.trim(u8, date_version_output, "\n\r ");
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "include_whatsapp", false);

    // External dependencies
    const tls_mod = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    }).module("tls");

    const xev_mod = b.dependency("xev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    // Libraries - defined in dependency order
    const core = b.addModule("core", .{
        .root_source_file = b.path("libs/core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const http = b.addModule("http", .{
        .root_source_file = b.path("libs/http/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tls", .module = tls_mod },
        },
    });

    const utils = b.addModule("utils", .{
        .root_source_file = b.path("libs/utils/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xev", .module = xev_mod },
            .{ .name = "core", .module = core },
        },
    });

    const providers = b.addModule("providers", .{
        .root_source_file = b.path("libs/providers/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
            .{ .name = "core", .module = core },
            .{ .name = "utils", .module = utils },
        },
    });

    const db = b.addModule("db", .{
        .root_source_file = b.path("libs/db/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "providers", .module = providers },
        },
    });

    const agent = b.addModule("agent", .{
        .root_source_file = b.path("libs/agent/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_opts", .module = build_options.createModule() },
            .{ .name = "core", .module = core },
            .{ .name = "tls", .module = tls_mod },
            .{ .name = "xev", .module = xev_mod },
            .{ .name = "db", .module = db },
            .{ .name = "http", .module = http },
            .{ .name = "providers", .module = providers },
            .{ .name = "utils", .module = utils },
        },
    });

    // Telegram module (for agent/gateway to use)
    const telegram_mod = b.addModule("telegram", .{
        .root_source_file = b.path("apps/telegram/src/telegram/telegram.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "providers", .module = providers },
            .{ .name = "http", .module = http },
            .{ .name = "xev", .module = xev_mod },
            .{ .name = "agent", .module = agent },
            .{ .name = "utils", .module = utils },
        },
    });

    // Console App (sync)
    const console_sync = b.addExecutable(.{
        .name = "console-sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/console/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "db", .module = db },
                .{ .name = "providers", .module = providers },
                .{ .name = "http", .module = http },
                .{ .name = "tls", .module = tls_mod },
                .{ .name = "build_opts", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(console_sync);

    // Console App (async with xev)
    const console_xev = b.addExecutable(.{
        .name = "console",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/console/src/xev_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "db", .module = db },
                .{ .name = "providers", .module = providers },
                .{ .name = "http", .module = http },
                .{ .name = "tls", .module = tls_mod },
                .{ .name = "xev", .module = xev_mod },
                .{ .name = "build_opts", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(console_xev);

    // Telegram Bot
    const telegram = b.addExecutable(.{
        .name = "telegram",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/telegram/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "db", .module = db },
                .{ .name = "providers", .module = providers },
                .{ .name = "http", .module = http },
                .{ .name = "telegram", .module = telegram_mod },
                .{ .name = "tls", .module = tls_mod },
                .{ .name = "xev", .module = xev_mod },
                .{ .name = "build_opts", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(telegram);

    // Run steps
    const run_console_sync = b.step("run-console-sync", "Run console-sync app");
    run_console_sync.dependOn(&b.addRunArtifact(console_sync).step);

    const run_console = b.step("run-console", "Run console app (xev)");
    run_console.dependOn(&b.addRunArtifact(console_xev).step);

    const run_telegram = b.step("run-telegram", "Run telegram bot");
    run_telegram.dependOn(&b.addRunArtifact(telegram).step);

    // Test step for all libraries
    const test_step = b.step("test", "Run library tests");

    const lib_tests = [_]struct { name: []const u8, path: []const u8, imports: []const std.Build.Module.Import }{
        .{ .name = "core", .path = "libs/core/src/root.zig", .imports = &.{} },
        .{ .name = "http", .path = "libs/http/src/root.zig", .imports = &.{.{ .name = "tls", .module = tls_mod }} },
        .{ .name = "utils", .path = "libs/utils/src/root.zig", .imports = &.{ .{ .name = "xev", .module = xev_mod }, .{ .name = "core", .module = core } } },
        .{ .name = "providers", .path = "libs/providers/src/root.zig", .imports = &.{ .{ .name = "http", .module = http }, .{ .name = "core", .module = core }, .{ .name = "utils", .module = utils } } },
        .{ .name = "db", .path = "libs/db/src/root.zig", .imports = &.{.{ .name = "providers", .module = providers }} },
        .{ .name = "agent", .path = "libs/agent/src/root.zig", .imports = &.{
            .{ .name = "build_opts", .module = build_options.createModule() },
            .{ .name = "core", .module = core },
            .{ .name = "tls", .module = tls_mod },
            .{ .name = "xev", .module = xev_mod },
            .{ .name = "db", .module = db },
            .{ .name = "http", .module = http },
            .{ .name = "providers", .module = providers },
            .{ .name = "utils", .module = utils },
        } },
    };

    for (lib_tests) |lib| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(lib.path),
            .target = target,
            .optimize = optimize,
            .imports = lib.imports,
        });
        const test_run = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
        test_step.dependOn(&test_run.step);
    }
}
