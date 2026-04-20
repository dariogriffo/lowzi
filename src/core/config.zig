const std = @import("std");
const errors = @import("errors.zig");

/// Runtime configuration populated by CLI parsing.
/// Defaults match §2.1 of the specification.
pub const Config = struct {
    /// -a / --alternate: use alternate screen buffer.
    alternate: bool = false,
    /// -m / --minimalist: hide the controls hint bar.
    minimalist: bool = false,
    /// -b / --borderless: render without borders.
    borderless: bool = false,
    /// -c / --clock: show a wall clock.
    clock: bool = false,
    /// -p / --paused: start paused.
    paused: bool = false,
    /// -f / --fps <N>: UI refresh rate (default 12).
    fps: u32 = 12,
    /// -w / --width <N>: player width tier 0..32 (default 3).
    width: u32 = 3,
    /// -t / --track-list <name|path>: named list or path. null = embedded default.
    track_list: ?[]const u8 = null,
    /// -s / --buffer-size <N>: number of tracks to buffer (default 5).
    buffer_size: u32 = 5,
    /// --timeout <ms>: per-request HTTP timeout (default 3000).
    timeout_ms: u32 = 3000,
    /// -d / --debug: verbose logging.
    debug: bool = false,

    /// Validate the parsed configuration. Returns an error on invalid combinations.
    pub fn validate(self: Config) errors.CliError!void {
        if (self.fps == 0) return error.InvalidValue;
        if (self.width > 32) return error.InvalidValue;
        if (self.buffer_size == 0) return error.InvalidValue;
    }
};
