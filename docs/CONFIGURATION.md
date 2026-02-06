# Configuration Guide

SatiBot uses a JSON configuration file located at `~/.bots/config.json`.

## Quick Setup

Run the onboard command to generate a default configuration:

```bash
zig build run -- onboard
```

## Structure

### Root Object

```json
{
  "agents": { ... },
  "providers": { ... },
  "tools": { ... }
}
```

---

### `agents`

Configures the default behavior of the agent.

```json
"agents": {
  "defaults": {
    "model": "openrouter/anthropic/claude-3-5-sonnet", // Primary model to use
    "temperature": 0.7,                                // Creative freedom (0.0 - 1.0)
    "maxTokens": 4096                                  // Response limit
  }
}
```

---

### `providers`

API keys and settings for LLM and service providers.

#### OpenRouter (Recommended)

Access almost any model (Claudia, GPT-4, Llama 3) via a single API.

```json
"openrouter": {
  "apiKey": "sk-or-v1-..."
}
```

#### Anthropic (Direct)

```json
"anthropic": {
  "apiKey": "sk-ant-..."
}
```

#### Groq (Fast & Voice)

Required for **Voice Transcription** and ultra-fast inference.

```json
"groq": {
  "apiKey": "gsk_..."
}
```

---

### `tools`

Configuration for external tools and chat platforms.

#### Telegram Bot

```json
"telegram": {
  "botToken": "123456:ABC-...",  // From @BotFather
  "chatId": "123456789",         // Your User ID (for proactive messages)
  "allowedUsers": [123456789]    // Optional: Restrict access
}
```

#### Web Search (Brave)

```json
"web": {
  "search": {
    "apiKey": "BS-..." // Brave Search API Key
  }
}
```

#### Discord (Webhook)

For sending alerts/logs to a Discord channel.

```json
"discord": {
  "webhookUrl": "https://discord.com/api/webhooks/..."
}
```

#### WhatsApp (Meta Cloud API)

```json
"whatsapp": {
  "accessToken": "EA...",
  "phoneNumberId": "100...",
  "recipientPhoneNumber": "1555..."
}
```

## Environment Variables

SatiBot also respects the following environment variables if config values are missing:

- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `GROQ_API_KEY`
- `TELEGRAM_BOT_TOKEN`
- `BRAVE_SEARCH_API_KEY`
