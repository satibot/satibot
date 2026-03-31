//! Music CLI Application
//!
//! A command-line tool for generating music and lyrics using the MiniMax API.
//!
//! ## Features
//! - Music generation with customizable style, mood, and vocals
//! - Lyrics generation from themes
//! - Configurable audio output settings
//! - Automatic MP3 download from generated URLs
//! - Attempts to play MP3 with system default player
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
//!
//! ## Output
//! - Lyrics are printed directly to the console
//! - Music files are downloaded as `generated_music_<timestamp>.mp3`
//! - The CLI attempts to open the MP3 with your system's default player

const std = @import("std");
const music = @import("minimax-music").music;
const build_options = @import("build_options");

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

    if (std.mem.eql(u8, subcommand, "--version") or std.mem.eql(u8, subcommand, "-v")) {
        std.debug.print("{s}\n", .{build_options.version});
        return;
    }

    var lyrics_arg: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var lyrics_optimizer: bool = false;
    var instrumental: bool = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--lyrics") or std.mem.eql(u8, args[i], "-l")) {
            if (i + 1 < args.len) {
                lyrics_arg = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--lyrics-optimizer")) {
            lyrics_optimizer = true;
        } else if (std.mem.eql(u8, args[i], "--instrumental")) {
            instrumental = true;
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
        try generateMusic(allocator, prompt.?, lyrics_arg, key.?, lyrics_optimizer, instrumental);
    } else {
        std.debug.print("Error: Unknown subcommand '{s}'. Use 'lyrics' or 'music'\n\n", .{subcommand});
        printUsage(args[0]);
    }
}

fn printUsage(prog_name: []const u8) void {
    const usage_text =
        \\Usage: {s} <subcommand> [options] [prompt] [api_key]
        \\
        \\Subcommands:
        \\  lyrics <prompt> [api_key]   Generate lyrics from a prompt
        \\  music <prompt> [api_key]   Generate music from a prompt
        \\
        \\Options:
        \\  -l, --lyrics <text>         Custom lyrics for music generation
        \\  --lyrics-optimizer          Auto-generate lyrics from prompt
        \\  --instrumental              Generate instrumental music (no vocals)
        \\  -h, --help                  Show this help message
        \\  -v, --version               Show version information
        \\
        \\Examples:
        \\  {s} lyrics "A soulful blues song about a rainy night"
        \\  {s} music "Soulful Blues, Rainy Night, Melancholy"
        \\  {s} music "Jazz, Smooth, Evening" --lyrics "[Verse 1]\\nTest"
        \\  {s} music "Rock, Energetic" --lyrics-optimizer
        \\  {s} music "Piano, Melancholy" --instrumental
        \\
        \\Features:
        \\  - Automatically downloads generated MP3 files
        \\  - Attempts to play the MP3 with default player
        \\  - Saves files as 'generated_music_<timestamp>.mp3'
        \\
        \\Configuration:
        \\  If no API key is provided, reads from config.json:
        \\  {{ "providers": {{ "minimax": {{ "apiKey": "your-key" }} }} }}
    ;
    std.debug.print(usage_text, .{ prog_name, prog_name, prog_name, prog_name, prog_name, prog_name });
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
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();

        if (parsed.value.providers) |providers| {
            if (providers.minimax) |minimax| {
                if (minimax.apiKey) |key| {
                    return allocator.dupe(u8, key) catch null;
                }
            }
        }
    }
    return null;
}

const Config = struct {
    providers: ?Providers = null,
    const Providers = struct {
        minimax: ?MiniMax = null,
        const MiniMax = struct {
            apiKey: ?[]const u8 = null,
        };
    };
};

fn generateLyrics(allocator: std.mem.Allocator, prompt: []const u8, api_key: []const u8) !void {
    var client = try music.MusicClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating lyrics for: {s}\n", .{prompt});

    const request: music.LyricsGenerationRequest = .{
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
            const lyrics_output =
                \\
                \\Generated Lyrics:
                \\==================
                \\
                \\{s}
                \\
            ;
            std.debug.print(lyrics_output, .{lyrics});
        } else {
            std.debug.print("No lyrics generated\n", .{});
        }
    } else {
        std.debug.print("No data in response\n", .{});
    }
}

fn generateMusic(allocator: std.mem.Allocator, prompt: []const u8, lyrics: ?[]const u8, api_key: []const u8, lyrics_optimizer: bool, instrumental: bool) !void {
    var client = try music.MusicClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating music for: {s}\n", .{prompt});
    if (lyrics) |l| {
        std.debug.print("With custom lyrics: {s}\n", .{l});
    }
    if (lyrics_optimizer) {
        std.debug.print("With lyrics optimizer: enabled\n", .{});
    }
    if (instrumental) {
        std.debug.print("Generating instrumental music\n", .{});
    } else if (lyrics == null and !lyrics_optimizer) {
        std.debug.print("No lyrics provided - generating instrumental music by default\n", .{});
    }
    std.debug.print("\n", .{});

    // Default to instrumental when no lyrics are provided
    const is_instrumental = instrumental or (lyrics == null and !lyrics_optimizer);

    const request: music.MusicGenerationRequest = .{
        .prompt = prompt,
        .lyrics = lyrics orelse "",
        .lyrics_optimizer = lyrics_optimizer,
        .is_instrumental = is_instrumental,
        .output_format = "url",
    };

    var response = try client.generateMusic(request);
    defer response.deinit();

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.data) |data| {
        if (data.audio) |audio| {
            // Check if the audio is a URL or hex data
            if (data.audio_type) |audio_type| {
                if (std.mem.eql(u8, audio_type, "url")) {
                    const url_output =
                        \\
                        \\Generated Music URL:
                        \\====================
                        \\
                        \\{s}
                        \\
                    ;
                    std.debug.print(url_output, .{audio});

                    const filename = try downloadMp3(allocator, audio);
                    defer allocator.free(filename);

                    const download_msg =
                        \\Downloaded to: {s}
                        \\
                    ;
                    std.debug.print(download_msg, .{filename});

                    // Try to open the file with the default player
                    try playMp3(filename);
                } else if (std.mem.eql(u8, audio_type, "hex")) {
                    // If we receive hex data, we need to save it directly
                    const filename = try saveHexAsMp3(allocator, audio);
                    defer allocator.free(filename);

                    const hex_msg =
                        \\Received audio data in hex format.
                        \\Saved to: {s}
                        \\
                    ;
                    std.debug.print(hex_msg, .{filename});

                    // Try to open the file with the default player
                    try playMp3(filename);
                } else {
                    std.debug.print("Unknown audio type: {s}\n", .{audio_type});
                    std.debug.print("Audio data: {s}\n", .{audio});
                }
            } else {
                // No audio type specified, assume it's a URL
                const url_output =
                    \\
                    \\Generated Music:
                    \\================
                    \\
                    \\{s}
                    \\
                ;
                std.debug.print(url_output, .{audio});
            }
        }
    }
}

fn saveHexAsMp3(allocator: std.mem.Allocator, hex_data: []const u8) ![]const u8 {
    // Generate filename with timestamp
    const timestamp = std.time.timestamp();
    const filename = try std.fmt.allocPrint(allocator, "generated_music_{d}.mp3", .{timestamp});

    std.debug.print("Saving MP3 from hex data ({d} chars)...\n", .{hex_data.len});

    // Calculate the required buffer size (hex string is 2x the binary size)
    const binary_size = hex_data.len / 2;
    const binary_data = try allocator.alloc(u8, binary_size);
    defer allocator.free(binary_data);

    // Convert hex string to binary data
    for (0..binary_size) |i| {
        const high_byte = std.fmt.charToDigit(hex_data[i * 2], 16) catch continue;
        const low_byte = std.fmt.charToDigit(hex_data[i * 2 + 1], 16) catch continue;
        binary_data[i] = @as(u8, @intCast(high_byte * 16 + low_byte));
    }

    // Write binary data to file
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    try file.writeAll(binary_data);

    std.debug.print("Successfully saved MP3 to: {s}\n", .{filename});
    return filename;
}

fn downloadMp3(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Generate filename with timestamp
    const timestamp = std.time.timestamp();
    const filename = try std.fmt.allocPrint(allocator, "generated_music_{d}.mp3", .{timestamp});

    std.debug.print("Downloading MP3 from: {s}\n", .{url});

    // Try using curl first
    const curl_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "curl", "-L", "-o", filename, url },
    });

    if (curl_result) |result| {
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term.Exited == 0) {
            // Check if file was created and has content
            if (std.fs.cwd().openFile(filename, .{})) |file| {
                defer file.close();
                const stat = try file.stat();
                if (stat.size > 0) {
                    std.debug.print("Successfully downloaded to: {s}\n", .{filename});
                    return filename;
                }
            } else |_| {}
            std.debug.print("Curl completed but file may be empty\n", .{});
        }
    } else |err| {
        const error_msg =
            \\Download failed: {}
            \\This may be due to URL authentication requirements.
            \\Please download manually: {s}
            \\
            \\To download manually:
            \\1. Copy the URL above
            \\2. Open it in your browser
            \\3. Save the file as: {s}
        ;
        std.debug.print(error_msg, .{ err, url, filename });
        return filename;
    }

    // If curl fails, try opening in browser
    const fallback_msg =
        \\Unable to download automatically.
        \\Opening URL in browser for manual download...
        \\
        \\Manual download instructions:
        \\1. The URL should open in your browser
        \\2. Right-click and save the audio as: {s}
        \\3. Once downloaded, you can play it with: open {s}
    ;
    std.debug.print(fallback_msg, .{ filename, filename });

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "open", url },
    }) catch |err| {
        const browser_error_msg =
            \\Failed to open browser: {}
            \\You can manually download the file by:
            \\1. Copying the URL: {s}
            \\2. Opening it in your browser
            \\3. Saving the file as: {s}
            \\4. Playing it with: open {s}
        ;
        std.debug.print(browser_error_msg, .{ err, url, filename, filename });
    };

    return filename;
}

fn playMp3(filename: []const u8) !void {
    // Try different players based on the platform
    const players = [_][]const u8{
        "open", // macOS
        "xdg-open", // Linux
        "start", // Windows
    };

    for (players) |player| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ player, filename },
        }) catch continue;

        if (result.term.Exited == 0) {
            std.debug.print("Playing MP3 with {s}...\n", .{player});
            return;
        }
    }
    const play_error_msg =
        \\Could not auto-play the MP3 file.
        \\You can play it manually with: {s}
    ;
    std.debug.print(play_error_msg, .{filename});
}
