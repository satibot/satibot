<p align="center">
  <img src="docs/icons/icon.png" alt="satibot mascot" width="180" />
</p>

# satibot

Inspired by [OpenClawd](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), `satibot` is a Ziglang-based agent framework for:

- Chat tools intergation: [Telegram (Guide)](docs/TELEGRAM_GUIDE.md), Discord, WhatsApp, etc.
- LLM providers (OpenRouter, Anthropic, etc.)
- Tool execution: shell commands, HTTP requests, etc.
- **Gateway**: Single command to run Telegram, Cron, and Heartbeat collectively.
- **Cron System**: Schedule recurring tasks (e.g., daily summaries, hourly status checks).
- **Heartbeat**: Proactive agent wake-up to check for pending tasks in `HEARTBEAT.md`.
- Conversation history
- Session persistence: Full session persistence in `~/.bots/sessions/`.
- Easy to add SKILL from any source, the agent can browse, search, and install its own skills.
  - Browse skills: <https://agent-skills.md/>
  - Install: `./scripts/install-skill.sh <github-url-or-path>`
- Context management: use memory, file, etc.
- **RAG & Knowledge base**: Local base with built-in support for:
  - **VectorDB**: Semantic search and long-term memory.
  - **GraphDB**: Relationship mapping and complex knowledge retrieval.
  - **RAG**: Retrieval-Augmented Generation for fact-based responses.
- **Subagent**: Background task execution with `subagent_spawn` tool.
- **Voice Transcription**: Telegram voice messages are automatically transcribed using **Groq** (if configured).

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [**Features**](docs/FEATURES.md) | Detailed walkthrough of Gateway, Voice, Cron, and more. |
| [**Configuration**](docs/CONFIGURATION.md) | Guide to `config.json`, keys, and customization. |
| [**Architecture**](docs/ARCHITECTURE.md) | Technical deep-dive into the Agent Loop and codebase. |
| [**Telegram Guide**](docs/TELEGRAM_GUIDE.md) | Hosting and setting up your bot. |
| [**RAG Guide**](docs/RAG.md) | How the memory system works. |

## Usage

```bash
# Run the agent with a message
zig build run -- agent -m "Your message"

# Run with a specific session ID to persist history
zig build run -- agent -m "Follow-up message" -s my-session

# Run as a Telegram Bot (long polling)
zig build run -- telegram

# Run the GATEWAY (Telegram + Cron + Heartbeat)
zig build run -- gateway

# RAG is enabled by default to remember conversations. 
# To disable it for a specific run:
zig build run -- agent -m "Don't remember this" --no-rag
```

## Structure

- `src/main.zig`: CLI entry point
- `src/agent.zig`: Agent logic
- `src/config.zig`: Configuration
- `src/http.zig`: HTTP client
- `src/providers/base.zig`: Provider interface
- `src/providers/openrouter.zig`: OpenRouter provider
- `src/root.zig`: Library exports
- `src/agent/context.zig`: Conversation history management
- `src/agent/session.zig`: Session persistence
- `src/agent/tools.zig`: Tool system and registry
- `src/agent/vector_db.zig`: Local vector database for semantic search
- `src/agent/graph_db.zig`: Local graph database for relationship mapping

## Architecture

SatiBot uses a **ReAct** (Reason+Action) loop for agentic behavior, listening for messages from various sources (CLI, Telegram, Cron), processing them through an LLM, executing tools, and persisting state.

For a deep dive into the code structure, Agent Loop, and Gateway system, see the [Architecture Guide](docs/ARCHITECTURE.md).

## Configuration

The agent's configuration is stored in `~/.bots/config.json`.

See the [Configuration Guide](docs/CONFIGURATION.md) for full details on setting up Providers (OpenRouter, Groq), Tools, and Agents.

## Addition information

### Bot name meaning

TL;DR: In SatiBot, Sati means “remembering to stay aware of what is happening right now.” It comes from Pāli, where it originally meant memory, and in Buddhism evolved into the idea of mindful awareness — not forgetting the present moment.

1. The original meaning (language level)

In Pāli (the language of early Buddhist texts), sati literally means:

> memory + recollection + not forgetting

It comes from an ancient Indo-European root meaning “to remember”.

So at its most basic level, sati is the mental ability to keep something in mind instead of losing track of it.

1. How Buddhism deepened the meaning

In Buddhist psychology, the word was expanded.

> remembering the present experience

In other words:

- Remember you are breathing
- Remember you are walking
- Remember anger is happening
- Remember thoughts are arising

So "mindfulness" (the common English translation) really means:

> "not forgetting what is happening now"

Metaphorically, SatiBot suggests a system that:

- Doesn’t forget context
- Tracks state consistently
- Stays aware of ongoing processes
- Doesn’t lose events in the flow
