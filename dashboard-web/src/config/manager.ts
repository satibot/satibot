import type { ConfigFile, ConfigFileInput } from './types';

const STORAGE_KEY = 'dashboard_config_files';

function generateId(): string {
	return `config_${Date.now()}_${Math.random().toString(36).slice(2, 11)}`;
}

function getStoredConfigs(): ConfigFile[] {
	try {
		const stored = localStorage.getItem(STORAGE_KEY);
		return stored ? JSON.parse(stored) : [];
	} catch {
		return [];
	}
}

function saveConfigs(configs: ConfigFile[]): void {
	localStorage.setItem(STORAGE_KEY, JSON.stringify(configs));
}

export function readConfigFiles(): ConfigFile[] {
	return getStoredConfigs();
}

export function readConfigFile(id: string): ConfigFile | undefined {
	const configs = getStoredConfigs();
	return configs.find((c) => c.id === id);
}

export function createConfigFile(input: ConfigFileInput): ConfigFile {
	const configs = getStoredConfigs();
	const now = Date.now();
	const newConfig: ConfigFile = {
		id: generateId(),
		name: input.name,
		content: input.content,
		createdAt: now,
		updatedAt: now,
	};
	configs.push(newConfig);
	saveConfigs(configs);
	return newConfig;
}

export function updateConfigFile(
	id: string,
	input: Partial<ConfigFileInput>,
): ConfigFile | undefined {
	const configs = getStoredConfigs();
	const index = configs.findIndex((c) => c.id === id);
	if (index === -1) return undefined;

	const updated: ConfigFile = {
		...configs[index],
		...input,
		updatedAt: Date.now(),
	};
	configs[index] = updated;
	saveConfigs(configs);
	return updated;
}

export function deleteConfigFile(id: string): boolean {
	const configs = getStoredConfigs();
	const index = configs.findIndex((c) => c.id === id);
	if (index === -1) return false;

	configs.splice(index, 1);
	saveConfigs(configs);
	return true;
}
