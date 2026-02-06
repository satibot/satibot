# Connecting satibot to Telegram with OpenRouter

This guide will walk you through the process of setting up **satibot** as a Telegram bot using a free model from **OpenRouter**.

## Prerequisites

- [satibot](https://github.com/satibot/satibot) (installed and compiled)
- A Telegram account
- An OpenRouter account

---

## Step 1: Get an OpenRouter API Key

1. Go to [OpenRouter.ai](https://openrouter.ai/).
2. Sign in and navigate to **Keys** in the sidebar.
3. Click **Create Key**, give it a name (e.g., `satibot-key`), and copy the generated key.
4. **Find a Free Model**:
    - Go to the [Models](https://openrouter.ai/models) page.
    - Filter by "Free" or search for models like `arcee-ai/trinity-large-preview:free` or `mistralai/mistral-7b-instruct:free`.
    - Note the "Model ID" (e.g., `google/gemini-2.0-flash-exp:free`).

## Step 2: Create a Telegram Bot

1. Open Telegram and search for [@BotFather](https://t.me/botfather).
2. Send `/newbot` and follow the instructions:
    - Choose a display name for your bot (e.g., `Satibot`).
    - Choose a username (must end in `bot`, e.g., `sati_super_bot`).
3. BotFather will give you an **API Token**. Copy this token (it looks like `12345678:ABC-DEF1234ghIkl-zyx57W2v1u1`).

## Step 3: Get your Telegram Chat ID (Optional)

If you want the agent to be able to send you proactive messages or if you want to restrict access:

1. Search for [@userinfobot](https://t.me/userinfobot) on Telegram.
2. Send any message to it, and it will reply with your **Id**.

## Step 4: Configure satibot

Create or edit your config file at `~/.bots/config.json`. If the directory doesn't exist, create it:

```bash
mkdir -p ~/.bots
```

Update the `config.json` with your keys and preferred model:

```bash
code ~/.bots/config.json
```

```json
{
  "agents": {
    "defaults": {
      "model": "arcee-ai/trinity-large-preview:free"
    }
  },
  "providers": {
    "openrouter": {
      "apiKey": "YOUR_OPENROUTER_API_KEY"
    }
  },
  "tools": {
    "web": {
      "search": {
        "apiKey": ""
      }
    },
    "telegram": {
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "chatId": "YOUR_CHAT_ID"
    }
  }
}
```

- Replace `YOUR_OPENROUTER_API_KEY` with the key from Step 1.
- Replace `YOUR_TELEGRAM_BOT_TOKEN` with the token from Step 2.
- Replace `YOUR_CHAT_ID` with the ID from Step 3 (if ignored, leave empty or remove).
- You can change the `model` to any other free model ID from OpenRouter.

## Step 5: Run satibot in Telegram Mode

In your terminal, run the following command from the project root:

```bash
zig build run -- telegram
```

You should see:
`Telegram bot started. Press Ctrl+C to stop.`

## Step 6: Start Chatting

1. Open your bot in Telegram (the link BotFather gave you).
2. Send a message like "Hello!".
3. **satibot** will process the message through OpenRouter and reply to you on Telegram.

### Features

- **Persistent Sessions**: Each Telegram user has their own session automatically mapped to their chat ID.
- **Tools**: The bot can use all registered tools (web search, files, RAG) directly from Telegram if configured.
- **Shared Memory**: All conversations are indexed into the local RAG knowledge base in `~/.bots/`.

## Troubleshooting

- **Error: NoApiKey**: Make sure your `config.json` is in the correct location (`~/.bots/config.json`) and the `apiKey` field is filled.
- **Bot not responding**: Double-check your `botToken`. Ensure you haven't started multiple instances of the bot with the same token.
- **OpenRouter Credits**: Some "free" models still require you to have at least a $0.00 balance or a verified account. Check OpenRouter's limits.
