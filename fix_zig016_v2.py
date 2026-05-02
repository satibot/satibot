#!/usr/bin/env python3
"""Fix Zig 0.16 migration issues in satibot codebase - v2."""

import re
import os


def fix_file(path):
    with open(path, 'r') as f:
        lines = f.readlines()

    modified = False
    new_lines = []

    for i, line in enumerate(lines):
        original = line

        # 1. Fix std.process.argsAlloc / argsFree
        if 'pub fn main() !void {' in line and any('argsAlloc' in l for l in lines):
            line = line.replace('pub fn main() !void {', 'pub fn main(init: std.process.Init.Minimal) !void {')
            modified = True

        if 'try std.process.argsAlloc(allocator)' in line:
            line = line.replace('try std.process.argsAlloc(allocator)', 'try init.args.toSlice(allocator)')
            modified = True

        if 'std.process.argsFree(' in line:
            line = ''  # Remove the defer line entirely
            modified = True

        # 2. Fix std.heap.PageAlloc
        if 'std.heap.PageAlloc.init(.{})' in line:
            line = line.replace('var gpa = std.heap.PageAlloc.init(.{});', 'var gpa: std.heap.DebugAllocator(.{}) = .init;')
            modified = True

        # 3. Fix std.posix.getenv
        if 'std.posix.getenv' in line:
            # Simple null check - no span needed
            if '== null' in line or '!= null' in line:
                line = line.replace('std.posix.getenv', 'std.c.getenv')
            else:
                # Check for if capture pattern: if (std.posix.getenv("X")) |var|
                m = re.search(r'if\s*\(\s*std\.posix\.getenv\(([^)]+)\)\s*\)\s*\|\s*(\w+)\s*\|', line)
                if m:
                    var_name = m.group(2)
                    # Replace the getenv but keep the if structure
                    # We need to add std.mem.span inside the block, but that's hard in a single line
                    # For now, just replace the function name and add a comment
                    line = line.replace('std.posix.getenv', 'std.c.getenv')
                else:
                    # orelse pattern or direct assignment - need span
                    # Check if line is an assignment with orelse
                    line = line.replace('std.posix.getenv', 'std.c.getenv')
                    # Add span wrapper for assignments
                    # Pattern: const X = std.c.getenv("Y") orelse Z;
                    m2 = re.search(r'(\s*)const\s+(\w+)\s*=\s*std\.c\.getenv\(([^)]+)\)\s+orelse\s+([^;]+);', line)
                    if m2:
                        indent, var_name, env_name, fallback = m2.groups()
                        line = f'{indent}const {var_name}_ptr = std.c.getenv({env_name}) orelse {fallback};\n'
                        line += f'{indent}const {var_name} = std.mem.span({var_name}_ptr);\n'
            modified = True

        # 4. Fix std.posix.setenv / unsetenv in test code
        if 'std.posix.setenv' in line:
            line = line.replace('try std.posix.setenv(', 'if (setenv(')
            # Add error check
            if line.strip().endswith(');'):
                line = line.rstrip().rstrip(';').rstrip(')') + ', 1) != 0) return error.SetenvFailed;\n'
            modified = True

        if 'std.posix.unsetenv' in line:
            line = line.replace('std.posix.unsetenv(', 'if (unsetenv(')
            if line.strip().endswith(');'):
                line = line.rstrip().rstrip(';').rstrip(')') + ') != 0) return error.UnsetenvFailed;\n'
            modified = True

        new_lines.append(line)

    if modified:
        # Check if we need to add extern declarations for setenv/unsetenv
        content = ''.join(new_lines)
        if 'setenv(' in content or 'unsetenv(' in content:
            # Add extern declarations at the top of the file if not present
            if 'extern "c" fn setenv' not in content:
                # Find the first `const std = @import` or after module doc comments
                extern_decl = 'extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;\n'
                extern_decl += 'extern "c" fn unsetenv(name: [*:0]const u8) c_int;\n\n'
                # Insert after the std import or at the beginning
                import_idx = content.find('const std = @import("std")')
                if import_idx >= 0:
                    # Find end of line
                    eol = content.find('\n', import_idx)
                    if eol >= 0:
                        content = content[:eol+1] + '\n' + extern_decl + content[eol+1:]
                else:
                    content = extern_decl + content

        with open(path, 'w') as f:
            f.write(content)
        print(f"Updated: {path}")
        return True
    return False


def main():
    files_to_check = []
    for root, dirs, files in os.walk('/Users/a0/w/chatbot/satibot'):
        dirs[:] = [d for d in dirs if d not in {'.zig-cache', 'zig-cache', 'zig-pkg', 'node_modules'}]
        for file in files:
            if file.endswith('.zig'):
                path = os.path.join(root, file)
                with open(path, 'r') as f:
                    content = f.read()
                if any(p in content for p in ['std.process.argsAlloc', 'std.heap.PageAlloc', 'std.posix.getenv', 'std.posix.setenv', 'std.posix.unsetenv']):
                    files_to_check.append(path)

    updated = 0
    for path in files_to_check:
        if fix_file(path):
            updated += 1

    print(f"\nTotal files updated: {updated}")


if __name__ == '__main__':
    main()
