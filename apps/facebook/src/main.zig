const std = @import("std");

const facebook = @import("facebook");

const usage =
    \\Usage: s-facebook [options]
    \\
    \\Options:
    \\  --test              Test Facebook API connection
    \\  --me                Get current user info
    \\  --page <id>         Get page info by ID
    \\  --posts <id>        Get posts from page (requires --page or --group)
    \\  --comments <id>     Get comments from post
    \\  --conversations <id> Get conversations from page
    \\  --messages <id>     Get messages from conversation
    \\  --group <id>        Get group feed
    \\  --limit <n>         Number of items to fetch (default: 10)
    \\  --token <token>     Facebook access token (or use FACEBOOK_ACCESS_TOKEN env)
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);

    var access_token: ?[]const u8 = null;
    var test_conn = false;
    var get_me = false;
    var page_id: ?[]const u8 = null;
    var post_id: ?[]const u8 = null;
    var conversation_id: ?[]const u8 = null;
    var group_id: ?[]const u8 = null;
    var limit: u32 = 10;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--token")) {
            if (i + 1 < args.len) {
                i += 1;
                access_token = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--test")) {
            test_conn = true;
        } else if (std.mem.eql(u8, arg, "--me")) {
            get_me = true;
        } else if (std.mem.eql(u8, arg, "--page")) {
            if (i + 1 < args.len) {
                i += 1;
                page_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--posts")) {
            if (i + 1 < args.len) {
                i += 1;
                page_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--comments")) {
            if (i + 1 < args.len) {
                i += 1;
                post_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--conversations")) {
            if (i + 1 < args.len) {
                i += 1;
                page_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--messages")) {
            if (i + 1 < args.len) {
                i += 1;
                conversation_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--group")) {
            if (i + 1 < args.len) {
                i += 1;
                group_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (i + 1 < args.len) {
                i += 1;
                limit = std.fmt.parseInt(u32, args[i], 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
    }

    if (access_token == null) {
        if (std.c.getenv("FACEBOOK_ACCESS_TOKEN")) |token_ptr| {
            access_token = std.mem.span(token_ptr);
        }
    }

    const token = access_token orelse {
        std.debug.print("Error: Facebook access token required. Use --token or FACEBOOK_ACCESS_TOKEN env var.\n", .{});
        std.debug.print("{s}", .{usage});
        return error.InvalidToken;
    };

    const config: facebook.Config = .{
        .access_token = token,
    };

    var client = try facebook.Client.init(allocator, config);
    defer client.deinit();

    if (test_conn) {
        const success = try client.testConnection();
        if (success) {
            std.debug.print("Facebook API connection successful!\n", .{});
        } else {
            std.debug.print("Facebook API connection failed!\n", .{});
            return error.ApiError;
        }
    }

    if (get_me) {
        const user = try client.getMe();
        defer {
            allocator.free(user.id);
            allocator.free(user.name);
        }
        std.debug.print("User: {s} (ID: {s})\n", .{ user.name, user.id });
    }

    if (page_id != null and post_id == null and conversation_id == null and group_id == null) {
        const pg = try client.getPage(page_id.?);
        defer {
            allocator.free(pg.id);
            allocator.free(pg.name);
            allocator.free(pg.category);
        }
        std.debug.print("Page: {s} (ID: {s}, Category: {s})\n", .{ pg.name, pg.id, pg.category });
    }

    const target_page = page_id;

    if (target_page != null and post_id == null and conversation_id == null and group_id == null) {
        const pgs = try client.getPagePosts(target_page.?, limit);
        defer {
            for (pgs) |p| {
                allocator.free(p.id);
                allocator.free(p.message);
                allocator.free(p.created_time);
            }
            allocator.free(pgs);
        }
        std.debug.print("Posts ({d} items):\n", .{pgs.len});
        for (pgs) |p| {
            const msg = if (p.message.len > 100) p.message[0..100] else p.message;
            std.debug.print("  [{s}] {s}...\n", .{ p.created_time, msg });
        }
    }

    if (post_id != null) {
        const comments = try client.getPostComments(post_id.?, limit);
        defer {
            for (comments) |c| {
                allocator.free(c.id);
                allocator.free(c.message);
                allocator.free(c.from_name);
                allocator.free(c.created_time);
            }
            allocator.free(comments);
        }
        std.debug.print("Comments ({d} items):\n", .{comments.len});
        for (comments) |c| {
            const msg = if (c.message.len > 80) c.message[0..80] else c.message;
            std.debug.print("  [{s}] {s}: {s}...\n", .{ c.created_time, c.from_name, msg });
        }
    }

    if (conversation_id != null) {
        const messages = try client.getConversationMessages(conversation_id.?, limit);
        defer {
            for (messages) |m| {
                allocator.free(m.id);
                allocator.free(m.message);
                allocator.free(m.from_name);
                allocator.free(m.created_time);
            }
            allocator.free(messages);
        }
        std.debug.print("Messages ({d} items):\n", .{messages.len});
        for (messages) |m| {
            const msg = if (m.message.len > 80) m.message[0..80] else m.message;
            std.debug.print("  [{s}] {s}: {s}...\n", .{ m.created_time, m.from_name, msg });
        }
    }

    if (target_page != null and conversation_id == null and group_id == null) {
        const convs = try client.getConversations(target_page.?, limit);
        defer {
            for (convs) |c| {
                allocator.free(c.id);
                allocator.free(c.updated_time);
                allocator.free(c.snippet);
            }
            allocator.free(convs);
        }
        std.debug.print("Conversations ({d} items):\n", .{convs.len});
        for (convs) |c| {
            const snip = if (c.snippet.len > 50) c.snippet[0..50] else c.snippet;
            std.debug.print("  [{s}] {s}...\n", .{ c.updated_time, snip });
        }
    }

    if (group_id != null) {
        const feed = try client.getGroupFeed(group_id.?, limit);
        defer {
            for (feed) |p| {
                allocator.free(p.id);
                allocator.free(p.message);
                allocator.free(p.created_time);
            }
            allocator.free(feed);
        }
        std.debug.print("Group Feed ({d} items):\n", .{feed.len});
        for (feed) |p| {
            const msg = if (p.message.len > 100) p.message[0..100] else p.message;
            std.debug.print("  [{s}] {s}...\n", .{ p.created_time, msg });
        }
    }
}
