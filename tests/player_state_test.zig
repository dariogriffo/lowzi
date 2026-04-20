/// Tests for player/state.zig
const std = @import("std");
const player = @import("player");
const core = @import("core");

const State = player.State;
const gpa = std.testing.allocator;

// ---------------------------------------------------------------------------
// applyCommand — table-driven
// ---------------------------------------------------------------------------

test "player.state: quit returns Event.quit" {
    var s = State{};
    defer s.deinit(gpa);
    const evt = s.applyCommand(.quit);
    try std.testing.expect(evt != null);
    try std.testing.expectEqual(core.message.Event.quit, evt.?);
}

test "player.state: skip returns null" {
    var s = State{};
    defer s.deinit(gpa);
    const evt = s.applyCommand(.skip);
    try std.testing.expect(evt == null);
}

test "player.state: bookmark returns null" {
    var s = State{};
    defer s.deinit(gpa);
    const evt = s.applyCommand(.bookmark);
    try std.testing.expect(evt == null);
}

test "player.state: toggle_pause flips flag and returns paused event" {
    var s = State{};
    defer s.deinit(gpa);

    try std.testing.expect(!s.paused);

    const evt1 = s.applyCommand(.toggle_pause);
    try std.testing.expect(evt1 != null);
    try std.testing.expect(s.paused);
    try std.testing.expectEqual(core.message.Event{ .paused = true }, evt1.?);

    const evt2 = s.applyCommand(.toggle_pause);
    try std.testing.expect(!s.paused);
    try std.testing.expectEqual(core.message.Event{ .paused = false }, evt2.?);
}

test "player.state: volume_delta clamps to [0, 100]" {
    var s = State{ .volume = 60 };
    defer s.deinit(gpa);

    // +10 → 70
    const evt1 = s.applyCommand(.{ .volume_delta = 10 });
    try std.testing.expectEqual(@as(u8, 70), s.volume);
    try std.testing.expectEqual(core.message.Event{ .volume_changed = 70 }, evt1.?);

    // -80 → clamped to 0 (70 - 80 < 0)
    const evt2 = s.applyCommand(.{ .volume_delta = -80 });
    try std.testing.expectEqual(@as(u8, 0), s.volume);
    try std.testing.expectEqual(core.message.Event{ .volume_changed = 0 }, evt2.?);

    // +120 → clamped to 100
    const evt3 = s.applyCommand(.{ .volume_delta = 120 });
    try std.testing.expectEqual(@as(u8, 100), s.volume);
    try std.testing.expectEqual(core.message.Event{ .volume_changed = 100 }, evt3.?);
}

test "player.state: volume_delta from 50 with +10 then -5" {
    var s = State{ .volume = 50 };
    defer s.deinit(gpa);
    _ = s.applyCommand(.{ .volume_delta = 10 });
    try std.testing.expectEqual(@as(u8, 60), s.volume);
    _ = s.applyCommand(.{ .volume_delta = -5 });
    try std.testing.expectEqual(@as(u8, 55), s.volume);
}

// ---------------------------------------------------------------------------
// pushTrack / advance
// ---------------------------------------------------------------------------

fn makeTrack(id: u64) core.Track {
    return core.Track{
        .id = id,
        .display_name = "test",
        .source_uri = "http://example.com/test.mp3",
        .duration_hint = null,
        .bytes = null,
    };
}

test "player.state: pushTrack returns false when queue is full" {
    var s = State{};
    defer s.deinit(gpa);
    const capacity: usize = 2;

    const ok1 = try s.pushTrack(gpa, capacity, makeTrack(1));
    try std.testing.expect(ok1);
    const ok2 = try s.pushTrack(gpa, capacity, makeTrack(2));
    try std.testing.expect(ok2);
    const ok3 = try s.pushTrack(gpa, capacity, makeTrack(3));
    try std.testing.expect(!ok3);
    // Queue should still have 2 items.
    try std.testing.expectEqual(@as(usize, 2), s.queue.items.len);
}

test "player.state: advance installs front of queue as current" {
    var s = State{};
    defer s.deinit(gpa);

    _ = try s.pushTrack(gpa, 4, makeTrack(10));
    _ = try s.pushTrack(gpa, 4, makeTrack(20));

    const first = s.advance(gpa);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(u64, 10), first.?.id);
    try std.testing.expect(s.current != null);
    try std.testing.expectEqual(@as(u64, 10), s.current.?.id);
    try std.testing.expectEqual(@as(usize, 1), s.queue.items.len);

    const second = s.advance(gpa);
    try std.testing.expectEqual(@as(u64, 20), second.?.id);
    try std.testing.expectEqual(@as(usize, 0), s.queue.items.len);

    const empty = s.advance(gpa);
    try std.testing.expect(empty == null);
    try std.testing.expect(s.current == null);
}

test "player.state: advance on empty queue returns null" {
    var s = State{};
    defer s.deinit(gpa);
    const result = s.advance(gpa);
    try std.testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// recordRecent — ring-buffer eviction
// ---------------------------------------------------------------------------

test "player.state: recordRecent tracks up to 16 IDs" {
    var s = State{};
    defer s.deinit(gpa);

    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        s.recordRecent(i);
    }
    try std.testing.expectEqual(@as(usize, 16), s.recent_ids.len);
    try std.testing.expectEqual(@as(i64, 0), s.recent_ids.buf[0]);
    try std.testing.expectEqual(@as(i64, 15), s.recent_ids.buf[15]);
}

test "player.state: recordRecent evicts oldest on overflow" {
    var s = State{};
    defer s.deinit(gpa);

    // Fill to capacity.
    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        s.recordRecent(i);
    }
    // Push one more: should evict ID 0.
    s.recordRecent(100);
    try std.testing.expectEqual(@as(usize, 16), s.recent_ids.len);
    // ID 0 was evicted; ID 1 should now be at index 0.
    try std.testing.expectEqual(@as(i64, 1), s.recent_ids.buf[0]);
    try std.testing.expectEqual(@as(i64, 100), s.recent_ids.buf[15]);
}

// ---------------------------------------------------------------------------
// deinit frees owned bytes (leak check via testing allocator)
// ---------------------------------------------------------------------------

test "player.state: deinit frees track bytes without leak" {
    var s = State{};

    // Push a track with owned bytes.
    var t = makeTrack(42);
    t.bytes = try gpa.dupe(u8, "mp3 data");
    _ = try s.pushTrack(gpa, 4, t);

    // advance makes it current.
    _ = s.advance(gpa);

    // deinit must free the bytes.
    s.deinit(gpa);
    // If there is a leak, the testing allocator will catch it.
}
