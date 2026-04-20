/// Tests for core.Channel: bounded MPSC channel.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

// We need std.testing.io for io.async-based tests.
// Initialize it once per file in beforeAll.
test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

// ---------------------------------------------------------------------------
// Basic send/recv
// ---------------------------------------------------------------------------

test "core.channel: send and recv a single item" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    try ch.send(io, 42);
    const val = try ch.recv(io);
    try std.testing.expectEqual(@as(u32, 42), val);
}

test "core.channel: FIFO order across multiple items" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 8);
    defer ch.deinit(gpa);

    try ch.send(io, 1);
    try ch.send(io, 2);
    try ch.send(io, 3);

    try std.testing.expectEqual(@as(u32, 1), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 2), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 3), try ch.recv(io));
}

// ---------------------------------------------------------------------------
// tryRecv returns null when empty
// ---------------------------------------------------------------------------

test "core.channel: tryRecv returns null on empty channel" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    const val = ch.tryRecv(io);
    try std.testing.expectEqual(@as(?u32, null), val);
}

test "core.channel: tryRecv returns item when available" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    try ch.send(io, 99);
    const val = ch.tryRecv(io);
    try std.testing.expectEqual(@as(?u32, 99), val);
    // Now empty again
    try std.testing.expectEqual(@as(?u32, null), ch.tryRecv(io));
}

// ---------------------------------------------------------------------------
// close propagates to recv
// ---------------------------------------------------------------------------

test "core.channel: close makes recv return error.Closed when drained" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    ch.close(io);
    try std.testing.expectError(error.Closed, ch.recv(io));
}

test "core.channel: close drains buffered items before Closed" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    try ch.send(io, 7);
    try ch.send(io, 8);
    ch.close(io);

    // Items buffered before close are returned first.
    try std.testing.expectEqual(@as(u32, 7), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 8), try ch.recv(io));
    // Now closed and empty.
    try std.testing.expectError(error.Closed, ch.recv(io));
}

test "core.channel: send after close returns error.Closed" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var ch = try core.Channel(u32).init(gpa, 4);
    defer ch.deinit(gpa);

    ch.close(io);
    try std.testing.expectError(error.Closed, ch.send(io, 1));
}

// ---------------------------------------------------------------------------
// Producer/consumer across two io.async tasks
// ---------------------------------------------------------------------------

const ProducerCtx = struct {
    ch: *core.Channel(u32),
    count: u32,
};

fn producer(ctx: ProducerCtx) !void {
    const io = std.testing.io;
    var i: u32 = 0;
    while (i < ctx.count) : (i += 1) {
        try ctx.ch.send(io, i);
    }
}

test "core.channel: producer task sends N items, consumer recvs in order" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const N: u32 = 16;
    var ch = try core.Channel(u32).init(gpa, 4); // smaller capacity than N → backpressure
    defer ch.deinit(gpa);

    const ctx = ProducerCtx{ .ch = &ch, .count = N };
    var prod_task = io.async(producer, .{ctx});
    defer _ = prod_task.cancel(io) catch {};

    var received: u32 = 0;
    while (received < N) : (received += 1) {
        const val = try ch.recv(io);
        try std.testing.expectEqual(received, val);
    }
    try prod_task.await(io);
}

// ---------------------------------------------------------------------------
// Backpressure: bounded capacity blocks sender until consumer makes room
// ---------------------------------------------------------------------------

const BlockCtx = struct {
    ch: *core.Channel(u32),
};

fn blockedSender(ctx: BlockCtx) !void {
    // capacity is 2; send 3 items so the 3rd must block until main recvs
    const io = std.testing.io;
    try ctx.ch.send(io, 10);
    try ctx.ch.send(io, 20);
    try ctx.ch.send(io, 30); // blocks until receiver frees a slot
}

test "core.channel: send blocks when at capacity until recv makes room" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var ch = try core.Channel(u32).init(gpa, 2);
    defer ch.deinit(gpa);

    const ctx = BlockCtx{ .ch = &ch };
    var sender_task = io.async(blockedSender, .{ctx});
    defer _ = sender_task.cancel(io) catch {};

    // Receive all three items; the third unblocks the sender
    try std.testing.expectEqual(@as(u32, 10), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 20), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 30), try ch.recv(io));

    try sender_task.await(io);
}
