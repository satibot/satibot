<p align="center">
 <img src="docs/icons/icon.png" alt="satibot mascot" width="180" />
</p>

# 🧘 satibot: The Mindful AI Agent Framework

Built in Zig for performance, designed for awareness.
`satibot` is a lightweight, memory-aware AI agent framework that never forgets. Inspired by [OpenClawd](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), it combines the power of ReAct loops with persistent memory to create agents that remember, learn, and assist.

IMPORTANT: Currently, it only supports Openrouter (LLM provider), Telegram and console, other features are under development.
- [x] Telegram + OpenRouter (Sync version)
- [x] Console
- [x] chat history saved to JSON base session file, start new session with `/new` message
- [x] VectorDB - very simple local first vector searching for similar content chat logs.
- [x] OpenTelemetry tracing for observability
- [x] HTTP Web API (zap framework) for REST interface built on top of the Zap logging library (used for fast, structured logging)
- [x] [apps/music/README.md](apps/music/README.md) - MiniMax music generation CLI
- [x] File operations - built-in `read_file` tool for reading local files with security restrictions
- [x] Web fetching - built-in `web_fetch` tool for fetching and extracting readable content from URLs

## Comparison with others

| Feature | OpenClaw | NanoBot | PicoClaw | satibot |
|---|---|---|---|---|
| Language | TypeScript | Python | Go | Zig |
| RAM Usage | >1GB | >100MB | < 10MB | < 4MB (disable RAG with `--no-rag` option) |
| Startup Time<br>(0.8GHz core) | >500s | >30s | <1s | ?s |
| Cost | Mac Mini $599 | Most Linux SBC<br>~$50 | Any Linux Board<br>As low as $10 | Not checked |
| src | [openclaw](https://github.com/openclaw/openclaw) | [nanobot](https://github.com/HKUDS/nanobot) | [picoclaw](https://github.com/sipeed/picoclaw) | [satibot](https://github.com/satibot/satibot) |

- ⚡️ Blazing Fast: Written in Zig for zero-overhead performance
- 🐵 Never Forgets: Built-in RAG, VectorDB, and GraphDB for long-term memory
- 🔧 Extensible: Easy skill installation and tool system
- 💬 Multi-Platform: Telegram, Console, Web API, and more
- 📊 Observability: Built-in OpenTelemetry tracing support

View more in [Features](docs/FEATURES.md).

## 📋 Requirements

- OS: Linux, macOS, or Windows (with WSL)
> Note: This project uses Zig 0.15.2's thread-based concurrency with XevEventLoop.

## ✨ Key Features

🪶 Lightweight & Fast: Minimal footprint with Zig's performance guarantees
🔬 Research-Ready: Clean, readable codebase perfect for experimentation
⚡️ Gateway System: Single command runs all services together
🤖 Smart Memory: RAG + VectorDB + GraphDB for intelligent context management
🔧 Skill Ecosystem: Browse and install skills from <https://agent-skills.md/>
📁 File Operations: Built-in tools for reading and analyzing local files
🎙️ Voice Ready: Automatic voice transcription with Groq
⏰ Proactive: Heartbeat system wakes agent for pending tasks
📅 Scheduled: `s-cron` CLI for recurring tasks

## 🚀 Quick Start

### 1. Install

Install Zig: <https://ziglang.org/learn/getting-started/>
```bash
# verify zig version
zig version
# 0.15.2

git clone https://github.com/satibot/satibot.git
cd satibot

# build all targets
zig build
# output: zig-out/bin/
# run:
# ./zig-out/bin/sati
# ./zig-out/bin/s-console-sync
# ./zig-out/bin/s-console
# ./zig-out/bin/s-telegram

# build release version
zig build -Doptimize=ReleaseFast --prefix $HOME/.local
# or
make prod

# initialize `~/.bots/config.json` (at HOME path)
# If platform sections already exists, it will do nothing
# default config is:
# - using `arcee-ai/trinity-large-preview:free`
# - using `openrouter`
# - using `telegram`
sati init
```

### Project Structure

This is a Zig monorepo with the following structure:
```text
libs/
  ├── core/         - Config and constants (shared)
  ├── http/         - HTTP client module
  ├── providers/    - LLM provider implementations
  ├── db/           - Database and session modules
  ├── utils/        - Shared utilities (xev_event_loop)
  └── agent/        - Core agent logic

apps/
  ├── console/      - Console applications (sync + async)
  ├── telegram/     - Telegram bot
  └── web/          - Web API backend (CORS support)
```

### 2. Configure

Read [docs/TELEGRAM_GUIDE.md](docs/TELEGRAM_GUIDE.md) for more details about Telegram + OpenRouter setup.
Edit `~/.bots/config.json`:

```json
{
  "agents": {
    "defaults": {
      "model": "arcee-ai/trinity-large-preview:free"
    }
  },
  "providers": {
    "openrouter": {
      "apiKey": "sk-or-v1-xxx"
    }
  },
  "tools": {
    "telegram": {
      "botToken": "",
      "chatId": ""
    }
  }
}
```

Add `sati` to your PATH, for example add to `~/.zshrc`:
```bash
export PATH="/Users/your-username/chatbot/satibot/zig-out/bin:$PATH"
```

## 🎮 Run

### Using the Sati CLI (Recommended)

```bash
# Show help and available commands
sati help

# for console (sync version - simple & reliable)
sati console-sync

# for console (async version with xev event loop)
sati console

# for telegram (sync version - simple & reliable)
sati telegram-sync

# for telegram (async version)
sati telegram

# for web api backend (requires web module enabled)
sati web -Dweb=true

# Check system status
sati status

# Vector database operations
sati vector-db stats
sati vector-db add "Your text here"
sati vector-db search "query text"

# Test LLM provider connectivity
sati test-llm
```

### Direct Binary Execution

```bash
# Run binaries directly from zig-out/bin/
./zig-out/bin/s-console-sync
./zig-out/bin/s-console
./zig-out/bin/s-telegram
./zig-out/bin/sati
./zig-out/bin/web              # Web API (build with -Dweb=true)
```

## Build Commands

```bash
# Build all targets (debug)
zig build

# Build specific targets
zig build sati              # Sati CLI
zig build s-console          # Async console app
zig build s-console-sync     # Sync console app
zig build s-telegram         # Telegram bot
zig build web -Dweb=true     # Web API backend (requires -Dweb=true)
zig build s-cron            # Cron CLI app

# Build and run
zig build run-console          # Build and run async console
zig build run-console-sync     # Build and run sync console
zig build run-telegram         # Build and run telegram bot
zig build run-web -Dweb=true   # Build and run web backend

# Web app specific commands
zig build -Dweb=true           # Build with web module enabled
./zig-out/bin/web              # Run built web binary
zig build run-web -Dweb=true   # Build and run web app directly
```

## CLI Options

### Agent Command Options

When using `sati agent`, you can use these options:
```bash
# Disable RAG (Retrieval-Augmented Generation)
sati agent --no-rag

# Single message with RAG disabled
sati agent -m "Hello, how are you?" --no-rag

# Interactive mode with specific session and RAG disabled
sati agent -s chat123 --no-rag
```

### Telegram Bot Versions

satibot offers two Telegram bot implementations:
🔄 Sync Version (`s-telegram-sync`)

- Simple, reliable, single-threaded
- Processes one message at a time
- Lower resource usage (~1MB on macOS M1)
- Text messages only (no voice support)
- Best for: development, small deployments, resource-constrained environments

⚡ Async Version (`s-telegram`)
- High-performance, event-driven (xev-based)
- Processes multiple messages concurrently
- Higher resource usage - RAM usage more than 3.5MB on macOS M1 (disable RAG with `--no-rag` option)

See [docs/TELEGRAM_SYNC_VS_ASYNC.md](docs/TELEGRAMSYNCVS_ASYNC.md) for detailed comparison.

## 💬 Chat Integrations

- Telegram: `sati telegram-sync` or `sati telegram`
- [docs/TELEGRAM_GUIDE.md](docs/TELEGRAM_GUIDE.md)
- [docs/TELEGRAM_SYNC_VS_ASYNC.md](docs/TELEGRAMSYNCVS_ASYNC.md)
- [docs/TELEGRAM_SYNC.md](docs/TELEGRAM_SYNC.md)
- Terminal console: `sati console-sync` or `sati console`
- [docs/CONSOLE.md](docs/CONSOLE.md)
- Web API: `sati web -Dweb=true` (requires web module enabled)
- [docs/WEB_API.md](docs/WEB_API.md)

## 🛠️ Advanced Features

### 🍡 Memory System

- VectorDB: Semantic search across conversations
- GraphDB: Relationship mapping for complex knowledge
- RAG: Retrieval-Augmented Generation for accurate responses
- Session Cache: In-memory session history with automatic cleanup (30 minutes idle timeout)

### 📚 VectorDB

🎯 Perfect For Chat Logs:
- Semantic Search: Find similar conversations by meaning, not just keywords
- Local First: No external database dependencies
- Fast Enough: Linear search suitable for thousands of entries
- Auto-indexing: Already integrated with conversation indexing

- Storage: `~/.bots/vector_db.json`
- Usage:

```bash
sati vector-db stats
sati vector-db list
sati vector-db search "your query" [top_k]
sati vector-db add "my name is John"
```

### 🔧 Skills & Tools

Browse and install skills from the community:
```bash
# Browse available skills
curl https://agent-skills.md/

# Install a new skill
./scripts/install-skill.sh <github-url-or-path>

# Use built-in tools
zig build s-console -- -- agent -m "Run: ls -la"
```

#### Built-in Tools

📁 read_file - Read local files
The `read_file` tool allows the AI agent to read contents of local files on your system.

Usage Examples:
```bash
# Ask the agent to read a file
sati console-sync
> Please read the contents of /home/user/config.txt

# Read and analyze a log file
> Can you read /var/log/system.log and summarize any errors?

# Read a code file
> Read the main.zig file and explain what it does
```

Arguments:
- `path` (required): Absolute or relative path to the file to read

Example JSON:
```json
{
  "path": "/path/to/your/file.txt"
}
```

Features:
- ✅ Supports text files of any size (10MB limit)
- ✅ Handles absolute and relative paths
- ✅ Proper error handling for missing files
- ✅ Built-in security restrictions for sensitive files
- ✅ Memory-efficient with automatic cleanup

Security Restrictions:
For security reasons, the tool automatically blocks access to sensitive files:

- Environment files: `.env`, `.env.local`, `.env.*` variations
- Private keys: `id_rsa`, `id_ed25519`, `private_key.*`, `*.key`
- Credentials: `credentials.*`, `secret.*`
- Sensitive directories: `.ssh/`, `.aws/`, `.kube/`

Examples of blocked files:
- `.env` ❌
- `id_rsa` ❌
- `private_key.pem` ❌
- `.ssh/config` ❌
- `config.txt` ✅
- `public_key.pem` ✅
- `data.json` ✅

🌐 web_fetch - Fetch web content
See [docs/tasks/web-fetch.md](docs/tasks/web-fetch.md) for detailed documentation.

### ⏰ Automation

Heartbeat: Proactive task checking
```bash
# Create a heartbeat task
echo "Check emails" > ~/.bots/HEARTBEAT.md

# Run the telegram bot (includes heartbeat)
sati telegram

Cron: Schedule recurring tasks
```bash
zig build run-cron -- --schedule "0 9 * * *" --message "Daily summary"
# or after build:
./zig-out/bin/s-cron --schedule "0 9 * * *" --message "Daily summary"
```

## 📚 Documentation

| Guide | Description |
|----|------------|
| [Features](docs/FEATURES.md) | Deep dive into Gateway, Voice, Cron systems |
| [Configuration](docs/CONFIGURATION.md) | Complete config guide for providers & tools |
| [Architecture](docs/ARCHITECTURE.md) | Technical guide to Agent Loop & Functional Architecture |
| [Functional Design](docs/FUNCTIONAL_DESIGN.md) | Pure functional approach and session cache |
| [Telegram Guide](docs/TELEGRAM_GUIDE.md) | Step-by-step Telegram bot setup |
| [WhatsApp Guide](docs/WHATSAPP_GUIDE.md) | WhatsApp Business API setup |
| [RAG Guide](docs/RAG.md) | Understanding the memory system |
| [OpenTelemetry](docs/OPENTELEMETRY.md) | Distributed tracing setup with OTEL |
| [Web API Guide](docs/WEB_API.md) | Backend setup for web interfaces & CORS |
| [⚠️ Security](docs/SECURITY.md) | Security risks, best practices, and guidelines |
| [Release Guide](docs/RELEASE_GUIDE.md) | Cross-platform builds and GitHub releases |

## 🤝 Contributing

We welcome contributions!
Please read our [docs/DEV.md](docs/DEV.md) for more information.

## 📖 The Meaning of Sati

Sati (Pāli) means "mindful awareness" — the art of not forgetting the present moment - "remembering to stay aware of what is happening right now.".
In Buddhist psychology, sati evolved from simple memory to profound awareness:

- Remember you are breathing
- Remember thoughts are arising
- Remember what is happening now

SatiBot embodies this principle:
- Never forgets context or conversations
- Tracks state consistently across sessions
- Stays aware of ongoing processes
- Never loses events in the flow

## 📄 License

Licensed under the MIT License.
<div align="center">
 <sub>Built with ❤️ by the SatiBot community</sub>
</div>
