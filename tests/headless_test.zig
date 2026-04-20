/// Tests for the headless front end — pure unit tests only.
///
/// Covers:
///   - parse(): keystroke → Command table, edge cases.
///   - formatEvent(): Event → stable output string, including escaping.
///
/// End-to-end stdin/stdout interaction is the smoke test's job (Step 9).
const std = @import("std");
const core = @import("core");
const headless = @import("headless");
const message = core.message;

// ---------------------------------------------------------------------------
// parse() — keystroke → Command table
// ---------------------------------------------------------------------------

test "headless.parse: s → skip" {
    const cmd = headless.parse("s\n");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.skip, cmd.?);
}

test "headless.parse: p → toggle_pause" {
    const cmd = headless.parse("p\n");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.toggle_pause, cmd.?);
}

test "headless.parse: + → volume_delta 10" {
    const cmd = headless.parse("+\n");
    try std.testing.expect(cmd != null);
    switch (cmd.?) {
        .volume_delta => |v| try std.testing.expectEqual(@as(i8, 10), v),
        else => return error.TestFailed,
    }
}

test "headless.parse: - → volume_delta -10" {
    const cmd = headless.parse("-\n");
    try std.testing.expect(cmd != null);
    switch (cmd.?) {
        .volume_delta => |v| try std.testing.expectEqual(@as(i8, -10), v),
        else => return error.TestFailed,
    }
}

test "headless.parse: b → bookmark" {
    const cmd = headless.parse("b\n");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.bookmark, cmd.?);
}

test "headless.parse: q → quit" {
    const cmd = headless.parse("q\n");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.quit, cmd.?);
}

test "headless.parse: uppercase S → null (case-sensitive)" {
    try std.testing.expectEqual(@as(?message.Command, null), headless.parse("S\n"));
}

test "headless.parse: uppercase Q → null (case-sensitive)" {
    try std.testing.expectEqual(@as(?message.Command, null), headless.parse("Q\n"));
}

test "headless.parse: empty string → null" {
    try std.testing.expectEqual(@as(?message.Command, null), headless.parse(""));
}

test "headless.parse: whitespace-only → null" {
    try std.testing.expectEqual(@as(?message.Command, null), headless.parse("   \n"));
}

test "headless.parse: unrecognised first char → null" {
    try std.testing.expectEqual(@as(?message.Command, null), headless.parse("xyz"));
}

test "headless.parse: leading whitespace ignored — first non-ws is trigger" {
    const cmd = headless.parse("  q  ");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.quit, cmd.?);
}

test "headless.parse: only first char matters — +++ → volume_delta 10" {
    const cmd = headless.parse("+++");
    try std.testing.expect(cmd != null);
    switch (cmd.?) {
        .volume_delta => |v| try std.testing.expectEqual(@as(i8, 10), v),
        else => return error.TestFailed,
    }
}

test "headless.parse: tab before char is whitespace" {
    const cmd = headless.parse("\tp");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqual(message.Command.toggle_pause, cmd.?);
}

// ---------------------------------------------------------------------------
// formatEvent() — Event → stable output line
// ---------------------------------------------------------------------------

test "headless.formatEvent: track_started with duration" {
    const track = core.Track{
        .id = 1,
        .display_name = "lofi - sample 01",
        .source_uri = "https://example.com/track.mp3",
        .duration_hint = 287000,
        .bytes = null,
    };
    var buf: [512]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .track_started = track });
    try std.testing.expectEqualStrings(
        "EVT track_started  name=\"lofi - sample 01\"  duration_ms=287000",
        line,
    );
}

test "headless.formatEvent: track_started without duration" {
    const track = core.Track{
        .id = 2,
        .display_name = "unknown",
        .source_uri = "https://example.com/track2.mp3",
        .duration_hint = null,
        .bytes = null,
    };
    var buf: [512]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .track_started = track });
    try std.testing.expectEqualStrings(
        "EVT track_started  name=\"unknown\"",
        line,
    );
}

test "headless.formatEvent: track_progress" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{
        .track_progress = .{ .elapsed_ms = 1000, .duration_ms = null },
    });
    try std.testing.expectEqualStrings("EVT track_progress  elapsed_ms=1000", line);
}

test "headless.formatEvent: track_ended" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, .track_ended);
    try std.testing.expectEqualStrings("EVT track_ended", line);
}

test "headless.formatEvent: paused true" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .paused = true });
    try std.testing.expectEqualStrings("EVT paused  value=true", line);
}

test "headless.formatEvent: paused false" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .paused = false });
    try std.testing.expectEqualStrings("EVT paused  value=false", line);
}

test "headless.formatEvent: volume_changed" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .volume_changed = 70 });
    try std.testing.expectEqualStrings("EVT volume_changed  value=70", line);
}

test "headless.formatEvent: bookmark_added" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .bookmark_added = "chill track" });
    try std.testing.expectEqualStrings("EVT bookmark_added  name=\"chill track\"", line);
}

test "headless.formatEvent: bookmark_removed" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .bookmark_removed = "chill track" });
    try std.testing.expectEqualStrings("EVT bookmark_removed  name=\"chill track\"", line);
}

test "headless.formatEvent: network_stalled" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, .network_stalled);
    try std.testing.expectEqualStrings("EVT network_stalled", line);
}

test "headless.formatEvent: decode_failed with reason" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .decode_failed = "unsupported format" });
    try std.testing.expectEqualStrings("EVT decode_failed  reason=\"unsupported format\"", line);
}

test "headless.formatEvent: audio_device_lost" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, .audio_device_lost);
    try std.testing.expectEqualStrings("EVT audio_device_lost", line);
}

test "headless.formatEvent: sync_in_progress" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, .sync_in_progress);
    try std.testing.expectEqualStrings("EVT sync_in_progress", line);
}

test "headless.formatEvent: sync_completed" {
    var buf: [64]u8 = undefined;
    const line = try headless.formatEvent(&buf, .sync_completed);
    try std.testing.expectEqualStrings("EVT sync_completed", line);
}

test "headless.formatEvent: sync_failed with reason" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .sync_failed = "connection lost" });
    try std.testing.expectEqualStrings("EVT sync_failed  reason=\"connection lost\"", line);
}

test "headless.formatEvent: quit" {
    var buf: [32]u8 = undefined;
    const line = try headless.formatEvent(&buf, .quit);
    try std.testing.expectEqualStrings("EVT quit", line);
}

// ---------------------------------------------------------------------------
// formatEvent() — quote escaping
// ---------------------------------------------------------------------------

test "headless.formatEvent: escapes double-quotes in name" {
    const track = core.Track{
        .id = 3,
        .display_name = "Lofi \"fire\"",
        .source_uri = "https://example.com/fire.mp3",
        .duration_hint = null,
        .bytes = null,
    };
    var buf: [512]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .track_started = track });
    try std.testing.expectEqualStrings(
        "EVT track_started  name=\"Lofi \\\"fire\\\"\"",
        line,
    );
}

test "headless.formatEvent: escapes backslashes in reason" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .decode_failed = "path\\to\\file" });
    try std.testing.expectEqualStrings("EVT decode_failed  reason=\"path\\\\to\\\\file\"", line);
}

test "headless.formatEvent: escapes both quote and backslash" {
    var buf: [256]u8 = undefined;
    const line = try headless.formatEvent(&buf, message.Event{ .decode_failed = "bad\\\"escape" });
    try std.testing.expectEqualStrings("EVT decode_failed  reason=\"bad\\\\\\\"escape\"", line);
}
