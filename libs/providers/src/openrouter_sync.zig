const std = @import("std");
const http = @import("http");
const base = @import("base.zig");
const agent = @import("agent");
const Config = agent.config.Config;

pub const OpenRouterError = error{
    ServiceUnavailable,
    ModelNotSupported,
    ApiRequestFailed,
    RateLimitExceeded,
};

pub const FunctionCallResponse = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const OpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://openrouter.ai/api/v1",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = try http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *OpenRouterProvider) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn chat(self: *OpenRouterProvider, messages: []const base.Message, model: []const u8, tools: ?[]const base.Tool) !base.LlmResponse {
        const body = try buildChatRequestBody(messages, model, tools);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const req = try http.Request.init(
            self.allocator,
            url,
            "POST",
            self.api_key,
            body,
        );
        defer req.deinit();

        const response = try self.client.send(req);
        defer response.deinit();

        if (response.status != 200) {
            return error.ApiRequestFailed;
        }

        return try parseChatResponse(self.allocator, response.body);
    }

    pub fn createInterface() base.ProviderInterface {
        return base.ProviderInterface{
            .chat = chatInterface,
        };
    }
};

fn chatInterface(allocator: std.mem.Allocator, config: Config, messages: []const base.Message, model: []const u8, tools: ?[]const base.Tool) !base.LlmResponse {
    const api_key = if (config.providers.openrouter) |p| p.apiKey else std.posix.getenv("OPENROUTER_API_KEY") orelse {
        return error.NoApiKey;
    };
    var provider = try OpenRouterProvider.init(allocator, api_key);
    defer provider.deinit();

    return try provider.chat(messages, model, tools);
}

fn buildChatRequestBody(messages: []const base.Message, model: []const u8, tools: ?[]const base.Tool) ![]u8 {
    var list = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer list.deinit();

    try list.appendSlice(
        \\{"model":"
    );
    try list.appendSlice(model);
    try list.appendSlice(
        \\","messages":[
    );

    for (messages, 0..) |msg, i| {
        if (i > 0) try list.append(',');
        try list.appendSlice(
            \\{"role":"
        );
        try list.appendSlice(@tagName(msg.role));
        try list.appendSlice(
            \\","content":"
        );
        try escapeJsonString(msg.content, &list);
        try list.append('"');
        if (msg.tool_calls) |calls| {
            try list.appendSlice(
                \\,"tool_calls":[{
            );
            for (calls, 0..) |call, j| {
                if (j > 0) try list.append(',');
                try list.appendSlice(
                    \\"id":"
                );
                try escapeJsonString(call.id, &list);
                try list.appendSlice(
                    \\","type":"function","function":{"name":"
                );
                try escapeJsonString(call.function.name, &list);
                try list.appendSlice(
                    \\","arguments":"
                );
                try escapeJsonString(call.function.arguments, &list);
                try list.appendSlice(
                    \\"}}]
                );
            }
            try list.append(']');
        }
        try list.append('}');
    }

    try list.appendSlice(
        \\],"max_tokens":4096}
    );

    if (tools) |t| {
        try list.appendSlice(
            \\,"tools":[{}
        );
        for (t, 0..) |tool, i| {
            if (i > 0) try list.append(',');
            try list.appendSlice(
                \\{"type":"function","function":{"name":"
            );
            try escapeJsonString(tool.name, &list);
            try list.appendSlice(
                \\","description":"
            );
            try escapeJsonString(tool.description, &list);
            try list.appendSlice(
                \\","parameters":"
            );
            try list.appendSlice(tool.parameters);
            try list.append('}');
        }
        try list.appendSlice(
            \\}]
        );
    }

    return list.toOwnedSlice();
}

fn escapeJsonString(s: []const u8, list: *std.ArrayList(u8)) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice("\\\""),
            '\\' => try list.appendSlice("\\\\"),
            '\n' => try list.appendSlice("\\n"),
            '\r' => try list.appendSlice("\\r"),
            '\t' => try list.appendSlice("\\t"),
            else => try list.append(c),
        }
    }
}

fn parseChatResponse(allocator: std.mem.Allocator, body: []const u8) !base.LlmResponse {
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(body);
    defer tree.deinit();

    const root = tree.root;
    const choices = root.object.get("choices").?;
    const first = choices.array.items[0];
    const message = first.object.get("message").?;

    const content = if (message.object.get("content")) |c| c.string else "";

    var tool_calls: ?[]base.ToolCall = null;
    if (message.object.get("tool_calls")) |tc| {
        var calls = std.ArrayList(base.ToolCall).init(allocator);
        for (tc.array.items) |item| {
            const tc_obj = item.object;
            const id = tc_obj.get("id").?.string;
            const func_obj = tc_obj.get("function").?.object;
            const name = func_obj.get("name").?.string;
            const args = func_obj.get("arguments").?.string;
            try calls.append(.{ .id = id, .function = .{ .name = name, .arguments = args } });
        }
        tool_calls = try calls.toOwnedSlice();
    }

    return .{
        .content = try allocator.dupe(u8, content),
        .tool_calls = tool_calls,
    };
}

test {
    _ = OpenRouterError;
    _ = FunctionCallResponse;
    _ = OpenRouterProvider;
}
