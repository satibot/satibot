# SatiBot API

WebSocket and HTTP servers for the SatiBot dashboard.

## Usage

```bash
# Start the chat logs API server (WebSocket on port 8080)
bun run dev

# Start the config API server (HTTP on port 3001, WebSocket on port 3002)
bun run config

# Or from the root workspace
bun run api:dev      # Chat logs API
bun run api:config   # Config API
```

## Services

### Chat Logs API (`index.ts`)

- **WebSocket**: `ws://localhost:8080/logs`
- Real-time streaming of chat logs and bot configuration monitoring
- Monitors `~/.bots/config.json` for changes
- Test log generation every 30 seconds

### Config API (`config.ts`)

- **HTTP API**: `http://localhost:3003`
- **WebSocket**: `ws://localhost:3004`
- RESTful endpoints for managing bot configuration files
- Real-time config updates via WebSocket
- File watching for automatic updates

#### Config API Endpoints

- `GET/POST /api/config` - All configurations
- `GET/POST /api/config/config` - JSON config file
- `GET/POST /api/config/soul` - Soul.md file
- `GET/POST /api/config/user` - User.md file  
- `GET/POST /api/config/memory` - Memory.md file

## Features

- Real-time WebSocket streaming
- Configuration file monitoring
- CORS support for web dashboard integration
- Graceful shutdown handling
- Automatic file watching and updates
