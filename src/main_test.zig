const std = @import("std");
const main = @import("main.zig");

test "Skill: extract description from SKILL.md" {
    const content =
        \\---
        \\name: test-skill
        \\description: This is a test skill for unit testing
        \\---
        \\
        \\# Test Skill
        \\
        \\This is the full content.
    ;

    const description = main.extractSkillDescription(content);
    try std.testing.expectEqualStrings("This is a test skill for unit testing", description);
}

test "Skill: extract description with dash prefix" {
    const content =
        \\---
        \\name: test-skill
        \\description: - Another test description
        \\---
    ;

    const description = main.extractSkillDescription(content);
    try std.testing.expectEqualStrings("Another test description", description);
}

test "Skill: extract description returns empty when not found" {
    const content =
        \\# Just a title
        \\
        \\Some content without description field.
    ;

    const description = main.extractSkillDescription(content);
    try std.testing.expectEqualStrings("", description);
}

test "Rule: first line extraction" {
    const content =
        \\# Zig Naming Conventions
        \\This rule explains naming conventions for Zig code.
    ;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    const first_line = line_iter.first();
    try std.testing.expectEqualStrings("# Zig Naming Conventions", first_line);
}
