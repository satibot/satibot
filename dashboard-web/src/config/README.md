# Config API Server

A Bun-based API server for serving and managing SatiBot configuration files with real-time WebSocket updates.

## Features

- **REST API**: CRUD operations for config files
- **Real-time Updates**: WebSocket integration for live config changes
- **File Watching**: Automatic detection of file system changes
- **CORS Support**: Cross-origin requests enabled
- **Type Safety**: TypeScript interfaces for all data structures

## Available Config Files

- `config.json` - Main bot configuration (agents, providers, tools)
- `soul.md` - Bot's identity and personality
- `user.md` - User context and preferences
- `memory.md` - Long-term memory and learned facts

## API Endpoints

### Get All Configs

```
GET /api/config
```

Returns all configuration files in a single response.

### Get Specific Config

```
GET /api/config/{type}
```

Where `{type}` is one of: `config`, `soul`, `user`, `memory`

### Update Config

```
POST /api/config/{type}
Content-Type: application/json (for config) or text/plain (for .md files)
```

## WebSocket Events

Connect to `ws://localhost:3002` for real-time updates:

- `initial` - All current configs on connection
- `update` - Individual config updates with `{ type, content }`

## Usage

### Start the Server

```bash
cd dashboard-web
bun run config-api
```

### Server URLs

- **HTTP API**: <http://localhost:3001>
- **WebSocket**: ws://localhost:3002

### Client Integration

```typescript
import { useConfig } from './config/useConfig';

function MyComponent() {
  const { configs, loading, error, updateConfig, connected } = useConfig();
  
  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error}</div>;
  
  return (
    <div>
      <div>Connected: {connected ? 'Yes' : 'No'}</div>
      <pre>{JSON.stringify(configs.config, null, 2)}</pre>
      <textarea 
        value={configs.soul || ''} 
        onChange={(e) => updateConfig('soul', e.target.value)}
      />
    </div>
  );
}
```

## File Structure

```text
src/config/
├── api.ts           # Bun server implementation
├── ConfigService.ts # Client-side API service
├── useConfig.ts     # React hook for state management
├── ConfigFileManager.tsx # UI component
└── README.md        # This file
```

## Development Notes

- The server watches for file changes in `../../../sample/` directory
- Config files are automatically reloaded when modified on disk
- WebSocket clients receive real-time updates
- JSON validation is performed for `config.json` updates
- Graceful shutdown on SIGINT (Ctrl+C)

## Error Handling

- File not found: Returns empty object for JSON, empty string for markdown
- Invalid JSON: Returns validation error
- Network errors: Automatic WebSocket reconnection after 3 seconds
- CORS: All origins allowed for development

## Security Considerations

- No authentication (development only)
- File system access limited to sample directory
- Input validation for JSON parsing
- Error messages don't expose sensitive paths
