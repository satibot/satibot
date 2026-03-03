//! Music CLI Application
//!
//! A command-line tool for generating music and lyrics using the MiniMax API.
//!
//! ## Features
//! - Music generation with customizable style, mood, and vocals
//! - Lyrics generation from themes
//! - Configurable audio output settings
//! - Configuration file support for API key management
//!
//! ## Usage
//!
//! Generate lyrics:
//! ```bash
//! s-music lyrics "A soulful blues song about a rainy night" [api_key]
//! ```
//!
//! Generate music with prompt only:
//! ```bash
//! s-music music "Soulful Blues, Rainy Night, Melancholy" [api_key]
//! ```
//!
//! Generate music with custom lyrics:
//! ```bash
//! s-music music "Soulful Blues, Rainy Night" --lyrics "[Verse 1]\nTest lyrics" [api_key]
//! ```
//!
//! Usage with configuration file (config.json):
//! ```bash
//! s-music lyrics "A soulful blues song about a rainy night"
//! ```
//! Config should contain: { "providers": { "minimax": { "apiKey": "your-api-key" } } }

const std = @import("std");
const music = @import("minimax-music").music;

pub fn main() !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage(args[0]);
        return;
    }

    const subcommand = args[1];

    if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUsage(args[0]);
        return;
    }

    var lyrics_arg: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--lyrics") or std.mem.eql(u8, args[i], "-l")) {
            if (i + 1 < args.len) {
                lyrics_arg = args[i + 1];
                i += 1;
            }
        } else if (prompt == null) {
            prompt = args[i];
        } else if (api_key == null) {
            api_key = args[i];
        }
    }

    if (prompt == null) {
        std.debug.print("Error: Prompt is required\n\n", .{});
        printUsage(args[0]);
        return;
    }

    const key = api_key orelse try getApiKeyFromConfig(allocator);

    if (key == null) {
        std.debug.print("Error: No API key provided and no config.json found with providers.minimax.apiKey\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "lyrics")) {
        try generateLyrics(allocator, prompt.?, key.?);
    } else if (std.mem.eql(u8, subcommand, "music")) {
        try generateMusic(allocator, prompt.?, lyrics_arg, key.?);
    } else {
        std.debug.print("Error: Unknown subcommand '{s}'. Use 'lyrics' or 'music'\n\n", .{subcommand});
        printUsage(args[0]);
    }
}

fn printUsage(prog_name: []const u8) void {
    std.debug.print("Usage: {s} <subcommand> [options] [prompt] [api_key]\n", .{prog_name});
    std.debug.print("\nSubcommands:\n", .{});
    std.debug.print("  lyrics <prompt> [api_key]   Generate lyrics from a prompt\n", .{});
    std.debug.print("  music <prompt> [api_key]   Generate music from a prompt\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -l, --lyrics <text>       Custom lyrics for music generation\n", .{});
    std.debug.print("  -h, --help                Show this help message\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("  {s} lyrics \"A soulful blues song about a rainy night\"\n", .{prog_name});
    std.debug.print("  {s} music \"Soulful Blues, Rainy Night, Melancholy\"\n", .{prog_name});
    std.debug.print("  {s} music \"Jazz, Smooth, Evening\" --lyrics \"[Verse 1]\\nTest\"\n", .{prog_name});
    std.debug.print("\nConfiguration:\n", .{});
    std.debug.print("  If no API key is provided, reads from config.json:\n", .{});
    std.debug.print("  {{ \"providers\": {{ \"minimax\": {{ \"apiKey\": \"your-key\" }} }} }}\n", .{});
}

fn getApiKeyFromConfig(allocator: std.mem.Allocator) !?[]const u8 {
    const config_path = "config.json";
    const config_file = std.fs.cwd().openFile(config_path, .{}) catch null;
    if (config_file) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(
            Config,
            allocator,
            content,
            .{},
        ) catch null;

        if (parsed) |p| {
            defer p.deinit();
            if (p.value.providers.minimax.apiKey) |key| {
                return allocator.dupe(u8, key) catch null;
            }
        }
    }
    return null;
}

const Config = struct {
    providers: Providers = .{},
    const Providers = struct {
        minimax: MiniMax = .{},
        const MiniMax = struct {
            apiKey: ?[]const u8 = null,
        };
    };
};

fn generateLyrics(allocator: std.mem.Allocator, prompt: []const u8, api_key: []const u8) !void {
    var client = try music.MusicClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating lyrics for: {s}\n\n", .{prompt});

    const request: music.LyricsGenerationRequest = .{
        .mode = "write_full_song",
        .prompt = prompt,
    };

    var response = try client.generateLyrics(request);
    defer response.deinit();

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.data) |data| {
        if (data.lyrics) |lyrics| {
            std.debug.print("Generated Lyrics:\n", .{});
            std.debug.print("=================\n\n", .{});
            std.debug.print("{s}\n", .{lyrics});
        }
    }
}

fn generateMusic(allocator: std.mem.Allocator, prompt: []const u8, lyrics: ?[]const u8, api_key: []const u8) !void {
    var client = try music.MusicClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating music for: {s}\n", .{prompt});
    if (lyrics) |l| {
        std.debug.print("With custom lyrics: {s}\n", .{l});
    }
    std.debug.print("\n", .{});

    const request: music.MusicGenerationRequest = .{
        .model = "music-2.5",
        .prompt = prompt,
        .lyrics = lyrics orelse "",
    };

    var response = try client.generateMusic(request);
    defer response.deinit();

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.data) |data| {
        if (data.audio) |audio| {
            std.debug.print("Generated Music URL:\n", .{});
            std.debug.print("====================\n\n", .{});
            std.debug.print("{s}\n", .{audio});

            std.debug.print("\nNote: Use the URL to download the audio file.\n", .{});
        }
    }
}
