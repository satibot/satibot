# satibot-dashboard-web

WARNING: This is a work in progress and is not yet ready for use.

A configuration management dashboard for SatiBot.

## Features

- **Configuration Management**: Manage bot settings and configuration files
- **Real-time Chat Log Monitoring**: Live streaming and monitoring of chat logs with filtering and search
- **Responsive Design**: Works on desktop and mobile devices
- **Modern UI**: Built with React, TypeScript, and Tailwind CSS

## Setup

Install the dependencies:

```bash
bun i
```

## Get started

Start the dev server, and the app will be available at [http://localhost:3000](http://localhost:3000).

```bash
bun run dev
```

### Real-time Chat Log Monitoring

To enable real-time chat log monitoring, you need to run the WebSocket backend server:

1. Install dependencies for the backend:

```bash
cd src/chat
bun add ws
```

1. Start the WebSocket server:

```bash
bun run src/chat/api.ts
```

The server will:

- Stream chat logs from `../../logs/chat.csv`
- Watch for file changes and broadcast updates
- Provide a WebSocket endpoint at `ws://localhost:8080/logs`
- Generate test log entries every 30 seconds for demonstration

Build the app for production:

```bash
bun run build
```

Preview the production build locally:

```bash
bun run preview
```

## Learn more

To learn more about Rsbuild, check out the following resources:

- [Rsbuild documentation](https://rsbuild.rs) - explore Rsbuild features and APIs.
- [Rsbuild GitHub repository](https://github.com/web-infra-dev/rsbuild) - your feedback and contributions are welcome!
