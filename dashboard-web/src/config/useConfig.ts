import { useCallback, useEffect, useState } from 'react';
import type { ConfigData, ConfigUpdate } from './ConfigService';
import { configService } from './ConfigService';

export function useConfig() {
	const [configs, setConfigs] = useState<ConfigData>({});
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const [connected, setConnected] = useState(false);

	// Load initial configs
	const loadConfigs = useCallback(async () => {
		try {
			setLoading(true);
			setError(null);
			const data = await configService.getAllConfigs();
			setConfigs(data);
		} catch (err) {
			setError(err instanceof Error ? err.message : 'Failed to load configs');
		} finally {
			setLoading(false);
		}
	}, []);

	// Update specific config
	const updateConfig = useCallback(
		async (
			type: keyof ConfigData,
			content: string | Record<string, unknown>,
		) => {
			try {
				await configService.updateConfig(
					type,
					content as string | Record<string, unknown>,
				);
				// Optimistically update local state
				setConfigs((prev) => ({ ...prev, [type]: content }));
			} catch (err) {
				setError(
					err instanceof Error ? err.message : `Failed to update ${type}`,
				);
				throw err;
			}
		},
		[],
	);

	// Get specific config
	const getConfig = useCallback(async (type: keyof ConfigData) => {
		try {
			return await configService.getConfig(type);
		} catch (err) {
			setError(err instanceof Error ? err.message : `Failed to get ${type}`);
			throw err;
		}
	}, []);

	// Setup WebSocket connection and listeners
	useEffect(() => {
		// Load initial data
		loadConfigs();

		// Setup WebSocket
		configService.connectWebSocket();

		// Listen for initial data
		const handleInitial = (data: unknown) => {
			const configData = data as ConfigData;
			setConfigs(configData);
			setLoading(false);
			setConnected(true);
		};

		// Listen for updates
		const handleUpdate = (update: unknown) => {
			const configUpdate = update as ConfigUpdate;
			setConfigs((prev) => ({
				...prev,
				[configUpdate.type]: configUpdate.content,
			}));
		};

		configService.on('initial', handleInitial);
		configService.on('update', handleUpdate);

		// Cleanup
		return () => {
			configService.off('initial', handleInitial);
			configService.off('update', handleUpdate);
			configService.disconnect();
		};
	}, [loadConfigs]);

	return {
		configs,
		loading,
		error,
		connected,
		updateConfig,
		getConfig,
		refetch: loadConfigs,
	};
}
