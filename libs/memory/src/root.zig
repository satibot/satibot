//! Memory module - Long-term memory storage with markdown, SQLite, and Memvid support

const build_options = @import("build_opts");

pub const graph = @import("graph.zig");
pub const memory = @import("memory.zig");
pub const memvid = @import("memvid.zig");
const sqlite_import = @import("sqlite.zig");

pub const enable_sqlite = if (@hasField(build_options, "enable_sqlite")) build_options.enable_sqlite else false;
pub const enable_memory_sqlite = if (@hasField(build_options, "enable_memory_sqlite")) build_options.enable_memory_sqlite else false;

pub const sqlite = if (enable_memory_sqlite) sqlite_import else null;
