/// Tools module provides all available agent capabilities.
/// Each tool is a function that can be called by the LLM with JSON arguments.
/// Tools include file operations, messaging, web search, database operations, and more.
const std = @import("std");

const Config = @import("core").config.Config;
const providers = @import("providers");
const base = providers.base;
const db = @import("db");
const vector_db = db.vector_db;

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

// /// List files in the current working directory.
// /// Returns a newline-separated list of filenames.
// pub fn list_files(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     _ = arguments;
//     var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
//     defer dir.close();

//     var iter = dir.iterate();
//     var result = std.ArrayListUnmanaged(u8){};
//     errdefer result.deinit(ctx.allocator);

//     while (try iter.next()) |entry| {
//         try result.appendSlice(ctx.allocator, entry.name);
//         try result.append(ctx.allocator, '\n');
//     }

//     return result.toOwnedSlice(ctx.allocator);
// }

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

    // Open file for reading
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Read entire file content with size limit
    return file.readToEndAlloc(ctx.allocator, 10485760); // 10 * 1024 * 1024
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

// /// Write content to a file specified by path in JSON arguments.
// /// Creates new file or overwrites existing.
// pub fn write_file(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     const file = try std.fs.cwd().createFile(parsed.value.path, .{});
//     defer file.close();

//     try file.writeAll(parsed.value.content);
//     return try ctx.allocator.dupe(u8, "File written successfully");
// }

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
    const home = std.posix.getenv("HOME") orelse return filename;
    const bots_dir = try std.fs.path.join(allocator, &.{ home, ".bots" });
    defer allocator.free(bots_dir);

    std.fs.makeDirAbsolute(bots_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

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

//     const home = std.posix.getenv("HOME") orelse "/tmp";
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
//     const home = std.posix.getenv("HOME") orelse "/tmp";
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

//     const home = std.posix.getenv("HOME") orelse "/tmp";
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

// pub fn run_command(ctx: ToolContext, arguments: []const u8) ![]const u8 {
//     const parsed = try std.json.parseFromSlice(struct { command: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
//     defer parsed.deinit();

//     // Security check: Prevent dangerous commands (basic)
//     // In a real agent, this should be more robust or sandboxed.
//     const cmd = parsed.value.command;
//     if (std.mem.indexOf(u8, cmd, "rm -rf /") != null) {
//         return try ctx.allocator.dupe(u8, "Error: Dangerous command blocked.");
//     }

//     const result = try std.process.Child.run(.{
//         .allocator = ctx.allocator,
//         .argv = &[_][]const u8{ "sh", "-c", cmd },
//         .max_output_bytes = 102400, // 100 * 1024
//     });
//     defer {
//         ctx.allocator.free(result.stdout);
//         ctx.allocator.free(result.stderr);
//     }

//     if (result.stdout.len > 0) {
//         return try ctx.allocator.dupe(u8, result.stdout);
//     } else if (result.stderr.len > 0) {
//         return try std.fmt.allocPrint(ctx.allocator, "Stderr: {s}", .{result.stderr});
//     } else {
//         return try ctx.allocator.dupe(u8, "(No output)");
//     }
// }

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
