//! X API v2 client - interacts with X/Twitter API.
const std = @import("std");
const http = @import("http");
const auth = @import("auth.zig");

const API_BASE = "https://api.x.com/2";

pub const ApiError = error{
    RateLimited,
    ApiError,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    creds: auth.Credentials,
    user_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, creds: auth.Credentials) !Client {
        const client = try http.Client.init(allocator);
        return .{
            .allocator = allocator,
            .http_client = client,
            .creds = creds,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    fn bearerGet(self: *Client, url: []const u8) ![]const u8 {
        const bearer_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.creds.bearer_token});
        defer self.allocator.free(bearer_header);

        const headers = &[1]std.http.Header{
            .{ .name = "Authorization", .value = bearer_header },
        };

        const resp = try self.http_client.get(url, headers);
        defer resp.deinit();

        return self.handleResponse(resp);
    }

    fn oauthRequest(self: *Client, method: []const u8, url: []const u8, json_body: ?[]const u8) ![]const u8 {
        const auth_header = try auth.Auth.generateOAuthHeader(self.allocator, method, url, &self.creds);
        defer self.allocator.free(auth_header);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = "Authorization", .value = auth_header });

        if (json_body != null) {
            try headers.append(.{ .name = "Content-Type", .value = "application/json" });
        }

        var resp: http.Response = undefined;
        if (std.mem.eql(u8, method, "GET")) {
            resp = try self.http_client.get(url, headers.items);
        } else if (std.mem.eql(u8, method, "POST")) {
            resp = try self.http_client.post(url, headers.items, json_body.?);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            resp = try self.http_client.delete(url, headers.items, json_body);
        } else {
            @panic("Unsupported HTTP method");
        }
        defer resp.deinit();

        return self.handleResponse(resp);
    }

    fn handleResponse(self: *Client, resp: http.Response) ![]const u8 {
        if (resp.status == .too_many_requests) {
            return ApiError.RateLimited;
        }

        if (resp.status != .ok and resp.status != .created and resp.status != .no_content) {
            std.log.err("X API error: {d} - {s}", .{ @intFromEnum(resp.status), resp.body });
            return ApiError.ApiError;
        }

        return self.allocator.dupe(u8, resp.body);
    }

    pub fn getAuthenticatedUserId(self: *Client) ![]const u8 {
        if (self.user_id) |id| return id;

        const resp = try self.oauthRequest("GET", API_BASE ++ "/users/me", null);
        defer self.allocator.free(resp);

        var json = std.json.Parser.init(self.allocator, .{});
        defer json.deinit();

        const tree = try json.parse(resp);
        defer tree.deinit();

        const data = tree.root.object.get("data").?;
        const id = data.object.get("id").?.string;
        self.user_id = try self.allocator.dupe(u8, id);
        return self.user_id.?;
    }

    pub fn postTweet(self: *Client, text: []const u8, reply_to: ?[]const u8, quote_tweet_id: ?[]const u8) ![]const u8 {
        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();

        try obj.put("text", .{ .string = text });

        if (reply_to) |reply| {
            var reply_obj = std.json.ObjectMap.init(self.allocator);
            defer reply_obj.deinit();
            try reply_obj.put("in_reply_to_tweet_id", .{ .string = reply });
            try obj.put("reply", .{ .object = reply_obj });
        }

        if (quote_tweet_id) |quote| {
            try obj.put("quote_tweet_id", .{ .string = quote });
        }

        const body = try std.json.stringifyAlloc(self.allocator, .{ .object = obj }, .{});
        defer self.allocator.free(body);

        return self.oauthRequest("POST", API_BASE ++ "/tweets", body);
    }

    pub fn deleteTweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tweets/{s}", .{ API_BASE, tweet_id });
        defer self.allocator.free(url);

        return self.oauthRequest("DELETE", url, null);
    }

    pub fn getTweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tweets/{s}?tweet.fields=created_at,public_metrics,author_id,conversation_id,in_reply_to_user_id,referenced_tweets,attachments,entities,lang,note_tweet&expansions=author_id,referenced_tweets.id,attachments.media_keys&user.fields=name,username,verified,profile_image_url,public_metrics&media.fields=url,preview_image_url,type,width,height,alt_text", .{ API_BASE, tweet_id });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn searchTweets(self: *Client, query: []const u8, max_results: u32) ![]const u8 {
        const clamped = @max(10, @min(max_results, 100));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tweets/search/recent?query={s}&max_results={d}&tweet.fields=created_at,public_metrics,author_id,conversation_id,entities,lang,note_tweet&expansions=author_id,attachments.media_keys&user.fields=name,username,verified,profile_image_url&media.fields=url,preview_image_url,type", .{ API_BASE, query, clamped });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn getUser(self: *Client, username: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/by/username/{s}?user.fields=created_at,description,public_metrics,verified,profile_image_url,url,location,pinned_tweet_id", .{ API_BASE, username });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn getTimeline(self: *Client, user_id: []const u8, max_results: u32) ![]const u8 {
        const clamped = @max(5, @min(max_results, 100));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/tweets?max_results={d}&tweet.fields=created_at,public_metrics,author_id,conversation_id,entities,lang,note_tweet&expansions=author_id,attachments.media_keys,referenced_tweets.id&user.fields=name,username,verified&media.fields=url,preview_image_url,type", .{ API_BASE, user_id, clamped });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn getFollowers(self: *Client, user_id: []const u8, max_results: u32) ![]const u8 {
        const clamped = @max(1, @min(max_results, 1000));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/followers?max_results={d}&user.fields=created_at,description,public_metrics,verified,profile_image_url", .{ API_BASE, user_id, clamped });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn getFollowing(self: *Client, user_id: []const u8, max_results: u32) ![]const u8 {
        const clamped = @max(1, @min(max_results, 1000));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/following?max_results={d}&user.fields=created_at,description,public_metrics,verified,profile_image_url", .{ API_BASE, user_id, clamped });
        defer self.allocator.free(url);

        return self.bearerGet(url);
    }

    pub fn getMentions(self: *Client, max_results: u32) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const clamped = @max(5, @min(max_results, 100));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/mentions?max_results={d}&tweet.fields=created_at,public_metrics,author_id,conversation_id,entities,note_tweet&expansions=author_id&user.fields=name,username,verified", .{ API_BASE, user_id, clamped });
        defer self.allocator.free(url);

        return self.oauthRequest("GET", url, null);
    }

    pub fn likeTweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const body = try std.fmt.allocPrint(self.allocator, "{{\"tweet_id\":\"{s}\"}}", .{tweet_id});
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/likes", .{ API_BASE, user_id });
        defer self.allocator.free(url);

        return self.oauthRequest("POST", url, body);
    }

    pub fn retweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const body = try std.fmt.allocPrint(self.allocator, "{{\"tweet_id\":\"{s}\"}}", .{tweet_id});
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/retweets", .{ API_BASE, user_id });
        defer self.allocator.free(url);

        return self.oauthRequest("POST", url, body);
    }

    pub fn getBookmarks(self: *Client, max_results: u32) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const clamped = @max(1, @min(max_results, 100));
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/bookmarks?max_results={d}&tweet.fields=created_at,public_metrics,author_id,conversation_id,entities,lang,note_tweet&expansions=author_id,attachments.media_keys&user.fields=name,username,verified,profile_image_url&media.fields=url,preview_image_url,type", .{ API_BASE, user_id, clamped });
        defer self.allocator.free(url);

        return self.oauthRequest("GET", url, null);
    }

    pub fn bookmarkTweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const body = try std.fmt.allocPrint(self.allocator, "{{\"tweet_id\":\"{s}\"}}", .{tweet_id});
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/bookmarks", .{ API_BASE, user_id });
        defer self.allocator.free(url);

        return self.oauthRequest("POST", url, body);
    }

    pub fn unbookmarkTweet(self: *Client, tweet_id: []const u8) ![]const u8 {
        const user_id = try self.getAuthenticatedUserId();
        const url = try std.fmt.allocPrint(self.allocator, "{s}/users/{s}/bookmarks/{s}", .{ API_BASE, user_id, tweet_id });
        defer self.allocator.free(url);

        return self.oauthRequest("DELETE", url, null);
    }
};
