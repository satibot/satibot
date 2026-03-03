// Example backend server for streaming chat logs
// Save this as a separate file and run with: `bun api.ts`

import { existsSync, readFileSync, watchFile, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { WebSocket, WebSocketServer } from 'ws';

const wss = new WebSocketServer({ port: 8080 });
const clients = new Set<WebSocket>();

console.log('WebSocket server started on ws://localhost:8080/logs');

// Log entry interface
interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'warn' | 'error';
  message: string;
  sessionId?: string;
  userId?: string;
  metadata?: {
    problem?: string;
    action?: string;
    files?: string;
    techStack?: string;
  };
}

// Function to read and parse chat logs
function readChatLogs(): LogEntry[] {
  const logPath = join(__dirname, '../../logs/chat.csv');

  try {
    if (!existsSync(logPath)) {
      return [];
    }

    const content = readFileSync(logPath, 'utf8');
    const lines = content.split('\n').filter((line: string) => line.trim());

    // Skip header if exists
    const dataLines = lines[0].includes('timestamp') ? lines.slice(1) : lines;

    return dataLines
      .map((line: string, index: number) => {
        const [
          timestamp,
          taskName,
          tags,
          problem,
          solution,
          action,
          files,
          techStack,
          createdBy,
        ] = line.split(',');

        return {
          id: `log-${index}`,
          timestamp: timestamp || new Date().toISOString(),
          level: 'info' as const,
          message: `Task: ${taskName || 'Unknown'} - ${solution || 'No solution'}`,
          sessionId: tags,
          userId: createdBy,
          metadata: {
            problem,
            action,
            files,
            techStack,
          },
        };
      })
      .reverse(); // Show newest first
  } catch (error) {
    console.error('Error reading chat logs:', error);
    return [];
  }
}

// Function to watch for file changes
function watchLogFile(): void {
  const logPath = join(__dirname, '../../logs/chat.csv');

  if (!existsSync(logPath)) {
    console.log('Log file not found, creating placeholder...');
    writeFileSync(
      logPath,
      'timestamp,task_name,tags,problem,solution,action,files,tech_stack,created_by\n',
      'utf8',
    );
  }

  watchFile(logPath, (_curr, _prev) => {
    console.log('Log file changed, broadcasting updates...');
    const logs = readChatLogs();
    broadcastLogs(logs.slice(0, 10)); // Send latest 10 entries
  });
}

// Function to broadcast logs to all connected clients
function broadcastLogs(logs: LogEntry[]): void {
  const message = JSON.stringify(logs);

  clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  });
}

// Handle WebSocket connections
wss.on('connection', (ws: WebSocket) => {
  console.log('New client connected');
  clients.add(ws);

  // Send existing logs on connection
  const logs = readChatLogs();
  ws.send(JSON.stringify(logs));

  // Handle client disconnection
  ws.on('close', () => {
    console.log('Client disconnected');
    clients.delete(ws);
  });

  ws.on('error', (error: Error) => {
    console.error('WebSocket error:', error);
    clients.delete(ws);
  });
});

// Start watching the log file
watchLogFile();

// Simulate real-time log updates (for testing)
setInterval(() => {
  const testLog: LogEntry = {
    id: `test-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    message: `Test log entry at ${new Date().toLocaleTimeString()}`,
    sessionId: 'test-session',
    userId: 'test-user',
  };

  broadcastLogs([testLog]);
}, 30000); // Every 30 seconds

console.log('Chat log streaming server is running...');
