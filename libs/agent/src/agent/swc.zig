//! SWC (Speedy Web Compiler) tool for parsing JavaScript/TypeScript into AST.
//!
//! SWC is a super-fast TypeScript/JavaScript compiler written in Rust.
//! This module provides a tool to parse JS/TS code into an AST.

const std = @import("std");
const ToolContext = @import("tools.zig").ToolContext;

pub const SwcTool = struct {
    name: []const u8 = "parse_typescript",
    description: []const u8 = "Parse JavaScript or TypeScript code into AST using SWC. Input: { \"code\": \"const x = 1;\", \"type\": \"ts\" }. Output: JSON AST representation.",
    parameters: []const u8 = "{ \"type\": \"object\", \"properties\": { \"code\": { \"type\": \"string\" }, \"type\": { \"type\": \"string\", \"enum\": [\"js\", \"ts\"] } }, \"required\": [\"code\"] }",

    pub fn execute(ctx: ToolContext, arguments: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(struct { code: []const u8, type: []const u8 }, ctx.allocator, arguments, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const code = parsed.value.code;
        const lang_type = if (parsed.value.type.len > 0) parsed.value.type else "js";

        const ext = if (std.mem.eql(u8, lang_type, "ts")) ".ts" else ".js";

        var tmp_buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "/tmp/swc_input_{d}", .{std.time.timestamp()});

        const filename = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ tmp_path, ext });
        defer ctx.allocator.free(filename);

        var file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();

        try file.writeAll(code);

        const parser = if (std.mem.eql(u8, lang_type, "ts")) "typescript" else "ecmascript";

        var cmd = std.process.Child.init(&.{ "npx", "-y", "swc", filename, "-o", "/dev/stdout", "--parser", parser, "--module", "commonjs" }, ctx.allocator);
        cmd.stdin_behavior = .Inherit;
        cmd.stdout_behavior = .Pipe;
        cmd.stderr_behavior = .Pipe;

        try cmd.spawn();

        const ast_stdout = try cmd.stdout.?.reader().readAllAlloc(ctx.allocator, 1024 * 1024);
        defer ctx.allocator.free(ast_stdout);

        const ast_stderr = try cmd.stderr.?.reader().readAllAlloc(ctx.allocator, 1024 * 1024);
        defer ctx.allocator.free(ast_stderr);

        const term = cmd.wait() catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "SWC error: {s}", .{@errorName(err)});
        };

        if (term.Exited != 0) {
            return std.fmt.allocPrint(ctx.allocator, "SWC parse error (exit {d}): {s}", .{ @intCast(term.Exited), ast_stderr });
        }

        return ctx.allocator.dupe(u8, ast_stdout);
    }
};

pub const AstNode = struct {
    node_type: []const u8 = "",
    span_start: usize = 0,
    span_end: usize = 0,
};

pub fn parseAstNode(json: []const u8) ?AstNode {
    if (std.mem.indexOf(u8, json, "\"type\"") == null) return null;

    const Span = struct {
        start: usize,
        end: usize,
    };

    const RawNode = struct {
        type: []const u8,
        span: Span,
    };

    var parsed = std.json.parseFromSlice(RawNode, std.heap.page_allocator, json, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .node_type = parsed.value.type,
        .span_start = parsed.value.span.start,
        .span_end = parsed.value.span.end,
    };
}

test "SwcTool: tool metadata" {
    const tool: SwcTool = .{};
    try std.testing.expectEqualStrings("parse_typescript", tool.name);
    try std.testing.expect(tool.description.len > 0);
    try std.testing.expect(tool.parameters.len > 0);
}

test "SwcTool: parseAstNode with valid JSON" {
    const json = "{\"type\":\"Program\",\"span\":{\"start\":0,\"end\":10}}";
    const node = parseAstNode(json);
    try std.testing.expect(node != null);
    try std.testing.expectEqualStrings("Program", node.?.node_type);
    try std.testing.expectEqual(@as(usize, 0), node.?.span_start);
    try std.testing.expectEqual(@as(usize, 10), node.?.span_end);
}

test "SwcTool: parseAstNode with invalid JSON" {
    const json = "not valid json";
    const node = parseAstNode(json);
    try std.testing.expect(node == null);
}

test "SwcTool: parseAstNode with missing type" {
    const json = "{\"span\":{\"start\":0,\"end\":10}}";
    const node = parseAstNode(json);
    try std.testing.expect(node == null);
}
