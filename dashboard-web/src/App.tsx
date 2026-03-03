import './App.css';
import { ChatLogMonitor } from './chat';
import { ConfigFileManager } from './config/ConfigFileManager';

const App = () => {
  return (
    <div className="min-h-screen bg-gray-900 p-6">
      <div className="max-w-7xl mx-auto">
        <h1 className="text-3xl font-bold text-white mb-8">
          SatiBot Dashboard
        </h1>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Config File Manager */}
          <div className="lg:col-span-1">
            <div className="bg-gray-800 rounded-lg shadow-md p-6 border border-gray-700">
              <h2 className="text-xl font-semibold text-white mb-4">
                Configuration
              </h2>
              <ConfigFileManager />
            </div>
          </div>

          {/* Chat Log Monitor */}
          <div className="lg:col-span-1">
            <div className="bg-gray-800 rounded-lg shadow-md p-6 border border-gray-700">
              <h2 className="text-xl font-semibold text-white mb-4">
                Real-time Chat Logs
              </h2>
              <ChatLogMonitor />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default App;
