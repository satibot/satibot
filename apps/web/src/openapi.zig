//! OpenAPI specification and handler for SatiBot web API

const std = @import("std");
const web = @import("zap");

const OpenApiSpec = struct {
    openapi: []const u8,
    info: Info,
    servers: []const Server,
    paths: []const PathItem,
};

const Info = struct {
    title: []const u8,
    version: []const u8,
    description: []const u8,
};

const Server = struct {
    url: []const u8,
    description: []const u8,
};

const PathItem = struct {
    path: []const u8,
    method: []const u8,
    operation: Operation,
};

const Operation = struct {
    summary: []const u8,
    description: []const u8,
    requestBody: ?RequestBody,
    responses: Responses,
};

const RequestBody = struct {
    required: bool,
    content: Content,
};

const Content = struct {
    @"application/json": MediaType,
};

const MediaType = struct {
    schema: *const Schema,
};

const Schema = struct {
    type: []const u8,
    properties: ?std.json.Value, // Use std.json.Value to avoid circular dependency
    items: ?*const Schema, // Use pointer to avoid circular dependency
    required: ?[]const []const u8,
    @"enum": ?[]const []const u8,
};

const BoxSchema = struct {
    type: []const u8,
    properties: ?Properties,
    @"enum": ?[]const []const u8,
};

const Properties = struct {
    messages: ?Schema,
    role: ?Schema,
    content: ?Schema,
    status: ?Schema,
    message: ?Schema,
};

const Responses = struct {
    @"200": Response,
    @"400": Response,
    @"500": Response,
};

const Response = struct {
    description: []const u8,
    content: ?Content,
};

/// Handle OpenAPI specification endpoint
pub fn handleOpenApi(req: web.zap.Request) !void {
    const openapi_spec: OpenApiSpec = .{
        .openapi = "3.0.0",
        .info = .{
            .title = "SatiBot API",
            .version = "1.0.0",
            .description = "AI chatbot API powered by Sati",
        },
        .servers = &.{
            .{ .url = "http://localhost:8080", .description = "Local development server" },
        },
        .paths = &.{
            .{
                .path = "/api/chat",
                .method = "post",
                .operation = .{
                    .summary = "Chat with AI assistant",
                    .description = "Send messages and receive AI responses",
                    .requestBody = .{
                        .required = true,
                        .content = .{
                            .@"application/json" = .{
                                .schema = .{
                                    .type = "object",
                                    .properties = .{
                                        .messages = .{
                                            .type = "array",
                                            .items = .{
                                                .type = "object",
                                                .properties = .{
                                                    .role = .{ .type = "string", .@"enum" = &.{ "user", "assistant", "system" } },
                                                    .content = .{ .type = "string" },
                                                },
                                                .required = &.{ "role", "content" },
                                            },
                                        },
                                    },
                                    .required = &.{"messages"},
                                },
                            },
                        },
                    },
                    .responses = .{
                        .@"200" = .{
                            .description = "Successful response",
                            .content = .{
                                .@"application/json" = .{
                                    .schema = .{
                                        .type = "object",
                                        .properties = .{
                                            .content = .{ .type = "string" },
                                        },
                                    },
                                },
                            },
                        },
                        .@"400" = .{
                            .description = "Bad request - invalid JSON or missing messages",
                        },
                        .@"500" = .{
                            .description = "Internal server error",
                        },
                    },
                },
            },
            .{
                .path = "/",
                .method = "get",
                .operation = .{
                    .summary = "API status",
                    .description = "Check if the API is running",
                    .requestBody = null,
                    .responses = .{
                        .@"200" = .{
                            .description = "API is running",
                            .content = .{
                                .@"application/json" = .{
                                    .schema = .{
                                        .type = "object",
                                        .properties = .{
                                            .status = .{ .type = "string" },
                                            .message = .{ .type = "string" },
                                        },
                                    },
                                },
                            },
                        },
                        .@"400" = .{ .description = "" },
                        .@"500" = .{ .description = "" },
                    },
                },
            },
            .{
                .path = "/openapi.json",
                .method = "get",
                .operation = .{
                    .summary = "OpenAPI specification",
                    .description = "Get the OpenAPI 3.0 specification in JSON format",
                    .requestBody = null,
                    .responses = .{
                        .@"200" = .{
                            .description = "OpenAPI specification",
                            .content = .{
                                .@"application/json" = .{
                                    .schema = .{
                                        .type = "object",
                                        .properties = null,
                                        .items = null,
                                        .required = null,
                                    },
                                },
                            },
                        },
                        .@"400" = .{ .description = "" },
                        .@"500" = .{ .description = "" },
                    },
                },
            },
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(openapi_spec, .{}, &aw.writer);
    req.sendJson(aw.written()) catch |e| {
        std.log.err("Failed to send OpenAPI response: {any}", .{e});
    };
}

const testing = std.testing;

test "OpenApiSpec structure validation" {
    const spec = OpenApiSpec{
        .openapi = "3.0.0",
        .info = .{
            .title = "Test API",
            .version = "1.0.0",
            .description = "Test description",
        },
        .servers = &.{
            .{ .url = "http://localhost:8080", .description = "Test server" },
        },
        .paths = &.{
            .{
                .path = "/test",
                .method = "get",
                .operation = .{
                    .summary = "Test endpoint",
                    .description = "Test description",
                    .requestBody = null,
                    .responses = .{
                        .@"200" = .{ .description = "Success", .content = null },
                        .@"400" = .{ .description = "Bad request", .content = null },
                        .@"500" = .{ .description = "Server error", .content = null },
                    },
                },
            },
        },
    };

    try testing.expectEqualStrings("3.0.0", spec.openapi);
    try testing.expectEqualStrings("Test API", spec.info.title);
    try testing.expectEqualStrings("1.0.0", spec.info.version);
    try testing.expectEqualStrings("Test description", spec.info.description);
    try testing.expect(spec.servers.len == 1);
    try testing.expectEqualStrings("http://localhost:8080", spec.servers[0].url);
    try testing.expect(spec.paths.len == 1);
    try testing.expectEqualStrings("/test", spec.paths[0].path);
}

test "Schema with enum values" {
    const schema = Schema{
        .type = "string",
        .properties = null,
        .items = null,
        .required = null,
        .@"enum" = &.{ "user", "assistant", "system" },
    };

    try testing.expectEqualStrings("string", schema.type);
    try testing.expect(schema.@"enum" != null);
    try testing.expect(schema.@"enum".?.len == 3);
    try testing.expectEqualStrings("user", schema.@"enum".?[0]);
    try testing.expectEqualStrings("assistant", schema.@"enum".?[1]);
    try testing.expectEqualStrings("system", schema.@"enum".?[2]);
}

test "BoxSchema structure" {
    const box_schema = BoxSchema{
        .type = "object",
        .properties = null,
        .@"enum" = &.{ "value1", "value2" },
    };

    try testing.expectEqualStrings("object", box_schema.type);
    try testing.expect(box_schema.@"enum" != null);
    try testing.expect(box_schema.@"enum".?.len == 2);
}

test "RequestBody with required content" {
    const schema = Schema{
        .type = "object",
        .properties = null,
        .items = null,
        .required = null,
        .@"enum" = null,
    };

    const request_body = RequestBody{
        .required = true,
        .content = .{
            .@"application/json" = .{
                .schema = &schema,
            },
        },
    };

    try testing.expect(request_body.required);
    try testing.expectEqualStrings("object", request_body.content.@"application/json".schema.type);
}

test "Response structure" {
    const schema = Schema{
        .type = "string",
        .properties = null,
        .items = null,
        .required = null,
        .@"enum" = null,
    };

    const response = Response{
        .description = "Test response",
        .content = .{
            .@"application/json" = .{
                .schema = &schema,
            },
        },
    };

    try testing.expectEqualStrings("Test response", response.description);
    try testing.expect(response.content != null);
    try testing.expectEqualStrings("string", response.content.?.@"application/json".schema.type);
}

test "OpenAPI JSON serialization" {
    const allocator = testing.allocator;

    const spec = OpenApiSpec{
        .openapi = "3.0.0",
        .info = .{
            .title = "Test API",
            .version = "1.0.0",
            .description = "Test description",
        },
        .servers = &.{
            .{ .url = "http://localhost:8080", .description = "Test server" },
        },
        .paths = &.{
            .{
                .path = "/test",
                .method = "get",
                .operation = .{
                    .summary = "Test endpoint",
                    .description = "Test description",
                    .requestBody = null,
                    .responses = .{
                        .@"200" = .{ .description = "Success", .content = null },
                        .@"400" = .{ .description = "Bad request", .content = null },
                        .@"500" = .{ .description = "Server error", .content = null },
                    },
                },
            },
        },
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(spec, .{}, &aw.writer);
    const json_output = aw.written();

    // Verify the JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, json_output, "3.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "Test API") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "/test") != null);
}
