/// player/state.zig — pure in-memory playback state.
///
/// No I/O, no channels. Every method mutates state and possibly returns an
/// Event for the controller to forward. Allocation lives in the GPA passed
/// to pushTrack/advance/deinit.
const std = @import("std");
const core = @import("core");

/// A simple fixed-capacity ring buffer for track IDs.
/// Replaces std.BoundedArray which does not exist in 0.16.
pub const RecentIds = struct {
    const CAP = 16;
    buf: [CAP]i64 = undefined,
    len: usize = 0,

    pub fn capacity(self: *const RecentIds) usize {
        _ = self;
        return CAP;
    }

    pub fn slice(self: *const RecentIds) []const i64 {
        return self.buf[0..self.len];
    }

    pub fn appendAssumeCapacity(self: *RecentIds, val: i64) void {
        self.buf[self.len] = val;
        self.len += 1;
    }

    pub fn get(self: *const RecentIds, i: usize) i64 {
        return self.buf[i];
    }
};

pub const State = struct {
    paused: bool = false,
    volume: u8 = 60,
    /// Currently-playing track. Owned; call deinit when replacing.
    current: ?core.Track = null,
    /// Upcoming tracks. Bounded by cfg.buffer_size — caller enforces via pushTrack.
    queue: std.ArrayList(core.Track) = .empty,
    /// Ring buffer of recently-played track IDs used as the NOT IN exclude list.
    recent_ids: RecentIds = .{},
    /// True until Event.sync_completed (or sync_failed) is received, so the
    /// fill loop does not attempt to pick from an empty catalog.
    sync_in_progress: bool = true,

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.current) |*t| t.deinit(gpa);
        self.current = null;
        for (self.queue.items) |*t| t.deinit(gpa);
        self.queue.deinit(gpa);
    }

    // -------------------------------------------------------------------------
    // Command application — returns the Event to emit (if any)
    // -------------------------------------------------------------------------

    /// Apply a front-end Command to the state. Returns the Event that should
    /// be forwarded to the UI, or null when the controller handles the effect
    /// itself (e.g. skip, bookmark).
    pub fn applyCommand(self: *State, cmd: core.message.Command) ?core.message.Event {
        return switch (cmd) {
            .quit => .quit,
            // skip: controller handles audio stop + DB write; nothing to emit here.
            .skip => null,
            .toggle_pause => {
                self.paused = !self.paused;
                return .{ .paused = self.paused };
            },
            .volume_delta => |delta| {
                const v: i16 = @as(i16, self.volume) + delta;
                self.volume = @intCast(std.math.clamp(v, 0, 100));
                return .{ .volume_changed = self.volume };
            },
            // bookmark: controller handles DB write + emit event.
            .bookmark => null,
        };
    }

    // -------------------------------------------------------------------------
    // Queue management
    // -------------------------------------------------------------------------

    /// Push a track onto the back of the queue.
    /// Returns false (without pushing) when `queue.items.len >= buffer_size`.
    pub fn pushTrack(
        self: *State,
        gpa: std.mem.Allocator,
        buffer_size: usize,
        t: core.Track,
    ) !bool {
        if (self.queue.items.len >= buffer_size) return false;
        try self.queue.append(gpa, t);
        return true;
    }

    /// Pop the front of the queue and install it as `current`.
    /// The old `current` is deinit'd first. Returns the new current (or null).
    pub fn advance(self: *State, gpa: std.mem.Allocator) ?core.Track {
        if (self.current) |*t| t.deinit(gpa);
        self.current = null;

        if (self.queue.items.len == 0) return null;

        // orderedRemove preserves queue order; first element is the front.
        self.current = self.queue.orderedRemove(0);
        return self.current;
    }

    // -------------------------------------------------------------------------
    // Recent-track ring buffer
    // -------------------------------------------------------------------------

    /// Record a track ID as recently played, evicting the oldest if full.
    pub fn recordRecent(self: *State, track_id: i64) void {
        if (self.recent_ids.len == RecentIds.CAP) {
            // Shift left to evict the oldest entry.
            var i: usize = 0;
            while (i + 1 < self.recent_ids.len) : (i += 1) {
                self.recent_ids.buf[i] = self.recent_ids.buf[i + 1];
            }
            self.recent_ids.len -= 1;
        }
        // appendAssumeCapacity is safe because we just made room.
        self.recent_ids.appendAssumeCapacity(track_id);
    }
};
