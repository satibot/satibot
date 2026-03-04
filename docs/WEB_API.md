# 🌐 Web API Guide

SatiBot provides a RESTful Web API built with the [zap](https://github.com/zigzap/zap) framework. This allows you to integrate SatiBot with web frontends or other services.

## Quick Start

1. **Build and Run**:

   ```bash
   zig build run-web -Dweb
   ```

   Or using the `sati` CLI:

   ```bash
   sati web
   ```

2. **Default Port**: The server listens on `http://localhost:8080` by default.

## API Endpoints

### `GET /`

Returns the API status.

- **Response**: `{"status":"ok","message":"SatiBot API"}`

### `GET /api/config`

Get current bot configuration. API keys are **removed** from the response for security.

- **Response**:

  ```json
  {
    "config": {
      "agents": {
        "defaults": {
          "model": "arcee-ai/trinity-large-preview:free",
          "embeddingModel": "local",
          "disableRag": false,
          "loadChatHistory": false,
          "maxChatHistory": 2
        }
      },
      "providers": {
        "openrouter": {},
        "anthropic": null
      },
      "tools": {
        "web": {
          "search": {},
          "server": null
        },
        "telegram": null,
        "discord": null,
        "whatsapp": null
      }
    }
  }
  ```

### `PUT /api/config`

Update bot configuration. API keys are preserved from existing config (client cannot update sensitive keys).

- **Request Body**: Configuration object (API keys are ignored - use CLI or direct file edit to update them)

- **Request Body**: Full configuration object (see [`~/.bots/config.json`](./CONFIGURATION.md))

- **Response**:

  ```json
  {
    "success": true
  }
  ```

### `POST /api/chat`

The main endpoint for chat interactions.

- **Request Body**:

  ```json
  {
    "messages": [
      { "role": "user", "content": "Hello!" }
    ]
  }
  ```

- **Response**:

  ```json
  {
    "content": "Hello! How can I help you today?"
  }
  ```

## CORS Configuration

By default, the server allows all origins (`*`). You can restrict this in your `~/.bots/config.json`:

```json
{
  "tools": {
    "web": {
      "server": {
        "allowOrigin": "http://localhost:3000"
      }
    }
  }
}
```

## Security Note

Currently, the Web API does not have built-in authentication. It is recommended to run it behind a reverse proxy (like Nginx) or use it only in trusted local environments.
