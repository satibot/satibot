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
      <h2>Configuration Files</h2>

      <div className="config-list">
        <button type="button" onClick={handleCreate} className="btn-primary">
          + New Config
        </button>

        <ul>
          {configs.map((config) => (
            <li
              key={config.id}
              className={selectedId === config.id ? 'selected' : ''}
            >
              <button
                type="button"
                onClick={() => handleNameClick(config.id)}
                className="name"
              >
                {config.name}
              </button>
              <button
                type="button"
                onClick={() => handleDelete(config.id)}
                className="btn-delete"
              >
                Delete
              </button>
            </li>
          ))}
          {configs.length === 0 && !isCreating && (
            <li className="empty">No config files yet</li>
          )}
        </ul>
      </div>

      {isCreating && (
        <div className="config-form">
          <h3>Create New Config</h3>
          <div>
            <label htmlFor="new-config-name">Name:</label>
            <input
              id="new-config-name"
              type="text"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="config.json"
            />
          </div>
          <div>
            <label htmlFor="new-config-content">Content:</label>
            <textarea
              id="new-config-content"
              value={newContent}
              onChange={(e) => setNewContent(e.target.value)}
              placeholder='{"key": "value"}'
              rows={10}
            />
          </div>
          <div className="actions">
            <button
              type="button"
              onClick={handleSaveNew}
              className="btn-primary"
            >
              Save
            </button>
            <button
              type="button"
              onClick={handleCancelCreate}
              className="btn-secondary"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {selectedConfig && !isCreating && (
        <div className="config-view">
          <h3>{isEditing ? 'Edit Config' : selectedConfig.name}</h3>

          {isEditing ? (
            <div className="config-form">
              <div>
                <label htmlFor="edit-config-name">Name:</label>
                <input
                  id="edit-config-name"
                  type="text"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                />
              </div>
              <div>
                <label htmlFor="edit-config-content">Content:</label>
                <textarea
                  id="edit-config-content"
                  value={editContent}
                  onChange={(e) => setEditContent(e.target.value)}
                  rows={10}
                />
              </div>
              <div className="actions">
                <button
                  type="button"
                  onClick={handleSaveEdit}
                  className="btn-primary"
                >
                  Save
                </button>
                <button
                  type="button"
                  onClick={handleCancelEdit}
                  className="btn-secondary"
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <>
              <pre className="config-content">{selectedConfig.content}</pre>
              <div className="meta">
                <span>
                  Created: {new Date(selectedConfig.createdAt).toLocaleString()}
                </span>
                <span>
                  Updated: {new Date(selectedConfig.updatedAt).toLocaleString()}
                </span>
              </div>
              <button
                type="button"
                onClick={handleEdit}
                className="btn-primary"
              >
                Edit
              </button>
            </>
          )}
        </div>
      )}

      {!selectedConfig && !isCreating && (
        <div className="config-empty">
          <p>Select a config file or create a new one</p>
        </div>
      )}
    </div>
  );
}

export default ConfigFileManager;
