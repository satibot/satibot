import { useCallback, useEffect, useRef, useState } from 'react';
import type { LogEntry } from './ChatLogMonitor';

interface LogStreamerProps {
  onLogEntry: (entry: LogEntry) => void;
  wsUrl?: string;
}

export function LogStreamer({
  onLogEntry,
  wsUrl = 'ws://localhost:8080/logs',
}: LogStreamerProps) {
  const [isConnected, setIsConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimeoutRef = useRef<NodeJS.Timeout>();

  const connectWebSocket = useCallback(() => {
    try {
      const ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        setIsConnected(true);
        console.log('Connected to chat log stream');
      };

      ws.onmessage = (event) => {
        try {
          const logEntry = JSON.parse(event.data);
          onLogEntry(logEntry);
        } catch (error) {
          console.error('Failed to parse log entry:', error);
        }
      };

      ws.onclose = () => {
        setIsConnected(false);
        console.log('Disconnected from chat log stream');

        // Reconnect after 3 seconds
        reconnectTimeoutRef.current = setTimeout(() => {
          connectWebSocket();
        }, 3000);
      };

      ws.onerror = (error) => {
        console.error('WebSocket error:', error);
      };
    } catch (error) {
      console.error('Failed to connect to WebSocket:', error);
      setIsConnected(false);
    }
  }, [wsUrl, onLogEntry]);

  useEffect(() => {
    connectWebSocket();

    return () => {
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, [connectWebSocket]);

  return isConnected;
}

export default LogStreamer;
