//! Video CLI Application
//!
//! A command-line tool for generating videos using the MiniMax API.
//!
//! ## Features
//! - Text-to-Video generation
//! - Image-to-Video generation
//! - First-and-Last-Frame-to-Video generation
//! - Subject-Reference-to-Video generation
//! - Template-based video generation
//! - Automatic task polling and video download
//! - Configuration file support for API key management
//!
//! ## Usage
//!
//! Generate video from text:
//! ```bash
//! s-video t2v "A dancer performing on a beach at sunset" [api_key]
//! ```
//!
//! Generate video from image:
//! ```bash
//! s-video i2v "The dancer moves gracefully" --first-frame "https://example.com/image.jpg" [api_key]
//! ```
//!
//! Generate video with first and last frame:
//! ```bash
//! s-video f2f "A flower blooming" --first-frame "start.jpg" --last-frame "end.jpg" [api_key]
//! ```
//!
//! Generate video with subject reference:
//! ```bash
//! s-video subject "Person walking in park" --subject-image "face.jpg" [api_key]
//! ```
//!
//! Generate video from template:
//! ```bash
//! s-video template --template-id "393769180141805569" --media "image.jpg" --text "Lion" [api_key]
//! ```
//!
//! Configuration file (config.json):
//! { "providers": { "minimax": { "apiKey": "your-key" } } }

const std = @import("std");
const build_options = @import("build_options");

const video = @import("minimax-video").video;

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

    var prompt: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var model: []const u8 = "MiniMax-Hailuo-2.3";
    var duration: u8 = 6;
    var resolution: []const u8 = "1080P";
    var first_frame: ?[]const u8 = null;
    var last_frame: ?[]const u8 = null;
    var subject_image: ?[]const u8 = null;
    var template_id: ?[]const u8 = null;
    var media_inputs: std.ArrayList([]const u8) = .empty;
    defer media_inputs.deinit(allocator);
    var text_inputs: std.ArrayList([]const u8) = .empty;
    defer text_inputs.deinit(allocator);
    var poll_interval: u32 = 10;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--model") or std.mem.eql(u8, args[i], "-m")) {
            if (i + 1 < args.len) {
                model = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--duration") or std.mem.eql(u8, args[i], "-d")) {
            if (i + 1 < args.len) {
                duration = @as(u8, @intCast(try std.fmt.parseInt(u8, args[i + 1], 10)));
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--resolution") or std.mem.eql(u8, args[i], "-r")) {
            if (i + 1 < args.len) {
                resolution = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--first-frame") or std.mem.eql(u8, args[i], "-f")) {
            if (i + 1 < args.len) {
                first_frame = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--last-frame") or std.mem.eql(u8, args[i], "-l")) {
            if (i + 1 < args.len) {
                last_frame = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--subject-image") or std.mem.eql(u8, args[i], "-s")) {
            if (i + 1 < args.len) {
                subject_image = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--template-id") or std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 < args.len) {
                template_id = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--media") or std.mem.eql(u8, args[i], "-M")) {
            if (i + 1 < args.len) {
                try media_inputs.append(allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--text") or std.mem.eql(u8, args[i], "-x")) {
            if (i + 1 < args.len) {
                try text_inputs.append(allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--poll-interval") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                poll_interval = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        } else if (prompt == null) {
            prompt = args[i];
        } else if (api_key == null) {
            api_key = args[i];
        }
    }

    if (prompt == null and template_id == null) {
        std.debug.print("Error: Prompt or --template-id is required\n\n", .{});
        printUsage(args[0]);
        return;
    }

    const key = api_key orelse try getApiKeyFromConfig(allocator);

    if (key == null) {
        std.debug.print("Error: No API key provided and no config.json found with providers.minimax.apiKey\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "t2v")) {
        try generateTextToVideo(allocator, prompt.?, model, duration, resolution, key.?);
    } else if (std.mem.eql(u8, subcommand, "i2v")) {
        if (first_frame == null) {
            std.debug.print("Error: --first-frame is required for image-to-video\n\n", .{});
            printUsage(args[0]);
            return;
        }
        try generateImageToVideo(allocator, prompt.?, first_frame.?, model, duration, resolution, key.?);
    } else if (std.mem.eql(u8, subcommand, "f2f")) {
        if (first_frame == null or last_frame == null) {
            std.debug.print("Error: --first-frame and --last-frame are required for first-and-last-frame video\n\n", .{});
            printUsage(args[0]);
            return;
        }
        try generateFirstLastFrameVideo(allocator, prompt.?, first_frame.?, last_frame.?, model, duration, resolution, key.?);
    } else if (std.mem.eql(u8, subcommand, "subject")) {
        if (subject_image == null) {
            std.debug.print("Error: --subject-image is required for subject-reference video\n\n", .{});
            printUsage(args[0]);
            return;
        }
        try generateSubjectReferenceVideo(allocator, prompt.?, subject_image.?, model, duration, resolution, key.?);
    } else if (std.mem.eql(u8, subcommand, "template")) {
        if (template_id == null) {
            std.debug.print("Error: --template-id is required for template video\n\n", .{});
            printUsage(args[0]);
            return;
        }
        try generateTemplateVideo(allocator, template_id.?, media_inputs.items, text_inputs.items, poll_interval, key.?);
    } else if (std.mem.eql(u8, subcommand, "s2v")) {
        if (subject_image == null) {
            std.debug.print("Error: --subject-image is required for subject-to-video\n\n", .{});
            printUsage(args[0]);
            return;
        }
        try generateSubjectReferenceVideo(allocator, prompt.?, subject_image.?, "S2V-01", duration, resolution, key.?);
    } else {
        std.debug.print("Error: Unknown subcommand '{s}'. Use 't2v', 'i2v', 'f2f', 'subject', 's2v', or 'template'\n\n", .{subcommand});
        printUsage(args[0]);
    }
}

fn printUsage(prog_name: []const u8) void {
    const usage_text =
        \\Usage: {s} <subcommand> [options] [prompt] [api_key]
        \\
        \\Subcommands:
        \\  t2v <prompt> [api_key]         Text-to-Video generation
        \\  i2v <prompt> [api_key]         Image-to-Video generation (requires --first-frame)
        \\  f2f <prompt> [api_key]         First-and-Last-Frame video (requires --first-frame, --last-frame)
        \\  subject <prompt> [api_key]      Subject-Reference video (requires --subject-image)
        \\  s2v <prompt> [api_key]          Subject-to-Video with S2V-01 model (requires --subject-image)
        \\  template [api_key]              Template-based video generation (requires --template-id)
        \\
        \\Options:
        \\  -m, --model <model>            Model to use (default: MiniMax-Hailuo-2.3)
        \\                                   Models: MiniMax-Hailuo-2.3, MiniMax-Hailuo-02, S2V-01
        \\  -d, --duration <seconds>       Video duration in seconds (default: 6)
        \\  -r, --resolution <res>          Video resolution (default: 1080P)
        \\                                   Options: 720P, 1080P
        \\  -f, --first-frame <url>         URL for first frame image (i2v, f2f modes)
        \\  -l, --last-frame <url>          URL for last frame image (f2f mode)
        \\  -s, --subject-image <url>       Subject reference image URL (subject, s2v modes)
        \\  -t, --template-id <id>          Template ID for template mode
        \\  -M, --media <url>               Media input URL for template mode
        \\  -x, --text <text>              Text input for template mode
        \\  -p, --poll-interval <seconds>  Polling interval (default: 10)
        \\  -h, --help                      Show this help message
        \\  -v, --version                   Show version information
        \\
        \\Examples:
        \\  {s} t2v "A dancer performing on a beach at sunset"
        \\  {s} i2v "The dancer moves gracefully" --first-frame "https://example.com/start.jpg"
        \\  {s} f2f "A flower blooming" --first-frame "start.jpg" --last-frame "end.jpg"
        \\  {s} subject "Person walking" --subject-image "https://example.com/face.jpg"
        \\  {s} s2v "Person smiling" --subject-image "https://example.com/face.jpg"
        \\  {s} template --template-id "393769180141805569" --media "image.jpg" --text "Lion"
        \\
        \\Configuration:
        \\  If no API key is provided, reads from config.json:
        \\  {{ "providers": {{ "minimax": {{ "apiKey": "your-key" }} }} }}
    ;
    std.debug.print(usage_text, .{ prog_name, prog_name, prog_name, prog_name, prog_name, prog_name, prog_name });
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
    return try buf.toOwnedSlice(allocator);
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

fn generateTextToVideo(allocator: std.mem.Allocator, prompt: []const u8, model: []const u8, duration: u8, resolution: []const u8, api_key: []const u8) !void {
    var client = try video.VideoClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating text-to-video for: {s}\n", .{prompt});
    std.debug.print("Model: {s}, Duration: {d}s, Resolution: {s}\n\n", .{ model, duration, resolution });

    const request: video.VideoGenerationRequest = .{
        .model = model,
        .prompt = prompt,
        .duration = duration,
        .resolution = resolution,
    };

    const response = try client.generateVideo(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollAndDownloadVideo(allocator, &client, task_id, "t2v");
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn generateImageToVideo(allocator: std.mem.Allocator, prompt: []const u8, first_frame: []const u8, model: []const u8, duration: u8, resolution: []const u8, api_key: []const u8) !void {
    var client = try video.VideoClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating image-to-video for: {s}\n", .{prompt});
    std.debug.print("First frame: {s}\n", .{first_frame});
    std.debug.print("Model: {s}, Duration: {d}s, Resolution: {s}\n\n", .{ model, duration, resolution });

    const request: video.VideoGenerationRequest = .{
        .model = model,
        .prompt = prompt,
        .duration = duration,
        .resolution = resolution,
        .first_frame_image = first_frame,
    };

    const response = try client.generateVideo(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollAndDownloadVideo(allocator, &client, task_id, "i2v");
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn generateFirstLastFrameVideo(allocator: std.mem.Allocator, prompt: []const u8, first_frame: []const u8, last_frame: []const u8, model: []const u8, duration: u8, resolution: []const u8, api_key: []const u8) !void {
    var client = try video.VideoClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating first-and-last-frame video for: {s}\n", .{prompt});
    std.debug.print("First frame: {s}\n", .{first_frame});
    std.debug.print("Last frame: {s}\n", .{last_frame});
    std.debug.print("Model: {s}, Duration: {d}s, Resolution: {s}\n\n", .{ model, duration, resolution });

    const request: video.VideoGenerationRequest = .{
        .model = model,
        .prompt = prompt,
        .duration = duration,
        .resolution = resolution,
        .first_frame_image = first_frame,
        .last_frame_image = last_frame,
    };

    const response = try client.generateVideo(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollAndDownloadVideo(allocator, &client, task_id, "f2f");
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn generateSubjectReferenceVideo(allocator: std.mem.Allocator, prompt: []const u8, subject_image: []const u8, model: []const u8, duration: u8, resolution: []const u8, api_key: []const u8) !void {
    var client = try video.VideoClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating subject-reference video for: {s}\n", .{prompt});
    std.debug.print("Subject image: {s}\n", .{subject_image});
    std.debug.print("Model: {s}, Duration: {d}s, Resolution: {s}\n\n", .{ model, duration, resolution });

    const request: video.VideoGenerationRequest = .{
        .model = model,
        .prompt = prompt,
        .duration = duration,
        .resolution = resolution,
        .subject_reference = .{
            .type = "character",
            .images = &.{subject_image},
        },
    };

    const response = try client.generateVideo(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollAndDownloadVideo(allocator, &client, task_id, "subject");
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn generateTemplateVideo(allocator: std.mem.Allocator, template_id: []const u8, media_inputs: []const []const u8, text_inputs: []const []const u8, poll_interval: u32, api_key: []const u8) !void {
    var client = try video.VideoClient.init(allocator, api_key);
    defer client.deinit();

    std.debug.print("Generating template video\n", .{});
    std.debug.print("Template ID: {s}\n", .{template_id});

    var media_list = try allocator.alloc(video.MediaInput, media_inputs.len);
    defer allocator.free(media_list);
    for (media_inputs, 0..) |input, idx| {
        media_list[idx] = .{ .value = input };
    }

    var text_list = try allocator.alloc(video.TextInput, text_inputs.len);
    defer allocator.free(text_list);
    for (text_inputs, 0..) |input, idx| {
        text_list[idx] = .{ .value = input };
    }

    const request: video.TemplateGenerationRequest = .{
        .template_id = template_id,
        .media_inputs = media_list,
        .text_inputs = text_list,
    };

    const response = try client.generateTemplateVideo(request);

    if (response.code != 0) {
        std.debug.print("Error: API returned code {d}: {s}\n", .{ response.code, response.msg });
        return;
    }

    if (response.task_id) |task_id| {
        std.debug.print("Task ID: {s}\n", .{task_id});
        try pollTemplateVideo(allocator, &client, task_id, poll_interval);
    } else {
        std.debug.print("Error: No task_id in response\n", .{});
    }
}

fn pollAndDownloadVideo(allocator: std.mem.Allocator, client: *video.VideoClient, task_id: []const u8, mode: []const u8) !void {
    std.debug.print("\nPolling for completion...\n", .{});

    while (true) {
        std.debug.print("Checking status...\n", .{});

        const status_response = try client.queryVideoStatus(task_id);

        if (std.mem.eql(u8, status_response.status, "Success")) {
            std.debug.print("\nVideo generation completed!\n", .{});

            if (status_response.file_id) |file_id| {
                std.debug.print("File ID: {s}\n", .{file_id});

                const file_response = try client.retrieveFile(file_id);

                if (file_response.download_url) |download_url| {
                    std.debug.print("Download URL: {s}\n", .{download_url});
                    try downloadVideo(allocator, download_url, mode);
                } else {
                    std.debug.print("Error: No download_url in file response\n", .{});
                }
            } else {
                std.debug.print("Error: No file_id in success response\n", .{});
            }
            return;
        } else if (std.mem.eql(u8, status_response.status, "Fail")) {
            std.debug.print("\nVideo generation failed: {s}\n", .{status_response.error_message orelse "Unknown error"});
            return;
        } else {
            std.debug.print("Status: {s} (waiting...)\n", .{status_response.status});
            std.debug.print("Waiting {d} seconds before next check...\n\n", .{10});
            var req = std.c.timespec{ .sec = 10, .nsec = 0 };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        }
    }
}

fn pollTemplateVideo(allocator: std.mem.Allocator, client: *video.VideoClient, task_id: []const u8, poll_interval: u32) !void {
    std.debug.print("\nPolling for completion...\n", .{});

    while (true) {
        std.debug.print("Checking status...\n", .{});

        const status_response = try client.queryTemplateVideoStatus(task_id);

        if (std.mem.eql(u8, status_response.status, "Success")) {
            std.debug.print("\nVideo generation completed!\n", .{});

            if (status_response.video_url) |video_url| {
                std.debug.print("Video URL: {s}\n", .{video_url});
                try downloadVideo(allocator, video_url, "template");
            } else {
                std.debug.print("Error: No video_url in success response\n", .{});
            }
            return;
        } else if (std.mem.eql(u8, status_response.status, "Fail")) {
            std.debug.print("\nVideo generation failed: {s}\n", .{status_response.error_message orelse "Unknown error"});
            return;
        } else {
            std.debug.print("Status: {s} (waiting...)\n", .{status_response.status});
            std.debug.print("Waiting {d} seconds before next check...\n\n", .{poll_interval});
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.sleep(io, std.Io.Duration.fromSeconds(poll_interval), .real) catch {};
        }
    }
}

fn downloadVideo(allocator: std.mem.Allocator, url: []const u8, mode: []const u8) !void {
    const timestamp = std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toSeconds();
    const extension = if (std.mem.endsWith(u8, url, ".mp4")) "mp4" else "mp4";
    const filename = try std.fmt.allocPrint(allocator, "generated_video_{s}_{d}.{s}", .{ mode, timestamp, extension });
    defer allocator.free(filename);

    std.debug.print("\nDownloading video to: {s}\n", .{filename});
    std.debug.print("URL: {s}\n", .{url});

    // std.process.Child.run() API changed in Zig 0.16; stubbed for now
    return error.NotImplemented;
}

fn playVideo(filename: []const u8) !void {
    std.debug.print("Could not auto-play the video.\n", .{});
    std.debug.print("You can play it manually with: open {s}\n", .{filename});
}
