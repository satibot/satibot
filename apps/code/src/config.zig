//! SatiCode Configuration
//!
//! This module provides configuration support for SatiCode with JSONC/JSON format
//! similar to OpenCode's configuration system.
//!
//! ## Configuration File Locations
//! - `.saticode.json` or `.saticode.jsonc` in current directory
//! - `~/.config/saticode/config.json` or `~/.config/saticode/config.jsonc`
//!
//! ## Example Configuration
//! ```jsonc
//! {
//!   "$schema": "https://satibot.github.io/saticode/config.json",
//!   "model": "MiniMax-M2.5",
//!   "autoupdate": true,
//!   "server": {
//!     "port": 4096,
//!     "host": "localhost"
//!   },
//!   "rag": {
//!     "enabled": true,
//!     "maxHistory": 50
//!   },
//!   "providers": {
//!     "minimax": {
//!       "apiKey": "${MINIMAX_API_KEY}",
//!       "apiBase": "https://api.minimax.io/anthropic"
//!     }
//!   }
//! }
//! ```

const std = @import("std");
const core = @import("core");
const agent = @import("agent");

/// SatiCode configuration structure
pub const SatiCodeConfig = struct {
    /// JSON schema URL for validation (stored as schema to avoid Zig identifier issues)
    schema: ?[]const u8 = null,

    /// Default model to use
    model: []const u8 = "openrouter/meta-llama/llama-3.1-8b-instruct:free",

    /// Enable automatic updates
    autoupdate: bool = false,

    /// Server configuration
    server: ?ServerConfig = null,

    /// RAG (Retrieval Augmented Generation) settings
    rag: ?RagConfig = null,

    /// Provider configurations
    providers: ?ProviderConfigs = null,

    /// Custom system prompt
    systemPrompt: ?[]const u8 = null,

    /// Additional tools configuration
    tools: ?ToolsConfig = null,
};

/// Server configuration for optional web server mode
pub const ServerConfig = struct {
    port: u16 = 4096,
    host: []const u8 = "localhost",
};

/// RAG configuration
pub const RagConfig = struct {
    enabled: bool = true,
    maxHistory: usize = 50,
    embeddingsModel: []const u8 = "local",
};

/// Provider configurations
pub const ProviderConfigs = struct {
    minimax: ?ProviderConfig = null,
    openrouter: ?ProviderConfig = null,
    anthropic: ?ProviderConfig = null,
    openai: ?ProviderConfig = null,
    groq: ?ProviderConfig = null,
};

/// Individual provider configuration
pub const ProviderConfig = struct {
    apiKey: []const u8,
    apiBase: ?[]const u8 = null,
};

/// Tools configuration
pub const ToolsConfig = struct {
    web: ?WebToolsConfig = null,
};

/// Web tools configuration
pub const WebToolsConfig = struct {
    search: ?WebSearchConfig = null,
};

/// Web search configuration
pub const WebSearchConfig = struct {
    apiKey: []const u8,
    engine: ?[]const u8 = null, // e.g., "google", "bing"
};

/// Load SatiCode configuration from standard locations
pub fn load(allocator: std.mem.Allocator) !LoadedConfig {
    // Try current directory first
    if (loadFromPath(allocator, ".saticode.jsonc")) |config| {
        return config;
    } else |_| {
        if (loadFromPath(allocator, ".saticode.json")) |config| {
            return config;
        } else |_| {
            // Try user config directory
            const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
            const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "saticode" });
            defer allocator.free(config_dir);

            const jsonc_path = try std.fs.path.join(allocator, &.{ config_dir, "config.jsonc" });
            defer allocator.free(jsonc_path);
            if (loadFromPath(allocator, jsonc_path)) |config| {
                return config;
            } else |_| {
                const json_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
                defer allocator.free(json_path);
                if (loadFromPath(allocator, json_path)) |config| {
                    return config;
                } else |_| {
                    // Return default configuration
                    return LoadedConfig{
                        .saticode = SatiCodeConfig{},
                        .path = null,
                    };
                }
            }
        }
    }
}

/// Load configuration from a specific file path
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LoadedConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.ConfigNotFound;
        }
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        if (err == error.FileTooBig) {
            return error.ConfigTooLarge;
        }
        return err;
    };
    defer allocator.free(content);

    // Remove JSONC comments if it's a .jsonc file
    const is_jsonc = std.mem.endsWith(u8, path, ".jsonc");
    const processed_content = if (is_jsonc)
        try removeJsoncComments(allocator, content)
    else
        content;

    if (is_jsonc) {
        defer allocator.free(processed_content);
    }

    // Parse JSON with custom handling for $schema field
    const parsed = parseSatiCodeConfig(allocator, processed_content) catch |err| {
        std.debug.print("Failed to parse config file {s}: {any}\n", .{ path, err });
        return error.InvalidConfig;
    };

    return LoadedConfig{
        .saticode = parsed.value,
        .path = try allocator.dupe(u8, path),
    };
}

/// Custom parser to handle $schema field mapping
fn parseSatiCodeConfig(allocator: std.mem.Allocator, content: []const u8) !std.json.Parsed(SatiCodeConfig) {
    // First parse as a generic JSON value to handle $schema
    const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed_value.deinit();

    const root = parsed_value.value.object;

    var config = SatiCodeConfig{};

    // Handle $schema field
    if (root.get("$schema")) |schema_val| {
        if (schema_val == .string) {
            config.schema = try allocator.dupe(u8, schema_val.string);
        }
    }

    // Parse other fields normally
    if (root.get("model")) |model_val| {
        if (model_val == .string) {
            config.model = try allocator.dupe(u8, model_val.string);
        }
    }

    if (root.get("autoupdate")) |autoupdate_val| {
        if (autoupdate_val == .bool) {
            config.autoupdate = autoupdate_val.bool;
        }
    }

    if (root.get("server")) |server_val| {
        config.server = try parseServerConfig(allocator, server_val);
    }

    if (root.get("rag")) |rag_val| {
        config.rag = try parseRagConfig(allocator, rag_val);
    }

    if (root.get("providers")) |providers_val| {
        config.providers = try parseProviderConfigs(allocator, providers_val);
    }

    if (root.get("systemPrompt")) |system_prompt_val| {
        if (system_prompt_val == .string) {
            config.systemPrompt = try allocator.dupe(u8, system_prompt_val.string);
        }
    }

    if (root.get("tools")) |tools_val| {
        config.tools = try parseToolsConfig(allocator, tools_val);
    }

    return .{
        .value = config,
        .arena = parsed_value.arena,
    };
}

/// Parse server configuration from JSON value
fn parseServerConfig(allocator: std.mem.Allocator, value: std.json.Value) !ServerConfig {
    var config = ServerConfig{};
    if (value.object.get("port")) |port_val| {
        if (port_val == .integer) {
            config.port = @intCast(port_val.integer);
        }
    }
    if (value.object.get("host")) |host_val| {
        if (host_val == .string) {
            config.host = try allocator.dupe(u8, host_val.string);
        }
    }
    return config;
}

/// Parse RAG configuration from JSON value
fn parseRagConfig(allocator: std.mem.Allocator, value: std.json.Value) !RagConfig {
    var config = RagConfig{};
    if (value.object.get("enabled")) |enabled_val| {
        if (enabled_val == .bool) {
            config.enabled = enabled_val.bool;
        }
    }
    if (value.object.get("maxHistory")) |max_history_val| {
        if (max_history_val == .integer) {
            config.maxHistory = @intCast(max_history_val.integer);
        }
    }
    if (value.object.get("embeddingsModel")) |embeddings_val| {
        if (embeddings_val == .string) {
            config.embeddingsModel = try allocator.dupe(u8, embeddings_val.string);
        }
    }
    return config;
}

/// Parse provider configurations from JSON value
fn parseProviderConfigs(allocator: std.mem.Allocator, value: std.json.Value) !ProviderConfigs {
    var configs = ProviderConfigs{};

    if (value.object.get("minimax")) |minimax_val| {
        configs.minimax = try parseProviderConfig(allocator, minimax_val);
    }
    if (value.object.get("openrouter")) |openrouter_val| {
        configs.openrouter = try parseProviderConfig(allocator, openrouter_val);
    }
    if (value.object.get("anthropic")) |anthropic_val| {
        configs.anthropic = try parseProviderConfig(allocator, anthropic_val);
    }
    if (value.object.get("openai")) |openai_val| {
        configs.openai = try parseProviderConfig(allocator, openai_val);
    }
    if (value.object.get("groq")) |groq_val| {
        configs.groq = try parseProviderConfig(allocator, groq_val);
    }

    return configs;
}

/// Parse individual provider configuration from JSON value
fn parseProviderConfig(allocator: std.mem.Allocator, value: std.json.Value) !ProviderConfig {
    var config = ProviderConfig{
        .apiKey = undefined,
    };

    if (value.object.get("apiKey")) |api_key_val| {
        if (api_key_val == .string) {
            config.apiKey = try allocator.dupe(u8, api_key_val.string);
        }
    }
    if (value.object.get("apiBase")) |api_base_val| {
        if (api_base_val == .string) {
            config.apiBase = try allocator.dupe(u8, api_base_val.string);
        }
    }

    return config;
}

/// Parse tools configuration from JSON value
fn parseToolsConfig(allocator: std.mem.Allocator, value: std.json.Value) !ToolsConfig {
    var configs = ToolsConfig{};

    if (value.object.get("web")) |web_val| {
        configs.web = try parseWebToolsConfig(allocator, web_val);
    }

    return configs;
}

/// Parse web tools configuration from JSON value
fn parseWebToolsConfig(allocator: std.mem.Allocator, value: std.json.Value) !WebToolsConfig {
    var config = WebToolsConfig{};

    if (value.object.get("search")) |search_val| {
        config.search = try parseWebSearchConfig(allocator, search_val);
    }

    return config;
}

/// Parse web search configuration from JSON value
fn parseWebSearchConfig(allocator: std.mem.Allocator, value: std.json.Value) !WebSearchConfig {
    var config = WebSearchConfig{
        .apiKey = undefined,
    };

    if (value.object.get("apiKey")) |api_key_val| {
        if (api_key_val == .string) {
            config.apiKey = try allocator.dupe(u8, api_key_val.string);
        }
    }
    if (value.object.get("engine")) |engine_val| {
        if (engine_val == .string) {
            config.engine = try allocator.dupe(u8, engine_val.string);
        }
    }
    return config;
}

/// Convert SatiCode config to agent Config
pub fn toAgentConfig(allocator: std.mem.Allocator, saticode_config: SatiCodeConfig) !core.config.Config {
    // Build providers configuration
    var providers: core.config.ProvidersConfig = .{};
    if (saticode_config.providers) |provider_configs| {
        if (provider_configs.minimax) |p| {
            providers.minimax = .{
                .apiKey = try expandEnvVars(allocator, p.apiKey),
                .apiBase = if (p.apiBase) |base| try expandEnvVars(allocator, base) else null,
            };
        }
        if (provider_configs.openrouter) |p| {
            providers.openrouter = .{
                .apiKey = try expandEnvVars(allocator, p.apiKey),
                .apiBase = if (p.apiBase) |base| try expandEnvVars(allocator, base) else null,
            };
        }
        if (provider_configs.anthropic) |p| {
            providers.anthropic = .{
                .apiKey = try expandEnvVars(allocator, p.apiKey),
                .apiBase = if (p.apiBase) |base| try expandEnvVars(allocator, base) else null,
            };
        }
        if (provider_configs.openai) |p| {
            providers.openai = .{
                .apiKey = try expandEnvVars(allocator, p.apiKey),
                .apiBase = if (p.apiBase) |base| try expandEnvVars(allocator, base) else null,
            };
        }
        if (provider_configs.groq) |p| {
            providers.groq = .{
                .apiKey = try expandEnvVars(allocator, p.apiKey),
                .apiBase = if (p.apiBase) |base| try expandEnvVars(allocator, base) else null,
            };
        }
    }

    // Build tools configuration
    var tools: core.config.ToolsConfig = .{
        .web = .{ .search = .{ .apiKey = "" } },
    };
    if (saticode_config.tools) |tools_config| {
        if (tools_config.web) |web_tools| {
            if (web_tools.search) |search_config| {
                tools.web.search.apiKey = try expandEnvVars(allocator, search_config.apiKey);
            }
        }
    }

    // Get RAG settings
    const rag_config = saticode_config.rag orelse RagConfig{};

    return core.config.Config{
        .agents = .{
            .defaults = .{
                .model = saticode_config.model,
                .embeddingModel = rag_config.embeddingsModel,
                .disableRag = !rag_config.enabled,
                .loadChatHistory = true,
                .maxChatHistory = @intCast(rag_config.maxHistory),
            },
        },
        .providers = providers,
        .tools = tools,
    };
}

/// Loaded configuration with file path information
pub const LoadedConfig = struct {
    saticode: SatiCodeConfig,
    path: ?[]const u8, // null if using default config
};

/// Remove JSONC comments (// and /* */) from JSON content
fn removeJsoncComments(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var in_single_line_comment = false;
    var in_multi_line_comment = false;
    var escape_next = false;

    while (i < content.len) {
        const char = content[i];

        if (escape_next) {
            try result.append(allocator, char);
            escape_next = false;
            i += 1;
            continue;
        }

        if (char == '\\' and in_string) {
            try result.append(allocator, char);
            escape_next = true;
            i += 1;
            continue;
        }

        if (char == '"' and !in_single_line_comment and !in_multi_line_comment) {
            in_string = !in_string;
            try result.append(allocator, char);
            i += 1;
            continue;
        }

        if (in_string) {
            try result.append(allocator, char);
            i += 1;
            continue;
        }

        // Check for single line comment
        if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/' and !in_multi_line_comment) {
            in_single_line_comment = true;
            i += 2;
            continue;
        }

        // Check for multi-line comment
        if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '*' and !in_single_line_comment) {
            in_multi_line_comment = true;
            i += 2;
            continue;
        }

        // End of single line comment
        if (char == '\n' and in_single_line_comment) {
            in_single_line_comment = false;
            try result.append(allocator, char);
            i += 1;
            continue;
        }

        // End of multi-line comment
        if (i + 1 < content.len and content[i] == '*' and content[i + 1] == '/' and in_multi_line_comment) {
            in_multi_line_comment = false;
            i += 2;
            continue;
        }

        if (!in_single_line_comment and !in_multi_line_comment) {
            try result.append(allocator, char);
        }

        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Expand environment variables in format ${VAR_NAME}
fn expandEnvVars(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 < input.len and input[i] == '$' and input[i + 1] == '{') {
            // Find closing brace
            const start = i + 2;
            var end = start;
            while (end < input.len and input[end] != '}') {
                end += 1;
            }

            if (end < input.len) {
                // Extract variable name
                const var_name = input[start..end];
                if (std.posix.getenv(var_name)) |var_value| {
                    try result.appendSlice(allocator, var_value);
                } else {
                    // Keep original if environment variable not found
                    try result.appendSlice(allocator, input[i .. end + 1]);
                }
                i = end + 1;
                continue;
            }
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

test "removeJsoncComments" {
    const allocator = std.testing.allocator;

    const input =
        \\{
        \\  // This is a comment
        \\  "key": "value", /* inline comment */
        \\  "nested": {
        \\    /* multi-line
        \\       comment */
        \\    "inner": "data" // another comment
        \\  }
        \\}
    ;

    const expected =
        \\{
        \\  "key": "value",
        \\  "nested": {
        \\    "inner": "data"
        \\  }
        \\}
    ;

    const result = try removeJsoncComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "expandEnvVars" {
    const allocator = std.testing.allocator;

    // Set test environment variable
    try std.posix.setenv("TEST_VAR", "test_value");

    const input = "prefix_${TEST_VAR}_suffix";
    const expected = "prefix_test_value_suffix";

    const result = try expandEnvVars(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);

    // Clean up
    std.posix.unsetenv("TEST_VAR");
}
