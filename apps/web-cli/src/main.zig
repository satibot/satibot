//! Web CLI Agent - Browser automation using PinchTab skill
const std = @import("std");
const core = @import("core");

const Main = @This();

allocator: std.mem.Allocator,
config: core.config.Config,
pinchtab_path: []const u8,

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    var config_parsed = try core.config.load(allocator);
    defer config_parsed.deinit();
    const config = config_parsed.value;

    var web_cli = try Main.init(allocator, config);
    defer web_cli.deinit();

    try web_cli.run(args[1..]);
}

pub fn init(allocator: std.mem.Allocator, config: core.config.Config) !Main {
    const pinchtab_path = std.process.getEnvVarOwned(allocator, "PINCHTAB_PATH") catch {
        const self: Main = .{
            .allocator = allocator,
            .config = config,
            .pinchtab_path = "pinchtab",
        };
        return self;
    };

    const self: Main = .{
        .allocator = allocator,
        .config = config,
        .pinchtab_path = if (pinchtab_path.len == 0) "pinchtab" else pinchtab_path,
    };
    return self;
}

pub fn deinit(self: *Main) void {
    if (self.pinchtab_path.len > 0 and !std.mem.eql(u8, self.pinchtab_path, "pinchtab")) {
        self.allocator.free(self.pinchtab_path);
    }
    self.* = undefined;
}

pub fn run(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        try printUsage();
        return;
    }

    const command = args[0];

    if (std.mem.eql(u8, command, "help")) {
        try printUsage();
    } else if (std.mem.eql(u8, command, "launch")) {
        try self.launchInstance(args[1..]);
    } else if (std.mem.eql(u8, command, "instances")) {
        try self.listInstances();
    } else if (std.mem.eql(u8, command, "nav")) {
        try self.navigate(args[1..]);
    } else if (std.mem.eql(u8, command, "snap")) {
        try self.snapshot(args[1..]);
    } else if (std.mem.eql(u8, command, "click")) {
        try self.click(args[1..]);
    } else if (std.mem.eql(u8, command, "type")) {
        try self.typeText(args[1..]);
    } else if (std.mem.eql(u8, command, "fill")) {
        try self.fill(args[1..]);
    } else if (std.mem.eql(u8, command, "text")) {
        try self.extractText(args[1..]);
    } else if (std.mem.eql(u8, command, "screenshot") or std.mem.eql(u8, command, "ss")) {
        try self.screenshot(args[1..]);
    } else if (std.mem.eql(u8, command, "eval")) {
        try self.evaluate(args[1..]);
    } else if (std.mem.eql(u8, command, "stop")) {
        try self.stopInstance(args[1..]);
    } else if (std.mem.eql(u8, command, "workflow")) {
        try self.runWorkflow(args[1..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn printUsage() !void {
    const help_text =
        \\🌐 Web CLI - Browser Automation with PinchTab
        \\
        \\USAGE:
        \\  sati web <command> [options] [args...]
        \\  s-web-cli <command> [options] [args...]
        \\
        \\INSTANCE MANAGEMENT:
        \\  launch [--mode headed] [--port <port>]  Launch browser instance
        \\  instances                              List all instances
        \\  stop <instance_id>                     Stop specific instance
        \\
        \\BROWSER CONTROL:
        \\  nav <url> [--instance <id>]           Navigate to URL
        \\  snap [-i] [-c] [-d] [--instance <id>] Take page snapshot
        \\  click <element_ref> [--instance <id>] Click element
        \\  type <element_ref> <text> [--instance <id>] Type text (with events)
        \\  fill <element_ref> <value> [--instance <id>] Fill input (no events)
        \\
        \\DATA EXTRACTION:
        \\  text [--raw] [--instance <id>]        Extract text content
        \\  screenshot [-o <file>] [--instance <id>] Take screenshot
        \\  eval <javascript> [--instance <id>]   Execute JavaScript
        \\
        \\WORKFLOWS:
        \\  workflow <workflow_file> [--instance <id>] Run workflow from JSON file
        \\
        \\EXAMPLES:
        \\  # Launch headed browser instance
        \\  sati web launch --mode headed
        \\
        \\  # Navigate and take snapshot
        \\  sati web nav https://example.com --instance inst_abc123
        \\  sati web snap -i -c --instance inst_abc123
        \\
        \\  # Click element and extract text
        \\  sati web click e5 --instance inst_abc123
        \\  sati web text --raw --instance inst_abc123
        \\
        \\  # Take screenshot
        \\  sati web screenshot -o result.png --instance inst_abc123
        \\
        \\For more information, see PinchTab documentation.
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}

fn launchInstance(self: *Main, args: []const []const u8) !void {
    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);
    try cmd_args.append(self.allocator, "instance");
    try cmd_args.append(self.allocator, "launch");

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--mode");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--port")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--port");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try self.executeCommand(cmd_args.items);
}

fn listInstances(self: *Main) !void {
    const cmd_args = [_][]const u8{ self.pinchtab_path, "instances" };
    try self.executeCommand(&cmd_args);
}

fn navigate(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati web nav <url> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    var url_idx: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--new-tab")) {
            try cmd_args.append(self.allocator, "--new-tab");
        } else if (std.mem.eql(u8, args[i], "--block-images")) {
            try cmd_args.append(self.allocator, "--block-images");
        } else {
            url_idx = i;
        }
    }

    if (url_idx == 0) {
        std.debug.print("URL is required\n", .{});
        return;
    }

    try cmd_args.append(self.allocator, "nav");
    try cmd_args.append(self.allocator, args[url_idx]);

    try self.executeCommand(cmd_args.items);
}

fn snapshot(self: *Main, args: []const []const u8) !void {
    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-i")) {
            try cmd_args.append(self.allocator, "-i");
        } else if (std.mem.eql(u8, args[i], "-c")) {
            try cmd_args.append(self.allocator, "-c");
        } else if (std.mem.eql(u8, args[i], "-d")) {
            try cmd_args.append(self.allocator, "-d");
        } else {
            std.debug.print("Unknown snapshot option: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "snap");

    try self.executeCommand(cmd_args.items);
}

fn click(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati web click <element_ref> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    const element_ref = args[0];

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "click");
    try cmd_args.append(self.allocator, element_ref);

    try self.executeCommand(cmd_args.items);
}

fn typeText(self: *Main, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: sati web type <element_ref> <text> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    const element_ref = args[0];
    const text = args[1];

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "type");
    try cmd_args.append(self.allocator, element_ref);
    try cmd_args.append(self.allocator, text);

    try self.executeCommand(cmd_args.items);
}

fn fill(self: *Main, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: sati web fill <element_ref> <value> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    const element_ref = args[0];
    const value = args[1];

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "fill");
    try cmd_args.append(self.allocator, element_ref);
    try cmd_args.append(self.allocator, value);

    try self.executeCommand(cmd_args.items);
}

fn extractText(self: *Main, args: []const []const u8) !void {
    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--raw")) {
            try cmd_args.append(self.allocator, "--raw");
        } else {
            std.debug.print("Unknown text option: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "text");

    try self.executeCommand(cmd_args.items);
}

fn screenshot(self: *Main, args: []const []const u8) !void {
    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "-o");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-q")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "-q");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown screenshot option: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "ss");

    try self.executeCommand(cmd_args.items);
}

fn evaluate(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati web eval <javascript> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    const javascript = args[0];

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "eval");
    try cmd_args.append(self.allocator, javascript);

    try self.executeCommand(cmd_args.items);
}

fn stopInstance(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati web stop <instance_id>\n", .{});
        return;
    }

    const instance_id = args[0];
    const cmd_args = [_][]const u8{ self.pinchtab_path, "instance", instance_id, "stop" };
    try self.executeCommand(&cmd_args);
}

fn runWorkflow(self: *Main, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: sati web workflow <workflow_file> [--instance <id>]\n", .{});
        return;
    }

    var cmd_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
    defer cmd_args.deinit(self.allocator);

    try cmd_args.append(self.allocator, self.pinchtab_path);

    const workflow_file = args[0];

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--instance")) {
            if (i + 1 < args.len) {
                try cmd_args.append(self.allocator, "--instance");
                try cmd_args.append(self.allocator, args[i + 1]);
                i += 1;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{args[i]});
            return;
        }
    }

    try cmd_args.append(self.allocator, "workflow");

    const workflow_content = try std.fs.cwd().readFileAlloc(self.allocator, workflow_file, 1048576);
    defer self.allocator.free(workflow_content);

    try self.executeCommandWithStdin(cmd_args.items, workflow_content);
}

fn executeCommand(self: *Main, args: []const []const u8) !void {
    var child = std.process.Child.init(args, self.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Failed to execute pinchtab command: {}\n", .{err});
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Command exited with code: {}\n", .{code});
            }
        },
        .Signal => |sig| {
            std.debug.print("Command killed by signal: {}\n", .{sig});
        },
        .Stopped => |sig| {
            std.debug.print("Command stopped by signal: {}\n", .{sig});
        },
        .Unknown => |code| {
            std.debug.print("Command terminated with unknown code: {}\n", .{code});
        },
    }
}

fn executeCommandWithStdin(self: *Main, args: []const []const u8, stdin_content: []const u8) !void {
    var child = std.process.Child.init(args, self.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| {
        std.debug.print("Failed to execute pinchtab command: {}\n", .{err});
        return;
    };

    try child.stdin.?.writeAll(stdin_content);
    child.stdin.?.close();

    const term = child.wait() catch |err| {
        std.debug.print("Failed to wait for command: {}\n", .{err});
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Command exited with code: {}\n", .{code});
            }
        },
        .Signal => |sig| {
            std.debug.print("Command killed by signal: {}\n", .{sig});
        },
        .Stopped => |sig| {
            std.debug.print("Command stopped by signal: {}\n", .{sig});
        },
        .Unknown => |code| {
            std.debug.print("Command terminated with unknown code: {}\n", .{code});
        },
    }
}
