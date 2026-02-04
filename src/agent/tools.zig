const std = @import("std");

const Config = @import("../config.zig").Config;

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON schema or simplified version
    execute: *const fn (ctx: ToolContext, arguments: []const u8) anyerror![]const u8,
};

pub const ToolRegistry = struct {
    tools: std.StringHashMap(Tool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .tools = std.StringHashMap(Tool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn get(self: *ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }
};

// Example tool: list_files
pub fn list_files(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    _ = arguments;
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(ctx.allocator);

    while (try iter.next()) |entry| {
        try result.appendSlice(ctx.allocator, entry.name);
        try result.append(ctx.allocator, '\n');
    }

    return result.toOwnedSlice(ctx.allocator);
}

pub fn read_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    // Basic arguments parsing (expecting just the filename as a string for now, or JSON)
    const parsed = try std.json.parseFromSlice(struct { path: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().openFile(parsed.value.path, .{});
    defer file.close();

    return file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024); // 10MB limit
}

pub fn write_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file = try std.fs.cwd().createFile(parsed.value.path, .{});
    defer file.close();

    try file.writeAll(parsed.value.content);
    return try ctx.allocator.dupe(u8, "File written successfully");
}

pub fn web_search(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { query: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const api_key = ctx.config.tools.web.search.apiKey orelse {
        return try ctx.allocator.dupe(u8, "Error: Search API key not configured.");
    };

    var client = @import("../http.zig").Client.init(ctx.allocator);
    defer client.deinit();

    var encoded_query = std.io.Writer.Allocating.init(ctx.allocator);
    defer encoded_query.deinit();
    try std.Uri.Component.formatQuery(.{ .raw = parsed.value.query }, &encoded_query.writer);

    const url = try std.fmt.allocPrint(ctx.allocator, "https://api.search.brave.com/res/v1/web/search?q={s}", .{encoded_query.written()});
    defer ctx.allocator.free(url);

    const headers = &[_]std.http.Header{
        .{ .name = "X-Subscription-Token", .value = api_key },
        .{ .name = "Accept", .value = "application/json" },
    };

    var response = client.get(url, headers) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error performing search: {any}", .{err});
    };
    defer response.deinit();

    if (response.status != .ok) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: Search API returned status {d}", .{@intFromEnum(response.status)});
    }

    // Parse Brave Search results
    const BraveResponse = struct {
        web: ?struct {
            results: []struct {
                title: []const u8,
                description: []const u8,
                url: []const u8,
            },
        } = null,
    };

    const search_data = std.json.parseFromSlice(BraveResponse, ctx.allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error parsing search results: {any}", .{err});
    };
    defer search_data.deinit();

    var result_text = std.ArrayListUnmanaged(u8){};
    errdefer result_text.deinit(ctx.allocator);

    if (search_data.value.web) |web| {
        for (web.results, 0..) |res, i| {
            if (i >= 5) break; // Limit to top 5 results
            try result_text.appendSlice(ctx.allocator, "Title: ");
            try result_text.appendSlice(ctx.allocator, res.title);
            try result_text.appendSlice(ctx.allocator, "\nURL: ");
            try result_text.appendSlice(ctx.allocator, res.url);
            try result_text.appendSlice(ctx.allocator, "\nDescription: ");
            try result_text.appendSlice(ctx.allocator, res.description);
            try result_text.appendSlice(ctx.allocator, "\n\n");
        }
    }

    if (result_text.items.len == 0) {
        return try ctx.allocator.dupe(u8, "No results found.");
    }

    return result_text.toOwnedSlice(ctx.allocator);
}

pub fn list_marketplace_skills(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    _ = arguments;
    // We use the GitHub API to list skills in futantan/agent-skills.md/skills
    var client = @import("../http.zig").Client.init(ctx.allocator);
    defer client.deinit();

    const url = "https://api.github.com/repos/futantan/agent-skills.md/contents/skills";
    const headers = &[_]std.http.Header{
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "User-Agent", .value = "minbot" },
    };

    var response = client.get(url, headers) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error fetching marketplace: {any}", .{err});
    };
    defer response.deinit();

    if (response.status != .ok) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: Marketplace API returned status {d}", .{@intFromEnum(response.status)});
    }

    const SkillEntry = struct {
        name: []const u8,
        type: []const u8,
    };

    const parsed = std.json.parseFromSlice([]SkillEntry, ctx.allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error parsing marketplace response: {any}", .{err});
    };
    defer parsed.deinit();

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(ctx.allocator);

    try result.appendSlice(ctx.allocator, "Available skills in marketplace:\n");
    for (parsed.value) |entry| {
        if (std.mem.eql(u8, entry.type, "dir")) {
            try result.appendSlice(ctx.allocator, "- ");
            try result.appendSlice(ctx.allocator, entry.name);
            try result.append(ctx.allocator, '\n');
        }
    }

    return result.toOwnedSlice(ctx.allocator);
}

pub fn search_marketplace_skills(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed_args = try std.json.parseFromSlice(struct { query: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed_args.deinit();

    const all_skills = try list_marketplace_skills(ctx, "{}");
    defer ctx.allocator.free(all_skills);

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(ctx.allocator);

    try result.appendSlice(ctx.allocator, "Search results for '");
    try result.appendSlice(ctx.allocator, parsed_args.value.query);
    try result.appendSlice(ctx.allocator, "':\n");

    var iter = std.mem.tokenizeScalar(u8, all_skills, '\n');
    _ = iter.next(); // Skip header
    while (iter.next()) |line| {
        if (std.ascii.indexOfIgnoreCase(line, parsed_args.value.query) != null) {
            try result.appendSlice(ctx.allocator, line);
            try result.append(ctx.allocator, '\n');
        }
    }

    if (result.items.len <= 20 + parsed_args.value.query.len) {
        return try ctx.allocator.dupe(u8, "No matching skills found in marketplace.");
    }

    return result.toOwnedSlice(ctx.allocator);
}

pub fn install_skill(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { skill_path: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // The skill_path can be a full URL or shorthan like "futantan/agent-skills.md/skills/notion"
    const script_path = "./scripts/install-skill.sh";

    var child = std.process.Child.init(&[_][]const u8{ "/bin/bash", script_path, parsed.value.skill_path }, ctx.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(ctx.allocator, 1024 * 1024);
    defer ctx.allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(ctx.allocator, 1024 * 1024);
    defer ctx.allocator.free(stderr);

    const term = try child.wait();

    if (term.Exited != 0) {
        return try std.fmt.allocPrint(ctx.allocator, "Installation failed with exit code {d}\nError: {s}", .{ term.Exited, stderr });
    }

    return try std.fmt.allocPrint(ctx.allocator, "Skill installed successfully!\nOutput:\n{s}", .{stdout});
}

pub fn telegram_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const config = ctx.config.tools.telegram orelse {
        return try ctx.allocator.dupe(u8, "Error: Telegram not configured.");
    };

    const parsed = try std.json.parseFromSlice(struct {
        chat_id: ?[]const u8 = null,
        text: []const u8,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const chat_id = parsed.value.chat_id orelse config.chatId orelse {
        return try ctx.allocator.dupe(u8, "Error: chat_id not provided and no default configured.");
    };

    var client = @import("../http.zig").Client.init(ctx.allocator);
    defer client.deinit();

    const url = try std.fmt.allocPrint(ctx.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{config.botToken});
    defer ctx.allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .chat_id = chat_id,
        .text = parsed.value.text,
    }, .{});
    defer ctx.allocator.free(body);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = client.post(url, headers, body) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error sending Telegram message: {any}", .{err});
    };
    defer response.deinit();

    if (response.status != .ok) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: Telegram API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
    }

    return try ctx.allocator.dupe(u8, "Message sent to Telegram successfully");
}

pub fn discord_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const config = ctx.config.tools.discord orelse {
        return try ctx.allocator.dupe(u8, "Error: Discord not configured.");
    };

    const parsed = try std.json.parseFromSlice(struct {
        content: []const u8,
        username: ?[]const u8 = null,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var client = @import("../http.zig").Client.init(ctx.allocator);
    defer client.deinit();

    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .content = parsed.value.content,
        .username = parsed.value.username,
    }, .{});
    defer ctx.allocator.free(body);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = client.post(config.webhookUrl, headers, body) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error sending Discord message: {any}", .{err});
    };
    defer response.deinit();

    // Discord webhook returns 204 No Content on success
    if (response.status != .no_content and response.status != .ok) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: Discord API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
    }

    return try ctx.allocator.dupe(u8, "Message sent to Discord successfully");
}

pub fn whatsapp_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const config = ctx.config.tools.whatsapp orelse {
        return try ctx.allocator.dupe(u8, "Error: WhatsApp not configured.");
    };

    const parsed = try std.json.parseFromSlice(struct {
        to: ?[]const u8 = null,
        text: []const u8,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const to = parsed.value.to orelse config.recipientPhoneNumber orelse {
        return try ctx.allocator.dupe(u8, "Error: 'to' phone number not provided and no default configured.");
    };

    var client = @import("../http.zig").Client.init(ctx.allocator);
    defer client.deinit();

    const url = try std.fmt.allocPrint(ctx.allocator, "https://graph.facebook.com/v17.0/{s}/messages", .{config.phoneNumberId});
    defer ctx.allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .messaging_product = "whatsapp",
        .to = to,
        .type = "text",
        .text = .{ .body = parsed.value.text },
    }, .{});
    defer ctx.allocator.free(body);

    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{config.accessToken});
    defer ctx.allocator.free(auth_header);

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    var response = client.post(url, headers, body) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error sending WhatsApp message: {any}", .{err});
    };
    defer response.deinit();

    if (response.status != .ok) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: WhatsApp API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
    }

    return try ctx.allocator.dupe(u8, "Message sent to WhatsApp successfully");
}

test "ToolRegistry: register and get" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "test",
        .description = "test tool",
        .parameters = "{}",
        .execute = struct {
            fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                _ = ctx;
                _ = args;
                return "ok";
            }
        }.exec,
    });

    const tool = registry.get("test");
    try std.testing.expect(tool != null);
    try std.testing.expectEqualStrings("test", tool.?.name);
}

test "Tools: write and read file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Use absolute path for tools since they use cwd
    const old_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(old_cwd);

    // We can't easily change CWD for the whole process in a thread-safe way in tests,
    // but tools use std.fs.cwd().
    // Actually, it's better if tools took a Dir or used a path relative to a root.
    // For now, let's just test with a real relative path in the tmp dir if we can.
    // Wait, tmpDir gives us a Dir. We can't easily make std.fs.cwd() point to it.

    // Let's just test the logic by manually creating a file and reading it.
    const ctx = ToolContext{
        .allocator = allocator,
        .config = undefined,
    };

    const file_path = "test_file.txt";
    const content = "hello tools";

    // Test write_file
    // Use a sub-path within the current directory to avoid cluttering,
    // but tmpDir is better. Let's try to use absolute paths in the arguments.
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const full_path = try std.fs.path.join(allocator, &.{ tmp_path, file_path });
    defer allocator.free(full_path);

    const write_args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"{s}\"}}", .{ full_path, content });
    defer allocator.free(write_args);

    const write_res = try write_file(ctx, write_args);
    defer allocator.free(write_res);
    try std.testing.expectEqualStrings("File written successfully", write_res);

    // Test read_file
    const read_args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{full_path});
    defer allocator.free(read_args);

    const read_res = try read_file(ctx, read_args);
    defer allocator.free(read_res);
    try std.testing.expectEqualStrings(content, read_res);
}
