// Client-side service for config API

export interface ConfigData {
	config?: Record<string, unknown>;
	soul?: string;
	user?: string;
	memory?: string;
}

export interface ConfigUpdate {
	type: 'config' | 'soul' | 'user' | 'memory';
	content: string | Record<string, unknown>;
}

class ConfigService {
	private baseUrl: string;
	private wsUrl: string;
	private ws: WebSocket | null = null;
	private listeners: Map<string, ((data: unknown) => void)[]> = new Map();

	constructor() {
		this.baseUrl = 'http://localhost:3001/api/config';
		this.wsUrl = 'ws://localhost:3002';
	}

	// Get all configs
	async getAllConfigs(): Promise<ConfigData> {
		const response = await fetch(this.baseUrl);
		if (!response.ok) {
			throw new Error(`Failed to fetch configs: ${response.statusText}`);
		}

		const text = await response.text();
		try {
			return JSON.parse(text);
		} catch (_error) {
			console.error('Invalid JSON response:', text.substring(0, 200));
			throw new Error('Invalid JSON response from server');
		}
	}

	// Get specific config
	async getConfig(
		type: keyof ConfigData,
	): Promise<string | Record<string, unknown>> {
		const response = await fetch(`${this.baseUrl}/${type}`);
		if (!response.ok) {
			throw new Error(`Failed to fetch ${type}: ${response.statusText}`);
		}

		if (type === 'config') {
			const text = await response.text();
			try {
				return JSON.parse(text);
			} catch (_error) {
				console.error('Invalid JSON response:', text.substring(0, 200));
				throw new Error('Invalid JSON response from server');
			}
		} else {
			return response.text();
		}
	}

	// Update specific config
	async updateConfig(
		type: keyof ConfigData,
		content: string | Record<string, unknown>,
	): Promise<void> {
		const response = await fetch(`${this.baseUrl}/${type}`, {
			method: 'POST',
			headers: {
				'Content-Type': type === 'config' ? 'application/json' : 'text/plain',
			},
			body: type === 'config' ? JSON.stringify(content) : (content as string),
		});

		if (!response.ok) {
			throw new Error(`Failed to update ${type}: ${response.statusText}`);
		}
	}

	// Connect to WebSocket for real-time updates
	connectWebSocket(): void {
		if (this.ws) {
			this.ws.close();
		}

		this.ws = new WebSocket(this.wsUrl);

		this.ws.onopen = () => {
			console.log('Connected to config WebSocket');
		};

		this.ws.onmessage = (event) => {
			try {
				const data = JSON.parse(event.data);

				if (data.type === 'initial') {
					this.emit('initial', data.data);
				} else if (data.type && data.content !== undefined) {
					this.emit('update', data);
				}
			} catch (error) {
				console.error('Error parsing WebSocket message:', error);
			}
		};

		this.ws.onclose = () => {
			console.log('Disconnected from config WebSocket');
			// Auto-reconnect after 3 seconds
			setTimeout(() => {
				this.connectWebSocket();
			}, 3000);
		};

		this.ws.onerror = (error) => {
			console.error('WebSocket error:', error);
		};
	}

	// Event listeners
	on(event: 'initial' | 'update', callback: (data: unknown) => void): void {
		if (!this.listeners.has(event)) {
			this.listeners.set(event, []);
		}
		this.listeners.get(event)?.push(callback);
	}

	off(event: 'initial' | 'update', callback: (data: unknown) => void): void {
		const callbacks = this.listeners.get(event);
		if (callbacks) {
			const index = callbacks.indexOf(callback);
			if (index > -1) {
				callbacks.splice(index, 1);
			}
		}
	}

	private emit(event: 'initial' | 'update', data: unknown): void {
		const callbacks = this.listeners.get(event);
		if (callbacks) {
			callbacks.forEach((callback) => {
				callback(data);
			});
		}
	}

	// Disconnect WebSocket
	disconnect(): void {
		if (this.ws) {
			this.ws.close();
			this.ws = null;
		}
	}
}

export const configService = new ConfigService();
