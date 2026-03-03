import { useCallback, useEffect, useRef, useState } from 'react';

export interface LogEntry {
	id: string;
	timestamp: string;
	level: 'info' | 'warn' | 'error' | 'debug';
	message: string;
	sessionId?: string;
	userId?: string;
	metadata?: Record<string, unknown>;
}

interface ChatLogMonitorProps {
	wsUrl?: string;
	maxEntries?: number;
}

export function ChatLogMonitor({
	wsUrl = 'ws://localhost:8080/logs',
	maxEntries = 100,
}: ChatLogMonitorProps) {
	const [logs, setLogs] = useState<LogEntry[]>([]);
	const [isConnected, setIsConnected] = useState(false);
	const [filter, setFilter] = useState('');
	const [levelFilter, setLevelFilter] = useState<string>('all');
	const [isPaused, setIsPaused] = useState(false);
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
				if (isPaused) return;

				try {
					const logEntry: LogEntry = JSON.parse(event.data);
					setLogs((prev) => {
						const updated = [logEntry, ...prev];
						return updated.slice(0, maxEntries);
					});
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
	}, [wsUrl, isPaused, maxEntries]);

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

	const filteredLogs = logs.filter((log) => {
		const matchesSearch =
			filter === '' ||
			log.message.toLowerCase().includes(filter.toLowerCase()) ||
			log.sessionId?.toLowerCase().includes(filter.toLowerCase()) ||
			log.userId?.toLowerCase().includes(filter.toLowerCase());

		const matchesLevel = levelFilter === 'all' || log.level === levelFilter;

		return matchesSearch && matchesLevel;
	});

	const clearLogs = () => {
		setLogs([]);
	};

	const togglePause = () => {
		setIsPaused(!isPaused);
	};

	const getLevelColor = (level: string) => {
		switch (level) {
			case 'error':
				return 'text-red-600 bg-red-50';
			case 'warn':
				return 'text-yellow-600 bg-yellow-50';
			case 'info':
				return 'text-blue-600 bg-blue-50';
			case 'debug':
				return 'text-gray-600 bg-gray-50';
			default:
				return 'text-gray-600 bg-gray-50';
		}
	};

	const formatTimestamp = (timestamp: string) => {
		return new Date(timestamp).toLocaleTimeString();
	};

	return (
		<div className="chat-log-monitor">
			<div className="flex items-center justify-between mb-4">
				<h3 className="text-lg font-semibold text-white">Chat Logs</h3>
				<div className="flex items-center gap-2">
					<div
						className={`w-2 h-2 rounded-full ${isConnected ? 'bg-green-500' : 'bg-red-500'}`}
					></div>
					<span className="text-sm text-gray-300">
						{isConnected ? 'Connected' : 'Disconnected'}
					</span>
				</div>
			</div>

			<div className="flex flex-col sm:flex-row gap-4 mb-4">
				<div className="flex-1">
					<input
						type="text"
						placeholder="Search logs..."
						value={filter}
						onChange={(e) => setFilter(e.target.value)}
						className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
					/>
				</div>
				<select
					value={levelFilter}
					onChange={(e) => setLevelFilter(e.target.value)}
					className="px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
				>
					<option value="all">All Levels</option>
					<option value="error">Error</option>
					<option value="warn">Warning</option>
					<option value="info">Info</option>
					<option value="debug">Debug</option>
				</select>
				<button
					type="button"
					onClick={togglePause}
					className={`px-4 py-2 rounded-md text-white font-medium transition-colors ${
						isPaused
							? 'bg-green-600 hover:bg-green-700'
							: 'bg-yellow-600 hover:bg-yellow-700'
					}`}
				>
					{isPaused ? 'Resume' : 'Pause'}
				</button>
				<button
					type="button"
					onClick={clearLogs}
					className="px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700 font-medium transition-colors"
				>
					Clear
				</button>
			</div>

			<div className="bg-gray-900 rounded-lg p-4 h-96 overflow-y-auto font-mono text-sm">
				{filteredLogs.length === 0 ? (
					<div className="text-gray-400 text-center py-8">
						{filter || levelFilter !== 'all'
							? 'No logs match the current filters'
							: 'No logs available yet'}
					</div>
				) : (
					<div className="space-y-2">
						{filteredLogs.map((log) => (
							<div
								key={log.id}
								className="border-b border-gray-700 pb-2 last:border-b-0"
							>
								<div className="flex items-start gap-2">
									<span className="text-gray-400 text-xs whitespace-nowrap">
										{formatTimestamp(log.timestamp)}
									</span>
									<span
										className={`px-2 py-1 rounded text-xs font-medium ${getLevelColor(log.level || 'info')}`}
									>
										{log.level?.toUpperCase() || 'INFO'}
									</span>
									{(log.sessionId || log.userId) && (
										<div className="flex gap-2">
											{log.sessionId && (
												<span className="text-xs text-purple-400">
													Session: {log.sessionId}
												</span>
											)}
											{log.userId && (
												<span className="text-xs text-blue-400">
													User: {log.userId}
												</span>
											)}
										</div>
									)}
								</div>
								<div className="mt-1 text-gray-300 break-words">
									{log.message}
								</div>
							</div>
						))}
					</div>
				)}
			</div>

			<div className="mt-2 text-xs text-gray-400 text-right">
				Showing {filteredLogs.length} of {logs.length} logs
			</div>
		</div>
	);
}

export default ChatLogMonitor;
