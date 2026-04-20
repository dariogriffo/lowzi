/// tests/source_downloader_test.zig — unit tests for source/downloader.
///
/// All tests use std.testing.allocator (zunit leak-checks between tests).
/// HTTP is replaced by a fake Fetcher so no real network is touched.
const std = @import("std");
const source = @import("source");
const downloader = source.downloader;
const Fetcher = downloader.Fetcher;
const core = @import("core");

// ---------------------------------------------------------------------------
// Io lifecycle — required because fetchWith takes std.Io even though in
// test mode backoffSleep is a no-op.  We initialise the global testing.io
// once per file via zunit lifecycle hooks.
// ---------------------------------------------------------------------------

test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

// ---------------------------------------------------------------------------
// Fake Fetcher helpers
// ---------------------------------------------------------------------------

/// Per-call specification used by FakeCtx.
const CallSpec = union(enum) {
    /// Return a copy of `body` (gpa-owned).
    ok: []const u8,
    /// Return the given error.
    err: downloader.FetchError,
};

/// A fake Fetcher context that plays back a fixed sequence of CallSpecs.
const FakeCtx = struct {
    calls: []const CallSpec,
    call_count: usize = 0,

    fn fetchOnce(
        ctx_opaque: *anyopaque,
        gpa: std.mem.Allocator,
        url: []const u8,
    ) downloader.FetchError![]u8 {
        _ = url;
        const self: *FakeCtx = @alignCast(@ptrCast(ctx_opaque));
        const idx = self.call_count;
        self.call_count += 1;
        if (idx >= self.calls.len) return error.ConnectionLost;
        return switch (self.calls[idx]) {
            .ok => |body| gpa.dupe(u8, body) catch return error.OutOfMemory,
            .err => |err| err,
        };
    }
};

const fake_vtable = Fetcher.VTable{ .fetchOnce = FakeCtx.fetchOnce };

fn makeFetcher(ctx: *FakeCtx) Fetcher {
    return Fetcher{ .ctx = @ptrCast(ctx), .vtable = &fake_vtable };
}

/// A zero-value Config is fine for all downloader tests.
fn defaultCfg() core.Config {
    return .{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "source.downloader: happy path returns body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{.{ .ok = "hello world" }} };
    const fetcher = makeFetcher(&ctx);

    const body = try downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    defer gpa.free(body);

    try std.testing.expectEqualStrings("hello world", body);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "source.downloader: retries on ConnectionLost then succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{
        .{ .err = error.ConnectionLost },
        .{ .err = error.ConnectionLost },
        .{ .ok = "recovered" },
    } };
    const fetcher = makeFetcher(&ctx);

    const body = try downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    defer gpa.free(body);

    try std.testing.expectEqualStrings("recovered", body);
    try std.testing.expectEqual(@as(usize, 3), ctx.call_count);
}

test "source.downloader: retry exhausted returns last error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{
        .{ .err = error.ConnectionLost },
        .{ .err = error.ConnectionLost },
        .{ .err = error.ConnectionLost },
    } };
    const fetcher = makeFetcher(&ctx);

    const result = downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    try std.testing.expectError(error.ConnectionLost, result);
    try std.testing.expectEqual(@as(usize, 3), ctx.call_count);
}

test "source.downloader: Canceled is not retried" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{
        .{ .err = error.Canceled },
        // Second call should never happen.
        .{ .ok = "should not reach" },
    } };
    const fetcher = makeFetcher(&ctx);

    const result = downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "source.downloader: OutOfMemory is not retried" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{
        .{ .err = error.OutOfMemory },
        .{ .ok = "should not reach" },
    } };
    const fetcher = makeFetcher(&ctx);

    const result = downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "source.downloader: BodyTooLarge is not retried" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var ctx = FakeCtx{ .calls = &.{
        .{ .err = error.BodyTooLarge },
        .{ .ok = "should not reach" },
    } };
    const fetcher = makeFetcher(&ctx);

    const result = downloader.fetchWith(io, gpa, defaultCfg(), "http://fake/track.mp3", fetcher);
    try std.testing.expectError(error.BodyTooLarge, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

test "source.downloader: MAX_BODY_BYTES constant is 25 MB" {
    try std.testing.expectEqual(@as(usize, 25 * 1024 * 1024), downloader.MAX_BODY_BYTES);
}
