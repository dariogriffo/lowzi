/// tests/source_sync_test.zig — unit tests for source/sync.
///
/// Uses an in-memory SQLite DB and fake manifest/body fetchers so no real
/// network is touched.  All tests use std.testing.allocator (zunit leak-checks).
const std = @import("std");
const storage = @import("storage");
const source = @import("source");
const core = @import("core");
const c = @import("storage_c");
const sync_mod = source.sync;

// ---------------------------------------------------------------------------
// Io lifecycle — initialised once per file via zunit hooks.
// ---------------------------------------------------------------------------

test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

// ---------------------------------------------------------------------------
// Helpers: fake manifest fetcher
// ---------------------------------------------------------------------------

const FakePlaylist = struct {
    name: []const u8,
    url: []const u8,
};

const FakeManifestCtx = struct {
    hash: []const u8,
    playlists: []const FakePlaylist,
};

/// Thread-local pointer so the comptime-compatible fn ptr can reach context.
/// Each test sets this before calling runWith.
var g_manifest_ctx: ?*const FakeManifestCtx = null;

fn fakeManifestFetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
) anyerror!source.manifest.Manifest {
    _ = io;
    _ = cfg;
    const ctx = g_manifest_ctx.?;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const hash = try alloc.dupe(u8, ctx.hash);
    const playlists = try alloc.alloc(source.manifest.PlaylistEntry, ctx.playlists.len);
    for (ctx.playlists, 0..) |pl, i| {
        playlists[i] = .{
            .name = try alloc.dupe(u8, pl.name),
            .url = try alloc.dupe(u8, pl.url),
        };
    }

    return source.manifest.Manifest{
        .arena = arena,
        .hash = hash,
        .playlists = playlists,
    };
}

// ---------------------------------------------------------------------------
// Helpers: fake body fetcher
// ---------------------------------------------------------------------------

const FakeBodyCall = union(enum) {
    ok: []const u8,   // M3U8 body to return (gpa-duped)
    err: anyerror,
};

const FakeBodyCtx = struct {
    calls: []const FakeBodyCall,
    call_count: usize = 0,
};

var g_body_ctx: ?*FakeBodyCtx = null;

fn fakeBodyFetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = cfg;
    _ = url;
    const ctx = g_body_ctx.?;
    const idx = ctx.call_count;
    ctx.call_count += 1;
    if (idx >= ctx.calls.len) return error.ConnectionLost;
    return switch (ctx.calls[idx]) {
        .ok => |body| gpa.dupe(u8, body) catch return error.OutOfMemory,
        .err => |err| err,
    };
}

// ---------------------------------------------------------------------------
// Helpers: DB inspection
// ---------------------------------------------------------------------------

fn countTable(conn: *storage.Conn, table: []const u8) !i64 {
    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf, "SELECT COUNT(*) FROM {s}", .{table});
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_step(stmt);
    return c.sqlite3_column_int64(stmt, 0);
}

fn getTrackIdByUrl(conn: *storage.Conn, url: []const u8) !?i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "SELECT id FROM tracks WHERE url = ?", -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), storage.sqliteTransient());
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc == c.SQLITE_DONE) return null;
    return c.sqlite3_column_int64(stmt, 0);
}

/// Drain all events currently in the channel without blocking. Returns a
/// heap-allocated slice; caller frees via gpa.free(slice).
fn drainEvents(gpa: std.mem.Allocator, bus: *core.Bus) ![]core.message.Event {
    const io = std.testing.io;
    var list: std.ArrayList(core.message.Event) = .empty;
    errdefer list.deinit(gpa);
    while (bus.player_to_ui.tryRecv(io)) |evt| {
        try list.append(gpa, evt);
    }
    return list.toOwnedSlice(gpa);
}

/// Drain and discard all events. Use this for intermediate syncs in
/// multi-round tests where we don't care about the intermediate events.
fn discardEvents(gpa: std.mem.Allocator, bus: *core.Bus) !void {
    const evts = try drainEvents(gpa, bus);
    gpa.free(evts);
}

fn defaultCfg() core.Config {
    return .{};
}

// ---------------------------------------------------------------------------
// M3U8 body fixtures
// ---------------------------------------------------------------------------

const M3U8_3_TRACKS =
    \\#EXTM3U
    \\#EXTINF:180.0,Track Alpha
    \\https://cdn.example.com/a.mp3
    \\#EXTINF:200.0,Track Beta
    \\https://cdn.example.com/b.mp3
    \\#EXTINF:220.0,Track Gamma
    \\https://cdn.example.com/c.mp3
;

const M3U8_2_TRACKS =
    \\#EXTM3U
    \\#EXTINF:100.0,Track Delta
    \\https://cdn.example.com/d.mp3
    \\#EXTINF:110.0,Track Epsilon
    \\https://cdn.example.com/e.mp3
;

// ---------------------------------------------------------------------------
// Test 1: Happy path, empty DB.
// ---------------------------------------------------------------------------

test "source.sync: happy path - empty DB gets 2 playlists and 5 tracks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-one", .url = "https://fake/pl-one.m3u8" },
        .{ .name = "pl-two", .url = "https://fake/pl-two.m3u8" },
    };
    var manifest_ctx = FakeManifestCtx{
        .hash = "sha256:abc123",
        .playlists = &playlists,
    };
    g_manifest_ctx = &manifest_ctx;

    var body_ctx = FakeBodyCtx{ .calls = &.{
        .{ .ok = M3U8_3_TRACKS },
        .{ .ok = M3U8_2_TRACKS },
    } };
    g_body_ctx = &body_ctx;

    try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);

    // 2 playlists, 5 tracks total.
    try std.testing.expectEqual(@as(i64, 2), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 5), try countTable(&conn, "tracks"));

    // manifest_hash updated.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const hash = try storage.queries.getManifestHash(&conn, arena.allocator());
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("sha256:abc123", hash.?);

    // sync_completed was sent.
    const events = try drainEvents(gpa, &bus);
    defer gpa.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .sync_completed => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Test 2: Hash match → no work.
// ---------------------------------------------------------------------------

test "source.sync: hash match skips download and sends sync_completed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // Pre-seed the manifest hash so it matches what our fake will return.
    try storage.queries.setManifestHash(&conn, "sha256:already-current");

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-one", .url = "https://fake/pl-one.m3u8" },
    };
    var manifest_ctx = FakeManifestCtx{
        .hash = "sha256:already-current",
        .playlists = &playlists,
    };
    g_manifest_ctx = &manifest_ctx;

    // Body fetcher should never be called.
    var body_ctx = FakeBodyCtx{ .calls = &.{} };
    g_body_ctx = &body_ctx;

    try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);

    // DB unchanged — no playlists or tracks.
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "tracks"));

    // Body fetcher was never called.
    try std.testing.expectEqual(@as(usize, 0), body_ctx.call_count);

    // sync_completed was still sent.
    const events = try drainEvents(gpa, &bus);
    defer gpa.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .sync_completed => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Test 3: Second sync with delta.
// ---------------------------------------------------------------------------

const M3U8_PL_A_V1 =
    \\#EXTM3U
    \\#EXTINF:180.0,Track 1
    \\https://cdn.example.com/t1.mp3
    \\#EXTINF:180.0,Track 2
    \\https://cdn.example.com/t2.mp3
    \\#EXTINF:180.0,Track 3
    \\https://cdn.example.com/t3.mp3
;

const M3U8_PL_A_V2 =
    \\#EXTM3U
    \\#EXTINF:180.0,Track 1
    \\https://cdn.example.com/t1.mp3
    \\#EXTINF:180.0,Track 2
    \\https://cdn.example.com/t2.mp3
    \\#EXTINF:180.0,Track 4
    \\https://cdn.example.com/t4.mp3
;

test "source.sync: second sync with delta — track removed and added, playlist row stable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists_v1 = [_]FakePlaylist{
        .{ .name = "pl-a", .url = "https://fake/pl-a.m3u8" },
    };

    // First sync: pl-a has 3 tracks.
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v1", .playlists = &playlists_v1 };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V1 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }

    // Drain the first sync_completed event.
    try discardEvents(gpa, &bus);

    // Second sync: pl-a now has t1, t2, t4 (t3 removed, t4 added).
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v2", .playlists = &playlists_v1 };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V2 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }

    // Playlist row still 1; tracks: t1, t2, t4 (3 rows); t3 gone.
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 3), try countTable(&conn, "tracks"));

    const t3_id = try getTrackIdByUrl(&conn, "https://cdn.example.com/t3.mp3");
    try std.testing.expect(t3_id == null);

    const t4_id = try getTrackIdByUrl(&conn, "https://cdn.example.com/t4.mp3");
    try std.testing.expect(t4_id != null);

    // manifest_hash updated.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const hash = try storage.queries.getManifestHash(&conn, arena.allocator());
    try std.testing.expectEqualStrings("sha256:v2", hash.?);
}

// ---------------------------------------------------------------------------
// Test 4: Bookmark survives track being kept across syncs.
// ---------------------------------------------------------------------------

test "source.sync: bookmark survives when track stays in playlist" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-a", .url = "https://fake/pl-a.m3u8" },
    };

    // First sync: load track X.
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v1", .playlists = &playlists };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V1 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }
    try discardEvents(gpa, &bus);

    // Bookmark track t1.
    const t1_id = (try getTrackIdByUrl(&conn, "https://cdn.example.com/t1.mp3")).?;
    try storage.queries.addBookmark(&conn, t1_id);
    try std.testing.expect(try storage.queries.isBookmarked(&conn, t1_id));

    // Second sync: pl-a same tracks (different hash to force re-sync), t1 kept.
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v2", .playlists = &playlists };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V1 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }

    // t1 still bookmarked (the row survived the merge because t1's URL is still in the playlist).
    // We need to look up t1_id again as the merge may have kept the same row.
    const t1_id_after = (try getTrackIdByUrl(&conn, "https://cdn.example.com/t1.mp3")).?;
    try std.testing.expect(try storage.queries.isBookmarked(&conn, t1_id_after));
}

// ---------------------------------------------------------------------------
// Test 5: Bookmark cascades when track is removed.
// ---------------------------------------------------------------------------

test "source.sync: bookmark cascades when track is removed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-a", .url = "https://fake/pl-a.m3u8" },
    };

    // First sync: 3 tracks including t3.
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v1", .playlists = &playlists };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V1 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }
    try discardEvents(gpa, &bus);

    // Bookmark t3.
    const t3_id = (try getTrackIdByUrl(&conn, "https://cdn.example.com/t3.mp3")).?;
    try storage.queries.addBookmark(&conn, t3_id);
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "bookmarks"));

    // Second sync: t3 removed from playlist.
    {
        var manifest_ctx = FakeManifestCtx{ .hash = "sha256:v2", .playlists = &playlists };
        g_manifest_ctx = &manifest_ctx;
        var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .ok = M3U8_PL_A_V2 } } };
        g_body_ctx = &body_ctx;
        try sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    }

    // t3 and its bookmark are gone (ON DELETE CASCADE).
    try std.testing.expect((try getTrackIdByUrl(&conn, "https://cdn.example.com/t3.mp3")) == null);
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "bookmarks"));
}

// ---------------------------------------------------------------------------
// Test 6: Download error mid-way rolls back.
// ---------------------------------------------------------------------------

test "source.sync: download error mid-way rolls back and sends sync_failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // Pre-seed one playlist so we can verify DB is unchanged.
    {
        var tx = try storage.queries.beginSync(&conn);
        try tx.appendTemp("stable-pl", "https://cdn.example.com/stable.mp3", null, null);
        try tx.mergeAndCommit("sha256:stable");
    }

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-one", .url = "https://fake/pl-one.m3u8" },
        .{ .name = "pl-two", .url = "https://fake/pl-two.m3u8" },
    };
    var manifest_ctx = FakeManifestCtx{ .hash = "sha256:new-hash", .playlists = &playlists };
    g_manifest_ctx = &manifest_ctx;

    // First body fetch succeeds; second fails.
    var body_ctx = FakeBodyCtx{ .calls = &.{
        .{ .ok = M3U8_3_TRACKS },
        .{ .err = error.ConnectionLost },
    } };
    g_body_ctx = &body_ctx;

    const result = sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    try std.testing.expectError(error.ConnectionLost, result);

    // DB unchanged: still has the stable-pl row (1 playlist, 1 track from seed;
    // the new transaction was rolled back).
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "tracks"));

    // sync_failed was sent with a non-empty reason.
    const events = try drainEvents(gpa, &bus);
    defer gpa.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    switch (events[0]) {
        .sync_failed => |reason| try std.testing.expect(reason.len > 0),
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Test 7: Cancellation rolls back, no sync_failed sent.
// ---------------------------------------------------------------------------

test "source.sync: cancellation rolls back and does not send sync_failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var bus = try core.Bus.init(gpa, defaultCfg());
    defer bus.deinit(gpa);

    const playlists = [_]FakePlaylist{
        .{ .name = "pl-one", .url = "https://fake/pl-one.m3u8" },
    };
    var manifest_ctx = FakeManifestCtx{ .hash = "sha256:any", .playlists = &playlists };
    g_manifest_ctx = &manifest_ctx;

    var body_ctx = FakeBodyCtx{ .calls = &.{ .{ .err = error.Canceled } } };
    g_body_ctx = &body_ctx;

    const result = sync_mod.runWith(io, gpa, defaultCfg(), &conn, &bus, fakeManifestFetch, fakeBodyFetch);
    try std.testing.expectError(error.Canceled, result);

    // DB unchanged.
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "tracks"));

    // No event sent — clean shutdown.
    const events = try drainEvents(gpa, &bus);
    defer gpa.free(events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}
