# SatiCode CLI

AI-powered software engineer CLI tool for code exploration, editing, and task automation.

## Installation

```bash
# Build from source
zig build saticode

# Run
./zig-out/bin/saticode
# or
zig build saticode-run
```

## Usage

```text
saticode              # Start interactive REPL
saticode -v           # Show version information
saticode --version    # Show version information
saticode --no-rag    # Start without RAG (vector memory)
```

## Commands

Type your request and press Enter. The AI will:

1. Understand your request
2. Explore the codebase using tools
3. Plan and execute changes
4. Report results

Type `exit` or `quit` to leave.

## Available Tools

### File Operations

| Tool | Description | Arguments |
|------|-------------|-----------|
| `list_files` | List files in directory | - |
| `read_file` | Read file contents | `{"path": "file.txt"}` |
| `write_file` | Write to file | `{"path": "file.txt", "content": "..."}` |
| `edit_file` | Edit file (find/replace) | `{"path": "file.txt", "oldString": "...", "newString": "..."}` |

### Code Search

| Tool | Description | Arguments |
|------|-------------|-----------|
| `find_fn` | Search functions (grep-based) | `{"name": "functionName", "path": "./src"}` |
| `find_fn_swc` | Search TS/JS functions (AST-based) | `{"name": "functionName", "path": "./src"}` |

### System

| Tool | Description | Arguments |
|------|-------------|-----------|
| `run_command` | Execute shell command | `{"command": "ls -la"}` |
| `web_fetch` | Fetch URL content | `{"url": "https://..."}` |
| `vector_upsert` | Remember text (RAG) | `{"text": "..."}` |
| `vector_search` | Search memory (RAG) | `{"query": "..."}` |

## Agent Rules & Skills

SatiCode automatically loads rules and skills from:

- `.agent/rules/` - Agent behavior rules (*.md,*.zig.md)
- `.agent/skills/*/SKILL.md` - Skill definitions
- `.agents/` - Alternative location

These are injected into the system prompt on every request.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                      SatiCode CLI                           │
│  apps/code/src/main.zig                                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                      Agent                                  │
│  libs/agent/src/agent.zig                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐   │
│  │   Context   │  │ ToolRegistry │  │   Observer     │   │
│  │ (messages)  │  │ (find_fn,    │  │ (metrics,     │   │
│  │             │  │  read_file,   │  │  events)      │   │
│  │             │  │  write_file)  │  │                │   │
│  └─────────────┘  └──────────────┘  └────────────────┘   │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    LLM Provider                             │
│  libs/providers/src/                                        │
│  - OpenRouter (default)                                     │
│  - Anthropic (Claude)                                      │
└─────────────────────┬───────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
    Tool Execution          Response
    (tools.zig)            Generation
```

## Tool Execution Flow

1. User Input → Agent receives message
2. LLM Request → Sends conversation + tool definitions to LLM
3. Tool Call → LLM requests tool execution
4. Tool Execution → Agent runs tool function
5. Result → Returns result to LLM
6. Response → LLM generates final response
7. Repeat → Until max iterations or final response

## Configuration

SatiCode supports JSON and JSONC configuration files. The system searches for configuration files in this order:

1. `.saticode.jsonc` (current directory) - JSON with comments
2. `.saticode.json` (current directory) - Standard JSON
3. `~/.config/saticode/config.jsonc` - User config with comments
4. `~/.config/saticode/config.json` - User config

### Example Configuration (`.saticode.jsonc`)

```jsonc
{
  "$schema": "https://satibot.github.io/saticode/config.json",
  "model": "MiniMax-M2.5",
  "autoupdate": true,
  "rag": {
    "enabled": true,
    "maxHistory": 50,
    "embeddingsModel": "local"
  },
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}",
      "apiBase": "https://api.minimax.io/anthropic"
    },
    "openrouter": {
      "apiKey": "${OPENROUTER_API_KEY}"
    }
  },
  "systemPrompt": "You are an expert software engineer. Help users efficiently with coding tasks.",
  "tools": {
    "web": {
      "search": {
        "apiKey": "${SEARCH_API_KEY}",
        "engine": "google"
      }
    }
  }
}
```

### Configuration Options

| Field | Type | Description |
|-------|------|-------------|
| `$schema` | string | JSON schema URL for IDE validation |
| `model` | string | Default LLM model to use |
| `autoupdate` | boolean | Enable automatic updates (future feature) |
| `rag.enabled` | boolean | Enable RAG/vector memory |
| `rag.maxHistory` | number | Maximum chat history to keep |
| `rag.embeddingsModel` | string | Embeddings model for RAG |
| `providers.*.apiKey` | string | API key (supports `${VAR}` env vars) |
| `providers.*.apiBase` | string | Custom API base URL |
| `systemPrompt` | string | Custom system prompt override |
| `tools.web.search.apiKey` | string | Web search API key |
| `tools.web.search.engine` | string | Search engine (google, bing) |

### Environment Variables

Configuration values support environment variable expansion using `${VAR_NAME}` syntax:

```jsonc
{
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}"  // Reads from MINIMAX_API_KEY env var
    }
  }
}
```

## Search Exclusions

Both `find_fn` and `find_fn_swc` automatically exclude:

### Directories

- `node_modules/`, `build/`, `dist/`, `.git/`, `.zig-cache/`, `target/`
- `venv/`, `env/`, `.venv/`, `__pycache__/`, `wheels/`, `tmp/`

### File Patterns

- `*.pem`, `*.crt`, `*.key`, `*.cer`
- `*.pyc`, `*.pyd`, `*.pyo`
- `.env`, `.env.*`, `.coverage`

Plus any patterns from `.gitignore`.

## Performance

- find_fn: Grep-based, multi-language support
- find_fn_swc: Uses grep first to find candidates, then SWC for accurate TypeScript AST parsing. ~10-50x faster than parsing all files.

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `MINIMAX_API_KEY` | MiniMax API key | Required for MiniMax models |
| `OPENROUTER_API_KEY` | OpenRouter API key | Required for OpenRouter models |
| `ANTHROPIC_API_KEY` | Anthropic API key | Required for Claude models |
| `OPENAI_API_KEY` | OpenAI API key | Required for OpenAI models |
| `GROQ_API_KEY` | Groq API key | Required for Groq models |
| `SEARCH_API_KEY` | Web search API key | Optional, for web search tools |

**Note**: API keys can also be configured in `.saticode.jsonc` files using environment variable expansion:

```jsonc
{
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}"
    }
  }
}
```

## Examples

### Basic Usage

```text
User: Find the main function
→ find_fn({"name": "main"})

User: Where is handleRequest defined?
→ find_fn_swc({"name": "handleRequest", "path": "./src"})

User: Read the config file
→ read_file({"path": ".saticode.jsonc"})

User: Add a test for calculate()
→ find_fn({"name": "calculate"})
→ read_file({"path": "..."})
→ write_file({"path": "...", "content": "..."})

User: Run the tests
→ run_command({"command": "zig build test"})
```

### Configuration Examples

**MiniMax Provider Setup:**

```jsonc
{
  "model": "MiniMax-M2.5",
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}"
    }
  }
}
```

**Multiple Providers:**

```jsonc
{
  "model": "anthropic/claude-3-5-sonnet",
  "providers": {
    "anthropic": {
      "apiKey": "${ANTHROPIC_API_KEY}"
    },
    "openrouter": {
      "apiKey": "${OPENROUTER_API_KEY}"
    }
  }
}
```

**Custom System Prompt:**

```jsonc
{
  "systemPrompt": "You are a senior Zig developer. Focus on performance and memory safety.",
  "rag": {
    "enabled": true,
    "maxHistory": 100
  }
}
```
