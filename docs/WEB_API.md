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
