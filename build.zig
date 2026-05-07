const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const build_options = b.addOptions();
    const timestamp: i64 = 0;
    build_options.addOption(i64, "build_time", timestamp);

    // Hardcode string fallback since we cannot run date easily cross-platform
    build_options.addOption([]const u8, "build_time_str", "2024-01-01 00:00:00 UTC");
    build_options.addOption([]const u8, "version", "2024.01.01.0000");
    build_options.addOption(bool, "include_whatsapp", false);
    const include_web = b.option(bool, "web", "Build with web module (zap)") orelse false;
    const enable_sqlite = b.option(bool, "sqlite", "Enable SQLite support") orelse true;
    const enable_memory_sqlite = b.option(bool, "memory-sqlite", "Enable SQLite memory backend") orelse true;

    // SQLite3 system library - no need to create a wrapper library
    // The system library will be linked directly to executables that need it

    build_options.addOption(bool, "enable_sqlite", enable_sqlite);
    build_options.addOption(bool, "enable_memory_sqlite", enable_sqlite and enable_memory_sqlite);

    // External dependencies
    const tls_mod = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    }).module("tls");

    const xev_mod = b.dependency("xev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    // web module (HTTP API using zap) — zap is a private dep of libs/web
    const web_mod: ?*std.Build.Module = if (include_web)
        b.dependency("web", .{
            .target = target,
            .optimize = optimize,
        }).module("web")
    else
        null;

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

    const facebook = b.addModule("facebook", .{
        .root_source_file = b.path("libs/facebook/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
        },
    });

    const x = b.addModule("x", .{
        .root_source_file = b.path("libs/x/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
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

    const memory = b.addModule("memory", .{
        .root_source_file = b.path("libs/memory/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_opts", .module = build_options.createModule() },
        },
    });

    const minimax_music = b.addModule("minimax-music", .{
        .root_source_file = b.path("libs/minimax-music/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
        },
    });

    const minimax_video = b.addModule("minimax-video", .{
        .root_source_file = b.path("libs/minimax-video/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
        },
    });

    const minimax_speech = b.addModule("minimax-speech", .{
        .root_source_file = b.path("libs/minimax-speech/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
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
        .name = "s-console-sync",
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
                .{ .name = "x", .module = x },
            },
        }),
    });
    b.installArtifact(console_sync);

    // Console App (async with xev)
    const console_xev = b.addExecutable(.{
        .name = "s-console",
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
        .name = "s-telegram",
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

    // Search CLI App
    const search_cli = b.addExecutable(.{
        .name = "s-search",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/search/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = http },
                .{ .name = "tls", .module = tls_mod },
            },
        }),
    });
    b.installArtifact(search_cli);

    // Music CLI App
    const music_cli = b.addExecutable(.{
        .name = "s-music",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/music/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimax-music", .module = minimax_music },
                .{ .name = "http", .module = http },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(music_cli);

    // Video CLI App
    const video_cli = b.addExecutable(.{
        .name = "s-video",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/minimax-video/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimax-video", .module = minimax_video },
                .{ .name = "http", .module = http },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(video_cli);

    // Speech CLI App
    const speech_cli = b.addExecutable(.{
        .name = "s-speech",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/speech/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimax-speech", .module = minimax_speech },
                .{ .name = "http", .module = http },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(speech_cli);

    // Facebook CLI App
    const facebook_cli = b.addExecutable(.{
        .name = "s-facebook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/facebook/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "facebook", .module = facebook },
                .{ .name = "http", .module = http },
            },
        }),
    });
    b.installArtifact(facebook_cli);

    // Graph Memory CLI App
    const graph_memory_cli = b.addExecutable(.{
        .name = "s-graph-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/graph-memory/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memory", .module = memory },
            },
        }),
    });
    b.installArtifact(graph_memory_cli);

    // Web CLI App
    const web_cli = b.addExecutable(.{
        .name = "s-web-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/web-cli/src/Main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "core", .module = core },
            },
        }),
    });
    b.installArtifact(web_cli);

    // Cron CLI App
    const cron_cli = b.addExecutable(.{
        .name = "s-cron",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cron/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
            },
        }),
    });
    cron_cli.root_module.link_libc = true;
    b.installArtifact(cron_cli);

    // Agent CLI App (Claude-Code style)
    const agent_cli = b.addExecutable(.{
        .name = "saticode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/code/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "core", .module = core },
                .{ .name = "db", .module = db },
            },
        }),
    });
    b.installArtifact(agent_cli);

    const run_agent_cli_cmd = b.addRunArtifact(agent_cli);
    if (b.args) |args| {
        run_agent_cli_cmd.addArgs(args);
    }
    const run_agent_cli = b.step("saticode", "Run SatiCode CLI app");
    run_agent_cli.dependOn(&run_agent_cli_cmd.step);

    // Sati CLI executable
    const sati_exe = b.addExecutable(.{
        .name = "sati",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "core", .module = core },
                .{ .name = "db", .module = db },
                .{ .name = "build_opts", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(sati_exe);

    // Web App (HTTP API)
    if (include_web) {
        const web_app = b.addExecutable(.{
            .name = "web",
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/web/src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "agent", .module = agent },
                    .{ .name = "web", .module = web_mod.? },
                    .{ .name = "core", .module = core },
                    .{ .name = "memory", .module = memory },
                    .{ .name = "build_opts", .module = build_options.createModule() },
                },
            }),
        });
        b.installArtifact(web_app);

        const run_web_cmd = b.addRunArtifact(web_app);
        if (b.args) |args| {
            run_web_cmd.addArgs(args);
        }
        const run_web = b.step("run-web", "Run web API server");
        run_web.dependOn(&run_web_cmd.step);

        // Link SQLite to web app if enabled
        if (enable_sqlite) {
            web_app.root_module.link_libc = true;
            web_app.root_module.linkSystemLibrary("sqlite3", .{});
        }
    } else {
        // Link SQLite to executables that need it (non-web)
    // Link libc to all CLI tools as they use getenv (via std.c in Zig 0.16 migration)
    console_sync.root_module.link_libc = true;
    console_xev.root_module.link_libc = true;
    telegram.root_module.link_libc = true;
    agent_cli.root_module.link_libc = true;
    sati_exe.root_module.link_libc = true;

    if (enable_sqlite) {
        console_sync.root_module.linkSystemLibrary("sqlite3", .{});
        console_xev.root_module.linkSystemLibrary("sqlite3", .{});
        telegram.root_module.linkSystemLibrary("sqlite3", .{});
        agent_cli.root_module.linkSystemLibrary("sqlite3", .{});
        sati_exe.root_module.linkSystemLibrary("sqlite3", .{});
    }
}


    // Run steps
    const run_console_sync_cmd = b.addRunArtifact(console_sync);
    if (b.args) |args| {
        run_console_sync_cmd.addArgs(args);
    }
    const run_console_sync = b.step("console-sync", "Run console-sync app");
    run_console_sync.dependOn(&run_console_sync_cmd.step);

    const run_console_cmd = b.addRunArtifact(console_xev);
    if (b.args) |args| {
        run_console_cmd.addArgs(args);
    }
    const run_console = b.step("console", "Run console app (xev)");
    run_console.dependOn(&run_console_cmd.step);

    const run_telegram_cmd = b.addRunArtifact(telegram);
    if (b.args) |args| {
        run_telegram_cmd.addArgs(args);
    }
    const run_telegram = b.step("run-telegram", "Run telegram bot");
    run_telegram.dependOn(&run_telegram_cmd.step);

    const run_search_cmd = b.addRunArtifact(search_cli);
    if (b.args) |args| {
        run_search_cmd.addArgs(args);
    }
    const run_search = b.step("run-search", "Run search CLI app");
    run_search.dependOn(&run_search_cmd.step);

    const run_music_cmd = b.addRunArtifact(music_cli);
    if (b.args) |args| {
        run_music_cmd.addArgs(args);
    }
    const run_music = b.step("run-music", "Run music CLI app");
    run_music.dependOn(&run_music_cmd.step);

    const run_video_cmd = b.addRunArtifact(video_cli);
    if (b.args) |args| {
        run_video_cmd.addArgs(args);
    }
    const run_video = b.step("run-video", "Run video CLI app");
    run_video.dependOn(&run_video_cmd.step);

    const run_speech_cmd = b.addRunArtifact(speech_cli);
    if (b.args) |args| {
        run_speech_cmd.addArgs(args);
    }
    const run_speech = b.step("run-speech", "Run speech CLI app");
    run_speech.dependOn(&run_speech_cmd.step);

    const run_facebook_cmd = b.addRunArtifact(facebook_cli);
    if (b.args) |args| {
        run_facebook_cmd.addArgs(args);
    }
    const run_facebook = b.step("run-facebook", "Run facebook CLI app");
    run_facebook.dependOn(&run_facebook_cmd.step);

    const run_graph_memory_cmd = b.addRunArtifact(graph_memory_cli);
    if (b.args) |args| {
        run_graph_memory_cmd.addArgs(args);
    }
    const run_graph_memory = b.step("run-graph-memory", "Run graph memory CLI app");
    run_graph_memory.dependOn(&run_graph_memory_cmd.step);

    const run_web_cli_cmd = b.addRunArtifact(web_cli);
    if (b.args) |args| {
        run_web_cli_cmd.addArgs(args);
    }
    const run_web_cli = b.step("run-web-cli", "Run web CLI app");
    run_web_cli.dependOn(&run_web_cli_cmd.step);

    const run_cron_cmd = b.addRunArtifact(cron_cli);
    if (b.args) |args| {
        run_cron_cmd.addArgs(args);
    }
    const run_cron = b.step("cron", "Run cron CLI app");
    run_cron.dependOn(&run_cron_cmd.step);

    // Build steps for individual binaries
    const build_console_sync = b.step("s-console-sync", "Build s-console-sync binary");
    build_console_sync.dependOn(&console_sync.step);

    const build_console = b.step("s-console", "Build s-console binary");
    build_console.dependOn(&console_xev.step);

    const build_telegram_binary = b.step("s-telegram", "Build s-telegram binary");
    build_telegram_binary.dependOn(&telegram.step);

    const build_search_binary = b.step("s-search", "Build s-search binary");
    build_search_binary.dependOn(&search_cli.step);

    const build_music_binary = b.step("s-music", "Build s-music binary");
    build_music_binary.dependOn(&music_cli.step);

    const build_video_binary = b.step("s-video", "Build s-video binary");
    build_video_binary.dependOn(&video_cli.step);

    const build_speech_binary = b.step("s-speech", "Build s-speech binary");
    build_speech_binary.dependOn(&speech_cli.step);

    const build_facebook_binary = b.step("s-facebook", "Build s-facebook binary");
    build_facebook_binary.dependOn(&facebook_cli.step);

    const build_graph_memory_binary = b.step("s-graph-memory", "Build s-graph-memory binary");
    build_graph_memory_binary.dependOn(&graph_memory_cli.step);

    const build_web_cli_binary = b.step("s-web-cli", "Build s-web-cli binary");
    build_web_cli_binary.dependOn(&web_cli.step);

    const build_cron_binary = b.step("s-cron", "Build s-cron binary");
    const cron_install = b.addInstallArtifact(cron_cli, .{});
    build_cron_binary.dependOn(&cron_install.step);

    const build_sati = b.step("sati", "Build sati CLI binary");
    build_sati.dependOn(&sati_exe.step);

    // Test step for all libraries
    const test_step = b.step("test", "Run library tests");

    const lib_tests = [_]struct { name: []const u8, path: []const u8, imports: []const std.Build.Module.Import }{
        .{ .name = "core", .path = "libs/core/src/root.zig", .imports = &.{} },
        .{ .name = "http", .path = "libs/http/src/root.zig", .imports = &.{.{ .name = "tls", .module = tls_mod }} },
        .{ .name = "utils", .path = "libs/utils/src/root.zig", .imports = &.{ .{ .name = "xev", .module = xev_mod }, .{ .name = "core", .module = core } } },
        .{ .name = "providers", .path = "libs/providers/src/root.zig", .imports = &.{ .{ .name = "http", .module = http }, .{ .name = "core", .module = core }, .{ .name = "utils", .module = utils } } },
        .{ .name = "facebook", .path = "libs/facebook/src/root.zig", .imports = &.{.{ .name = "http", .module = http }} },
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
        .{ .name = "memory", .path = "libs/memory/src/root.zig", .imports = &.{
            .{ .name = "build_opts", .module = build_options.createModule() },
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

    // Web module tests (conditional)
    if (include_web) {
        const web_test = b.addTest(.{
            .root_module = web_mod.?,
        });
        const web_test_run = b.addRunArtifact(web_test);
        test_step.dependOn(&web_test_run.step);

        // App web tests
        const app_web_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/web/src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "agent", .module = agent },
                    .{ .name = "web", .module = web_mod.? },
                    .{ .name = "core", .module = core },
                    .{ .name = "build_opts", .module = build_options.createModule() },
                },
            }),
        });
        const app_web_test_run = b.addRunArtifact(app_web_test);
        test_step.dependOn(&app_web_test_run.step);
    }

    // Music app tests
    const music_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/music/src/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimax-music", .module = minimax_music },
                .{ .name = "http", .module = http },
            },
        }),
    });
    const music_test_run = b.addRunArtifact(music_test);
    test_step.dependOn(&music_test_run.step);
}
