/// Thin wrapper over std.log.
///
/// In v0.1, the file-routing branch is stubbed: all output goes to stderr.
/// TODO Step 8: route to <state_dir>/log when in TUI mode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;

/// Re-export scoped so callers can write:
///   const log = core.log.scoped(.my_module);
pub const scoped = std.log.scoped;

/// Initialize logging based on the config.
/// In v0.1 this only sets the log level; file routing is a TODO for Step 8.
pub fn init(gpa: Allocator, io: std.Io, cfg: Config) error{}!void {
    // Suppress unused-parameter warnings.
    _ = gpa;
    _ = io;
    _ = cfg;
    // TODO Step 8: when cfg.debug and in TUI mode, open state_dir/log and
    // redirect log output there so it does not clobber the screen.
    // For now all log output goes to stderr via std.log's default handler.
}
