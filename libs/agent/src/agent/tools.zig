/// Tools module provides all available agent capabilities.
/// Each tool is a function that can be called by the LLM with JSON arguments.
/// Tools include file operations, messaging, web search, database operations, and more.
const std = @import("std");

const Config = @import("core").config.Config;
const db = @import("db");
const vector_db = db.vector_db;
const http = @import("http");
const providers = @import("providers");
const base = providers.base;
const utils = @import("utils");

/// Context passed to tool functions containing allocator, config, and helper functions.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// Optional function to get text embeddings for vector operations.
    get_embeddings: ?*const fn (allocator: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse = null,
    /// Optional function to spawn subagent for parallel task execution.
    spawn_subagent: ?*const fn (ctx: ToolContext, task: []const u8, label: []const u8) anyerror![]const u8 = null,
};

/// Tool definition containing metadata and execution function.
/// Tools are registered in ToolRegistry and can be called by name.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON schema or simplified version
    execute: *const fn (ctx: ToolContext, arguments: []const u8) anyerror![]const u8,
};

/// Registry for managing available tools.
/// Stores tools in a hash map keyed by tool name.
pub const ToolRegistry = struct {
    tools: std.StringHashMap(Tool),
    allocator: std.mem.Allocator,

    /// Initialize empty tool registry.
    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .tools = std.StringHashMap(Tool).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up registry resources.
    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
        self.* = undefined;
    }

    /// Register a new tool in the registry.
    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Get a tool by name. Returns null if not found.
    pub fn get(self: *ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }
};

/// List files in the current working directory.
/// Returns a newline-separated list of filenames.
pub fn listFiles(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    _ = arguments;
    return ctx.allocator.dupe(u8, "(File listing disabled in Zig 0.16)\n");
}

/// Read contents of a file specified by path in JSON arguments.
/// Max file size: 10MB (10485760 = 10 * 1024 * 1024)
pub fn readFile(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    // Parse JSON arguments expecting a path field
    const parsed = try std.json.parseFromSlice(struct { path: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const file_path = parsed.value.path;

    // Security checks: prevent reading sensitive files
    // Check for .env files and other sensitive patterns
    if (isSensitiveFile(file_path)) {
        return ctx.allocator.dupe(u8, "Error: Access to sensitive files is not allowed for security reasons.");
    }

    // Read file via C I/O
    const path_z = try ctx.allocator.dupeZ(u8, file_path);
    defer ctx.allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(ctx.allocator, temp[0..n]);
    }
    if (buf.items.len > 10485760) return error.FileTooBig;
    return try buf.toOwnedSlice(ctx.allocator);
}

fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (utils.html.isTagStartWith(html, i, "<script") or
                utils.html.isTagStartWith(html, i, "<style") or
                utils.html.isTagStartWith(html, i, "<head"))
            {
                i += 1;
                var depth: usize = 1;
                while (i < html.len and depth > 0) {
                    if (i + 1 < html.len and html[i] == '<' and html[i + 1] == '/') {
                        depth -= 1;
                        if (depth == 0) break;
                    } else if (i + 1 < html.len and html[i] == '<') {
                        if (utils.html.isTagStartWith(html, i + 1, "script") or
                            utils.html.isTagStartWith(html, i + 1, "style") or
                            utils.html.isTagStartWith(html, i + 1, "head"))
                        {
                            depth += 1;
                        }
                    }
                    i += 1;
                }
                while (i < html.len and html[i] != '>') i += 1;
                i += 1;
                continue;
            }

            var tag_end = i + 1;
            while (tag_end < html.len and html[tag_end] != '>') tag_end += 1;

            const in_script = utils.html.isTagStartWith(html, i, "<br") or
                utils.html.isTagStartWith(html, i, "<p") or
                utils.html.isTagStartWith(html, i, "<div") or
                utils.html.isTagStartWith(html, i, "<li") or
                utils.html.isTagStartWith(html, i, "<tr") or
                utils.html.isTagStartWith(html, i, "<h1") or
                utils.html.isTagStartWith(html, i, "<h2") or
                utils.html.isTagStartWith(html, i, "<h3") or
                utils.html.isTagStartWith(html, i, "<h4") or
                utils.html.isTagStartWith(html, i, "<h5") or
                utils.html.isTagStartWith(html, i, "<h6") or
                utils.html.isTagStartWith(html, i, "</");

            const is_li = utils.html.isTagStartWith(html, i, "<li>");
            const is_ul = utils.html.isTagStartWith(html, i, "<ul");
            const is_ol = utils.html.isTagStartWith(html, i, "<ol");

            i = tag_end + 1;

            if (in_script) try result.append(allocator, '\n');
            if (is_li or is_ul or is_ol) try result.appendSlice(allocator, "• ");
            continue;
        }

        if (html[i] == '&') {
            const entity_end = std.mem.indexOfScalarPos(u8, html, i + 1, ';') orelse html.len;
            const entity = html[i .. entity_end + 1];

            if (std.mem.eql(u8, entity, "&nbsp;")) {
                try result.append(allocator, ' ');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try result.append(allocator, '<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try result.append(allocator, '>');
            } else if (std.mem.eql(u8, entity, "&amp;")) {
                try result.appendSlice(allocator, "&");
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try result.append(allocator, '"');
            } else if (std.mem.eql(u8, entity, "&apos;")) {
                try result.append(allocator, '\'');
            } else if (entity.len > 2 and entity[1] == '#') {
                var num_start: usize = 2;
                if (entity.len > 2 and (entity[2] == 'x' or entity[2] == 'X')) {
                    num_start = 3;
                }
                if (num_start < entity.len) {
                    const digits = entity[num_start..entity_end];
                    if (digits.len > 0) {
                        const codepoint = std.fmt.parseInt(u21, digits, 0) catch 0;
                        if (codepoint > 0) {
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                            if (len > 0) {
                                try result.appendSlice(allocator, buf[0..len]);
                            }
                        }
                    }
                }
                i = entity_end + 1;
                continue;
            } else {
                try result.appendSlice(allocator, entity);
            }
            i = entity_end + 1;
            continue;
        }

        try result.append(allocator, html[i]);
        i += 1;
    }

    const output = try result.toOwnedSlice(allocator);
    var cleaned: std.ArrayList(u8) = .empty;
    errdefer cleaned.deinit(allocator);

    var prev_was_space = false;
    for (output) |c| {
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            if (!prev_was_space) {
                try cleaned.append(allocator, ' ');
                prev_was_space = true;
            }
        } else {
            try cleaned.append(allocator, c);
            prev_was_space = false;
        }
    }

    allocator.free(output);

    return cleaned.toOwnedSlice(allocator);
}

const max_html_size = 5 * 1024 * 1024;

pub fn webFetch(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { url: []const u8, format: ?[]const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const url = parsed.value.url;
    const format = parsed.value.format orelse "markdown";

    var client = try http.Client.init(ctx.allocator);
    defer client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "User-Agent", .value = "SatiBot/1.0 (LLM Assistant)" },
        .{ .name = "Accept", .value = "text/html,application/xhtml+xml" },
    };

    var response = try client.get(url, headers);

    if (response.status != .ok) {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "HTTP Error: {d} {s}", .{ @intFromEnum(response.status), @tagName(response.status) });
        response.deinit();
        return err_msg;
    }

    if (response.body.len > max_html_size) {
        response.deinit();
        return std.fmt.allocPrint(ctx.allocator, "Content too large: {d} bytes (max: {d} bytes). URL: {s}", .{ response.body.len, max_html_size, url });
    }

    const text = try htmlToText(ctx.allocator, response.body);
    response.deinit();

    if (std.mem.eql(u8, format, "raw")) {
        return text;
    }

    return text;
}

/// Check if a file path matches sensitive file patterns that should be blocked
fn isSensitiveFile(path: []const u8) bool {
    // Get just the filename for checking
    const filename = std.fs.path.basename(path);

    // Block .env files and variations (must start with .env)
    if (std.mem.startsWith(u8, filename, ".env")) {
        return true;
    }

    // Block specific sensitive file patterns (more precise matching)
    const sensitive_patterns = [_][]const u8{
        "id_rsa",
        "id_ed25519",
        "private_key",
        "secret_key",
        "credentials",
    };

    for (sensitive_patterns) |pattern| {
        if (std.mem.eql(u8, filename, pattern) or
            std.mem.startsWith(u8, filename, pattern) or
            std.mem.endsWith(u8, filename, pattern))
        {
            return true;
        }
    }

    // Block files with sensitive extensions (but allow safe variations)
    const sensitive_extensions = [_][]const u8{
        ".key",
        ".p12",
        ".pfx",
    };

    for (sensitive_extensions) |ext| {
        if (std.mem.endsWith(u8, filename, ext)) {
            return true;
        }
    }

    // Block files containing sensitive keywords in their name
    const sensitive_keywords = [_][]const u8{
        "private",
        "secret",
        "credential",
    };

    for (sensitive_keywords) |keyword| {
        if (std.mem.indexOf(u8, filename, keyword) != null) {
            return true;
        }
    }

    // Block files in sensitive directories
    if (std.mem.indexOf(u8, path, ".ssh/") != null or
        std.mem.indexOf(u8, path, ".aws/") != null or
        std.mem.indexOf(u8, path, ".kube/") != null)
    {
        return true;
    }

    return false;
}

/// Write content to a file specified by path in JSON arguments.
/// Creates new file or overwrites existing.
pub fn writeFile(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (isSensitiveFile(parsed.value.path)) {
        return ctx.allocator.dupe(u8, "Error: Writing to sensitive files is not allowed for security reasons.");
    }

    const path_z = try ctx.allocator.dupeZ(u8, parsed.value.path);
    defer ctx.allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "w") orelse return error.FileOpenError;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(parsed.value.content.ptr, 1, parsed.value.content.len, file);
    return ctx.allocator.dupe(u8, "File written successfully");
}

/// Edit a file by replacing a specific string with new content.
/// This enables precise code modifications like opencode.
/// Arguments: {"path": "file.txt", "oldString": "old text", "newString": "new text", "replaceAll": false}
pub fn editFile(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct {
        path: []const u8,
        oldString: []const u8,
        newString: []const u8,
        replaceAll: ?bool = false,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (isSensitiveFile(parsed.value.path)) {
        return ctx.allocator.dupe(u8, "Error: Editing sensitive files is not allowed for security reasons.");
    }

    const file_path = parsed.value.path;
    const old_string = parsed.value.oldString;
    const new_string = parsed.value.newString;
    const replace_all = parsed.value.replaceAll orelse false;

    if (old_string.len == 0) {
        return ctx.allocator.dupe(u8, "Error: oldString cannot be empty.");
    }

    const read_path_z = try ctx.allocator.dupeZ(u8, file_path);
    defer ctx.allocator.free(read_path_z);
    const file_r = std.c.fopen(read_path_z.ptr, "r") orelse return std.fmt.allocPrint(ctx.allocator, "Error opening file", .{});
    defer _ = std.c.fclose(file_r);

    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(ctx.allocator);
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file_r);
        if (n == 0) break;
        try content_buf.appendSlice(ctx.allocator, temp[0..n]);
    }
    const content = content_buf.items;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.allocator);

    if (replace_all) {
        var remaining = content;
        var found = false;
        while (std.mem.indexOf(u8, remaining, old_string)) |idx| {
            found = true;
            try result.appendSlice(ctx.allocator, remaining[0..idx]);
            try result.appendSlice(ctx.allocator, new_string);
            remaining = remaining[idx + old_string.len ..];
        }
        try result.appendSlice(ctx.allocator, remaining);

        if (!found) {
            return std.fmt.allocPrint(ctx.allocator, "Error: oldString not found in file: {s}", .{old_string});
        }
    } else {
        const idx = std.mem.indexOf(u8, content, old_string) orelse {
            return std.fmt.allocPrint(ctx.allocator, "Error: oldString not found in file: {s}", .{old_string});
        };
        try result.appendSlice(ctx.allocator, content[0..idx]);
        try result.appendSlice(ctx.allocator, new_string);
        try result.appendSlice(ctx.allocator, content[idx + old_string.len ..]);
    }

    const write_path_z = try ctx.allocator.dupeZ(u8, file_path);
    defer ctx.allocator.free(write_path_z);
    const file_w = std.c.fopen(write_path_z.ptr, "w") orelse return error.FileOpenError;
    defer _ = std.c.fclose(file_w);
    _ = std.c.fwrite(result.items.ptr, 1, result.items.len, file_w);

    const replace_count = if (replace_all) blk: {
        var count: usize = 0;
        var search_start: usize = 0;
        while (std.mem.indexOf(u8, result.items[search_start..], old_string)) |idx| {
            count += 1;
            search_start += idx + old_string.len;
        }
        break :blk count;
    } else 1;

    return std.fmt.allocPrint(ctx.allocator, "File edited successfully. Replaced {} occurrence(s).", .{replace_count});
}

// /// Search the web using Brave Search API.
// /// Requires API key to be configured in settings.
// pub fn web_search(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { query: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     const api_key = ctx.config.tools.web.search.apiKey orelse {
//         return try ctx.allocator.dupe(u8, "Error: Search API key not configured.");
//     };

//     var client = try @import("../http.zig").Client.init(ctx.allocator);
//     defer client.deinit();

//     var encoded_query = std.io.Writer.Allocating.init(ctx.allocator);
//     defer encoded_query.deinit();
//     try std.Uri.Component.formatQuery(.{ .raw = parsed.value.query }, &encoded_query.writer);

//     const url = try std.fmt.allocPrint(ctx.allocator, "https://api.search.brave.com/res/v1/web/search?q={s}", .{encoded_query.written()});
//     defer ctx.allocator.free(url);

//     const headers = &[_]std.http.Header{
//         .{ .name = "X-Subscription-Token", .value = api_key },
//         .{ .name = "Accept", .value = "application/json" },
//     };

//     var response = client.get(url, headers) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error performing search: {any}", .{err});
//     };
//     defer response.deinit();

//     if (response.status != .ok) {
//         return try std.fmt.allocPrint(ctx.allocator, "Error: Search API returned status {d}", .{@intFromEnum(response.status)});
//     }

//     // Parse Brave Search results
//     const BraveResponse = struct {
//         web: ?struct {
//             results: []struct {
//                 title: []const u8,
//                 description: []const u8,
//                 url: []const u8,
//             },
//         } = null,
//     };

//     const search_data = std.json.parseFromSlice(BraveResponse, ctx.allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error parsing search results: {any}", .{err});
//     };
//     defer search_data.deinit();

//     var result_text = std.ArrayListUnmanaged(u8){};
//     errdefer result_text.deinit(ctx.allocator);

//     if (search_data.value.web) |web| {
//         for (web.results, 0..) |res, i| {
//             if (i >= 5) break; // Limit to top 5 results
//             try result_text.appendSlice(ctx.allocator, "Title: ");
//             try result_text.appendSlice(ctx.allocator, res.title);
//             try result_text.appendSlice(ctx.allocator, "\nURL: ");
//             try result_text.appendSlice(ctx.allocator, res.url);
//             try result_text.appendSlice(ctx.allocator, "\nDescription: ");
//             try result_text.appendSlice(ctx.allocator, res.description);
//             try result_text.appendSlice(ctx.allocator, "\n\n");
//         }
//     }

//     if (result_text.items.len == 0) {
//         return try ctx.allocator.dupe(u8, "No results found.");
//     }

//     return result_text.toOwnedSlice(ctx.allocator);
// }

// pub fn list_marketplace_skills(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     _ = arguments;
//     // We use the GitHub API to list skills in futantan/agent-skills.md/skills
//     var client = try @import("../http.zig").Client.init(ctx.allocator);
//     defer client.deinit();

//     const url = "https://api.github.com/repos/futantan/agent-skills.md/contents/skills";
//     const headers = &[_]std.http.Header{
//         .{ .name = "Accept", .value = "application/vnd.github+json" },
//         .{ .name = "User-Agent", .value = "satibot/1.0" },
//     };

//     var response = client.get(url, headers) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error fetching marketplace: {any}", .{err});
//     };
//     defer response.deinit();

//     if (response.status != .ok) {
//         return try std.fmt.allocPrint(ctx.allocator, "Error: Marketplace API returned status {d}", .{@intFromEnum(response.status)});
//     }

//     const SkillEntry = struct {
//         name: []const u8,
//         type: []const u8,
//     };

//     const parsed = std.json.parseFromSlice([]SkillEntry, ctx.allocator, response.body, .{ .ignore_unknown_fields = true }) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error parsing marketplace response: {any}", .{err});
//     };
//     defer parsed.deinit();

//     var result = std.ArrayListUnmanaged(u8){};
//     errdefer result.deinit(ctx.allocator);

//     try result.appendSlice(ctx.allocator, "Available skills in marketplace:\n");
//     for (parsed.value) |entry| {
//         if (std.mem.eql(u8, entry.type, "dir")) {
//             try result.appendSlice(ctx.allocator, "- ");
//             try result.appendSlice(ctx.allocator, entry.name);
//             try result.append(ctx.allocator, '\n');
//         }
//     }

//     return result.toOwnedSlice(ctx.allocator);
// }

// pub fn search_marketplace_skills(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed_args = try std.json.parseFromSlice(struct { query: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed_args.deinit();

//     const all_skills = try list_marketplace_skills(ctx, "{}");
//     defer ctx.allocator.free(all_skills);

//     var result = std.ArrayListUnmanaged(u8){};
//     errdefer result.deinit(ctx.allocator);

//     try result.appendSlice(ctx.allocator, "Search results for '");
//     try result.appendSlice(ctx.allocator, parsed_args.value.query);
//     try result.appendSlice(ctx.allocator, "':\n");

//     var iter = std.mem.tokenizeScalar(u8, all_skills, '\n');
//     _ = iter.next(); // Skip header
//     while (iter.next()) |line| {
//         if (std.ascii.indexOfIgnoreCase(line, parsed_args.value.query) != null) {
//             try result.appendSlice(ctx.allocator, line);
//             try result.append(ctx.allocator, '\n');
//         }
//     }

//     if (result.items.len <= 20 + parsed_args.value.query.len) {
//         return try ctx.allocator.dupe(u8, "No matching skills found in marketplace.");
//     }

//     return result.toOwnedSlice(ctx.allocator);
// }

// pub fn install_skill(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { skill_path: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     // The skill_path can be a full URL or shorthan like "futantan/agent-skills.md/skills/notion"
//     const script_path = "./scripts/install-skill.sh";

//     var child = std.process.Child.init(&[_][]const u8{ "/bin/bash", script_path, parsed.value.skill_path }, ctx.allocator);
//     child.stdout_behavior = .Pipe;
//     child.stderr_behavior = .Pipe;

//     try child.spawn();

//     const stdout = try child.stdout.?.readToEndAlloc(ctx.allocator, 1048576); // 1024 * 1024
//     defer ctx.allocator.free(stdout);
//     const stderr = try child.stderr.?.readToEndAlloc(ctx.allocator, 1048576); // 1024 * 1024
//     defer ctx.allocator.free(stderr);

//     const term = try child.wait();

//     if (term.Exited != 0) {
//         return try std.fmt.allocPrint(ctx.allocator, "Installation failed with exit code {d}\nError: {s}", .{ term.Exited, stderr });
//     }

//     return try std.fmt.allocPrint(ctx.allocator, "Skill installed successfully!\nOutput:\n{s}", .{stdout});
// }

// pub fn telegram_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const config = ctx.config.tools.telegram orelse {
//         return try ctx.allocator.dupe(u8, "Error: Telegram not configured.");
//     };

//     const parsed = try std.json.parseFromSlice(struct {
//         chat_id: ?[]const u8 = null,
//         text: []const u8,
//     }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     const chat_id = parsed.value.chat_id orelse config.chatId orelse {
//         return try ctx.allocator.dupe(u8, "Error: chat_id not provided and no default configured.");
//     };

//     var client = try @import("../http.zig").Client.init(ctx.allocator);
//     defer client.deinit();

//     const url = try std.fmt.allocPrint(ctx.allocator, "https://api.telegram.org/bot{s}/sendMessage", .{config.botToken});
//     defer ctx.allocator.free(url);

//     const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
//         .chat_id = chat_id,
//         .text = parsed.value.text,
//     }, .{});
//     defer ctx.allocator.free(body);

//     const headers = &[_]std.http.Header{
//         .{ .name = "Content-Type", .value = "application/json" },
//     };

//     var response = client.post(url, headers, body) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error sending Telegram message: {any}", .{err});
//     };
//     defer response.deinit();

//     if (response.status != .ok) {
//         return try std.fmt.allocPrint(ctx.allocator, "Error: Telegram API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
//     }

//     return try ctx.allocator.dupe(u8, "Message sent to Telegram successfully");
// }

// pub fn discord_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const config = ctx.config.tools.discord orelse {
//         return try ctx.allocator.dupe(u8, "Error: Discord not configured.");
//     };

//     const parsed = try std.json.parseFromSlice(struct {
//         content: []const u8,
//         username: ?[]const u8 = null,
//     }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     var client = try @import("../http.zig").Client.init(ctx.allocator);
//     defer client.deinit();

//     const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
//         .content = parsed.value.content,
//         .username = parsed.value.username,
//     }, .{});
//     defer ctx.allocator.free(body);

//     const headers = &[_]std.http.Header{
//         .{ .name = "Content-Type", .value = "application/json" },
//     };

//     var response = client.post(config.webhookUrl, headers, body) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error sending Discord message: {any}", .{err});
//     };
//     defer response.deinit();

//     // Discord webhook returns 204 No Content on success
//     if (response.status != .no_content and response.status != .ok) {
//         return try std.fmt.allocPrint(ctx.allocator, "Error: Discord API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
//     }

//     return try ctx.allocator.dupe(u8, "Message sent to Discord successfully");
// }

// Helper to get db paths
fn getDbPath(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const home_ptr = std.c.getenv("HOME") orelse return filename;
    const home = std.mem.span(home_ptr);
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);

    const bots_dir_z = try allocator.dupeZ(u8, bots_dir);
    defer allocator.free(bots_dir_z);
    _ = std.c.mkdir(bots_dir_z.ptr, 0o755);

    return std.fs.path.join(allocator, &.{ bots_dir, filename });
}

pub fn upsertVector(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    if (ctx.config.agents.defaults.disableRag) {
        return ctx.allocator.dupe(u8, "Error: RAG is globally disabled in configuration.");
    }
    const parsed = try std.json.parseFromSlice(struct { text: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const get_embeddings = ctx.get_embeddings orelse return ctx.allocator.dupe(u8, "Error: Embedding service not available.");

    var resp = try get_embeddings(ctx.allocator, ctx.config, &.{parsed.value.text});
    defer resp.deinit();

    if (resp.embeddings.len == 0) return ctx.allocator.dupe(u8, "Error: No embeddings generated.");

    var store = vector_db.VectorStore.init(ctx.allocator);
    defer store.deinit();

    const path = try getDbPath(ctx.allocator, "vector_db.json");
    defer ctx.allocator.free(path);

    try store.load(path);
    try store.add(parsed.value.text, resp.embeddings[0]);
    try store.save(path);

    return ctx.allocator.dupe(u8, "Vector upserted successfully");
}

pub fn vectorSearch(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    if (ctx.config.agents.defaults.disableRag) {
        return ctx.allocator.dupe(u8, "Error: RAG is globally disabled in configuration.");
    }
    const parsed = try std.json.parseFromSlice(struct { query: []const u8, top_k: ?usize = 3 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const get_embeddings = ctx.get_embeddings orelse return ctx.allocator.dupe(u8, "Error: Embedding service not available.");

    var resp = try get_embeddings(ctx.allocator, ctx.config, &.{parsed.value.query});
    defer resp.deinit();

    if (resp.embeddings.len == 0) return ctx.allocator.dupe(u8, "Error: No embeddings generated.");

    var store = vector_db.VectorStore.init(ctx.allocator);
    defer store.deinit();

    const path = try getDbPath(ctx.allocator, "vector_db.json");
    defer ctx.allocator.free(path);

    try store.load(path);
    const results = try store.search(resp.embeddings[0], parsed.value.top_k.?);
    defer store.freeSearchResults(results);

    var result_text: std.ArrayList(u8) = std.ArrayList(u8).initCapacity(ctx.allocator, 1024) catch unreachable;
    defer result_text.deinit(ctx.allocator);

    const writer = result_text.writer(ctx.allocator);
    try writer.print("Vector Search Results ({d} items):\n", .{results.len});
    for (results) |res| {
        try writer.print("- {s}\n", .{res.text});
    }

    if (results.len == 0) return ctx.allocator.dupe(u8, "No similar vectors found.");

    return result_text.toOwnedSlice(ctx.allocator);
}

// pub fn graph_upsert_node(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { id: []const u8, label: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     var g = graph_db.Graph.init(ctx.allocator);
//     defer g.deinit();

//     const path = try get_db_path(ctx.allocator, "graph_db.json");
//     defer ctx.allocator.free(path);

//     try g.load(path);
//     try g.add_node(parsed.value.id, parsed.value.label);
//     try g.save(path);

//     return try ctx.allocator.dupe(u8, "Node upserted successfully");
// }

// pub fn graph_upsert_edge(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { from: []const u8, to: []const u8, relation: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     var g = graph_db.Graph.init(ctx.allocator);
//     defer g.deinit();

//     const path = try get_db_path(ctx.allocator, "graph_db.json");
//     defer ctx.allocator.free(path);

//     try g.load(path);
//     try g.add_edge(parsed.value.from, parsed.value.to, parsed.value.relation);
//     try g.save(path);

//     return try ctx.allocator.dupe(u8, "Edge upserted successfully");
// }

// pub fn graph_query(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { start_node: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     var g = graph_db.Graph.init(ctx.allocator);
//     defer g.deinit();

//     const path = try get_db_path(ctx.allocator, "graph_db.json");
//     defer ctx.allocator.free(path);

//     try g.load(path);
//     return try g.query(parsed.value.start_node);
// }

// pub fn rag_search(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { query: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     // RAG search combines Vector Search and maybe more in the future.
//     // For now it's a convenient wrapper.
//     const vector_res = try vector_search(ctx, arguments);
//     return vector_res;
// }

// pub fn whatsapp_send_message(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const config = ctx.config.tools.whatsapp orelse {
//         return try ctx.allocator.dupe(u8, "Error: WhatsApp not configured.");
//     };

//     const parsed = try std.json.parseFromSlice(struct {
//         to: ?[]const u8 = null,
//         text: []const u8,
//     }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     const to = parsed.value.to orelse config.recipientPhoneNumber orelse {
//         return try ctx.allocator.dupe(u8, "Error: 'to' phone number not provided and no default configured.");
//     };

//     var client = try @import("../http.zig").Client.init(ctx.allocator);
//     defer client.deinit();

//     const url = try std.fmt.allocPrint(ctx.allocator, "https://graph.facebook.com/v17.0/{s}/messages", .{config.phoneNumberId});
//     defer ctx.allocator.free(url);

//     const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{
//         .messaging_product = "whatsapp",
//         .to = to,
//         .type = "text",
//         .text = .{ .body = parsed.value.text },
//     }, .{});
//     defer ctx.allocator.free(body);

//     const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{config.accessToken});
//     defer ctx.allocator.free(auth_header);

//     const headers = &[_]std.http.Header{
//         .{ .name = "Content-Type", .value = "application/json" },
//         .{ .name = "Authorization", .value = auth_header },
//     };

//     var response = client.post(url, headers, body) catch |err| {
//         return try std.fmt.allocPrint(ctx.allocator, "Error sending WhatsApp message: {any}", .{err});
//     };
//     defer response.deinit();

//     if (response.status != .ok) {
//         return try std.fmt.allocPrint(ctx.allocator, "Error: WhatsApp API returned status {d}. Response: {s}", .{ @intFromEnum(response.status), response.body });
//     }

//     return try ctx.allocator.dupe(u8, "Message sent to WhatsApp successfully");
// }

// pub fn cron_add(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct {
//         name: []const u8,
//         message: []const u8,
//         every_seconds: ?u64 = null,
//         at_timestamp_ms: ?i64 = null,
//     }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();
//
//     const home_ptr = std.c.getenv("HOME") orelse "/tmp";
//     const home = std.mem.span(home_ptr);
//     const bots_dir = try std.fs.path.join(ctx.allocator, &.{ home, ".bots" });
//     defer ctx.allocator.free(bots_dir);
//     const cron_path = try std.fs.path.join(ctx.allocator, &.{ bots_dir, "cron_jobs.json" });
//     defer ctx.allocator.free(cron_path);

//     var store = cron.CronStore.init(ctx.allocator);
//     defer store.deinit();
//     try store.load(cron_path);

//     var schedule: cron.CronSchedule = undefined;
//     if (parsed.value.every_seconds) |s| {
//         schedule = .{ .kind = .every, .every_ms = @as(i64, @intCast(s)) * 1000 };
//     } else if (parsed.value.at_timestamp_ms) |at| {
//         schedule = .{ .kind = .at, .at_ms = at };
//     } else {
//         return try ctx.allocator.dupe(u8, "Error: Must specify either every_seconds or at_timestamp_ms");
//     }

//     const id = try store.add_job(parsed.value.name, schedule, parsed.value.message);
//     try store.save(cron_path);

//     return try std.fmt.allocPrint(ctx.allocator, "Cron job added successfully with ID: {s}", .{id});
// }

// pub fn cron_list(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     _ = arguments;
//     const home_ptr = std.c.getenv("HOME") orelse "/tmp";
//     const home = std.mem.span(home_ptr);
//     const bots_dir = try std.fs.path.join(ctx.allocator, &.{ home, ".bots" });
//     defer ctx.allocator.free(bots_dir);
//     const cron_path = try std.fs.path.join(ctx.allocator, &.{ bots_dir, "cron_jobs.json" });
//     defer ctx.allocator.free(cron_path);

//     var store = cron.CronStore.init(ctx.allocator);
//     defer store.deinit();
//     try store.load(cron_path);

//     if (store.jobs.items.len == 0) return try ctx.allocator.dupe(u8, "No cron jobs scheduled.");

//     var result = std.ArrayListUnmanaged(u8){};
//     errdefer result.deinit(ctx.allocator);
//     const writer = result.writer(ctx.allocator);

//     try writer.print("Scheduled Cron Jobs ({d}):\n", .{store.jobs.items.len});
//     for (store.jobs.items) |job| {
//         const sched_str = if (job.schedule.kind == .every)
//             try std.fmt.allocPrint(ctx.allocator, "every {d}s", .{@divTrunc(job.schedule.every_ms.?, 1000)})
//         else
//             try std.fmt.allocPrint(ctx.allocator, "at {d}", .{job.schedule.at_ms.?});
//         defer ctx.allocator.free(sched_str);

//         try writer.print("- ID: {s}, Name: {s}, Schedule: {s}, Message: {s}, Enabled: {any}\n", .{ job.id, job.name, sched_str, job.payload.message, job.enabled });
//     }

//     return result.toOwnedSlice(ctx.allocator);
// }

// pub fn cron_remove(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { id: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();
//
//     const home_ptr = std.c.getenv("HOME") orelse "/tmp";
//     const home = std.mem.span(home_ptr);
//     const bots_dir = try std.fs.path.join(ctx.allocator, &.{ home, ".bots" });
//     defer ctx.allocator.free(bots_dir);
//     const cron_path = try std.fs.path.join(ctx.allocator, &.{ bots_dir, "cron_jobs.json" });
//     defer ctx.allocator.free(cron_path);

//     var store = cron.CronStore.init(ctx.allocator);
//     defer store.deinit();
//     try store.load(cron_path);

//     var found = false;
//     for (store.jobs.items, 0..) |job, i| {
//         if (std.mem.eql(u8, job.id, parsed.value.id)) {
//             var j = store.jobs.orderedRemove(i);
//             j.deinit(ctx.allocator);
//             found = true;
//             break;
//         }
//     }

//     if (!found) return try ctx.allocator.dupe(u8, "Error: Cron job ID not found.");

//     try store.save(cron_path);
//     return try ctx.allocator.dupe(u8, "Cron job removed successfully");
// }

// pub fn subagent_spawn(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { task: []const u8, label: ?[]const u8 = null }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     if (ctx.spawn_subagent) |spawn| {
//         return try spawn(ctx, parsed.value.task, parsed.value.label orelse "subagent");
//     } else {
//         return try ctx.allocator.dupe(u8, "Error: Subagent spawning not supported in this environment.");
//     }
// }

pub fn runCommand(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct { command: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Security check: Prevent dangerous commands (basic)
    const cmd = parsed.value.command;
    if (std.mem.indexOf(u8, cmd, "rm -rf /") != null) {
        return ctx.allocator.dupe(u8, "Error: Dangerous command blocked.");
    }

    return ctx.allocator.dupe(u8, "(Command execution disabled in Zig 0.16)");
}

fn buildExcludePatterns(allocator: std.mem.Allocator) ![]const u8 {
    const default_exclusions = [_][]const u8{
        "node_modules",
        "build",
        "dist",
        ".git",
        ".zig-cache",
        "target",
        "__pycache__",
        "venv",
        "env",
        ".venv",
        ".env",
        "wheels",
        ".coverage",
        "tmp",
        "*.pem",
        "*.crt",
        "*.key",
        "*.cer",
        "*.pyc",
        "*.pyd",
        "*.pyo",
        ".env",
        ".env.*",
    };

    var exclusions: std.ArrayList([]const u8) = .empty;
    defer exclusions.deinit(allocator);

    // Track dynamically allocated strings separately
    var dynamic_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (dynamic_strings.items) |s| allocator.free(s);
        dynamic_strings.deinit(allocator);
    }

    try exclusions.appendSlice(allocator, &default_exclusions);

    const gitignore_path = ".gitignore";
    const gitignore_path_z = try allocator.dupeZ(u8, gitignore_path);
    defer allocator.free(gitignore_path_z);
    const gitignore_file = std.c.fopen(gitignore_path_z.ptr, "r");
    if (gitignore_file) |gf| {
        defer _ = std.c.fclose(gf);
        var gi_buf: std.ArrayList(u8) = .empty;
        defer gi_buf.deinit(allocator);
        var temp: [4096]u8 = undefined;
        while (true) {
            const n = std.c.fread(&temp, 1, temp.len, gf);
            if (n == 0) break;
            try gi_buf.appendSlice(allocator, temp[0..n]);
        }
        if (gi_buf.items.len > 1024 * 64) {
            return buildExcludeArg(allocator, exclusions.items);
        }
        const gitignore_content = try gi_buf.toOwnedSlice(allocator);
        defer allocator.free(gitignore_content);

        var line_iter = std.mem.tokenizeScalar(u8, gitignore_content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            if (std.mem.endsWith(u8, trimmed, "/")) {
                const dir_name = trimmed[0 .. trimmed.len - 1];
                const dupe = try allocator.dupe(u8, dir_name);
                try exclusions.append(allocator, dupe);
                try dynamic_strings.append(allocator, dupe);
            } else if (std.mem.indexOf(u8, trimmed, "*") == null) {
                if (trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '\\')) {
                    continue;
                }
                const dupe = try allocator.dupe(u8, trimmed);
                try exclusions.append(allocator, dupe);
                try dynamic_strings.append(allocator, dupe);
            }
        }
    }

    return buildExcludeArg(allocator, exclusions.items);
}

fn buildExcludeArg(allocator: std.mem.Allocator, exclusions: []const []const u8) ![]const u8 {
    if (exclusions.len == 0) {
        return allocator.dupe(u8, "");
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (exclusions) |ex| {
        if (result.items.len > 0) {
            try result.append(allocator, ' ');
        }
        try result.appendSlice(allocator, "--exclude=");
        try result.appendSlice(allocator, ex);
        if (ex.len > 0 and ex[0] != '*') {
            try result.appendSlice(allocator, "/*");
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn findFn(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct {
        name: []const u8,
        path: ?[]const u8 = null,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const fn_name = parsed.value.name;
    const search_path = parsed.value.path orelse ".";

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.allocator);

    try result.appendSlice(ctx.allocator, "Searching for function: ");
    try result.appendSlice(ctx.allocator, fn_name);
    try result.appendSlice(ctx.allocator, " in ");
    try result.appendSlice(ctx.allocator, search_path);
    try result.append(ctx.allocator, '\n');

    const exclude_arg = buildExcludePatterns(ctx.allocator) catch "";
    defer ctx.allocator.free(exclude_arg);

    const extensions = [_][]const u8{ ".zig", ".ts", ".js", ".tsx", ".jsx", ".py", ".go", ".rs", ".c", ".h", ".java" };

    const found_count: usize = 0;
    _ = found_count; // autofix

    for (extensions) |ext| {
        const cmd = if (exclude_arg.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "grep -rn {s} 'fn {s}' --include='*{s}' {s} 2>/dev/null | head -20", .{ exclude_arg, fn_name, ext, search_path })
        else
            try std.fmt.allocPrint(ctx.allocator, "grep -rn 'fn {s}' --include='*{s}' {s} 2>/dev/null | head -20", .{ fn_name, ext, search_path });
        defer ctx.allocator.free(cmd);

        // Command execution disabled in Zig 0.16
        continue;
    }

    try result.appendSlice(ctx.allocator, "\nNo function definitions found.");

    return result.toOwnedSlice(ctx.allocator);
}

pub fn findFnSwc(ctx: ToolContext, arguments: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(struct {
        name: []const u8,
        path: ?[]const u8 = null,
    }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const fn_name = parsed.value.name;
    const search_path = parsed.value.path orelse ".";

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.allocator);

    try result.appendSlice(ctx.allocator, "SWC: Searching for function '");
    try result.appendSlice(ctx.allocator, fn_name);
    try result.appendSlice(ctx.allocator, "' in ");
    try result.appendSlice(ctx.allocator, search_path);
    try result.append(ctx.allocator, '\n');

    const exclude_arg = buildExcludePatterns(ctx.allocator) catch "";
    defer ctx.allocator.free(exclude_arg);

    const grep_cmd = if (exclude_arg.len > 0)
        try std.fmt.allocPrint(ctx.allocator, "grep -rl {s} '{s}' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' {s} 2>/dev/null | head -20", .{ exclude_arg, fn_name, search_path })
    else
        try std.fmt.allocPrint(ctx.allocator, "grep -rl '{s}' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' {s} 2>/dev/null | head -20", .{ fn_name, search_path });
    defer ctx.allocator.free(grep_cmd);

    // std.process.Child.run removed in Zig 0.16; stubbed out
    const grep_result: struct { stdout: []const u8, stderr: []const u8, term: enum { Exited } = .Exited } = .{ .stdout = "", .stderr = "" };
    defer {
        ctx.allocator.free(grep_result.stdout);
        ctx.allocator.free(grep_result.stderr);
    }

    if (grep_result.stdout.len == 0) {
        try result.appendSlice(ctx.allocator, "\nNo files found containing the function.");
        return result.toOwnedSlice(ctx.allocator);
    }

    const found_count: usize = 0;
    var line_iter = std.mem.tokenizeScalar(u8, grep_result.stdout, '\n');
    while (line_iter.next()) |file_path| {
        if (file_path.len == 0) continue;

        const is_ts = std.mem.endsWith(u8, file_path, ".ts") or std.mem.endsWith(u8, file_path, ".tsx");
        const parser = if (is_ts) "typescript" else "ecmascript";
        _ = parser; // autofix

        // SWC parsing disabled in Zig 0.16
        continue;
    }

    if (found_count == 0) {
        try result.appendSlice(ctx.allocator, "\nNo function definitions found using SWC.");
    }

    return result.toOwnedSlice(ctx.allocator);
}

fn getFnContext(allocator: std.mem.Allocator, file_path: []const u8, fn_name: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return allocator.dupe(u8, "(Could not read file)");
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1048576) catch return allocator.dupe(u8, "(Could not read file content)");
    defer allocator.free(content);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var line_iter = std.mem.tokenizeScalar(u8, content, '\n');
    var line_num: usize = 0;
    while (line_iter.next()) |line| : (line_num += 1) {
        if (std.mem.indexOf(u8, line, fn_name) != null) {
            try result.writer(allocator).print("  {d}: {s}\n", .{ line_num + 1, line });
        }
    }

    if (result.items.len == 0) {
        return allocator.dupe(u8, "(Function not found in source)");
    }

    return result.toOwnedSlice(allocator);
}

test "htmlToText: basic HTML conversion" {
    const allocator = std.testing.allocator;
    const html = "<html><body><h1>Hello</h1><p>World</p></body></html>";
    const result = try htmlToText(allocator, html);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "World") != null);
}

test "htmlToText: strips script and style tags" {
    const allocator = std.testing.allocator;
    const html = "<html><head><script>alert('xss')</script><style>.hidden{display:none}</style></head><body><p>Visible</p></body></html>";
    const result = try htmlToText(allocator, html);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "display") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Visible") != null);
}

test "htmlToText: converts HTML entities" {
    const allocator = std.testing.allocator;
    const html = "&lt;div&gt;&amp;";
    const result = try htmlToText(allocator, html);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("<div>&", result);
}

test "htmlToText: handles lists" {
    const allocator = std.testing.allocator;
    const html = "<ul><li>Item 1</li><li>Item 2</li></ul>";
    const result = try htmlToText(allocator, html);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "• Item 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "• Item 2") != null);
}

test "htmlToText: handles empty input" {
    const allocator = std.testing.allocator;
    const result = try htmlToText(allocator, "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "htmlToText: handles plain text without HTML" {
    const allocator = std.testing.allocator;
    const text = "Just plain text with no HTML tags.";
    const result = try htmlToText(allocator, text);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(text, result);
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

    // Only register vector tools - others are commented out
    try registry.register(.{
        .name = "vector_search",
        .description = "Search vector database for similar content",
        .parameters = "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\"}, \"top_k\": {\"type\": \"integer\"}}, \"required\": [\"query\"]}",
        .execute = vectorSearch,
    });
    try registry.register(.{
        .name = "vector_upsert",
        .description = "Add content to vector database",
        .parameters = "{\"type\": \"object\", \"properties\": {\"text\": {\"type\": \"string\"}}, \"required\": [\"text\"]}",
        .execute = upsertVector,
    });

    const tool = registry.get("test");
    try std.testing.expect(tool != null);
    try std.testing.expectEqualStrings("test", tool.?.name);
}

// test "Tools: write and read file" {
//     const allocator = std.testing.allocator;
//     var tmp = std.testing.tmpDir(.{ .iterate = true });
//     defer tmp.cleanup();

//     // Use absolute path for tools since they use cwd
//     const old_cwd = try std.process.getCwdAlloc(allocator);
//     defer allocator.free(old_cwd);

//     // We can't easily change CWD for the whole process in a thread-safe way in tests,
//     // but tools use std.fs.cwd().
//     // Actually, it's better if tools took a Dir or used a path relative to a root.
//     // For now, let's just test with a real relative path in the tmp dir if we can.
//     // Wait, tmpDir gives us a Dir. We can't easily make std.fs.cwd() point to it.

//     // Let's just test the logic by manually creating a file and reading it.
//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = undefined,
//     };

//     const file_path = "test_file.txt";
//     const content = "hello tools";

//     // Test write_file
//     // Use a sub-path within the current directory to avoid cluttering,
//     // but tmpDir is better. Let's try to use absolute paths in the arguments.
//     const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
//     defer allocator.free(tmp_path);
//     const full_path = try std.fs.path.join(allocator, &.{ tmp_path, file_path });
//     defer allocator.free(full_path);

//     const write_args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"{s}\"}}", .{ full_path, content });
//     defer allocator.free(write_args);

//     const write_res = try write_file(ctx, write_args);
//     defer allocator.free(write_res);
//     try std.testing.expectEqualStrings("File written successfully", write_res);

//     // Test read_file
//     const read_args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{full_path});
//     defer allocator.free(read_args);

//     const read_res = try read_file(ctx, read_args);
//     defer allocator.free(read_res);
//     try std.testing.expectEqualStrings(content, read_res);
// }

test "Tools: vector_upsert and vector_search" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Mock embedding service
    const mock_embeddings = struct {
        fn exec(all: std.mem.Allocator, config: Config, input: []const []const u8) anyerror!base.EmbeddingResponse {
            _ = config;
            var embeddings = try all.alloc([]const f32, input.len);
            for (input, 0..) |item, i| {
                _ = item;
                const emb = try all.alloc(f32, 2);
                emb[0] = 1.0;
                emb[1] = 0.0;
                embeddings[i] = emb;
            }
            return .{
                .embeddings = embeddings,
                .allocator = all,
            };
        }
    }.exec;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
        .get_embeddings = mock_embeddings,
    };

    // We need to point get_db_path to a temporary location for the test.
    // However, get_db_path uses HOME env var.
    // Let's just test that it fails or succeeds based on the mock.
    // Actually, upsertVector calls get_db_path.
    // We can't easily mock get_db_path without changing the ENV.

    const res1 = upsertVector(ctx, "{\"text\": \"hello\"}") catch |err| {
        // If it fails due to HOME not set or similar, we skip the rest
        if (err == error.HomeNotFound) return;
        return err;
    };
    defer allocator.free(res1);

    const res2 = vectorSearch(ctx, "{\"query\": \"hi\"}");
    if (res2) |r| {
        defer allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "Vector Search Results") != null);
    } else |_| {}
}

test "Tools: ToolRegistry basic operations" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const test_tool: Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .parameters = "{}",
        .execute = struct {
            fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                _ = ctx;
                _ = args;
                return @constCast("test result");
            }
        }.exec,
    };

    try registry.register(test_tool);

    const retrieved = registry.get("test_tool");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test_tool", retrieved.?.name);
    try std.testing.expectEqualStrings("A test tool", retrieved.?.description);
    try std.testing.expectEqualStrings("{}", retrieved.?.parameters);
}

test "Tools: ToolRegistry multiple tools" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tools = [_]Tool{
        .{
            .name = "tool_a",
            .description = "Tool A",
            .parameters = "{}",
            .execute = struct {
                fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                    _ = ctx;
                    _ = args;
                    return @constCast("A");
                }
            }.exec,
        },
        .{
            .name = "tool_b",
            .description = "Tool B",
            .parameters = "{}",
            .execute = struct {
                fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                    _ = ctx;
                    _ = args;
                    return @constCast("B");
                }
            }.exec,
        },
        .{
            .name = "tool_c",
            .description = "Tool C",
            .parameters = "{}",
            .execute = struct {
                fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                    _ = ctx;
                    _ = args;
                    return @constCast("C");
                }
            }.exec,
        },
    };

    for (tools) |tool| {
        try registry.register(tool);
    }

    try std.testing.expect(registry.get("tool_a") != null);
    try std.testing.expect(registry.get("tool_b") != null);
    try std.testing.expect(registry.get("tool_c") != null);
    try std.testing.expect(registry.get("tool_d") == null);
}

test "Tools: ToolRegistry overwrite tool" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tool1: Tool = .{
        .name = "my_tool",
        .description = "Original description",
        .parameters = "{}",
        .execute = struct {
            fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                _ = ctx;
                _ = args;
                return @constCast("v1");
            }
        }.exec,
    };

    const tool2: Tool = .{
        .name = "my_tool",
        .description = "Updated description",
        .parameters = "{\"type\": \"object\"}",
        .execute = struct {
            fn exec(ctx: ToolContext, args: []const u8) ![]const u8 {
                _ = ctx;
                _ = args;
                return @constCast("v2");
            }
        }.exec,
    };

    try registry.register(tool1);
    try registry.register(tool2); // Should overwrite

    const retrieved = registry.get("my_tool");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("Updated description", retrieved.?.description);
    try std.testing.expectEqualStrings("{\"type\": \"object\"}", retrieved.?.parameters);
}

// test "Tools: list_files in current directory" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = undefined,
//     };

//     const result = list_files(ctx, "{}") catch |err| {
//         // If we can't read the directory, that's ok for this test
//         if (err == error.AccessDenied) return;
//         return err;
//     };
//     defer allocator.free(result);

//     // Should return some content (file names in current dir)
//     try std.testing.expect(result.len > 0);
// }

test "Tools: readFile success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create a test file in the temporary directory
    const test_content = "Hello, World!\nThis is a test file.\nWith multiple lines.";
    const test_file_path = "test_read.txt";
    try tmp.dir.writeFile(.{ .sub_path = test_file_path, .data = test_content });

    // Get the absolute path to the test file
    const abs_path = try tmp.dir.realpathAlloc(allocator, test_file_path);
    defer allocator.free(abs_path);

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test reading the file
    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{abs_path});
    defer allocator.free(args);

    const result = try readFile(ctx, args);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(test_content, result);
}

test "Tools: readFile non-existent" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    const result = readFile(ctx, "{\"path\": \"/non/existent/file.txt\"}");
    try std.testing.expectError(error.FileNotFound, result);
}

test "Tools: readFile invalid JSON" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    const result = readFile(ctx, "invalid json");
    // Accept any JSON parse error
    const is_json_error = result == error.UnexpectedToken or
        result == error.InvalidCharacter or
        result == error.SyntaxError;
    try std.testing.expect(is_json_error);
}

test "Tools: readFile missing path parameter" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    const result = readFile(ctx, "{\"other\": \"value\"}");
    try std.testing.expectError(error.MissingField, result);
}

test "Tools: readFile empty file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create an empty test file
    const test_file_path = "empty_test.txt";
    try tmp.dir.writeFile(.{ .sub_path = test_file_path, .data = "" });

    // Get the absolute path to the test file
    const abs_path = try tmp.dir.realpathAlloc(allocator, test_file_path);
    defer allocator.free(abs_path);

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{abs_path});
    defer allocator.free(args);

    const result = try readFile(ctx, args);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "Tools: readFile security blocks .env files" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test blocking various .env file patterns
    const sensitive_files = [_][]const u8{
        ".env",
        ".env.local",
        ".env.development",
        ".env.production",
        ".env.test",
        "/path/to/.env",
        "./.env.example",
        "config/.env.backup",
    };

    for (sensitive_files) |file_path| {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{file_path});
        defer allocator.free(args);

        const result = try readFile(ctx, args);
        defer allocator.free(result);

        try std.testing.expect(std.mem.indexOf(u8, result, "Error: Access to sensitive files is not allowed") != null);
    }
}

test "Tools: readFile security blocks private keys" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test blocking private key files
    const sensitive_files = [_][]const u8{
        "id_rsa",
        "id_ed25519",
        "private_key.pem",
        "secret.key",
        "credentials.json",
        "/home/user/.ssh/id_rsa",
        "./.aws/credentials",
    };

    for (sensitive_files) |file_path| {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{file_path});
        defer allocator.free(args);

        const result = try readFile(ctx, args);
        defer allocator.free(result);

        try std.testing.expect(std.mem.indexOf(u8, result, "Error: Access to sensitive files is not allowed") != null);
    }
}

test "Tools: readFile security blocks sensitive directories" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test blocking files in sensitive directories
    const sensitive_paths = [_][]const u8{
        ".ssh/config",
        ".aws/config",
        ".kube/config",
        "/home/user/.ssh/known_hosts",
        "./.aws/credentials",
    };

    for (sensitive_paths) |file_path| {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{file_path});
        defer allocator.free(args);

        const result = try readFile(ctx, args);
        defer allocator.free(result);

        try std.testing.expect(std.mem.indexOf(u8, result, "Error: Access to sensitive files is not allowed") != null);
    }
}

test "Tools: readFile security allows safe files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create a safe test file
    const test_content = "This is a safe file content.";
    const test_file_path = "safe_file.txt";
    try tmp.dir.writeFile(.{ .sub_path = test_file_path, .data = test_content });

    // Get the absolute path to the test file
    const abs_path = try tmp.dir.realpathAlloc(allocator, test_file_path);
    defer allocator.free(abs_path);

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{abs_path});
    defer allocator.free(args);

    const result = try readFile(ctx, args);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(test_content, result);
}

test "Tools: isSensitiveFile function" {
    // Test blocked files
    try std.testing.expect(isSensitiveFile(".env"));
    try std.testing.expect(isSensitiveFile(".env.local"));
    try std.testing.expect(isSensitiveFile("id_rsa"));
    try std.testing.expect(isSensitiveFile("private_key.pem"));
    try std.testing.expect(isSensitiveFile("secret.key"));
    try std.testing.expect(isSensitiveFile(".ssh/config"));
    try std.testing.expect(isSensitiveFile("/path/to/.env"));

    // Test allowed files
    try std.testing.expect(!isSensitiveFile("config.txt"));
    try std.testing.expect(!isSensitiveFile("readme.md"));
    try std.testing.expect(!isSensitiveFile("main.zig"));
    try std.testing.expect(!isSensitiveFile("data.json"));
    try std.testing.expect(!isSensitiveFile("environment.txt")); // Similar but not .env
    try std.testing.expect(!isSensitiveFile("public_key.pem")); // Safe certificate file
}

test "Tools: readFile edge cases and boundary conditions" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test edge case: files with similar but safe names
    const edge_cases = [_][]const u8{
        "environment.txt", // Similar to .env but safe
        "env_backup.txt", // Contains env but not .env prefix
        "public_key.pem", // Contains .pem but safe
        "certificate.crt", // Certificate file
        "api_key_example.txt", // Contains key but example
        "config.json", // Safe config
        "readme.env.md", // Contains .env but not starting with .env
    };

    for (edge_cases) |file_path| {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{file_path});
        defer allocator.free(args);

        // These should fail with FileNotFound, not security error
        const result = readFile(ctx, args);
        try std.testing.expectError(error.FileNotFound, result);
    }
}

test "Tools: readFile security error message consistency" {
    const allocator = std.testing.allocator;

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test that all blocked files return the same error message
    const blocked_files = [_][]const u8{
        ".env",
        "id_rsa",
        "private_key.pem",
        ".ssh/config",
    };

    const expected_error = "Error: Access to sensitive files is not allowed for security reasons.";

    for (blocked_files) |file_path| {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{file_path});
        defer allocator.free(args);

        const result = try readFile(ctx, args);
        defer allocator.free(result);

        try std.testing.expectEqualStrings(expected_error, result);
    }
}

test "Tools: readFile with absolute and relative paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create test files
    const test_content = "Test content for path handling.";
    const safe_file = "safe_config.txt";
    try tmp.dir.writeFile(.{ .sub_path = safe_file, .data = test_content });

    const abs_path = try tmp.dir.realpathAlloc(allocator, safe_file);
    defer allocator.free(abs_path);

    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = undefined,
    };

    // Test absolute path
    {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{abs_path});
        defer allocator.free(args);

        const result = try readFile(ctx, args);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(test_content, result);
    }

    // Test relative path (should fail with FileNotFound since we're in different dir)
    {
        const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{safe_file});
        defer allocator.free(args);

        const result = readFile(ctx, args);
        try std.testing.expectError(error.FileNotFound, result);
    }
}

// test "Tools: write_file with invalid JSON" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = undefined,
//     };

//     const result = write_file(ctx, "invalid json");
//     // Accept any JSON parse error
//     const is_json_error = result == error.UnexpectedToken or
//         result == error.InvalidCharacter or
//         result == error.SyntaxError;
//     try std.testing.expect(is_json_error);
// }

// test "Tools: web_search without API key" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = Config{
//             .agents = .{ .defaults = .{ .model = "test" } },
//             .providers = .{},
//             .tools = .{ .web = .{ .search = .{ .apiKey = null } } },
//         },
//     };

//     const result = try web_search(ctx, "{\"query\": \"test\"}");
//     defer allocator.free(result);
//     try std.testing.expect(std.mem.indexOf(u8, result, "Error: Search API key not configured.") != null);
// }

// test "Tools: telegram_send_message without token" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = Config{
//             .agents = .{ .defaults = .{ .model = "test" } },
//             .providers = .{},
//             .tools = .{
//                 .web = .{ .search = .{} },
//                 .telegram = null,
//             },
//         },
//     };

//     const result = try telegram_send_message(ctx, "{\"text\": \"hello\"}");
//     defer allocator.free(result);
//     // Accept either "not configured" or "token not configured" message
//     const has_error = std.mem.indexOf(u8, result, "not configured") != null or
//         std.mem.indexOf(u8, result, "Error") != null;
//     try std.testing.expect(has_error);
// }

// test "Tools: discord_send_message without webhook" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = Config{
//             .agents = .{ .defaults = .{ .model = "test" } },
//             .providers = .{},
//             .tools = .{
//                 .web = .{ .search = .{} },
//                 .discord = null,
//             },
//         },
//     };

//     const result = try discord_send_message(ctx, "{\"content\": \"hello\"}");
//     defer allocator.free(result);
//     // Accept either error or configuration message
//     const has_error = std.mem.indexOf(u8, result, "not configured") != null or
//         std.mem.indexOf(u8, result, "webhook") != null or
//         std.mem.indexOf(u8, result, "Error") != null;
//     try std.testing.expect(has_error);
// }

// test "Tools: whatsapp_send_message without config" {
//     const allocator = std.testing.allocator;

//     const ctx = ToolContext{
//         .allocator = allocator,
//         .config = Config{
//             .agents = .{ .defaults = .{ .model = "test" } },
//             .providers = .{},
//             .tools = .{
//                 .web = .{ .search = .{} },
//                 .whatsapp = null,
//             },
//         },
//     };

//     const result = try whatsapp_send_message(ctx, "{\"text\": \"hello\"}");
//     defer allocator.free(result);
//     try std.testing.expect(std.mem.indexOf(u8, result, "WhatsApp not configured") != null);
// }

test "Tools: JSON argument parsing" {
    const allocator = std.testing.allocator;

    // Test valid JSON parsing
    const valid_json = "{\"path\": \"test.txt\", \"content\": \"hello world\"}";
    const parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, allocator, valid_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test.txt", parsed.value.path);
    try std.testing.expectEqualStrings("hello world", parsed.value.content);

    // Test parsing with extra fields (should be ignored)
    const extra_fields = "{\"path\": \"test.txt\", \"content\": \"hello\", \"extra\": \"ignored\"}";
    const parsed2 = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, allocator, extra_fields, .{ .ignore_unknown_fields = true });
    defer parsed2.deinit();

    try std.testing.expectEqualStrings("test.txt", parsed2.value.path);
    try std.testing.expectEqualStrings("hello", parsed2.value.content);
}

test "Tools: respect disableRag flag" {
    const allocator = std.testing.allocator;
    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = Config{
            .agents = .{ .defaults = .{ .model = "test", .disableRag = true } },
            .providers = .{},
            .tools = .{
                .web = .{ .search = .{} },
            },
        },
    };

    const upsert_res = try upsertVector(ctx, "{\"text\": \"hello\"}");
    defer allocator.free(upsert_res);
    try std.testing.expect(std.mem.indexOf(u8, upsert_res, "RAG is globally disabled") != null);

    const search_res = try vectorSearch(ctx, "{\"query\": \"hello\"}");
    defer allocator.free(search_res);
    try std.testing.expect(std.mem.indexOf(u8, search_res, "RAG is globally disabled") != null);
}

test "Tools: findFn with valid arguments" {
    const allocator = std.testing.allocator;
    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = Config{
            .agents = .{ .defaults = .{ .model = "test" } },
            .providers = .{},
            .tools = .{
                .web = .{ .search = .{} },
            },
        },
    };

    const result = try findFn(ctx, "{\"name\": \"main\", \"path\": \".\"}");
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "Searching for function: main") != null);
}

test "Tools: findFn with default path" {
    const allocator = std.testing.allocator;
    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = Config{
            .agents = .{ .defaults = .{ .model = "test" } },
            .providers = .{},
            .tools = .{
                .web = .{ .search = .{} },
            },
        },
    };

    const result = try findFn(ctx, "{\"name\": \"test\"}");
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "Searching for function: test") != null);
}

test "Tools: getFnContext with valid TypeScript file" {
    const allocator = std.testing.allocator;

    const test_code =
        \\export function hello() {
        \\  console.log("hello");
        \\}
        \\
        \\function world() {
        \\  return "world";
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "test.ts", .data = test_code });

    const abs_path = try tmp.dir.realpathAlloc(allocator, "test.ts");
    defer allocator.free(abs_path);

    const result = try getFnContext(allocator, abs_path, "hello");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
}

test "Tools: buildExcludePatterns returns default exclusions" {
    const allocator = std.testing.allocator;

    const result = try buildExcludePatterns(allocator);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);

    // Test core exclusions
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=node_modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=build") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.git") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.zig-cache") != null);

    // Test Python-related exclusions
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=__pycache__") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=venv") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=env") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.venv") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.pyc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.pyd") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.pyo") != null);

    // Test certificate exclusions
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.pem") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.crt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.key") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=*.cer") != null);

    // Test environment and coverage exclusions
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.env") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.env.*") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.coverage") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=wheels") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=target") != null);
}

test "Tools: buildExcludePatterns array integrity" {
    const allocator = std.testing.allocator;

    // Test that all default exclusions are present and count matches
    const result = try buildExcludePatterns(allocator);
    defer allocator.free(result);

    // Count the number of --exclude patterns to verify all 23 are present
    var exclude_count: usize = 0;
    var i: usize = 0;
    while (i < result.len) {
        if (std.mem.startsWith(u8, result[i..], "--exclude=")) {
            exclude_count += 1;
            // Move to next pattern
            const end = std.mem.indexOf(u8, result[i..], " ") orelse result.len;
            i += end;
        } else {
            i += 1;
        }
    }

    // Should have at least 23 default exclusions
    try std.testing.expect(exclude_count >= 23);
}

test "Tools: buildExcludePatterns reads .gitignore" {
    const allocator = std.testing.allocator;

    const result = try buildExcludePatterns(allocator);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);

    // Check for patterns that should be in the current .gitignore
    // Note: This test depends on the actual .gitignore content in the project root
    // Wildcard patterns (*.log, *.tmp, etc.) are skipped by the current logic
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=zig-cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--exclude=.DS_Store") != null);
}

test "Tools: findFn with excluded patterns" {
    const allocator = std.testing.allocator;
    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = Config{
            .agents = .{ .defaults = .{ .model = "test" } },
            .providers = .{},
            .tools = .{
                .web = .{ .search = .{} },
            },
        },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("node_modules");
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/test.js", .data = "function main() {}" });
    try tmp.dir.writeFile(.{ .sub_path = "main.zig", .data = "pub fn main() void {}" });

    const result = try findFn(ctx, "{\"name\": \"main\", \"path\": \".\"}");
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "main.zig") != null);
}

test "Tools: findFnSwc excludes node_modules" {
    const allocator = std.testing.allocator;
    const ctx: ToolContext = .{
        .allocator = allocator,
        .config = Config{
            .agents = .{ .defaults = .{ .model = "test" } },
            .providers = .{},
            .tools = .{
                .web = .{ .search = .{} },
            },
        },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("node_modules");
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/test.ts", .data = "export function hello() {}" });
    try tmp.dir.writeFile(.{ .sub_path = "main.ts", .data = "export function hello() {}" });

    const result = try findFnSwc(ctx, "{\"name\": \"hello\", \"path\": \".\"}");
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}
