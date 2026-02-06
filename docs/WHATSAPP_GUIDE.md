# WhatsApp Setup Guide

This guide walks you through setting up **satibot** as a WhatsApp bot using the Meta Cloud API.

## Prerequisites

- [satibot](https://github.com/satibot/satibot) (installed and compiled)
- A Meta Developer account
- A phone number for testing

---

## Step 1: Create a Meta Developer Account

1. Go to [Meta for Developers](https://developers.facebook.com/)
2. Create or log in to your developer account
3. Complete any required verification steps

## Step 2: Create a WhatsApp Business App

1. Go to [Meta Developers Dashboard](https://developers.facebook.com/apps)
2. Click **Create App**
3. Select **Business** as the app type
4. Fill in app details:
   - **App Name**: `satibot` (or any name you prefer)
   - **App Contact Email**: Your email
   - **Business Portfolio**: Create new or select existing

## Step 3: Add WhatsApp Product

1. In your app's dashboard, click **Add Product**
2. Find **WhatsApp** and click **Set Up**
3. You'll see the **Quickstart** page with your API credentials

## Step 4: Get Your Credentials

From the WhatsApp Quickstart page, note down:

- **Access Token** (Temporary or Permanent)
- **Phone Number ID**
- **Recipient Phone Number** (your test phone number)

### Get a Permanent Access Token

Temporary tokens expire in 24 hours. For production, get a permanent token:

1. Go to **System Users** in Business Settings
2. Create a system user
3. Add WhatsApp App permission to the system user
4. Generate a token with `whatsapp_business_messaging` scope

## Step 5: Configure satibot

Create your config file at `~/.bots/config.json`:

```bash
mkdir -p ~/.bots
code ~/.bots/config.json
```

Add the WhatsApp configuration:

```json
{
  "agents": {
    "defaults": {
      "model": "anthropic/claude-3-5-sonnet-20241022"
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
    "whatsapp": {
      "accessToken": "YOUR_ACCESS_TOKEN",
      "phoneNumberId": "YOUR_PHONE_NUMBER_ID",
      "recipientPhoneNumber": "YOUR_PHONE_NUMBER"
    }
  }
}
```

Replace:
- `YOUR_OPENROUTER_API_KEY` - Your OpenRouter API key
- `YOUR_ACCESS_TOKEN` - From Step 4
- `YOUR_PHONE_NUMBER_ID` - From Step 4
- `YOUR_PHONE_NUMBER` - Your test phone number (with country code, e.g., `+1234567890`)

## Step 6: Run satibot in WhatsApp Mode

Start the WhatsApp bot:

```bash
zig build run -- whatsapp
```

**Note**: The WhatsApp bot requires a public HTTPS webhook endpoint. For local development:

### Using ngrok (Local Development)

1. Install [ngrok](https://ngrok.com/)
2. Start ngrok to tunnel port 8080:
   ```bash
   ngrok http 8080
   ```
3. Copy the HTTPS URL (e.g., `https://abc123.ngrok.io`)
4. In Meta Developer Dashboard, configure webhook:
   - **Callback URL**: `https://abc123.ngrok.io/webhook`
   - **Verify Token**: `satibot_webhook_token`

## Step 7: Start Messaging

1. Open WhatsApp on your phone
2. Send a message to your test number (the one configured in Meta Dashboard)
3. The bot will respond using your configured LLM

---

## Quick Setup via WhatsApp (Auto-Config)

If you have satibot running (even partially configured), you can use the `/setibot` command in WhatsApp:

1. Send the message: `/setibot` to your bot
2. The bot will create a default config file at `~/.bots/config.json` with:
   - Default model: `anthropic/claude-3-5-sonnet-20241022`
   - Template API keys (you need to fill these in)
   - Your phone number (shown for easy reference)
3. Edit the config file with your real API credentials
4. Restart satibot

### Available Commands

Once connected, these commands are available in WhatsApp:

- `/help` - Show available commands
- `/setibot` - Generate default config file
- `/new` - Clear conversation session memory
- Any other message - Chat with the AI assistant

---

## Webhook Configuration

### Meta Dashboard Webhook Setup

1. In Meta Developer Dashboard, go to **WhatsApp > Configuration**
2. Under **Webhooks**, click **Configure**
3. Add webhook configuration:
   - **Callback URL**: Your HTTPS URL + `/webhook`
   - **Verify Token**: `satibot_webhook_token`
4. Subscribe to events:
   - `messages`

### Webhook Verification

The webhook must respond to verification requests. satibot's WhatsApp bot includes automatic verification handling for the `/webhook` endpoint.

---

## Features

- **Message Processing**: Incoming WhatsApp messages are processed by the AI agent
- **Session Management**: Each phone number gets its own conversation session
- **RAG Integration**: Conversations are indexed to the vector database for long-term memory
- **Tool Access**: All registered tools (web search, files, etc.) are available if configured

---

## Troubleshooting

### Webhook Not Receiving Messages

- Ensure ngrok is running and the URL is correct in Meta Dashboard
- Check that you're subscribed to `messages` webhook events
- Verify your verify token matches `satibot_webhook_token`

### "Message failed to send"

- Check your access token hasn't expired
- Verify the phone number ID is correct
- Ensure the recipient phone number is in international format (+1234567890)

### Bot Not Responding

- Check satibot logs for errors
- Verify your OpenRouter API key is valid
- Ensure the WhatsApp configuration in `config.json` is complete

---

## Production Deployment

For production:

1. Get a permanent access token (not temporary)
2. Deploy to a server with a public IP/domain
3. Use proper SSL/TLS certificates
4. Configure webhook with your production HTTPS URL
5. Consider rate limiting and message queueing for high volume

---

## Related Documentation

- [CONFIGURATION.md](./CONFIGURATION.md) - Full configuration reference
- [TELEGRAM_GUIDE.md](./TELEGRAM_GUIDE.md) - Telegram bot setup
