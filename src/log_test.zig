const std = @import("std");
const logging = @import("log.zig");

test "Log: debug flag functionality" {
    // Test initial state
    try std.testing.expect(!logging.isDebugEnabled());

    // Test enabling debug
    logging.enableDebug();
    try std.testing.expect(logging.isDebugEnabled());
}

test "Log: Logger convenience functions" {
    // Test that all logger functions compile and don't crash
    logging.Logger.info(.main, "Info test: {s}", .{"test"});
    logging.Logger.warn(.main, "Warning test: {s}", .{"test"});
    logging.Logger.err(.main, "Error test: {s}", .{"test"});
}

test "Log: log macros" {
    logging.log.debug(.main, "Macro debug: {s}", .{"test"});
    logging.log.info(.main, "Macro info: {s}", .{"test"});
    logging.log.warn(.main, "Macro warn: {s}", .{"test"});
    logging.log.err(.main, "Macro error: {s}", .{"test"});
}
