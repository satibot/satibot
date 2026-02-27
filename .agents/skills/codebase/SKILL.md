---
name: satibot-codebase
description: Quick reference for understanding the SatiBot project structure, key files, and common patterns. Use this when working on this codebase to avoid re-exploring.
---

# SatiBot Codebase Quick Reference

## Project Overview

SatiBot is a Zig-based AI chatbot that uses LLM agents with RAG (Retrieval-Augmented Generation) capabilities. It supports multiple interfaces: console, Telegram, and web.

## Directory Structure

```text
satibot/
├── apps/              # Application entry points
│   ├── console/       # Console CLI app
│   ├── telegram/      # Telegram bot
│   └── web/           # Web API server (port 8080)
├── libs/              # Reusable libraries
│   ├── agent/         # AI agent implementation
│   ├── core/          # Core utilities (config, logging, etc.)
│   ├── http/          # HTTP client
│   ├── memory/        # Memory management utilities
│   ├── rag/           # RAG (Retrieval-Augmented Generation)
│   └── web/           # Web server framework (zap-based)
├── docs/              # Documentation
├── scripts/           # Build/deployment scripts
└── sample/            # Sample data/files
```

## Key Files

| File | Purpose |
|------|---------|
| `build.zig` | Zig build configuration |
| `AGENTS.md` | Agent instructions and build commands |
| `Makefile` | Build automation |
| `apps/web/src/main.zig` | Web API server (GET /, POST /api/chat, GET /openapi.json) |
| `libs/agent/src/main.zig` | Core Agent implementation |
| `libs/core/src/config.zig` | Configuration loading from environment |
| `libs/web/src/root.zig` | Web server framework (Server, Router) |

## API Endpoints (Web)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | API status |
| `/api/chat` | POST | Chat with AI |
| `/openapi.json` | GET | OpenAPI spec (JSON) |

**Chat Request:**

```json
{ "messages": [{ "role": "user", "content": "Hello!" }] }
```

**Chat Response:**

```json
{ "content": "AI response here" }
```

## Build Commands

```bash
zig build # Debug build
zig build -Doptimize=ReleaseFast # Release build
zig build test # Run tests
zig build run-console # Run console app
zig build telegram # Build Telegram bot
make lint # Run linting
```

## Key Patterns

### Memory Management

- Use `ArenaAllocator` for request-scoped allocations
- Pass allocators explicitly to functions
- Free owned fields before calling `deinit()` on containers

### Agent Flow

1. `agent.Agent.init(allocator, config, session_id, use_rag)`
2. Add messages to context with `bot.ctx.addMessage(msg)`
3. Run agent with `bot.run(user_input)`
4. Get response from `bot.ctx.getMessages()`

### Web Server (zap-based)

- `web.Server.init(allocator, config)`
- Set `server.on_request = handler_fn`
- Handler receives `web.zap.Request` with `.path`, `.method`, `.body`
- Response via `req.sendJson(json_string)` or `req.sendText()`

### Configuration

- Load config via `core.config.load(allocator)`
- Environment variables: `TELEGRAM_BOT_TOKEN`, `OPENROUTER_API_KEY`, `DATABASE_URL`, etc.
- See `libs/core/src/config.zig` for full config structure

## Common Imports

```zig
const std = @import("std");
const web = @import("web");
const agent = @import("agent");
const core = @import("core");
```

## Agent-Specific Files

- `libs/agent/src/base.zig` - LlmMessage, LlmRole types
- `libs/agent/src/llm.zig` - LLM client (OpenRouter)
- `libs/rag/src/` - RAG implementation
- `libs/core/src/logger.zig` - Logging utilities

## Important Notes

- Use `std.debug.print` with format: `std.debug.print("msg {}\n", .{value})`
- Always use `defer` for cleanup after resource acquisition
- Prefer pure functions over stateful objects
- Separate IO from business logic
- Follow AGENTS.md for code style and conventions
