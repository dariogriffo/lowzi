/// Tests for audio.Output — pure ring-buffer tests, no real audio device.
const std = @import("std");
const audio = @import("audio");
const Ring = @import("audio").Ring;

test "Ring: write N samples, read N samples, FIFO order" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit(gpa);

    const input = [_]i16{ 1, 2, 3, 4, 5 };
    const written = ring.writeSamples(&input);
    try std.testing.expectEqual(@as(usize, 5), written);

    var out: [5]i16 = undefined;
    const read = ring.readSamples(&out);
    try std.testing.expectEqual(@as(usize, 5), read);
    try std.testing.expectEqualSlices(i16, &input, &out);
}

test "Ring: full ring write returns short count" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit(gpa);

    const cap = audio.RING_CAPACITY - 1; // usable capacity
    const big = try gpa.alloc(i16, cap + 10);
    defer gpa.free(big);
    @memset(big, 42);

    const written = ring.writeSamples(big);
    try std.testing.expectEqual(cap, written);

    // Ring is full; additional write should return 0.
    const more = [_]i16{99};
    try std.testing.expectEqual(@as(usize, 0), ring.writeSamples(&more));
}

test "Ring: drain to empty restores full capacity" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit(gpa);

    const samples = [_]i16{ 10, 20, 30 };
    _ = ring.writeSamples(&samples);

    var drain: [3]i16 = undefined;
    _ = ring.readSamples(&drain);

    // After drain, freeSpace should be back to capacity - 1.
    try std.testing.expectEqual(audio.RING_CAPACITY - 1, ring.freeSpace());
}

test "Ring: read from empty ring returns 0" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit(gpa);

    var out: [8]i16 = undefined;
    const n = ring.readSamples(&out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "Ring: partial write when nearly full" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit(gpa);

    // Fill up to cap - 3 slots.
    const cap = audio.RING_CAPACITY - 1;
    const pre = try gpa.alloc(i16, cap - 3);
    defer gpa.free(pre);
    @memset(pre, 1);
    const w1 = ring.writeSamples(pre);
    try std.testing.expectEqual(cap - 3, w1);

    // Only 3 slots remain.
    const overflow = [_]i16{ 10, 20, 30, 40, 50 };
    const w2 = ring.writeSamples(&overflow);
    try std.testing.expectEqual(@as(usize, 3), w2);
}
