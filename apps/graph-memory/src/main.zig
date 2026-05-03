const std = @import("std");

const memory = @import("memory");
const graph = memory.graph;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);

    var graph_memory = graph.GraphMemory.init(allocator);
    defer graph_memory.deinit();

    std.debug.print("=== Graph Memory CLI ===\nCommands: add-entity, add-rel, list-entities, list-relationships, find, stats, demo\n\n", .{});

    if (args.len < 2) {
        try runDemo(allocator, &graph_memory);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "add-entity")) {
        if (args.len < 3) {
            std.debug.print("Usage: add-entity <label> [key=value...]\n", .{});
            return;
        }
        const label = args[2];

        var props = std.StringHashMap([]const u8).init(allocator);
        defer props.deinit();

        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const pair = args[i];
            if (std.mem.find(u8, pair, "=")) |idx| {
                const key = pair[0..idx];
                const value = pair[idx + 1 ..];
                try props.put(key, value);
            }
        }

        const entity = try graph_memory.addEntity(label, props);
        std.debug.print("Added entity: {s} (id: {s})\n", .{ entity.label, entity.id });
    } else if (std.mem.eql(u8, command, "add-rel")) {
        if (args.len < 5) {
            std.debug.print("Usage: add-rel <source_id> <target_id> <type> [key=value...]\n", .{});
            return;
        }
        const source_id = args[2];
        const target_id = args[3];
        const rel_type = args[4];

        var props = std.StringHashMap([]const u8).init(allocator);
        defer props.deinit();

        var i: usize = 5;
        while (i < args.len) : (i += 1) {
            const pair = args[i];
            if (std.mem.find(u8, pair, "=")) |idx| {
                const key = pair[0..idx];
                const value = pair[idx + 1 ..];
                try props.put(key, value);
            }
        }

        const rel = try graph_memory.addRelationship(source_id, target_id, rel_type, props);
        std.debug.print("Added relationship: {s} -> {s} ({s})\n", .{ source_id, target_id, rel.relation_type });
    } else if (std.mem.eql(u8, command, "list-entities")) {
        const entities = graph_memory.getAllEntities();
        std.debug.print("Entities ({d}):\n", .{entities.len});
        for (entities) |entity| {
            std.debug.print("  [{s}] {s}\n", .{ entity.id, entity.label });
            var iter = entity.properties.iterator();
            while (iter.next()) |entry| {
                std.debug.print("    {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    } else if (std.mem.eql(u8, command, "list-relationships")) {
        const relations = graph_memory.getAllRelationships();
        std.debug.print("Relationships ({d}):\n", .{relations.len});
        for (relations) |rel| {
            std.debug.print("  [{s}] {s} --[{s}]--> {s}\n", .{ rel.id, rel.source_id, rel.relation_type, rel.target_id });
        }
    } else if (std.mem.eql(u8, command, "find")) {
        if (args.len < 3) {
            std.debug.print("Usage: find <label>\n", .{});
            return;
        }
        const label = args[2];
        const entities = try graph_memory.findEntitiesByLabel(label);

        std.debug.print("Found {d} entities with label '{s}':\n", .{ entities.items.len, label });
        for (entities.items) |entity| {
            std.debug.print("  [{s}] {s}\n", .{ entity.id, entity.label });
        }
    } else if (std.mem.eql(u8, command, "stats")) {
        std.debug.print("Graph Stats:\n  Entities: {d}\n", .{graph_memory.countEntities()});
        std.debug.print("  Relationships: {d}\n", .{graph_memory.countRelationships()});
    } else if (std.mem.eql(u8, command, "demo")) {
        try runDemo(allocator, &graph_memory);
    } else {
        std.debug.print("Unknown command: {s}\nAvailable: add-entity, add-rel, list-entities, list-relationships, find, stats, demo\n", .{command});
    }
}

fn runDemo(allocator: std.mem.Allocator, graph_memory: *graph.GraphMemory) !void {
    std.debug.print("\n=== Running Demo ===\n\n", .{});

    var alice_props = std.StringHashMap([]const u8).init(allocator);
    defer alice_props.deinit();
    try alice_props.put("name", "Alice");
    try alice_props.put("age", "30");

    const alice = try graph_memory.addEntity("person", alice_props);
    std.debug.print("Added: {s} (id: {s})\n", .{ alice.label, alice.id });

    var bob_props = std.StringHashMap([]const u8).init(allocator);
    defer bob_props.deinit();
    try bob_props.put("name", "Bob");
    try bob_props.put("age", "25");

    const bob = try graph_memory.addEntity("person", bob_props);
    std.debug.print("Added: {s} (id: {s})\n", .{ bob.label, bob.id });

    var charlie_props = std.StringHashMap([]const u8).init(allocator);
    defer charlie_props.deinit();
    try charlie_props.put("name", "Charlie");
    try charlie_props.put("role", "Engineer");

    const charlie = try graph_memory.addEntity("person", charlie_props);
    std.debug.print("Added: {s} (id: {s})\n", .{ charlie.label, charlie.id });

    _ = try graph_memory.addRelationship(alice.id, bob.id, "knows", null);
    std.debug.print("Added relationship: Alice knows Bob\n", .{});

    _ = try graph_memory.addRelationship(bob.id, charlie.id, "works_with", null);
    std.debug.print("Added relationship: Bob works with Charlie\n", .{});

    _ = try graph_memory.addRelationship(alice.id, charlie.id, "knows", null);
    std.debug.print("Added relationship: Alice knows Charlie\n", .{});

    var san_francisco_props = std.StringHashMap([]const u8).init(allocator);
    defer san_francisco_props.deinit();
    try san_francisco_props.put("country", "USA");

    const sf = try graph_memory.addEntity("city", san_francisco_props);
    std.debug.print("Added: {s} (id: {s})\n", .{ sf.label, sf.id });

    _ = try graph_memory.addRelationship(alice.id, sf.id, "lives_in", null);
    std.debug.print("Added relationship: Alice lives in San Francisco\n", .{});

    _ = try graph_memory.addRelationship(bob.id, sf.id, "lives_in", null);
    std.debug.print("Added relationship: Bob lives in San Francisco\n", .{});

    std.debug.print("\n--- Entities ---\n", .{});
    const entities = graph_memory.getAllEntities();
    for (entities) |entity| {
        std.debug.print("[{s}] {s}\n", .{ entity.id, entity.label });
        var iter = entity.properties.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    std.debug.print("\n--- Relationships ---\n", .{});
    const relations = graph_memory.getAllRelationships();
    for (relations) |rel| {
        std.debug.print("{s} --[{s}]--> {s}\n", .{ rel.source_id, rel.relation_type, rel.target_id });
    }

    std.debug.print("\n--- Find 'person' entities ---\n", .{});
    const persons = try graph_memory.findEntitiesByLabel("person");
    for (persons.items) |person| {
        std.debug.print("[{s}] {s}\n", .{ person.id, person.label });
    }

    std.debug.print("\n--- Stats ---\nTotal entities: {d}\n", .{graph_memory.countEntities()});
    std.debug.print("Total relationships: {d}\n\n--- Entities connected to Alice ---\n", .{graph_memory.countRelationships()});

    const from_alice = graph_memory.getRelationshipsFrom(alice.id);
    for (from_alice.items) |rel| {
        std.debug.print("Alice --[{s}]--> {s}\n", .{ rel.relation_type, rel.target_id });
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
