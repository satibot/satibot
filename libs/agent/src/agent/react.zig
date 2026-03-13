//! ReAct Agent Implementation
//!
//! ReAct (Reasoning + Acting) is a prompting technique where the AI:
//! 1. Thinks about the problem (Thought)
//! 2. Takes an action (Action)
//! 3. Observes the result (Observation)
//! 4. Repeats until final answer

const std = @import("std");

pub const ReactStep = struct {
    thought: []const u8,
    action: ?[]const u8,
    action_input: ?[]const u8,
    observation: ?[]const u8,
    is_final: bool,
};

pub const ReactTrace = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(ReactStep),

    pub fn init(allocator: std.mem.Allocator) ReactTrace {
        return .{
            .allocator = allocator,
            .steps = .empty,
        };
    }

    pub fn deinit(self: *ReactTrace) void {
        for (self.steps.items) |step| {
            self.allocator.free(step.thought);
            if (step.action) |a| self.allocator.free(a);
            if (step.action_input) |ai| self.allocator.free(ai);
            if (step.observation) |o| self.allocator.free(o);
        }
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addStep(self: *ReactTrace, thought: []const u8, action: ?[]const u8, action_input: ?[]const u8, observation: ?[]const u8, is_final: bool) !void {
        const step: ReactStep = .{
            .thought = try self.allocator.dupe(u8, thought),
            .action = if (action) |a| try self.allocator.dupe(u8, a) else null,
            .action_input = if (action_input) |ai| try self.allocator.dupe(u8, ai) else null,
            .observation = if (observation) |o| try self.allocator.dupe(u8, o) else null,
            .is_final = is_final,
        };
        try self.steps.append(self.allocator, step);
    }

    pub fn printTrace(self: *ReactTrace) void {
        std.debug.print("\n=== ReAct Trace ===\n", .{});

        for (self.steps.items, 0..) |step, i| {
            std.debug.print("\nStep {d}:\n", .{i + 1});
            std.debug.print("  Thought: {s}\n", .{step.thought});

            if (step.action) |action| {
                std.debug.print("  Action: {s}\n", .{action});
            }
            if (step.action_input) |input| {
                std.debug.print("  Input: {s}\n", .{input});
            }
            if (step.observation) |obs| {
                std.debug.print("  Observation: {s}\n", .{obs});
            }
            if (step.is_final) {
                std.debug.print("  [FINAL]\n", .{});
            }
        }

        std.debug.print("\n======================\n", .{});
    }

    pub fn getSystemPrompt(allocator: std.mem.Allocator) ![]const u8 {
        return allocator.dupe(u8,
            \\You are a ReAct (Reasoning + Acting) agent.
            \\
            \\Your response MUST follow this format for each step:
            \\
            \\Thought: <your reasoning about what to do next>
            \\Action: <tool_name> (only if you need to use a tool)
            \\Action Input: <input to the tool> (only if Action is specified)
            \\Observation: <result of the action> (will be provided after action)
            \\
            \\After receiving an Observation, continue with your next Thought.
            \\
            \\When you have the final answer, respond with:
            \\
            \\Thought: I now have the answer
            \\Final Answer: <your complete answer>
            \\
            \\IMPORTANT:
            \\- Always show your reasoning in "Thought:" sections
            \\- Use tools only when necessary
            \\- Build upon previous observations
            \\- Be explicit about your reasoning process
        );
    }

    pub fn isFinalAnswer(content: []const u8) bool {
        return std.mem.indexOf(u8, content, "Final Answer:") != null;
    }

    pub fn parseSteps(self: *ReactTrace, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_thought: std.ArrayList(u8) = .empty;
        defer current_thought.deinit(self.allocator);

        var current_action: ?[]const u8 = null;
        var current_input: ?[]const u8 = null;
        defer {
            if (current_action) |a| self.allocator.free(a);
            if (current_input) |i| self.allocator.free(i);
        }

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (std.mem.startsWith(u8, trimmed, "Thought:")) {
                if (current_thought.items.len > 0) {
                    try self.addStep(current_thought.items, current_action, current_input, null, false);
                    current_thought.clearRetainingCapacity();
                    current_action = null;
                    current_input = null;
                }
                try current_thought.appendSlice(self.allocator, trimmed["Thought:".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "Action:")) {
                if (current_thought.items.len > 0) {
                    try self.addStep(current_thought.items, null, null, null, false);
                    current_thought.clearRetainingCapacity();
                }
                current_action = try self.allocator.dupe(u8, trimmed["Action:".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "Action Input:")) {
                current_input = try self.allocator.dupe(u8, trimmed["Action Input:".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "Observation:")) {
                const observation = trimmed["Observation:".len..];
                try self.addStep(
                    if (current_thought.items.len > 0) current_thought.items else "",
                    current_action,
                    current_input,
                    observation,
                    false,
                );
                current_thought.clearRetainingCapacity();
                current_action = null;
                current_input = null;
            } else if (current_thought.items.len > 0) {
                try current_thought.appendSlice(self.allocator, "\n");
                try current_thought.appendSlice(self.allocator, trimmed);
            }
        }

        if (current_thought.items.len > 0) {
            const is_final = isFinalAnswer(current_thought.items);
            try self.addStep(current_thought.items, current_action, current_input, null, is_final);
        }
    }
};

pub fn getSystemPrompt(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8,
        \\You are a ReAct (Reasoning + Acting) agent.
        \\
        \\Your response MUST follow this format for each step:
        \\
        \\Thought: <your reasoning about what to do next>
        \\Action: <tool_name> (only if you need to use a tool)
        \\Action Input: <input to the tool> (only if Action is specified)
        \\Observation: <result of the action> (will be provided after action)
        \\
        \\After receiving an Observation, continue with your next Thought.
        \\
        \\When you have the final answer, respond with:
        \\
        \\Thought: I now have the answer
        \\Final Answer: <your complete answer>
        \\
        \\IMPORTANT:
        \\- Always show your reasoning in "Thought:" sections
        \\- Use tools only when necessary
        \\- Build upon previous observations
        \\- Be explicit about your reasoning process
    );
}

pub fn runReactAgent(
    allocator: std.mem.Allocator,
    config: anytype,
    message: []const u8,
    session_id: []const u8,
    use_rag: bool,
) !void {
    _ = config;
    _ = session_id;
    _ = use_rag;

    std.debug.print("\n=== ReAct Agent ===\n", .{});
    std.debug.print("Message: {s}\n\n", .{message});

    var trace = ReactTrace.init(allocator);
    defer trace.deinit();

    const prompt = try getSystemPrompt(allocator);
    defer allocator.free(prompt);

    std.debug.print("ReAct System Prompt:\n{s}\n\n", .{prompt});

    std.debug.print("Note: Full ReAct loop requires LLM integration.\n", .{});
    std.debug.print("This shows the ReAct trace parsing capability.\n", .{});

    const example_response =
        \\Thought: I need to understand the project structure to answer this question.
        \\Action: run_command
        \\Action Input: ls -la
        \\Observation: Total 64 items in directory
        \\
        \\Thought: Now I have the directory listing. Let me check the main source files.
        \\Action: read_file
        \\Action Input: src/main.zig
        \\Observation: File contains 200 lines of Zig code
        \\
        \\Thought: I now have enough context to provide an answer.
        \\Final Answer: The project has 64 items in the root directory and main.zig contains 200 lines of Zig code.
    ;

    try trace.parseSteps(example_response);
    trace.printTrace();

    std.debug.print("\n✅ ReAct demonstration complete!\n", .{});
}

test "ReactTrace: init and deinit" {
    const allocator = std.testing.allocator;
    var trace = ReactTrace.init(allocator);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.steps.items.len);
}

test "ReactTrace: addStep" {
    const allocator = std.testing.allocator;
    var trace = ReactTrace.init(allocator);
    defer trace.deinit();

    try trace.addStep("I need to read a file", "read_file", "test.zig", null, false);
    try std.testing.expectEqual(@as(usize, 1), trace.steps.items.len);

    const step = trace.steps.items[0];
    try std.testing.expectEqualStrings("I need to read a file", step.thought);
    try std.testing.expectEqualStrings("read_file", step.action.?);
    try std.testing.expectEqualStrings("test.zig", step.action_input.?);
}

test "ReactTrace: isFinalAnswer" {
    try std.testing.expect(ReactTrace.isFinalAnswer("Final Answer: The answer is 42"));
    try std.testing.expect(!ReactTrace.isFinalAnswer("Let me think about this"));
}

test "ReactTrace: parseSteps - simple" {
    const allocator = std.testing.allocator;
    var trace = ReactTrace.init(allocator);
    defer trace.deinit();

    const content = "Thought: Test thought";

    try trace.parseSteps(content);

    try std.testing.expectEqual(@as(usize, 1), trace.steps.items.len);
}
