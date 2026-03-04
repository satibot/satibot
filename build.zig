const std = @import("std");

const VendoredFileHash = struct {
    path: []const u8,
    sha256_hex: []const u8,
};

const VENDORED_SQLITE_HASHES = [_]VendoredFileHash{
    .{
        .path = "libs/sqlite3/sqlite3.c",
        .sha256_hex = "dc58f0b5b74e8416cc29b49163a00d6b8bf08a24dd4127652beaaae307bd1839",
    },
    .{
        .path = "libs/sqlite3/sqlite3.h",
        .sha256_hex = "05c48cbf0a0d7bda2b6d0145ac4f2d3a5e9e1cb98b5d4fa9d88ef620e1940046",
    },
    .{
        .path = "libs/sqlite3/sqlite3ext.h",
        .sha256_hex = "ea81fb7bd05882e0e0b92c4d60f677b205f7f1fbf085f218b12f0b5b3f0b9e48",
    },
};

fn hashWithCanonicalLineEndings(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            if (i > chunk_start) hasher.update(bytes[chunk_start..i]);
            hasher.update("\n");
            i += 1;
            chunk_start = i + 1;
        }
    }
    if (chunk_start < bytes.len) hasher.update(bytes[chunk_start..]);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn verifyVendoredSqliteHashes(b: *std.Build) !void {
    const max_vendor_file_size = 16 * 1024 * 1024;
    for (VENDORED_SQLITE_HASHES) |entry| {
        const file_path = b.pathFromRoot(entry.path);
        defer b.allocator.free(file_path);

        const bytes = std.fs.cwd().readFileAlloc(b.allocator, file_path, max_vendor_file_size) catch |err| {
            std.log.err("failed to read {s}: {s}", .{ file_path, @errorName(err) });
            return err;
        };
        defer b.allocator.free(bytes);

        const digest = hashWithCanonicalLineEndings(bytes);

        const actual_hex_buf = std.fmt.bytesToHex(digest, .lower);
        const actual_hex = actual_hex_buf[0..];

        if (!std.mem.eql(u8, actual_hex, entry.sha256_hex)) {
            std.log.err("vendored sqlite checksum mismatch for {s}", .{entry.path});
            std.log.err("expected: {s}", .{entry.sha256_hex});
            std.log.err("actual:   {s}", .{actual_hex});
            return error.VendoredSqliteChecksumMismatch;
        }
    }
}

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
    const include_web = b.option(bool, "web", "Build with web module (zap)") orelse false;
    const enable_sqlite = b.option(bool, "sqlite", "Enable SQLite support") orelse true;
    const enable_memory_sqlite = b.option(bool, "memory-sqlite", "Enable SQLite memory backend") orelse true;

    // Verify vendored sqlite hashes
    if (enable_sqlite) {
        verifyVendoredSqliteHashes(b) catch |err| {
            std.log.warn("Failed to verify SQLite hashes: {}", .{err});
        };
    }

    const sqlite3 = if (enable_sqlite) blk: {
        const sqlite3_dep = b.dependency("sqlite3", .{
            .target = target,
            .optimize = optimize,
        });
        const sqlite3_artifact = sqlite3_dep.artifact("sqlite3");
        sqlite3_artifact.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
        break :blk sqlite3_artifact;
    } else null;

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
            },
        }),
    });
    b.installArtifact(music_cli);

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
        if (sqlite3) |lib| {
            web_app.root_module.linkLibrary(lib);
        }
    } else {
        // Link SQLite to executables that need it (non-web)
        if (sqlite3) |lib| {
            console_sync.root_module.linkLibrary(lib);
            console_xev.root_module.linkLibrary(lib);
            telegram.root_module.linkLibrary(lib);
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

    const build_facebook_binary = b.step("s-facebook", "Build s-facebook binary");
    build_facebook_binary.dependOn(&facebook_cli.step);

    const build_graph_memory_binary = b.step("s-graph-memory", "Build s-graph-memory binary");
    build_graph_memory_binary.dependOn(&graph_memory_cli.step);

    const build_web_cli_binary = b.step("s-web-cli", "Build s-web-cli binary");
    build_web_cli_binary.dependOn(&web_cli.step);

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
}
