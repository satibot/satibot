import { useState } from 'react';
import { useConfig } from './useConfig';

interface ConfigFile {
	id: string;
	name: string;
	content: string;
	createdAt: Date;
	updatedAt: Date;
}

export function ConfigFileManager() {
	const { configs, loading, error, updateConfig, connected } = useConfig();
	const [selectedId, setSelectedId] = useState<string | null>(null);
	const [isEditing, setIsEditing] = useState(false);
	const [editName, setEditName] = useState('');
	const [editContent, setEditContent] = useState('');
	const [isCreating, setIsCreating] = useState(false);
	const [newName, setNewName] = useState('');
	const [newContent, setNewContent] = useState('');

	// Convert API configs to ConfigFile format
	const configFiles: ConfigFile[] = [
		{
			id: 'config',
			name: 'config.json',
			content: JSON.stringify(configs.config, null, 2),
			createdAt: new Date(),
			updatedAt: new Date(),
		},
		{
			id: 'soul',
			name: 'soul.md',
			content: configs.soul || '',
			createdAt: new Date(),
			updatedAt: new Date(),
		},
		{
			id: 'user',
			name: 'user.md',
			content: configs.user || '',
			createdAt: new Date(),
			updatedAt: new Date(),
		},
		{
			id: 'memory',
			name: 'memory.md',
			content: configs.memory || '',
			createdAt: new Date(),
			updatedAt: new Date(),
		},
	];

	function handleSelect(id: string) {
		const config = configFiles.find((c) => c.id === id);
		if (config) {
			setSelectedId(id);
			setEditName(config.name);
			setEditContent(config.content);
			setIsEditing(false);
			setIsCreating(false);
		}
	}

	function handleCreate() {
		setIsCreating(true);
		setIsEditing(false);
		setSelectedId(null);
		setNewName('');
		setNewContent('');
	}

	async function handleSaveNew() {
		if (!newName.trim()) return;
		// Note: Creating new files is not supported by the current API
		// Only updating existing config files is supported
		alert(
			'Creating new config files is not supported. Please edit existing config files.',
		);
		setIsCreating(false);
		setNewName('');
		setNewContent('');
	}

	function handleCancelCreate() {
		setIsCreating(false);
		setNewName('');
		setNewContent('');
	}

	function handleEdit() {
		setIsEditing(true);
	}

	async function handleSaveEdit() {
		if (!selectedId || !editName.trim()) return;

		try {
			let content: string | Record<string, unknown> = editContent;

			// Parse JSON for config.json
			if (selectedId === 'config') {
				try {
					content = JSON.parse(editContent);
				} catch (_e) {
					alert('Invalid JSON format');
					return;
				}
			}

			await updateConfig(selectedId as keyof typeof configs, content);
			setIsEditing(false);
		} catch (err) {
			alert(
				'Failed to save config: ' +
					(err instanceof Error ? err.message : 'Unknown error'),
			);
		}
	}

	function handleCancelEdit() {
		if (selectedId) {
			const config = configFiles.find((c) => c.id === selectedId);
			if (config) {
				setEditName(config.name);
				setEditContent(config.content);
			}
		}
		setIsEditing(false);
	}

	function handleDelete(_id: string) {
		alert('Deleting config files is not supported.');
	}

	function handleNameClick(id: string) {
		handleSelect(id);
	}

	const selectedConfig = selectedId
		? configFiles.find((c) => c.id === selectedId)
		: null;

	if (loading) {
		return (
			<div className="config-manager">
				<h2 className="text-xl font-semibold text-white mb-4">
					Configuration Files
				</h2>
				<div className="text-center py-8">
					<p className="text-gray-400">Loading configs...</p>
				</div>
			</div>
		);
	}

	if (error) {
		return (
			<div className="config-manager">
				<h2 className="text-xl font-semibold text-white mb-4">
					Configuration Files
				</h2>
				<div className="text-center py-8">
					<p className="text-red-400">Error: {error}</p>
				</div>
			</div>
		);
	}

	return (
		<div className="config-manager">
			<div className="flex justify-between items-center mb-4">
				<h2 className="text-xl font-semibold text-white">
					Configuration Files
				</h2>
				<div className="flex items-center gap-2">
					<div
						className={`w-3 h-3 rounded-full ${connected ? 'bg-green-500' : 'bg-red-500'}`}
					></div>
					<span className="text-sm text-gray-300">
						{connected ? 'Connected' : 'Disconnected'}
					</span>
				</div>
			</div>

			<div className="config-list">
				<button
					type="button"
					onClick={handleCreate}
					className="btn-primary bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
				>
					+ New Config
				</button>

				<ul className="space-y-2">
					{configFiles.map((config) => (
						<li
							key={config.id}
							className={`flex items-center justify-between p-3 rounded-md border ${
								selectedId === config.id
									? 'bg-blue-900 border-blue-700'
									: 'bg-gray-700 border-gray-600 hover:bg-gray-600'
							} transition-colors`}
						>
							<button
								type="button"
								onClick={() => handleNameClick(config.id)}
								className="name text-white font-medium hover:text-blue-300 transition-colors"
							>
								{config.name}
							</button>
							<button
								type="button"
								onClick={() => handleDelete(config.id)}
								className="btn-delete bg-red-600 hover:bg-red-700 text-white px-3 py-1 rounded text-sm font-medium transition-colors"
							>
								Delete
							</button>
						</li>
					))}
					{configFiles.length === 0 && !isCreating && (
						<li className="empty text-gray-400">No config files yet</li>
					)}
				</ul>
			</div>

			{isCreating && (
				<div className="config-form">
					<h3 className="text-lg font-semibold text-white mb-4">
						Create New Config
					</h3>
					<div className="mb-4">
						<label
							htmlFor="new-config-name"
							className="block text-sm font-medium text-gray-300 mb-2"
						>
							Name:
						</label>
						<input
							id="new-config-name"
							type="text"
							value={newName}
							onChange={(e) => setNewName(e.target.value)}
							placeholder="config.json"
							className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
						/>
					</div>
					<div className="mb-4">
						<label
							htmlFor="new-config-content"
							className="block text-sm font-medium text-gray-300 mb-2"
						>
							Content:
						</label>
						<textarea
							id="new-config-content"
							value={newContent}
							onChange={(e) => setNewContent(e.target.value)}
							placeholder='{"key": "value"}'
							rows={10}
							className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 font-mono"
						/>
					</div>
					<div className="actions flex gap-2">
						<button
							type="button"
							onClick={handleSaveNew}
							className="btn-primary bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
						>
							Save
						</button>
						<button
							type="button"
							onClick={handleCancelCreate}
							className="btn-secondary bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
						>
							Cancel
						</button>
					</div>
				</div>
			)}

			{selectedConfig && !isCreating && (
				<div className="config-view">
					<h3 className="text-lg font-semibold text-white mb-4">
						{isEditing ? 'Edit Config' : selectedConfig.name}
					</h3>

					{isEditing ? (
						<div className="config-form">
							<div className="mb-4">
								<label
									htmlFor="edit-config-name"
									className="block text-sm font-medium text-gray-300 mb-2"
								>
									Name:
								</label>
								<input
									id="edit-config-name"
									type="text"
									value={editName}
									onChange={(e) => setEditName(e.target.value)}
									className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
								/>
							</div>
							<div className="mb-4">
								<label
									htmlFor="edit-config-content"
									className="block text-sm font-medium text-gray-300 mb-2"
								>
									Content:
								</label>
								<textarea
									id="edit-config-content"
									value={editContent}
									onChange={(e) => setEditContent(e.target.value)}
									rows={10}
									className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 font-mono"
								/>
							</div>
							<div className="actions flex gap-2">
								<button
									type="button"
									onClick={handleSaveEdit}
									className="btn-primary bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
								>
									Save
								</button>
								<button
									type="button"
									onClick={handleCancelEdit}
									className="btn-secondary bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
								>
									Cancel
								</button>
							</div>
						</div>
					) : (
						<>
							<pre className="config-content bg-gray-900 text-gray-300 p-4 rounded-md overflow-x-auto font-mono text-sm">
								{selectedConfig.content}
							</pre>
							<div className="meta text-sm text-gray-400 space-y-1">
								<span>
									Created: {new Date(selectedConfig.createdAt).toLocaleString()}
								</span>
								<span className="block">
									Updated: {new Date(selectedConfig.updatedAt).toLocaleString()}
								</span>
							</div>
							<button
								type="button"
								onClick={handleEdit}
								className="btn-primary bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium transition-colors mt-4"
							>
								Edit
							</button>
						</>
					)}
				</div>
			)}

			{!selectedConfig && !isCreating && (
				<div className="config-empty text-center py-8">
					<p className="text-gray-400">
						Select a config file or create a new one
					</p>
				</div>
			)}
		</div>
	);
}

export default ConfigFileManager;
