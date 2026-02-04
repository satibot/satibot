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
