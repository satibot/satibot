import { useCallback, useEffect, useState } from 'react';
import * as manager from './manager';
import type { ConfigFile } from './types';

export function ConfigFileManager() {
  const [configs, setConfigs] = useState<ConfigFile[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState('');
  const [editContent, setEditContent] = useState('');
  const [isCreating, setIsCreating] = useState(false);
  const [newName, setNewName] = useState('');
  const [newContent, setNewContent] = useState('');

  const loadConfigs = useCallback(() => {
    setConfigs(manager.readConfigFiles());
  }, []);

  useEffect(() => {
    loadConfigs();
  }, [loadConfigs]);

  function handleSelect(id: string) {
    const config = manager.readConfigFile(id);
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

  function handleSaveNew() {
    if (!newName.trim()) return;
    manager.createConfigFile({ name: newName, content: newContent });
    loadConfigs();
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

  function handleSaveEdit() {
    if (!selectedId || !editName.trim()) return;
    manager.updateConfigFile(selectedId, {
      name: editName,
      content: editContent,
    });
    loadConfigs();
    setIsEditing(false);
  }

  function handleCancelEdit() {
    if (selectedId) {
      const config = manager.readConfigFile(selectedId);
      if (config) {
        setEditName(config.name);
        setEditContent(config.content);
      }
    }
    setIsEditing(false);
  }

  function handleDelete(id: string) {
    if (confirm('Are you sure you want to delete this config file?')) {
      manager.deleteConfigFile(id);
      if (selectedId === id) {
        setSelectedId(null);
        setIsEditing(false);
      }
      loadConfigs();
    }
  }

  function handleNameClick(id: string) {
    handleSelect(id);
  }

  const selectedConfig = selectedId
    ? configs.find((c) => c.id === selectedId)
    : null;

  return (
    <div className="config-manager">
      <h2 className="text-xl font-semibold text-white mb-4">
        Configuration Files
      </h2>

      <div className="config-list">
        <button
          type="button"
          onClick={handleCreate}
          className="btn-primary bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium transition-colors"
        >
          + New Config
        </button>

        <ul className="space-y-2">
          {configs.map((config) => (
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
          {configs.length === 0 && !isCreating && (
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
