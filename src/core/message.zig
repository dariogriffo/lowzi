/// Typed message schemas for every inter-module channel.
///
/// Centralizing these here keeps versioning trivial and enforces that no
/// module has to import its upstream sibling to discover its message types.
const Track = @import("track.zig").Track;

// ---------------------------------------------------------------------------
// UI → Player
// ---------------------------------------------------------------------------

pub const Command = union(enum) {
    quit,
    skip,
    toggle_pause,
    /// Percent points; the receiver clamps to [0, 100].
    volume_delta: i8,
    bookmark,
};

// ---------------------------------------------------------------------------
// Player → UI
// ---------------------------------------------------------------------------

pub const Event = union(enum) {
    /// Track has started. The Track is not owned by this event; its lifetime
    /// is managed by the player state machine.
    track_started: Track,
    track_progress: struct { elapsed_ms: u32, duration_ms: ?u32 },
    track_ended,
    paused: bool,
    /// Volume as a percentage 0..100.
    volume_changed: u8,
    bookmark_added: []const u8,
    bookmark_removed: []const u8,
    network_stalled,
    decode_failed: []const u8,
    audio_device_lost,
    /// Sync task is running; no tracks available yet.
    sync_in_progress,
    /// Catalog reconciliation finished (hash matched or diff merged).
    sync_completed,
    /// Catalog reconciliation failed; payload is a human-readable reason string.
    sync_failed: []const u8,
    quit,
};

// ---------------------------------------------------------------------------
// Sync → Player (separate channel so sync task can signal the player without
// routing through the UI-bound player_to_ui channel)
// ---------------------------------------------------------------------------

pub const SyncMsg = union(enum) {
    completed,
    /// Human-readable failure reason.
    failed: []const u8,
};

// ---------------------------------------------------------------------------
// Player → Source  /  Source → Player
// ---------------------------------------------------------------------------

pub const SourceRequest = union(enum) { next };

pub const SourceResponse = union(enum) {
    track: Track,
    err: []const u8,
};

// ---------------------------------------------------------------------------
// Player → Audio  /  Audio → Player
//
// Defined here (in core) so that audio/ can depend on core without the
// reverse dependency. See §4.1 / Brief: core/ (Step 2).
// ---------------------------------------------------------------------------

pub const AudioCommand = union(enum) {
    /// Takes ownership of Track.bytes.
    play: Track,
    pause: bool,
    set_volume: u8,
    /// Skip the currently-playing track.
    stop_current,
    quit,
};

pub const AudioEvent = union(enum) {
    track_started: struct { duration_ms: ?u32 },
    /// Elapsed milliseconds since the track started.
    progress: u32,
    track_ended,
    decode_failed: []const u8,
    device_lost,
};
