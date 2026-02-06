/// Graph database module for storing node-edge relationships.
/// Simple in-memory graph with nodes (entities) and edges (relationships).
const std = @import("std");

/// Node representing an entity in the graph with ID and label.
pub const Node = struct {
    id: []const u8,
    label: []const u8,
};

/// Edge representing a directed relationship between two nodes.
pub const Edge = struct {
    from: []const u8, // Source node ID
    to: []const u8, // Target node ID
    relation: []const u8, // Type of relationship
};

/// In-memory graph database storing nodes and edges.
pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(Node),
    edges: std.ArrayListUnmanaged(Edge) = .{},

    /// Initialize an empty graph.
    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(Node).init(allocator),
        };
    }

    /// Free all nodes, edges, and the graph itself.
    pub fn deinit(self: *Graph) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.label);
        }
        self.nodes.deinit();

        for (self.edges.items) |edge| {
            self.allocator.free(edge.from);
            self.allocator.free(edge.to);
            self.allocator.free(edge.relation);
        }
        self.edges.deinit(self.allocator);
    }

    /// Add a node with the given ID and label.
    pub fn add_node(self: *Graph, id: []const u8, label: []const u8) !void {
        if (self.nodes.contains(id)) return;
        try self.nodes.put(try self.allocator.dupe(u8, id), .{
            .id = try self.allocator.dupe(u8, id),
            .label = try self.allocator.dupe(u8, label),
        });
    }

    /// Add a directed edge between two nodes with the given relation.
    pub fn add_edge(self: *Graph, from: []const u8, to: []const u8, relation: []const u8) !void {
        try self.edges.append(self.allocator, .{
            .from = try self.allocator.dupe(u8, from),
            .to = try self.allocator.dupe(u8, to),
            .relation = try self.allocator.dupe(u8, relation),
        });
    }

    /// Query the graph for relations starting from the given node.
    pub fn query(self: *Graph, start_node: []const u8) ![]const u8 {
        var out = std.io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        try out.writer.print("Graph context for node: {s}\n", .{start_node});

        var found = false;
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.from, start_node)) {
                try out.writer.print("- {s} --[{s}]--> {s}\n", .{ edge.from, edge.relation, edge.to });
                found = true;
            } else if (std.mem.eql(u8, edge.to, start_node)) {
                try out.writer.print("- {s} --[{s}]--> {s}\n", .{ edge.from, edge.relation, edge.to });
                found = true;
            }
        }

        if (!found) {
            try out.writer.print("No relations found for {s}\n", .{start_node});
        }

        return out.toOwnedSlice();
    }

    pub fn save(self: *Graph, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const export_data = struct {
            nodes: []Node,
            edges: []Edge,
        }{
            .nodes = try self.allocator.alloc(Node, self.nodes.count()),
            .edges = self.edges.items,
        };
        defer self.allocator.free(export_data.nodes);

        var i: usize = 0;
        var iter = self.nodes.valueIterator();
        while (iter.next()) |node| {
            export_data.nodes[i] = node.*;
            i += 1;
        }

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(export_data, .{}, &out.writer);
        try file.writeAll(out.written());
    }

    pub fn load(self: *Graph, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 104857600); // 100 * 1024 * 1024
        defer self.allocator.free(content);

        const ImportData = struct {
            nodes: []Node,
            edges: []Edge,
        };
        const parsed = try std.json.parseFromSlice(ImportData, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value.nodes) |node| {
            try self.add_node(node.id, node.label);
        }
        for (parsed.value.edges) |edge| {
            try self.add_edge(edge.from, edge.to, edge.relation);
        }
    }
};

test "Graph: add nodes and query" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    try g.add_node("user", "Person");
    try g.add_node("bot", "Agent");
    try g.add_edge("user", "bot", "talks_to");

    // Test duplicate node (should be ignored)
    try g.add_node("user", "Duplicate");
    try std.testing.expectEqual(@as(usize, 2), g.nodes.count());
    const user_node = g.nodes.get("user").?;
    try std.testing.expectEqualStrings("Person", user_node.label);

    const result = try g.query("user");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "talks_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bot") != null);

    // Test reverse query
    const bot_result = try g.query("bot");
    defer allocator.free(bot_result);
    try std.testing.expect(std.mem.indexOf(u8, bot_result, "talks_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, bot_result, "user") != null);
}

test "Graph: query non-existent" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    const result = try g.query("none");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "No relations found for none") != null);
}

test "Graph: save and load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "graph_test.json" });
    defer allocator.free(file_path);

    {
        var g = Graph.init(allocator);
        defer g.deinit();
        try g.add_node("A", "Node");
        try g.add_node("B", "Node");
        try g.add_node("C", "Node");
        try g.add_edge("A", "B", "points");
        try g.add_edge("B", "C", "points_to");
        try g.save(file_path);
    }

    {
        var g = Graph.init(allocator);
        defer g.deinit();
        try g.load(file_path);
        try std.testing.expectEqual(@as(usize, 3), g.nodes.count());
        try std.testing.expectEqual(@as(usize, 2), g.edges.items.len);
        try std.testing.expect(std.mem.eql(u8, g.edges.items[0].relation, "points") or std.mem.eql(u8, g.edges.items[1].relation, "points"));
        try std.testing.expect(std.mem.eql(u8, g.edges.items[0].relation, "points_to") or std.mem.eql(u8, g.edges.items[1].relation, "points_to"));
    }
}

test "Graph: complex relations" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    try g.add_node("A", "TypeA");
    try g.add_node("B", "TypeB");
    try g.add_node("C", "TypeC");

    try g.add_edge("A", "B", "rel1");
    try g.add_edge("B", "C", "rel2");
    try g.add_edge("C", "A", "rel3");

    const res_a = try g.query("A");
    defer allocator.free(res_a);
    try std.testing.expect(std.mem.indexOf(u8, res_a, "rel1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_a, "rel3") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_a, "rel2") == null);

    const res_b = try g.query("B");
    defer allocator.free(res_b);
    try std.testing.expect(std.mem.indexOf(u8, res_b, "rel1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_b, "rel2") != null);
}

test "Graph: add duplicate node" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    try g.add_node("A", "TypeA");
    try g.add_node("A", "TypeA"); // Should not error, just skip

    try std.testing.expectEqual(@as(usize, 1), g.nodes.count());
}

test "Graph: query non-existent node" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    try g.add_node("A", "TypeA");
    try g.add_edge("A", "B", "rel1");

    const res = try g.query("Z");
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "No relations found") != null);
}

test "Graph: Node struct" {
    const node = Node{
        .id = "node1",
        .label = "Person",
    };
    try std.testing.expectEqualStrings("node1", node.id);
    try std.testing.expectEqualStrings("Person", node.label);
}

test "Graph: Edge struct" {
    const edge = Edge{
        .from = "A",
        .to = "B",
        .relation = "knows",
    };
    try std.testing.expectEqualStrings("A", edge.from);
    try std.testing.expectEqualStrings("B", edge.to);
    try std.testing.expectEqualStrings("knows", edge.relation);
}

test "Graph: init and deinit empty" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 0), g.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), g.edges.items.len);
}
