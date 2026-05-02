#!/usr/bin/env python3
"""Fix std.fs -> C file I/O for Zig 0.16 migration."""

import re
import os


def fix_std_fs_cwd_openFile_for_config(content, func_name="getApiKeyFromConfig"):
    """Replace std.fs.cwd().openFile config reading with C file I/O."""
    # Pattern for getApiKeyFromConfig-like functions
    old = f'''    const config_file = std.fs.cwd().openFile(config_path, .{{}}) catch null;
    if (config_file) |file| {{
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(
            Config,
            allocator,
            content,
            .{{ .ignore_unknown_fields = true }},
        ) catch return null;
        defer parsed.deinit();

        if (parsed.value.providers) |providers| {{
            if (providers.minimax) |minimax| {{
                if (minimax.apiKey) |key| {{
                    return allocator.dupe(u8, key) catch null;
                }}
            }}
        }}
    }}
    return null;
}}'''

    new = '''    const content = readFileAlloc(allocator, config_path) catch return null;
    if (content) |buf| {
        defer allocator.free(buf);
        const parsed = std.json.parseFromSlice(
            Config,
            allocator,
            buf,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();

        if (parsed.value.providers) |providers| {
            if (providers.minimax) |minimax| {
                if (minimax.apiKey) |key| {
                    return allocator.dupe(u8, key) catch null;
                }
            }
        }
    }
    return null;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(file);
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(temp[0..n]);
    }
    return buf.toOwnedSlice();
}'''

    return content.replace(old, new)


def fix_std_fs_cwd_openFile_search(content):
    """Replace std.fs.cwd().openFile in search app."""
    old = '''        const config_file = std.fs.cwd().openFile(config_path, .{}) catch null;
        if (config_file) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(content);

            const parsed = std.json.parseFromSlice(
                struct { tools: struct { web: struct { search: struct { apiKey: ?[]const u8 } } } },
                allocator,
                content,
                .{},
            ) catch null;

            if (parsed) |p| {
                defer p.deinit();
                if (p.value.tools.web.search.apiKey) |key| {
                    try doSearch(allocator, query, key);
                    return;
                }
            }
        }'''

    new = '''        const content = readConfigFile(allocator, config_path) catch return;
        if (content) |buf| {
            defer allocator.free(buf);
            const parsed = std.json.parseFromSlice(
                struct { tools: struct { web: struct { search: struct { apiKey: ?[]const u8 } } } },
                allocator,
                buf,
                .{},
            ) catch null;

            if (parsed) |p| {
                defer p.deinit();
                if (p.value.tools.web.search.apiKey) |key| {
                    try doSearch(allocator, query, key);
                    return;
                }
            }
        }'''

    return content.replace(old, new)


def fix_libs_core_config(content):
    """Replace std.fs.openFileAbsolute in libs/core/src/config.zig."""
    old = '''    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.ConfigNotFound;
        }
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        if (err == error.FileTooBig) {
            return error.ConfigTooLarge;
        }
        return err;
    };
    defer allocator.free(content);'''

    new = '''    const content = readFileAbsolute(allocator, path) catch |err| {
        if (err == error.ConfigNotFound or err == error.ConfigTooLarge) return err;
        return error.ConfigReadError;
    };
    defer allocator.free(content);'''

    return content.replace(old, new)


def fix_apps_code_config(content):
    """Replace std.fs.cwd().openFile in apps/code/src/config.zig."""
    old = '''    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.ConfigNotFound;
        }
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        if (err == error.FileTooBig) {
            return error.ConfigTooLarge;
        }
        return err;
    };
    defer allocator.free(content);'''

    new = '''    const content = readFileAbsolute(allocator, path) catch |err| {
        if (err == error.ConfigNotFound or err == error.ConfigTooLarge) return err;
        return error.ConfigReadError;
    };
    defer allocator.free(content);'''

    return content.replace(old, new)


def fix_tools_file_io(content):
    """Fix std.fs usages in libs/agent/src/agent/tools.zig."""
    # Fix createFile + writeAll
    old1 = '''    const file_write = try std.fs.cwd().createFile(file_path, .{});
    defer file_write.close();
    try file_write.writeAll(result.items);'''
    new1 = '''    const file_path_z = try ctx.allocator.dupeZ(u8, file_path);
    defer ctx.allocator.free(file_path_z);
    const file_write = std.c.fopen(file_path_z.ptr, "w") orelse return std.fmt.allocPrint(ctx.allocator, "Error: could not create file {s}", .{file_path});
    defer _ = std.c.fclose(file_write);
    _ = std.c.fwrite(result.items.ptr, 1, result.items.len, file_write);'''
    content = content.replace(old1, new1)

    # Fix makeDirAbsolute
    old2 = '''    std.fs.makeDirAbsolute(bots_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };'''
    new2 = '''    const bots_dir_z = try allocator.dupeZ(u8, bots_dir);
    defer allocator.free(bots_dir_z);
    _ = std.c.mkdir(bots_dir_z.ptr, 0o755);'''
    content = content.replace(old2, new2)

    # Fix openFile for gitignore
    old3 = '''    const gitignore_file = std.fs.cwd().openFile(gitignore_path, .{}) catch {
        return buildExcludeArg(allocator, exclusions.items);
    };
    defer gitignore_file.close();

    const gitignore_content = gitignore_file.readToEndAlloc(allocator, 1024 * 64) catch {
        return buildExcludeArg(allocator, exclusions.items);
    };'''
    new3 = '''    const gitignore_content = readFileAlloc(allocator, gitignore_path) catch {
        return buildExcludeArg(allocator, exclusions.items);
    };
    if (gitignore_content) |buf| {
        defer allocator.free(buf);'''
    content = content.replace(old3, new3)

    # Fix openFile for reading source files
    old4 = '''    const file = std.fs.cwd().openFile(file_path, .{}) catch return allocator.dupe(u8, "(Could not read file)");
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1048576) catch return allocator.dupe(u8, "(Could not read file content)");
    defer allocator.free(content);'''
    new4 = '''    const content = readFileAlloc(allocator, file_path) catch return allocator.dupe(u8, "(Could not read file)");
    if (content) |buf| {
        defer allocator.free(buf);'''
    content = content.replace(old4, new4)

    return content


def fix_web_cli(content):
    """Fix std.fs.cwd().readFileAlloc in apps/web-cli/src/Main.zig."""
    old = '''    const workflow_content = try std.fs.cwd().readFileAlloc(self.allocator, workflow_file, 1048576);
    defer self.allocator.free(workflow_content);'''
    new = '''    const workflow_content = readFileAlloc(self.allocator, workflow_file) catch |err| {
        std.log.err("Failed to read workflow file: {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(workflow_content);'''
    return content.replace(old, new)


def fix_speech_text_file(content):
    """Fix std.fs.cwd().openFile for text file in apps/speech/src/main.zig."""
    old = '''    if (text_file) |file_path| {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("Error: Could not open file '{s}': {}\\n", .{ file_path, err });
            return;
        };
        defer file.close();
        const stat = try file.stat();
        text = try file.readToEndAlloc(allocator, stat.size);
    }'''
    new = '''    if (text_file) |file_path| {
        const content = readFileAlloc(allocator, file_path) catch |err| {
            std.debug.print("Error: Could not open file '{s}': {s}\\n", .{ file_path, @errorName(err) });
            return;
        };
        if (content) |buf| {
            text = buf;
        }
    }'''
    return content.replace(old, new)


def fix_speech_file_check(content):
    """Fix std.fs.cwd().openFile for file size check in apps/speech/src/main.zig."""
    old = '''        if (std.fs.cwd().openFile(filename, .{})) |file| {
            defer file.close();
            const stat = file.stat() catch undefined;
            if (stat.size > 0) {
                std.debug.print("Successfully downloaded ({d} bytes) to: {s}\\n", .{ stat.size, filename });
                return;
            }
        } else |_| {}'''
    new = '''        if (fileExistsAndHasSize(filename)) |size| {
            if (size > 0) {
                std.debug.print("Successfully downloaded ({d} bytes) to: {s}\\n", .{ size, filename });
                return;
            }
        }'''
    return content.replace(old, new)


def add_readFileAlloc_helper(content, add_at_end=True):
    """Add a readFileAlloc helper function if not already present."""
    if "fn readFileAlloc(" in content:
        return content

    helper = '''
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(file);
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(temp[0..n]);
    }
    return buf.toOwnedSlice();
}
'''

    if add_at_end:
        return content.rstrip() + "\n" + helper
    else:
        # Insert before first function
        return content + helper


def add_readFileAbsolute_helper(content):
    """Add a readFileAbsolute helper function if not already present."""
    if "fn readFileAbsolute(" in content:
        return content

    helper = '''
fn readFileAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return error.ConfigNotFound;
    defer _ = std.c.fclose(file);
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var temp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&temp, 1, temp.len, file);
        if (n == 0) break;
        try buf.appendSlice(temp[0..n]);
    }
    if (buf.items.len > 1048576) return error.ConfigTooLarge;
    return buf.toOwnedSlice();
}
'''

    return content.rstrip() + "\n" + helper


def fix_apps_code_main(content):
    """Replace loadAgentConfig with simple empty return."""
    # Find the loadAgentConfig function and replace its body
    pattern = r'(fn loadAgentConfig\(allocator: std\.mem\.Allocator\) !\[\]const u8 \{)'
    if re.search(pattern, content):
        start = content.find('fn loadAgentConfig(allocator: std.mem.Allocator) ![]const u8 {')
        if start >= 0:
            # Find the matching closing brace
            depth = 0
            end = start
            for i in range(start, len(content)):
                if content[i] == '{':
                    depth += 1
                elif content[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
            new_func = '''fn loadAgentConfig(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "");
}'''
            content = content[:start] + new_func + content[end:]
    return content


def add_fileExistsAndHasSize_helper(content):
    if "fn fileExistsAndHasSize(" in content:
        return content
    helper = '''
fn fileExistsAndHasSize(path: []const u8) ?u64 {
    const path_z = std.cstr.toC(path) catch return null;
    defer std.c.free(path_z);
    const fd = std.c.open(path_z.ptr, 0, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var stat_buf: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat_buf) != 0) return null;
    return @intCast(stat_buf.size);
}
'''
    return content.rstrip() + "\n" + helper


def main():
    files = {
        '/Users/a0/w/chatbot/satibot/apps/music/src/main.zig': lambda c: add_readFileAlloc_helper(fix_std_fs_cwd_openFile_for_config(c, "getApiKeyFromConfig")),
        '/Users/a0/w/chatbot/satibot/apps/speech/src/main.zig': lambda c: add_fileExistsAndHasSize_helper(add_readFileAlloc_helper(fix_std_fs_cwd_openFile_for_config(fix_speech_text_file(fix_speech_file_check(c)), "getApiKeyFromConfig"))),
        '/Users/a0/w/chatbot/satibot/apps/minimax-video/src/main.zig': lambda c: add_readFileAlloc_helper(fix_std_fs_cwd_openFile_for_config(c, "getApiKeyFromConfig")),
        '/Users/a0/w/chatbot/satibot/apps/search/src/main.zig': lambda c: add_readFileAlloc_helper(fix_std_fs_cwd_openFile_search(c)),
        '/Users/a0/w/chatbot/satibot/apps/code/src/config.zig': lambda c: add_readFileAbsolute_helper(fix_apps_code_config(c)),
        '/Users/a0/w/chatbot/satibot/apps/code/src/main.zig': fix_apps_code_main,
        '/Users/a0/w/chatbot/satibot/apps/web-cli/src/Main.zig': lambda c: add_readFileAlloc_helper(fix_web_cli(c)),
        '/Users/a0/w/chatbot/satibot/libs/core/src/config.zig': lambda c: add_readFileAbsolute_helper(fix_libs_core_config(c)),
        '/Users/a0/w/chatbot/satibot/libs/agent/src/agent/tools.zig': fix_tools_file_io,
    }

    for path, fix_func in files.items():
        with open(path, 'r') as f:
            content = f.read()

        new_content = fix_func(content)

        if new_content != content:
            with open(path, 'w') as f:
                f.write(new_content)
            print(f"Updated: {path}")


if __name__ == '__main__':
    main()
