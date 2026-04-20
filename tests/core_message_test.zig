/// Tests for core.message: round-trip every union variant via tag discrimination.
const std = @import("std");
const core = @import("core");
const message = core.message;

// ---------------------------------------------------------------------------
// Command variants
// ---------------------------------------------------------------------------

test "core.message: Command.quit discriminates correctly" {
    const cmd = message.Command.quit;
    switch (cmd) {
        .quit => {},
        else => return error.TestFailed,
    }
}

test "core.message: Command.skip discriminates correctly" {
    const cmd = message.Command.skip;
    switch (cmd) {
        .skip => {},
        else => return error.TestFailed,
    }
}

test "core.message: Command.toggle_pause discriminates correctly" {
    const cmd = message.Command.toggle_pause;
    switch (cmd) {
        .toggle_pause => {},
        else => return error.TestFailed,
    }
}

test "core.message: Command.volume_delta stores value" {
    const cmd = message.Command{ .volume_delta = -10 };
    switch (cmd) {
        .volume_delta => |v| try std.testing.expectEqual(@as(i8, -10), v),
        else => return error.TestFailed,
    }
}

test "core.message: Command.bookmark discriminates correctly" {
    const cmd = message.Command.bookmark;
    switch (cmd) {
        .bookmark => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Event variants
// ---------------------------------------------------------------------------

test "core.message: Event.track_ended discriminates correctly" {
    const evt = message.Event.track_ended;
    switch (evt) {
        .track_ended => {},
        else => return error.TestFailed,
    }
}

test "core.message: Event.paused stores bool" {
    const evt = message.Event{ .paused = true };
    switch (evt) {
        .paused => |v| try std.testing.expect(v),
        else => return error.TestFailed,
    }
}

test "core.message: Event.volume_changed stores value" {
    const evt = message.Event{ .volume_changed = 75 };
    switch (evt) {
        .volume_changed => |v| try std.testing.expectEqual(@as(u8, 75), v),
        else => return error.TestFailed,
    }
}

test "core.message: Event.network_stalled discriminates correctly" {
    const evt = message.Event.network_stalled;
    switch (evt) {
        .network_stalled => {},
        else => return error.TestFailed,
    }
}

test "core.message: Event.audio_device_lost discriminates correctly" {
    const evt = message.Event.audio_device_lost;
    switch (evt) {
        .audio_device_lost => {},
        else => return error.TestFailed,
    }
}

test "core.message: Event.quit discriminates correctly" {
    const evt = message.Event.quit;
    switch (evt) {
        .quit => {},
        else => return error.TestFailed,
    }
}

test "core.message: Event.track_progress stores fields" {
    const evt = message.Event{ .track_progress = .{ .elapsed_ms = 1000, .duration_ms = 30000 } };
    switch (evt) {
        .track_progress => |p| {
            try std.testing.expectEqual(@as(u32, 1000), p.elapsed_ms);
            try std.testing.expectEqual(@as(?u32, 30000), p.duration_ms);
        },
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// AudioCommand variants
// ---------------------------------------------------------------------------

test "core.message: AudioCommand.pause stores bool" {
    const cmd = message.AudioCommand{ .pause = false };
    switch (cmd) {
        .pause => |v| try std.testing.expect(!v),
        else => return error.TestFailed,
    }
}

test "core.message: AudioCommand.set_volume stores value" {
    const cmd = message.AudioCommand{ .set_volume = 60 };
    switch (cmd) {
        .set_volume => |v| try std.testing.expectEqual(@as(u8, 60), v),
        else => return error.TestFailed,
    }
}

test "core.message: AudioCommand.stop_current discriminates correctly" {
    const cmd = message.AudioCommand.stop_current;
    switch (cmd) {
        .stop_current => {},
        else => return error.TestFailed,
    }
}

test "core.message: AudioCommand.quit discriminates correctly" {
    const cmd = message.AudioCommand.quit;
    switch (cmd) {
        .quit => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// AudioEvent variants
// ---------------------------------------------------------------------------

test "core.message: AudioEvent.track_started stores duration_ms" {
    const evt = message.AudioEvent{ .track_started = .{ .duration_ms = 287000 } };
    switch (evt) {
        .track_started => |s| try std.testing.expectEqual(@as(?u32, 287000), s.duration_ms),
        else => return error.TestFailed,
    }
}

test "core.message: AudioEvent.progress stores elapsed" {
    const evt = message.AudioEvent{ .progress = 3000 };
    switch (evt) {
        .progress => |v| try std.testing.expectEqual(@as(u32, 3000), v),
        else => return error.TestFailed,
    }
}

test "core.message: AudioEvent.track_ended discriminates correctly" {
    const evt = message.AudioEvent.track_ended;
    switch (evt) {
        .track_ended => {},
        else => return error.TestFailed,
    }
}

test "core.message: AudioEvent.device_lost discriminates correctly" {
    const evt = message.AudioEvent.device_lost;
    switch (evt) {
        .device_lost => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// SourceRequest / SourceResponse
// ---------------------------------------------------------------------------

test "core.message: SourceRequest.next discriminates correctly" {
    const req = message.SourceRequest.next;
    switch (req) {
        .next => {},
    }
}
