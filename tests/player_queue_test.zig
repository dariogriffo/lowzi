/// Tests for player/queue.zig
const std = @import("std");
const player = @import("player");
const storage = @import("storage");
const core = @import("core");

const gpa = std.testing.allocator;

// ---------------------------------------------------------------------------
// Seed a minimal in-memory database with a playlist and some tracks.
// ---------------------------------------------------------------------------

fn seedDb(conn: *storage.Conn) !void {
    const c = @import("storage_c");
    {
        const rc = c.sqlite3_exec(conn.db,
            "INSERT INTO playlists (id, name, url, added_at) VALUES (1, 'test', 'http://x.com/test.m3u8', 0)",
            null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }
    {
        const rc = c.sqlite3_exec(conn.db,
            "INSERT INTO tracks (id, playlist_id, url, display_name, duration_ms, added_at) VALUES " ++
            "(1, 1, 'http://x.com/1.mp3', 'Track 1', 180000, 0)," ++
            "(2, 1, 'http://x.com/2.mp3', 'Track 2', 200000, 0)," ++
            "(3, 1, 'http://x.com/3.mp3', 'Track 3', null, 0)",
            null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }
}

// ---------------------------------------------------------------------------
// pickCandidate
// ---------------------------------------------------------------------------

test "player.queue: pickCandidate returns a track when DB has rows" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const row = try player.queue.pickCandidate(&conn, arena.allocator(), &.{});
    try std.testing.expect(row != null);
    // Should be one of our seeded IDs.
    try std.testing.expect(row.?.id >= 1 and row.?.id <= 3);
}

test "player.queue: pickCandidate respects exclude list" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Exclude all three tracks.
    const row = try player.queue.pickCandidate(&conn, arena.allocator(), &.{ 1, 2, 3 });
    try std.testing.expect(row == null);
}

test "player.queue: pickCandidate returns null on empty DB" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const row = try player.queue.pickCandidate(&conn, arena.allocator(), &.{});
    try std.testing.expect(row == null);
}

test "player.queue: pickCandidate never returns excluded ID" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Exclude IDs 1 and 3; only ID 2 should come back.
    const row = try player.queue.pickCandidate(&conn, arena.allocator(), &.{ 1, 3 });
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 2), row.?.id);
}

// ---------------------------------------------------------------------------
// fetchTrackBody with a fake BodyFetchFn
// ---------------------------------------------------------------------------

const fake_bytes = "fake mp3 bytes";

fn fakeFetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = cfg;
    _ = url;
    return alloc.dupe(u8, fake_bytes);
}

fn failFetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = alloc;
    _ = cfg;
    _ = url;
    return error.ConnectionLost;
}

test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

test "player.queue: fetchTrackBody returns bytes from fake fetcher" {
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const row = (try player.queue.pickCandidate(&conn, arena.allocator(), &.{})).?;
    const cfg = core.Config{};

    const body = try player.queue.fetchTrackBody(io, gpa, cfg, row, fakeFetch);
    defer gpa.free(body);

    try std.testing.expectEqualSlices(u8, fake_bytes, body);
}

test "player.queue: fetchTrackBody propagates fetch error" {
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const row = (try player.queue.pickCandidate(&conn, arena.allocator(), &.{})).?;
    const cfg = core.Config{};

    try std.testing.expectError(
        error.ConnectionLost,
        player.queue.fetchTrackBody(io, gpa, cfg, row, failFetch),
    );
}
