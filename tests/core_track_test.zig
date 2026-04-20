/// Tests for core.Track: deinit releases owned bytes.
const std = @import("std");
const core = @import("core");

test "core.track: deinit frees bytes slice" {
    const gpa = std.testing.allocator;

    const bytes = try gpa.dupe(u8, "fake mp3 data");
    var track = core.Track{
        .id = 1,
        .display_name = "test track",
        .source_uri = "http://example.com/test.mp3",
        .duration_hint = 30000,
        .bytes = bytes,
    };
    // The testing allocator will catch a leak if deinit is not called.
    track.deinit(gpa);
    try std.testing.expectEqual(@as(?[]u8, null), track.bytes);
}

test "core.track: deinit is safe when bytes is null" {
    const gpa = std.testing.allocator;
    var track = core.Track{
        .id = 2,
        .display_name = "no bytes",
        .source_uri = "http://example.com/nodata.mp3",
        .duration_hint = null,
        .bytes = null,
    };
    // Must not crash and must not leak.
    track.deinit(gpa);
}

test "core.track: deinit is idempotent" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, "pcm data");
    var track = core.Track{
        .id = 3,
        .display_name = "idempotent track",
        .source_uri = "file:///tmp/x.mp3",
        .duration_hint = 5000,
        .bytes = bytes,
    };
    track.deinit(gpa);
    // Second deinit: bytes is null, so no double-free.
    track.deinit(gpa);
}
