// Config API server for dashboard-web
// Export functions to be used by index.ts

import { existsSync, readFileSync, watchFile } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";

// Config file paths - updated for new location
const CONFIG_DIR = join(homedir(), ".bots");
export const FILES = {
	config: join(CONFIG_DIR, "config.json"),
	soul: join(CONFIG_DIR, "soul.md"),
	user: join(CONFIG_DIR, "user.md"),
	memory: join(CONFIG_DIR, "memory.md"),
};

// Type definitions
export interface ConfigData {
	config?: Record<string, unknown>;
	soul?: string;
	user?: string;
	memory?: string;
}

export interface ConfigUpdate {
	type: keyof typeof FILES;
	content: string | Record<string, unknown>;
}

// Read config file content
export function readConfigFile(filePath: string): string | object {
	try {
		if (!existsSync(filePath)) {
			console.warn(`Config file not found: ${filePath}`);
			return filePath.endsWith(".json") ? {} : "";
		}

		const content = readFileSync(filePath, "utf8");
		return filePath.endsWith(".json") ? JSON.parse(content) : content;
	} catch (error) {
		console.error(`Error reading config file ${filePath}:`, error);
		return filePath.endsWith(".json") ? {} : "";
	}
}

// Get all config data
export function getAllConfigs(): ConfigData {
	return {
		config: readConfigFile(FILES.config) as Record<string, unknown>,
		soul: readConfigFile(FILES.soul) as string,
		user: readConfigFile(FILES.user) as string,
		memory: readConfigFile(FILES.memory) as string,
	};
}

// Broadcast config updates to WebSocket clients
export function broadcastConfigUpdate(
	type: keyof typeof FILES,
	content: string | Record<string, unknown>,
	clients: Set<WebSocket>,
): void {
	const update: ConfigUpdate = { type, content };
	const message = JSON.stringify(update);

	clients.forEach((client) => {
		if (client.readyState === WebSocket.OPEN) {
			client.send(message);
		}
	});
}

// Watch for config file changes
export function setupFileWatchers(clients: Set<WebSocket>): void {
	Object.entries(FILES).forEach(([type, filePath]) => {
		if (existsSync(filePath)) {
			watchFile(filePath, () => {
				console.log(`Config file changed: ${type}`);
				const content = readConfigFile(filePath);
				broadcastConfigUpdate(
					type as keyof typeof FILES,
					content as string | Record<string, unknown>,
					clients,
				);
			});
		}
	});
}
