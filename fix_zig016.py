#!/usr/bin/env python3
"""Fix Zig 0.16 migration issues in satibot codebase."""

import re
import os


def fix_getenv(content):
    """Replace std.posix.getenv with std.c.getenv + std.mem.span where needed."""
    # Pattern 1: std.posix.getenv("X") orelse Y (where Y is not a block)
    # const home = std.posix.getenv("HOME") orelse "/tmp";
    content = re.sub(
        r'(\s*)const\s+(\w+)\s*=\s*std\.posix\.getenv\("([^"]+)"\)\s+orelse\s+([^;]+);',
        r'\1const \2_ptr = std.c.getenv("\3") orelse \4;\n\1const \2 = std.mem.span(\2_ptr);',
        content,
    )

    # Pattern 2: std.posix.getenv("X") orelse { block } (multiline)
    # This is harder with regex. Let's do a simpler approach for common patterns.

    # Pattern 3: simple null checks - no span needed
    content = content.replace("std.posix.getenv(", "std.c.getenv(")

    # But now we need to fix the assignments that used the first pattern
    # The first regex already handled simple cases. For complex cases,
    # we need to manually identify them.

    return content


def fix_args_alloc(content):
    """Replace std.process.argsAlloc/argsFree with init.args.toSlice."""
    # Change main signature
    content = content.replace(
        "pub fn main() !void {",
        "pub fn main(init: std.process.Init.Minimal) !void {",
    )

    # Replace argsAlloc call
    content = content.replace(
        "try std.process.argsAlloc(allocator)",
        "try init.args.toSlice(allocator)",
    )

    # Remove argsFree defer
    content = re.sub(
        r'\s*defer\s+std\.process\.argsFree\([^)]+\);',
        '',
        content,
    )

    return content


def fix_page_alloc(content):
    """Replace std.heap.PageAlloc with std.heap.DebugAllocator."""
    content = content.replace(
        "var gpa = std.heap.PageAlloc.init(.{});",
        "var gpa: std.heap.DebugAllocator(.{}) = .init;",
    )
    return content


def fix_posix_setenv(content):
    """Replace std.posix.setenv/unsetenv with local extern declarations in tests."""
    if "std.posix.setenv" in content or "std.posix.unsetenv" in content:
        # Add extern declarations before the first setenv usage
        content = content.replace(
            "try std.posix.setenv(",
            '''extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

try setenv('''
        )
        content = content.replace(
            "std.posix.unsetenv(",
            "unsetenv(",
        )
        # Fix string literals for C functions
        content = content.replace(
            'try setenv("',
            'if (setenv("'
        )
        # This is getting too hacky. Let me just handle the specific test case.
    return content


def process_file(path):
    with open(path, 'r') as f:
        content = f.read()

    original = content

    if 'std.process.argsAlloc' in content:
        content = fix_args_alloc(content)

    if 'std.heap.PageAlloc' in content:
        content = fix_page_alloc(content)

    if 'std.posix.getenv' in content:
        content = fix_getenv(content)

    if 'std.posix.setenv' in content or 'std.posix.unsetenv' in content:
        content = fix_posix_setenv(content)

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        print(f"Updated: {path}")
        return True
    return False


def main():
    # Find all .zig files with the patterns
    files_to_check = []
    for root, dirs, files in os.walk('/Users/a0/w/chatbot/satibot'):
        # Skip zig cache and node_modules
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
        if process_file(path):
            updated += 1

    print(f"\nTotal files updated: {updated}")


if __name__ == '__main__':
    main()
