const std = @import("std");
const http = @import("../http.zig");
const base = @import("base.zig");

// Response structures for OpenRouter/OpenAI API
const CompletionResponse = struct {
    id: []const u8,
    choices: []const Choice,
};

const Choice = struct {
    message: Message,
};

const Message = struct {
    content: ?[]const u8 = null,
    role: []const u8,
    tool_calls: ?[]const ToolCallResponse = null,
};

const ToolCallResponse = struct {
    id: []const u8,
    type: []const u8,
    function: FunctionCallResponse,
};

const FunctionCallResponse = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const OpenRouterProvider = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    api_key: []const u8,
    api_base: []const u8 = "https://openrouter.ai/api/v1",

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) OpenRouterProvider {
        return .{
            .allocator = allocator,
            .client = http.Client.init(allocator),
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *OpenRouterProvider) void {
        self.client.deinit();
    }

    pub fn chat(self: *OpenRouterProvider, messages: []const base.LLMMessage, model: []const u8) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
        };

        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header_val);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header_val },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.client.post(url, headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("API Error: {d} {s}\n", .{ @intFromEnum(response.status), response.body });
            return error.ApiRequestFailed;
        }

        const parsed = try std.json.parseFromSlice(CompletionResponse, self.allocator, response.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.choices.len == 0) {
            return error.NoChoicesReturned;
        }

        const msg = parsed.value.choices[0].message;

        var tool_calls: ?[]base.ToolCall = null;
        if (msg.tool_calls) |calls| {
            tool_calls = try self.allocator.alloc(base.ToolCall, calls.len);
            var allocated: usize = 0;
            errdefer {
                for (0..allocated) |i| {
                    self.allocator.free(tool_calls.?[i].id);
                    self.allocator.free(tool_calls.?[i].function_name);
                    self.allocator.free(tool_calls.?[i].arguments);
                }
                self.allocator.free(tool_calls.?);
            }
            for (calls, 0..) |call, i| {
                tool_calls.?[i] = .{
                    .id = try self.allocator.dupe(u8, call.id),
                    .function_name = try self.allocator.dupe(u8, call.function.name),
                    .arguments = try self.allocator.dupe(u8, call.function.arguments),
                };
                allocated += 1;
            }
        }

        return base.LLMResponse{
            .content = if (msg.content) |c| try self.allocator.dupe(u8, c) else null,
            .tool_calls = tool_calls,
            .allocator = self.allocator,
        };
    }

    pub fn chatStream(self: *OpenRouterProvider, messages: []const base.LLMMessage, model: []const u8, callback: *const fn (chunk: []const u8) void) !base.LLMResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.api_base});
        defer self.allocator.free(url);

        const payload = .{
            .model = model,
            .messages = messages,
            .stream = true,
        };

        const body = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        const auth_header_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header_val);

        const headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header_val },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var req = try self.client.postStream(url, headers, body);
        defer req.deinit();

        var head_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&head_buf);

        if (response.head.status != .ok) {
            return error.ApiRequestFailed;
        }

        var full_content = std.ArrayListUnmanaged(u8){};
        errdefer full_content.deinit(self.allocator);

        var response_body_buf: [8192]u8 = undefined;
        var reader = response.reader(&response_body_buf);

        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        while (true) {
            var read_buf: [4096]u8 = undefined;
            const bytes_read = reader.readSliceShort(&read_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read == 0) break;
            try buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);

            while (true) {
                const newline_pos = std.mem.indexOfScalar(u8, buffer.items, '\n') orelse break;
                const line = buffer.items[0..newline_pos];
                const trimmed = std.mem.trim(u8, line, " \r\n");
                if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, "data: ")) {
                    const data = trimmed[6..];
                    if (std.mem.eql(u8, data, "[DONE]")) {
                        try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
                        break;
                    }

                    const ChunkResponse = struct {
                        choices: []struct {
                            delta: struct {
                                content: ?[]const u8 = null,
                            },
                        },
                    };

                    const parsed = std.json.parseFromSlice(ChunkResponse, self.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
                        std.debug.print("Failed to parse chunk: {any} Data: {s}\n", .{ err, data });
                        try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
                        continue;
                    };
                    defer parsed.deinit();

                    if (parsed.value.choices.len > 0) {
                        if (parsed.value.choices[0].delta.content) |content| {
                            try full_content.appendSlice(self.allocator, content);
                            callback(content);
                        }
                    }
                }
                try buffer.replaceRange(self.allocator, 0, newline_pos + 1, &.{});
            }
        }

        return base.LLMResponse{
            .content = try full_content.toOwnedSlice(self.allocator),
            .tool_calls = null,
            .allocator = self.allocator,
        };
    }
};
