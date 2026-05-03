//! Speech CLI Application
//!
//! A command-line tool for async text-to-speech synthesis using the MiniMax API.
//!
//! ## Features
//! - Long-form text-to-speech (up to 1M characters)
//! - Multiple voice models support
//! - Customizable voice settings
//! - Automatic task polling and audio download
//! - Configuration file support for API key management
//!
//! ## Usage
//!
//! Synthesize text:
//! ```bash
//! s-speech "Hello, world!" [api_key]
//! ```
//!
//! With custom voice:
//! ```bash
//! s-speech "Hello" --voice Chinese_neural --speed 1.2 [api_key]
//! ```
//!
//! From text file:
//! ```bash
//! s-speech --file input.txt [api_key]
//! ```

const std = @import("std");
const build_options = @import("build_options");

const speech = @import("minimax-speech").speech;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);

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

    var text: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var text_file: ?[]const u8 = null;
    var model: []const u8 = "speech-2.8-hd";
    var voice_id: []const u8 = "English_expressive_narrator";
    var speed: f32 = 1.0;
    var vol: f32 = 1.0;
    var pitch: f32 = 0;
    var audio_format: []const u8 = "mp3";
    var sample_rate: u32 = 32000;
    var bitrate: u32 = 128000;
    var channel: u32 = 1;
    var output_file: ?[]const u8 = null;
    var poll_interval: u32 = 10;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--text") or std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 < args.len) {
                text = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                text_file = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--model") or std.mem.eql(u8, args[i], "-m")) {
            if (i + 1 < args.len) {
                model = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--voice") or std.mem.eql(u8, args[i], "-v")) {
            if (i + 1 < args.len) {
                voice_id = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--speed") or std.mem.eql(u8, args[i], "-s")) {
            if (i + 1 < args.len) {
                speed = try std.fmt.parseFloat(f32, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--vol")) {
            if (i + 1 < args.len) {
                vol = try std.fmt.parseFloat(f32, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--pitch")) {
            if (i + 1 < args.len) {
                pitch = try std.fmt.parseFloat(f32, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--format")) {
            if (i + 1 < args.len) {
                audio_format = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--sample-rate")) {
            if (i + 1 < args.len) {
                sample_rate = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--bitrate")) {
            if (i + 1 < args.len) {
                bitrate = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--channel")) {
            if (i + 1 < args.len) {
                channel = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 < args.len) {
                output_file = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--poll-interval") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                poll_interval = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (text == null) {
            text = args[i];
        } else if (api_key == null) {
            api_key = args[i];
        }
    }

    if (text == null and text_file == null) {
        std.debug.print("Error: Text or --file is required\n\n", .{});
        printUsage(args[0]);
        return;
    }

    const key = api_key orelse try getApiKeyFromConfig(allocator);

    if (key == null) {
        std.debug.print("Error: No API key provided and no config.json found with providers.minimax.apiKey\n", .{});
        return;
    }

    if (text_file) |file_path| {
        const content = readFileAlloc(allocator, file_path) catch |err| {
            std.debug.print("Error: Could not open file '{s}': {}\n", .{ file_path, err });
            return;
        };
        if (content) |c| {
            text = c;
        } else {
            std.debug.print("Error: Could not open file '{s}'\n", .{file_path});
            return;
        }
    }

    try synthesizeSpeech(allocator, text.?, model, voice_id, speed, vol, pitch, audio_format, sample_rate, bitrate, channel, output_file, poll_interval, key.?);
}

fn printUsage(prog_name: []const u8) void {
    const usage_text =
        \\Usage: {s} [options] [text] [api_key]
        \\
        \\Arguments:
        \\  text                    Text to synthesize (or use --text / --file)
        \\  api_key                 MiniMax API key (optional if in config.json)
        \\
        \\Options:
        \\  -t, --text <text>       Text to synthesize
        \\  -f, --file <path>       Text file to synthesize
        \\  -m, --model <model>     Voice model (default: speech-2.8-hd)
        \\  -v, --voice <voice>     Voice ID (default: English_expressive_narrator)
        \\  -s, --speed <rate>      Speech speed (default: 1.0)
        \\  --vol <volume>          Volume (default: 1.0)
        \\  --pitch <pitch>         Pitch adjustment (default: 0)
        \\  --format <format>       Audio format: mp3, wav, pcm (default: mp3)
        \\  --sample-rate <rate>    Sample rate (default: 32000)
        \\  --bitrate <rate>        Bitrate (default: 128000)
        \\  --channel <ch>          Audio channels 1 or 2 (default: 1)
        \\  -o, --output <file>     Output file path
        \\  -p, --poll-interval <s> Polling interval in seconds (default: 10)
        \\  -h, --help              Show this help message
        \\  -V, --version            Show version information
        \\
        \\Voice Models:
        \\  speech-2.8-hd    Perfecting tonal nuances
        \\  speech-2.6-hd    Ultra-low latency
        \\  speech-2.8-turbo Faster, more affordable
        \\  speech-2.6-turbo Faster, ideal for agents
        \\  speech-02-hd     Superior rhythm and stability
        \\  speech-02-turbo  Superior rhythm, multilingual
        \\
        \\Examples:
        \\  {s} "Hello, world!"
        \\  {s} "Hello" --voice Chinese_neural --speed 1.2
        \\  {s} --file input.txt --output speech.mp3
        \\
        \\Configuration:
        \\  If no API key is provided, reads from config.json:
        \\  {{ "providers": {{ "minimax": {{ "apiKey": "your-key" }} }} }}
    ;
    std.debug.print(usage_text, .{ prog_name, prog_name, prog_name, prog_name });
}

fn getApiKeyFromConfig(allocator: std.mem.Allocator) !?[]const u8 {
    const config_path = "config.json";
    const content = readFileAlloc(allocator, config_path) catch return null;
    if (content) |buf| {
        defer allocator.free(buf);
        const parsed = std.json.parseFromSlice(
            Config,
            allocator,
            buf,
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

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(file);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(allocator, temp[0..n]);
    }
    const result = try buf.toOwnedSlice(allocator);
    return result;
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

fn synthesizeSpeech(
    allocator: std.mem.Allocator,
    text: []const u8,
    model: []const u8,
    voice_id: []const u8,
    speed: f32,
    vol: f32,
    pitch: f32,
    audio_format: []const u8,
    sample_rate: u32,
    bitrate: u32,
    channel: u32,
    output_file: ?[]const u8,
    poll_interval: u32,
    api_key: []const u8,
) !void {
    var client = try speech.SpeechClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Synthesizing text ({d} chars)...\n", .{text.len});
    std.debug.print("Model: {s}, Voice: {s}, Speed: {d}\n\n", .{ model, voice_id, speed });

    const request: speech.AsyncSpeechRequest = .{
        .model = model,
        .text = text,
        .voice_setting = .{
            .voice_id = voice_id,
            .speed = speed,
            .vol = vol,
            .pitch = pitch,
        },
        .audio_setting = .{
            .audio_sample_rate = sample_rate,
            .bitrate = bitrate,
            .format = audio_format,
            .channel = channel,
        },
    };

    const response = try client.createSpeechTask(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollAndDownload(allocator, &client, task_id, output_file, poll_interval, audio_format);
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn pollAndDownload(
    allocator: std.mem.Allocator,
    client: *speech.SpeechClient,
    task_id: []const u8,
    output_file: ?[]const u8,
    poll_interval: u32,
    audio_format: []const u8,
) !void {
    std.debug.print("\nPolling for completion...\n", .{});

    while (true) {
        std.debug.print("Checking status...\n", .{});

        const status_response = try client.queryTaskStatus(task_id);

        if (std.mem.eql(u8, status_response.status, "Success")) {
            std.debug.print("\nSpeech synthesis completed!\n", .{});

            if (status_response.audio_duration) |dur| {
                std.debug.print("Audio duration: {d}s\n", .{dur});
            }
            if (status_response.audio_size) |size| {
                std.debug.print("Audio size: {d} bytes\n", .{size});
            }

            if (status_response.file_id) |file_id| {
                std.debug.print("File ID: {s}\n", .{file_id});
                try downloadAudio(allocator, client, file_id, output_file, audio_format);
            } else {
                std.debug.print("Error: No file_id in success response\n", .{});
            }
            return;
        } else if (std.mem.eql(u8, status_response.status, "Fail")) {
            std.debug.print("\nSpeech synthesis failed: {s}\n", .{status_response.error_message orelse "Unknown error"});
            return;
        } else {
            std.debug.print("Status: {s} (waiting...)\n", .{status_response.status});
            std.debug.print("Waiting {d} seconds before next check...\n\n", .{poll_interval});
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(poll_interval)), .real) catch |err| std.log.warn("sleep failed: {any}", .{err});
        }
    }
}

fn downloadAudio(
    allocator: std.mem.Allocator,
    _: *speech.SpeechClient,
    file_id: []const u8,
    output_file: ?[]const u8,
    audio_format: []const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.minimax.io/v1/files/retrieve_content?file_id={s}", .{file_id});
    defer allocator.free(url);

    std.debug.print("Downloading audio from: {s}\n", .{url});

    const filename = if (output_file) |f|
        f
    else blk: {
        const fn_str = try std.fmt.allocPrint(allocator, "output.{s}", .{audio_format});
        break :blk fn_str;
    };
    defer if (output_file == null) allocator.free(filename);

    // std.process.Child.run() API changed in Zig 0.16; stubbed for now
    // const curl_result = std.process.Child.run(.{
    //     .allocator = allocator,
    //     .argv = &[_][]const u8{ "curl", "-L", "-o", filename, url },
    // });
    return error.NotImplemented;
}
