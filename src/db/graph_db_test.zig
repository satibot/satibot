const std = @import("std");
const graph_db = @import("graph_db.zig");

test "Node: struct creation and access" {
    const node = graph_db.Node{
        .id = "user_123",
        .label = "Person",
    };

    try std.testing.expectEqualStrings("user_123", node.id);
    try std.testing.expectEqualStrings("Person", node.label);
}

test "Node: empty strings" {
    const node = graph_db.Node{
        .id = "",
        .label = "",
    };

    try std.testing.expectEqualStrings("", node.id);
    try std.testing.expectEqualStrings("", node.label);
}

test "Edge: struct creation and access" {
    const edge = graph_db.Edge{
        .from = "node_a",
        .to = "node_b",
        .relation = "connected_to",
    };

    try std.testing.expectEqualStrings("node_a", edge.from);
    try std.testing.expectEqualStrings("node_b", edge.to);
    try std.testing.expectEqualStrings("connected_to", edge.relation);
}

test "Edge: self-referencing" {
    const edge = graph_db.Edge{
        .from = "self_node",
        .to = "self_node",
        .relation = "references",
    };

    try std.testing.expectEqualStrings("self_node", edge.from);
    try std.testing.expectEqualStrings("self_node", edge.to);
    try std.testing.expectEqualStrings("references", edge.relation);
}

test "Graph: init empty graph" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 0), graph.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(allocator, graph.allocator);
}

test "Graph: add single node" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("test_node", "TestLabel");

    try std.testing.expectEqual(@as(usize, 1), graph.nodes.count());

    const node = graph.nodes.get("test_node").?;
    try std.testing.expectEqualStrings("test_node", node.id);
    try std.testing.expectEqualStrings("TestLabel", node.label);
}

test "Graph: add multiple nodes" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("node1", "Label1");
    try graph.add_node("node2", "Label2");
    try graph.add_node("node3", "Label3");

    try std.testing.expectEqual(@as(usize, 3), graph.nodes.count());

    try std.testing.expectEqualStrings("Label1", graph.nodes.get("node1").?.label);
    try std.testing.expectEqualStrings("Label2", graph.nodes.get("node2").?.label);
    try std.testing.expectEqualStrings("Label3", graph.nodes.get("node3").?.label);
}

test "Graph: add duplicate node should not overwrite" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("duplicate", "OriginalLabel");
    try graph.add_node("duplicate", "NewLabel"); // Should be ignored

    try std.testing.expectEqual(@as(usize, 1), graph.nodes.count());
    try std.testing.expectEqualStrings("OriginalLabel", graph.nodes.get("duplicate").?.label);
}

test "Graph: add single edge" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("from_node", "From");
    try graph.add_node("to_node", "To");
    try graph.add_edge("from_node", "to_node", "test_relation");

    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);

    const edge = graph.edges.items[0];
    try std.testing.expectEqualStrings("from_node", edge.from);
    try std.testing.expectEqualStrings("to_node", edge.to);
    try std.testing.expectEqualStrings("test_relation", edge.relation);
}

test "Graph: add multiple edges" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("A", "NodeA");
    try graph.add_node("B", "NodeB");
    try graph.add_node("C", "NodeC");

    try graph.add_edge("A", "B", "rel1");
    try graph.add_edge("B", "C", "rel2");
    try graph.add_edge("A", "C", "rel3");

    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);
}

test "Graph: query node with outgoing edges" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("source", "SourceNode");
    try graph.add_node("target1", "Target1");
    try graph.add_node("target2", "Target2");

    try graph.add_edge("source", "target1", "connects_to");
    try graph.add_edge("source", "target2", "relates_to");

    const result = try graph.query("source");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "source") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "connects_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "relates_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "target1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "target2") != null);
}

test "Graph: query node with incoming edges" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("target", "TargetNode");
    try graph.add_node("source1", "Source1");
    try graph.add_node("source2", "Source2");

    try graph.add_edge("source1", "target", "points_to");
    try graph.add_edge("source2", "target", "references");

    const result = try graph.query("target");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "target") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "points_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "references") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source2") != null);
}

test "Graph: query node with both incoming and outgoing edges" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("middle", "MiddleNode");
    try graph.add_node("before", "BeforeNode");
    try graph.add_node("after", "AfterNode");

    try graph.add_edge("before", "middle", "precedes");
    try graph.add_edge("middle", "after", "follows");

    const result = try graph.query("middle");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "precedes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "follows") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "after") != null);
}

test "Graph: query non-existent node" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    const result = try graph.query("non_existent");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "No relations found for non_existent") != null);
}

test "Graph: query node with no relations" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("isolated", "IsolatedNode");

    const result = try graph.query("isolated");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "No relations found for isolated") != null);
}

test "Graph: save and load functionality" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_graph.json" });
    defer allocator.free(file_path);

    // Create and save graph
    {
        var graph = graph_db.Graph.init(allocator);
        defer graph.deinit();

        try graph.add_node("saved_node1", "SavedType1");
        try graph.add_node("saved_node2", "SavedType2");
        try graph.add_edge("saved_node1", "saved_node2", "saved_relation");

        try graph.save(file_path);
    }

    // Load and verify graph
    {
        var graph = graph_db.Graph.init(allocator);
        defer graph.deinit();

        try graph.load(file_path);

        try std.testing.expectEqual(@as(usize, 2), graph.nodes.count());
        try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);

        try std.testing.expectEqualStrings("SavedType1", graph.nodes.get("saved_node1").?.label);
        try std.testing.expectEqualStrings("SavedType2", graph.nodes.get("saved_node2").?.label);
        try std.testing.expectEqualStrings("saved_relation", graph.edges.items[0].relation);
    }
}

test "Graph: load non-existent file" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    // This should not error, just do nothing
    try graph.load("/non/existent/path.json");

    try std.testing.expectEqual(@as(usize, 0), graph.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
}

test "Graph: complex graph with cycles" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    // Create a cycle: A -> B -> C -> A
    try graph.add_node("A", "NodeA");
    try graph.add_node("B", "NodeB");
    try graph.add_node("C", "NodeC");

    try graph.add_edge("A", "B", "to_b");
    try graph.add_edge("B", "C", "to_c");
    try graph.add_edge("C", "A", "to_a");

    // Each node should have one incoming and one outgoing edge
    const result_a = try graph.query("A");
    defer allocator.free(result_a);
    try std.testing.expect(std.mem.indexOf(u8, result_a, "to_b") != null); // outgoing
    try std.testing.expect(std.mem.indexOf(u8, result_a, "to_a") != null); // incoming

    const result_b = try graph.query("B");
    defer allocator.free(result_b);
    try std.testing.expect(std.mem.indexOf(u8, result_b, "to_b") != null); // incoming
    try std.testing.expect(std.mem.indexOf(u8, result_b, "to_c") != null); // outgoing
}

test "Graph: memory management verification" {
    const allocator = std.testing.allocator;

    // Create graph with many nodes and edges
    {
        var graph = graph_db.Graph.init(allocator);
        defer graph.deinit();

        // Add many nodes
        for (0..100) |i| {
            const node_id = try std.fmt.allocPrint(allocator, "node_{d}", .{i});
            defer allocator.free(node_id);
            const label = try std.fmt.allocPrint(allocator, "Label_{d}", .{i});
            defer allocator.free(label);

            try graph.add_node(node_id, label);
        }

        // Add many edges
        for (0..50) |i| {
            const from = try std.fmt.allocPrint(allocator, "node_{d}", .{i});
            defer allocator.free(from);
            const to = try std.fmt.allocPrint(allocator, "node_{d}", .{i + 1});
            defer allocator.free(to);
            const relation = try std.fmt.allocPrint(allocator, "rel_{d}", .{i});
            defer allocator.free(relation);

            try graph.add_edge(from, to, relation);
        }

        try std.testing.expectEqual(@as(usize, 100), graph.nodes.count());
        try std.testing.expectEqual(@as(usize, 50), graph.edges.items.len);
    }
    // If deinit works correctly, no memory leaks should occur
}

test "Graph: edge cases with empty strings" {
    const allocator = std.testing.allocator;
    var graph = graph_db.Graph.init(allocator);
    defer graph.deinit();

    try graph.add_node("", "EmptyId");
    try graph.add_node("empty_label", "");

    try graph.add_edge("", "empty_label", "empty_from");
    try graph.add_edge("empty_label", "", "empty_to");
    try graph.add_edge("empty_label", "empty_label", "");

    try std.testing.expectEqual(@as(usize, 2), graph.nodes.count());
    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);

    // Query with empty string should work
    const result = try graph.query("");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "empty_from") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "empty_to") != null);
}
