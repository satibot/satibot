//! Facebook Graph API client for reading pages, groups, threads, and comments.
//! Uses the Facebook Marketing API / Graph API endpoints.
const std = @import("std");
const http = @import("http");

const BASE_URL = "https://graph.facebook.com/v21.0";

fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try buf.append(allocator, c);
            },
            else => {
                try buf.append(allocator, '%');
                try buf.append(allocator, "0123456789ABCDEF"[c >> 4]);
                try buf.append(allocator, "0123456789ABCDEF"[c & 0xF]);
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub const Error = error{
    InvalidToken,
    NetworkError,
    ParseError,
    ApiError,
    RateLimited,
};

pub const Config = struct {
    access_token: []const u8,
    app_secret: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
};

const ApiErrorResponse = struct {
    err: ApiErrorBody,
};

const ApiErrorBody = struct {
    message: []const u8,
    type: []const u8,
    code: u32,
    fbtrace_id: ?[]const u8 = null,
};

const JsonUser = struct {
    id: []const u8,
    name: []const u8,
};

const JsonPage = struct {
    id: []const u8,
    name: []const u8,
    category: ?[]const u8 = null,
};

const JsonPost = struct {
    id: []const u8,
    message: ?[]const u8 = null,
    created_time: ?[]const u8 = null,
};

const JsonPostsData = struct {
    data: []JsonPost,
};

const JsonFrom = struct {
    name: []const u8,
};

const JsonComment = struct {
    id: []const u8,
    message: ?[]const u8 = null,
    from: ?JsonFrom = null,
    created_time: ?[]const u8 = null,
};

const JsonCommentsData = struct {
    data: []JsonComment,
};

const JsonConversation = struct {
    id: []const u8,
    updated_time: ?[]const u8 = null,
    snippet: ?[]const u8 = null,
};

const JsonConversationsData = struct {
    data: []JsonConversation,
};

const JsonMessage = struct {
    id: []const u8,
    message: ?[]const u8 = null,
    from: ?JsonFrom = null,
    created_time: ?[]const u8 = null,
};

const JsonMessagesData = struct {
    data: []JsonMessage,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        const http_client = try http.Client.init(allocator);
        return .{
            .allocator = allocator,
            .http_client = http_client,
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    fn buildUrl(self: *Client, path: []const u8, query_params: ?[]const []const u8) ![]u8 {
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(self.allocator);

        try url.appendSlice(self.allocator, BASE_URL);
        try url.appendSlice(self.allocator, path);

        try url.append(self.allocator, '?');
        try url.appendSlice(self.allocator, "access_token=");
        const encoded_token = try urlEncode(self.allocator, self.config.access_token);
        defer self.allocator.free(encoded_token);
        try url.appendSlice(self.allocator, encoded_token);

        if (query_params) |params| {
            for (params) |param| {
                try url.append(self.allocator, '&');
                try url.appendSlice(self.allocator, param);
            }
        }

        return url.toOwnedSlice(self.allocator);
    }

    fn get(self: *Client, path: []const u8, query_params: ?[]const []const u8) !http.Response {
        const url = try self.buildUrl(path, query_params);
        defer self.allocator.free(url);

        return self.http_client.get(url, &.{});
    }

    pub fn testConnection(self: *Client) !bool {
        var response = try self.get("/me", null);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("Connection test failed with status: {}\n", .{response.status});
            return false;
        }

        const json = response.body;
        if (std.mem.indexOf(u8, json, "id") != null and std.mem.indexOf(u8, json, "name") != null) {
            std.debug.print("Connection successful! Response: {s}\n", .{json});
            return true;
        }

        return false;
    }

    pub fn getMe(self: *Client) !User {
        var response = try self.get("/me", null);
        defer response.deinit();

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parseUser(response.body);
    }

    pub fn getPage(self: *Client, page_id: []const u8) !Page {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}", .{page_id});
        defer self.allocator.free(path);

        var response = try self.get(path, null);
        defer response.deinit();

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parsePage(response.body);
    }

    pub fn getPagePosts(self: *Client, page_id: []const u8, limit: u32) ![]Post {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/posts", .{page_id});
        defer self.allocator.free(path);

        const params = &[_][]const u8{try std.fmt.allocPrint(self.allocator, "limit={d}", .{limit})};
        const response = try self.get(path, params);
        defer self.allocator.free(params[0]);

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parsePosts(response.body);
    }

    pub fn getPostComments(self: *Client, post_id: []const u8, limit: u32) ![]Comment {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/comments", .{post_id});
        defer self.allocator.free(path);

        const params = &[_][]const u8{try std.fmt.allocPrint(self.allocator, "limit={d}", .{limit})};
        const response = try self.get(path, params);
        defer self.allocator.free(params[0]);

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parseComments(response.body);
    }

    pub fn getConversations(self: *Client, page_id: []const u8, limit: u32) ![]Conversation {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/conversations", .{page_id});
        defer self.allocator.free(path);

        const params = &[_][]const u8{try std.fmt.allocPrint(self.allocator, "limit={d}", .{limit})};
        const response = try self.get(path, params);
        defer self.allocator.free(params[0]);

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parseConversations(response.body);
    }

    pub fn getConversationMessages(self: *Client, conversation_id: []const u8, limit: u32) ![]Message {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/messages", .{conversation_id});
        defer self.allocator.free(path);

        const params = &[_][]const u8{try std.fmt.allocPrint(self.allocator, "limit={d}", .{limit})};
        const response = try self.get(path, params);
        defer self.allocator.free(params[0]);

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parseMessages(response.body);
    }

    pub fn getGroupFeed(self: *Client, group_id: []const u8, limit: u32) ![]Post {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/feed", .{group_id});
        defer self.allocator.free(path);

        const params = &[_][]const u8{try std.fmt.allocPrint(self.allocator, "limit={d}", .{limit})};
        const response = try self.get(path, params);
        defer self.allocator.free(params[0]);

        if (response.status != .ok) {
            return Error.ApiError;
        }

        return self.parsePosts(response.body);
    }

    fn parseUser(self: *Client, json: []const u8) !User {
        const parsed = try std.json.parseFromSlice(JsonUser, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return .{
            .id = try self.allocator.dupe(u8, parsed.value.id),
            .name = try self.allocator.dupe(u8, parsed.value.name),
        };
    }

    fn parsePage(self: *Client, json: []const u8) !Page {
        const parsed = try std.json.parseFromSlice(JsonPage, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return .{
            .id = try self.allocator.dupe(u8, parsed.value.id),
            .name = try self.allocator.dupe(u8, parsed.value.name),
            .category = if (parsed.value.category) |c|
                try self.allocator.dupe(u8, c)
            else
                try self.allocator.dupe(u8, ""),
        };
    }

    fn parsePosts(self: *Client, json: []const u8) ![]Post {
        const parsed = try std.json.parseFromSlice(JsonPostsData, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var posts = try std.ArrayList(Post).initCapacity(self.allocator, parsed.value.data.len);
        for (parsed.value.data) |p| {
            posts.appendAssumeCapacity(.{
                .id = try self.allocator.dupe(u8, p.id),
                .message = if (p.message) |m|
                    try self.allocator.dupe(u8, m)
                else
                    try self.allocator.dupe(u8, ""),
                .created_time = if (p.created_time) |t|
                    try self.allocator.dupe(u8, t)
                else
                    try self.allocator.dupe(u8, ""),
            });
        }

        return posts.toOwnedSlice(self.allocator);
    }

    fn parseComments(self: *Client, json: []const u8) ![]Comment {
        const parsed = try std.json.parseFromSlice(JsonCommentsData, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var comments = try std.ArrayList(Comment).initCapacity(self.allocator, parsed.value.data.len);
        for (parsed.value.data) |c| {
            comments.appendAssumeCapacity(.{
                .id = try self.allocator.dupe(u8, c.id),
                .message = if (c.message) |m|
                    try self.allocator.dupe(u8, m)
                else
                    try self.allocator.dupe(u8, ""),
                .from_name = if (c.from) |f|
                    try self.allocator.dupe(u8, f.name)
                else
                    try self.allocator.dupe(u8, ""),
                .created_time = if (c.created_time) |t|
                    try self.allocator.dupe(u8, t)
                else
                    try self.allocator.dupe(u8, ""),
            });
        }

        return comments.toOwnedSlice(self.allocator);
    }

    fn parseConversations(self: *Client, json: []const u8) ![]Conversation {
        const parsed = try std.json.parseFromSlice(JsonConversationsData, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var conversations = try std.ArrayList(Conversation).initCapacity(self.allocator, parsed.value.data.len);
        for (parsed.value.data) |c| {
            conversations.appendAssumeCapacity(.{
                .id = try self.allocator.dupe(u8, c.id),
                .updated_time = if (c.updated_time) |t|
                    try self.allocator.dupe(u8, t)
                else
                    try self.allocator.dupe(u8, ""),
                .snippet = if (c.snippet) |s|
                    try self.allocator.dupe(u8, s)
                else
                    try self.allocator.dupe(u8, ""),
            });
        }

        return conversations.toOwnedSlice(self.allocator);
    }

    fn parseMessages(self: *Client, json: []const u8) ![]Message {
        const parsed = try std.json.parseFromSlice(JsonMessagesData, self.allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var messages = try std.ArrayList(Message).initCapacity(self.allocator, parsed.value.data.len);
        for (parsed.value.data) |m| {
            messages.appendAssumeCapacity(.{
                .id = try self.allocator.dupe(u8, m.id),
                .message = if (m.message) |msg|
                    try self.allocator.dupe(u8, msg)
                else
                    try self.allocator.dupe(u8, ""),
                .from_name = if (m.from) |f|
                    try self.allocator.dupe(u8, f.name)
                else
                    try self.allocator.dupe(u8, ""),
                .created_time = if (m.created_time) |t|
                    try self.allocator.dupe(u8, t)
                else
                    try self.allocator.dupe(u8, ""),
            });
        }

        return messages.toOwnedSlice(self.allocator);
    }
};

pub const User = struct {
    id: []const u8,
    name: []const u8,
};

pub const Page = struct {
    id: []const u8,
    name: []const u8,
    category: []const u8,
};

pub const Post = struct {
    id: []const u8,
    message: []const u8,
    created_time: []const u8,
};

pub const Comment = struct {
    id: []const u8,
    message: []const u8,
    from_name: []const u8,
    created_time: []const u8,
};

pub const Conversation = struct {
    id: []const u8,
    updated_time: []const u8,
    snippet: []const u8,
};

pub const Message = struct {
    id: []const u8,
    message: []const u8,
    from_name: []const u8,
    created_time: []const u8,
};
