// Example backend server for streaming chat logs and config management
// Run with: `bun api/index.ts`

import {
	existsSync,
	mkdirSync,
	readFileSync,
	watchFile,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { WebSocket, WebSocketServer } from "ws";

// Import config functions
import {
	broadcastConfigUpdate,
	FILES,
	getAllConfigs,
	readConfigFile,
	setupFileWatchers,
} from "./config";

const PORT = 3003;
const wssLogs = new WebSocketServer({ port: 8080 });
const wssConfig = new WebSocketServer({ port: 3004 });
const logClients = new Set<WebSocket>();
const configClients = new Set<WebSocket>();

console.log("WebSocket server started on ws://localhost:8080/logs");
console.log("WebSocket config server started on ws://localhost:3004/config");

// Log entry interface
interface LogEntry {
	id: string;
	timestamp: string;
	level: "info" | "warn" | "error";
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

function readChatLogs(): LogEntry[] {
	const configPath = join(homedir(), ".bots/config.json");

	try {
		if (!existsSync(configPath)) {
			return [];
		}

		const content = readFileSync(configPath, "utf8");
		const configData = JSON.parse(content);

		const allLogs: LogEntry[] = [];

		if (configData.agents) {
			const timestamp = new Date().toISOString();
			allLogs.push({
				id: "config-0",
				timestamp: timestamp,
				level: "info",
				message: `Bot configuration loaded with agents: ${JSON.stringify(configData.agents || {})}`,
				sessionId: "config",
				userId: "system",
				metadata: {
					problem: "Configuration monitoring",
					action: "Read config file",
					files: "config.json",
					techStack: "JSON configuration",
				},
			});
		}

		return allLogs;
	} catch (error) {
		console.error("Error reading config file:", error);
		return [];
	}
}

// Initialize config directory and file
function initializeConfig(): void {
	const configDir = join(homedir(), ".bots");
	const configPath = FILES.config;

	if (!existsSync(configDir)) {
		console.log("Bots directory not found, creating...");
		mkdirSync(configDir, { recursive: true });
	}

	if (!existsSync(configPath)) {
		console.log("Config file not found, creating placeholder...");
		writeFileSync(
			configPath,
			JSON.stringify(
				{ agents: { defaults: { model: "z-ai/glm-4.5-air:free" } } },
				null,
				2,
			),
			"utf8",
		);
	}
}

// Watch config file for changes and broadcast to log clients
function watchConfigFile(): void {
	watchFile(FILES.config, (_curr, _prev) => {
		console.log("Config file changed, broadcasting updates...");
		const logs = readChatLogs();
		broadcastLogs(logs);
	});
}

// Broadcast logs to WebSocket clients
function broadcastLogs(logs: LogEntry[]): void {
	const message = JSON.stringify(logs);

	logClients.forEach((client) => {
		if (client.readyState === WebSocket.OPEN) {
			client.send(message);
		}
	});
}

// Handle WebSocket connections for logs
wssLogs.on("connection", (ws: WebSocket) => {
	console.log("New log client connected");
	logClients.add(ws);

	// Send existing logs on connection
	const logs = readChatLogs();
	ws.send(JSON.stringify(logs));

	ws.on("close", () => {
		console.log("Log client disconnected");
		logClients.delete(ws);
	});

	ws.on("error", (error: Error) => {
		console.error("Log WebSocket error:", error);
		logClients.delete(ws);
	});
});

// Handle WebSocket connections for config
wssConfig.on("connection", (ws: WebSocket) => {
	console.log("New config client connected");
	configClients.add(ws);

	const configs = getAllConfigs();
	ws.send(JSON.stringify({ type: "initial", data: configs }));

	ws.on("close", () => {
		console.log("Config client disconnected");
		configClients.delete(ws);
	});

	ws.on("error", (error: Error) => {
		console.error("Config WebSocket error:", error);
		configClients.delete(ws);
	});
});

// Setup file watchers for config changes
setupFileWatchers(configClients);

// Initialize config system
initializeConfig();
watchConfigFile();

// HTTP server using Bun
const server = Bun.serve({
	port: PORT,
	async fetch(req: Request) {
		const url = new URL(req.url);
		const path = url.pathname;

		const corsHeaders = {
			"Access-Control-Allow-Origin": "*",
			"Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
			"Access-Control-Allow-Headers": "Content-Type, Authorization",
		};

		if (req.method === "OPTIONS") {
			return new Response(null, { headers: corsHeaders });
		}

		try {
			switch (path) {
				case "/api/config":
					if (req.method === "GET") {
						const configs = getAllConfigs();
						return new Response(JSON.stringify(configs, null, 2), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					}
					break;

				case "/api/config/config":
					if (req.method === "GET") {
						const config = readConfigFile(FILES.config);
						return new Response(JSON.stringify(config, null, 2), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					} else if (req.method === "POST") {
						const body = (await req.json()) as Record<string, unknown>;
						writeFileSync(FILES.config, JSON.stringify(body, null, 2));
						broadcastConfigUpdate("config", body, configClients);
						return new Response(JSON.stringify({ success: true }), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					}
					break;

				case "/api/config/soul":
					if (req.method === "GET") {
						const soul = readConfigFile(FILES.soul) as string;
						return new Response(soul, {
							headers: { "Content-Type": "text/plain", ...corsHeaders },
						});
					} else if (req.method === "POST") {
						const body = await req.text();
						writeFileSync(FILES.soul, body);
						broadcastConfigUpdate("soul", body, configClients);
						return new Response(JSON.stringify({ success: true }), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					}
					break;

				case "/api/config/user":
					if (req.method === "GET") {
						const user = readConfigFile(FILES.user) as string;
						return new Response(user, {
							headers: { "Content-Type": "text/plain", ...corsHeaders },
						});
					} else if (req.method === "POST") {
						const body = await req.text();
						writeFileSync(FILES.user, body);
						broadcastConfigUpdate("user", body, configClients);
						return new Response(JSON.stringify({ success: true }), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					}
					break;

				case "/api/config/memory":
					if (req.method === "GET") {
						const memory = readConfigFile(FILES.memory) as string;
						return new Response(memory, {
							headers: { "Content-Type": "text/plain", ...corsHeaders },
						});
					} else if (req.method === "POST") {
						const body = await req.text();
						writeFileSync(FILES.memory, body);
						broadcastConfigUpdate("memory", body, configClients);
						return new Response(JSON.stringify({ success: true }), {
							headers: { "Content-Type": "application/json", ...corsHeaders },
						});
					}
					break;

				default:
					return new Response("Not Found", { status: 404 });
			}
		} catch (error) {
			console.error("API Error:", error);
			return new Response(JSON.stringify({ error: "Internal Server Error" }), {
				status: 500,
				headers: { "Content-Type": "application/json", ...corsHeaders },
			});
		}

		return new Response("Method Not Allowed", { status: 405 });
	},
});

// Start watching files
// watchLogFile() is now handled by watchConfigFile()
// setupConfigFileWatchers() is now handled by setupFileWatchers(configClients)

// Simulate real-time log updates (for testing)
setInterval(() => {
	const testLog: LogEntry = {
		id: `test-${Date.now()}`,
		timestamp: new Date().toISOString(),
		level: "info",
		message: `Test log entry at ${new Date().toLocaleTimeString()}`,
		sessionId: "test-session",
		userId: "test-user",
	};

	broadcastLogs([testLog]);
}, 30000);

console.log("Server is running...");
console.log(`HTTP server started on http://localhost:${PORT}`);
console.log(`  GET/POST http://localhost:${PORT}/api/config - All configs`);
console.log(
	`  GET/POST http://localhost:${PORT}/api/config/config - JSON config`,
);
console.log(`  GET/POST http://localhost:${PORT}/api/config/soul - Soul.md`);
console.log(`  GET/POST http://localhost:${PORT}/api/config/user - User.md`);
console.log(
	`  GET/POST http://localhost:${PORT}/api/config/memory - Memory.md`,
);

// Graceful shutdown
process.on("SIGINT", () => {
	console.log("\nShutting down servers...");
	server.stop();
	wssLogs.close();
	wssConfig.close();
	process.exit(0);
});
