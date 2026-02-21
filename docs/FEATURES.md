# SatiBot Features

## Overview

Inspired by [OpenClaw](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), `satibot` is a Zig Language based agent framework for:

- Chat tools integration: [Telegram (Guide)](docs/TELEGRAM_GUIDE.md), Discord, WhatsApp, etc.
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

## 🚪 Gateway Service

The **Gateway** is the central nervous system of SatiBot. Instead of running separate processes for different tasks, the Gateway runs them all concurrently in a single, efficient Zig process.

**Run it:**

```bash
# Run individual services
sati telegram      # Telegram bot
sati console       # Console (async)
sati console-sync  # Console (sync)
```

Note: The Gateway service currently runs as part of the Telegram bot. Cron and Heartbeat are handled within the telegram executable.

**Services included:**

1. **Telegram Bot**: Listens for messages, handles commands, voice notes, and file downloads.
2. **Cron Scheduler**: Executes recurring tasks defined in your configuration.
3. **Heartbeat**: Periodically checks `~/.bots/HEARTBEAT.md` for proactive tasks.

---

## 🎙️ Voice Transcription

SatiBot supports multi-modal interaction via **Telegram Voice Messages**.

**How it works:**

1. You send a voice note to the bot on Telegram.
2. The bot downloads the audio file.
3. It uses the **Groq API** (Whisper model) to transcribe the audio to text.
4. The transcribed text is fed into the Agent as if you typed it yourself.

**Configuration:**
Requires a Groq API key in specific config:

```json
"providers": {
  "groq": {
    "apiKey": "gsk_..."
  }
}
```

---

## 🏗️ Subagents & Background Tasks

SatiBot can delegate long-running or complex tasks to **Subagents**. This allows the main conversation to continue while background work happens.

**Tool:** `subagent_spawn`

- **Arguments**: `task` (string), `label` (string)
- **Behavior**: Spawns an isolated Agent instance with its own context.
- **Use Case**: "Research this topic while we talk about something else", "Monitor this crypto price for an hour".

**Shell Execution:**
SatiBot includes a `run_command` tool for executing shell commands, allowing it to act as a system administrator or coding assistant.

---

## ⚡ Interactive REPL

For direct communication with the agent from your terminal.

**Run it:**

```bash
zig build run -- agent
```

**Features:**

- **Persistent Sessions**: History is saved automatically.
- **RAG Integration**: Conversations are indexed for long-term memory.
- **Rich Output**: Streaming text, tool execution visualization.

---

## ⏰ Cron System

Schedule recurring agent tasks using natural language.

**Tools:**

- `cron_add`: Schedule a new job.
  - *Example*: "Remind me to drink water every 2 hours"
  - *Example*: "Check server status at 9:00 AM"
- `cron_list`: View active schedules.
- `cron_remove`: Cancel a job.

**Storage**: Jobs are persisted in `~/.bots/cron_jobs.json`.

---

## 💓 Heartbeat System

The Heartbeat allows the agent to be "proactive".

**How it works:**

1. The agent wakes up every 60 seconds (configurable).
2. It reads `~/.bots/HEARTBEAT.md`.
3. If there are instructions in that file, the agent executes them contextually.

**Use Case**:

- You can leave notes for the agent in that file like "If Bitcoin drops below $90k, alert me on Telegram".
- The agent effectively "thinks" periodically about your standing instructions.

---

## 🛠️ CLI Utilities

**Setup:**

```bash
zig build run -- onboard
# Creates ~/.bots structure and default config
```

**Status:**

```bash
zig build run -- status
# Shows:
# - Active Provider
# - Connected Channels (Telegram/Discord)
# - Active Cron Jobs
# - Data Directory Path
```
