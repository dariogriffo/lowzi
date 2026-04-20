/// player — the state machine that owns playback.
///
/// Pulls tracks from storage/, hands URLs to source/downloader, drives audio/,
/// and translates front-end Commands into Events.
pub const State = @import("state.zig").State;
pub const controller = @import("controller.zig");
pub const queue = @import("queue.zig");
pub const bookmark = @import("bookmark.zig");
