const std = @import("std");

const log = std.log.scoped(.graph_memory);

pub const Entity = struct {
    id: []const u8,
    label: []const u8,
    properties: std.StringHashMap([]const u8),
    created_at: i64,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        self.properties.deinit();
        self.* = undefined;
    }
};

pub const Relationship = struct {
    id: []const u8,
    source_id: []const u8,
    target_id: []const u8,
    relation_type: []const u8,
    properties: std.StringHashMap([]const u8),
    created_at: i64,

    pub fn deinit(self: *Relationship, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_id);
        allocator.free(self.target_id);
        allocator.free(self.relation_type);
        self.properties.deinit();
        self.* = undefined;
    }
};

pub const GraphMemory = struct {
    allocator: std.mem.Allocator,
    entities: std.StringHashMap(Entity),
    relationships: std.ArrayList(Relationship),
    entity_index: std.StringHashMap(std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator) GraphMemory {
        return .{
            .allocator = allocator,
            .entities = std.StringHashMap(Entity).init(allocator),
            .relationships = std.ArrayList(Relationship).initCapacity(allocator, 0) catch unreachable,
            .entity_index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *GraphMemory) void {
        var entity_iter = self.entities.iterator();
        while (entity_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entities.deinit();

        for (self.relationships.items) |*rel| {
            rel.deinit(self.allocator);
        }
        self.relationships.deinit(self.allocator);

        var index_iter = self.entity_index.iterator();
        while (index_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entity_index.deinit();
        self.* = undefined;
    }

    fn generateId(allocator: std.mem.Allocator) ![]const u8 {
        const timestamp = std.time.timestamp();
        var random: u32 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&random));
        return std.fmt.allocPrint(allocator, "{d}-{x}", .{ timestamp, random });
    }

    pub fn addEntity(self: *GraphMemory, label: []const u8, properties: ?std.StringHashMap([]const u8)) !Entity {
        const id = try GraphMemory.generateId(self.allocator);
        errdefer self.allocator.free(id);

        const id_copy = try self.allocator.dupe(u8, id);
        const label_copy = try self.allocator.dupe(u8, label);

        var props = std.StringHashMap([]const u8).init(self.allocator);
        if (properties) |p| {
            var iter = p.iterator();
            while (iter.next()) |entry| {
                const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
                try props.put(key_copy, value_copy);
            }
        }

        const entity: Entity = .{
            .id = id_copy,
            .label = label_copy,
            .properties = props,
            .created_at = std.time.timestamp(),
        };

        try self.entities.put(id_copy, entity);

        var index_list: std.ArrayList(usize) = .empty;
        try index_list.append(self.allocator, self.relationships.items.len);
        try self.entity_index.put(id_copy, index_list);

        return entity;
    }

    pub fn getEntity(self: *const GraphMemory, id: []const u8) ?*const Entity {
        return self.entities.get(id);
    }

    pub fn findEntitiesByLabel(self: *const GraphMemory, label: []const u8) !std.ArrayList(*const Entity) {
        var results: std.ArrayList(*const Entity) = .empty;

        var iter = self.entities.valueIterator();
        while (iter.next()) |entity| {
            if (std.mem.eql(u8, entity.label, label)) {
                try results.append(self.allocator, entity);
            }
        }

        return results;
    }

    pub fn addRelationship(
        self: *GraphMemory,
        source_id: []const u8,
        target_id: []const u8,
        relation_type: []const u8,
        properties: ?std.StringHashMap([]const u8),
    ) !Relationship {
        if (self.entities.get(source_id) == null) {
            return error.SourceEntityNotFound;
        }
        if (self.entities.get(target_id) == null) {
            return error.TargetEntityNotFound;
        }

        const id = try GraphMemory.generateId(self.allocator);
        errdefer self.allocator.free(id);

        const id_copy = try self.allocator.dupe(u8, id);
        const source_copy = try self.allocator.dupe(u8, source_id);
        const target_copy = try self.allocator.dupe(u8, target_id);
        const type_copy = try self.allocator.dupe(u8, relation_type);

        var props = std.StringHashMap([]const u8).init(self.allocator);
        if (properties) |p| {
            var iter = p.iterator();
            while (iter.next()) |entry| {
                const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
                try props.put(key_copy, value_copy);
            }
        }

        const relationship: Relationship = .{
            .id = id_copy,
            .source_id = source_copy,
            .target_id = target_copy,
            .relation_type = type_copy,
            .properties = props,
            .created_at = std.time.timestamp(),
        };

        try self.relationships.append(self.allocator, relationship);

        if (self.entity_index.getPtr(source_id)) |list| {
            list.append(self.allocator, self.relationships.items.len - 1) catch |err| {
                log.warn("Failed to append to entity index: {}", .{err});
            };
        }

        return relationship;
    }

    pub fn getRelationshipsFrom(self: *const GraphMemory, source_id: []const u8) std.ArrayList(*const Relationship) {
        var results: std.ArrayList(*const Relationship) = .empty;

        for (self.relationships.items) |rel| {
            if (std.mem.eql(u8, rel.source_id, source_id)) {
                results.append(self.allocator, &rel) catch |err| {
                    log.warn("Failed to append relationship: {}", .{err});
                };
            }
        }

        return results;
    }

    pub fn getRelationshipsTo(self: *const GraphMemory, target_id: []const u8) std.ArrayList(*const Relationship) {
        var results: std.ArrayList(*const Relationship) = .empty;

        for (self.relationships.items) |rel| {
            if (std.mem.eql(u8, rel.target_id, target_id)) {
                results.append(self.allocator, &rel) catch |err| {
                    log.warn("Failed to append relationship: {}", .{err});
                };
            }
        }

        return results;
    }

    pub fn getAllRelationships(self: *const GraphMemory) []Relationship {
        return self.relationships.items;
    }

    pub fn getAllEntities(self: *const GraphMemory) []Entity {
        var results: std.ArrayList(Entity) = .empty;
        defer results.deinit(self.allocator);

        var iter = self.entities.valueIterator();
        while (iter.next()) |entity| {
            results.append(self.allocator, entity.*) catch |err| {
                log.warn("Failed to append entity: {}", .{err});
            };
        }

        return results.toOwnedSlice(self.allocator) catch &[_]Entity{};
    }

    pub fn deleteEntity(self: *GraphMemory, id: []const u8) !bool {
        const entity = self.entities.get(id) orelse return false;

        var new_rels: std.ArrayList(Relationship) = .empty;
        for (self.relationships.items) |rel| {
            if (std.mem.eql(u8, rel.source_id, id) or std.mem.eql(u8, rel.target_id, id)) {
                rel.deinit(self.allocator);
                continue;
            }
            try new_rels.append(self.allocator, rel);
        }

        self.relationships.deinit(self.allocator);
        self.relationships = new_rels;

        entity.deinit(self.allocator);
        _ = self.entities.remove(id);

        return true;
    }

    pub fn countEntities(self: *const GraphMemory) usize {
        return self.entities.count();
    }

    pub fn countRelationships(self: *const GraphMemory) usize {
        return self.relationships.items.len;
    }
};

test "GraphMemory add and get entity" {
    const allocator = std.testing.allocator;
    var graph = GraphMemory.init(allocator);
    defer graph.deinit();

    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("name", "Alice");

    const entity = try graph.addEntity("person", props);
    defer entity.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, entity.label, "person"));
    try std.testing.expect(entity.properties.get("name") != null);
}

test "GraphMemory add relationship" {
    const allocator = std.testing.allocator;
    var graph = GraphMemory.init(allocator);
    defer graph.deinit();

    var props1 = std.StringHashMap([]const u8).init(allocator);
    defer props1.deinit();
    try props1.put("name", "Alice");

    const entity1 = try graph.addEntity("person", props1);
    defer entity1.deinit(allocator);

    var props2 = std.StringHashMap([]const u8).init(allocator);
    defer props2.deinit();
    try props2.put("name", "Bob");

    const entity2 = try graph.addEntity("person", props2);
    defer entity2.deinit(allocator);

    const rel = try graph.addRelationship(entity1.id, entity2.id, "knows", null);
    defer rel.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, rel.relation_type, "knows"));
}

test "GraphMemory find by label" {
    const allocator = std.testing.allocator;
    var graph = GraphMemory.init(allocator);
    defer graph.deinit();

    _ = try graph.addEntity("person", null);
    _ = try graph.addEntity("person", null);
    _ = try graph.addEntity("place", null);

    const persons = try graph.findEntitiesByLabel("person");
    defer persons.deinit(allocator);

    try std.testing.expect(persons.items.len == 2);
}
