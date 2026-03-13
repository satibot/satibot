# `find_fn` and `find_fn_swc` Tools

## Overview

These tools search for function definitions in code files. Two implementations are provided:

1. `find_fn` - Grep-based search across multiple languages
2. `find_fn_swc` - SWC AST-based search for TypeScript/JavaScript files

## Usage

### `find_fn`

```json
{
  "name": "functionName",
  "path": "./src"
}
```

Arguments:

- `name` (required): The function name to search for
- `path` (optional): Directory to search in, defaults to "."

Supported extensions: .zig, .ts, .js, .tsx, .jsx, .py, .go, .rs, .c, .h, .java

### `find_fn_swc`

```json
{
  "name": "functionName", 
  "path": "./src"
}
```

Arguments:

- `name` (required): The function name to search for
- `path` (optional): Directory to search in, defaults to "."

Supported extensions: .ts, .tsx, .js, .jsx

Uses SWC (Speedy Web Compiler) to parse TypeScript/JavaScript into AST for more accurate function detection.

## Exclusions

Both tools automatically exclude:

### Default Directory Exclusions

- `node_modules/`
- `build/`
- `dist/`
- `.git/`
- `.zig-cache/`
- `target/`

### Default File Exclusions

- `*.pem`
- `*.crt`
- `*.key`
- `*.cer`
- `.env`
- `.env.*`

### .gitignore Integration

Tools also read `.gitignore` files to exclude project-specific patterns.

## Performance

- `find_fn`: Fast grep-based search, suitable for quick searches across many languages
- `find_fn_swc`: Uses grep first to find candidate files, then parses with SWC for accurate TypeScript detection. ~10-50x faster than parsing all files.

## Examples

```text
find_fn({"name": "main", "path": "./libs"})
find_fn({"name": "handleRequest"})
find_fn_swc({"name": "useState", "path": "./frontend"})
```
