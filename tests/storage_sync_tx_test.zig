const std = @import("std");
const storage = @import("storage");
const q = storage.queries;
const c = @import("storage_c");

// ---------------------------------------------------------------------------
// Helpers
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

fn countTracksForPlaylist(conn: *storage.Conn, pl_name: []const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db,
        "SELECT COUNT(*) FROM tracks t JOIN playlists p ON p.id = t.playlist_id WHERE p.name = ?",
        -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, pl_name.ptr, @intCast(pl_name.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_step(stmt);
    return c.sqlite3_column_int64(stmt, 0);
}

fn tempTableExists(conn: *storage.Conn) bool {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "SELECT 1 FROM temp_tracks LIMIT 1", -1, &stmt, null);
    if (stmt != null) _ = c.sqlite3_finalize(stmt);
    return rc == c.SQLITE_OK;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "storage.sync_tx: beginSync + appendTemp + mergeAndCommit produces correct rows" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var tx = try q.beginSync(&conn);
    try tx.appendTemp("lofi-focus", "https://example.com/t1.mp3", "Track 1", 180_000);
    try tx.appendTemp("lofi-focus", "https://example.com/t2.mp3", null, null);
    try tx.appendTemp("chillhop", "https://example.com/t3.mp3", "Track 3", 240_000);
    try tx.mergeAndCommit("sha256:hash1");

    // 2 playlists, 3 tracks.
    try std.testing.expectEqual(@as(i64, 2), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 3), try countTable(&conn, "tracks"));
    try std.testing.expectEqual(@as(i64, 2), try countTracksForPlaylist(&conn, "lofi-focus"));
    try std.testing.expectEqual(@as(i64, 1), try countTracksForPlaylist(&conn, "chillhop"));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("sha256:hash1", hash.?);
}

test "storage.sync_tx: second sync overlapping rows — no duplicates, new added, removed deleted" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // First sync: 2 playlists, 3 tracks.
    {
        var tx = try q.beginSync(&conn);
        try tx.appendTemp("pl-a", "https://example.com/a1.mp3", "A1", null);
        try tx.appendTemp("pl-a", "https://example.com/a2.mp3", "A2", null);
        try tx.appendTemp("pl-b", "https://example.com/b1.mp3", "B1", null);
        try tx.mergeAndCommit("sha256:v1");
    }

    // Bookmark track b1 so we can verify cascade.
    {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(conn.db,
            "SELECT id FROM tracks WHERE url = 'https://example.com/b1.mp3'",
            -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_step(stmt);
        const b1_id = c.sqlite3_column_int64(stmt, 0);
        try q.addBookmark(&conn, b1_id);
    }

    // Second sync: pl-a keeps a1, drops a2, adds a3; pl-b removed entirely.
    {
        var tx = try q.beginSync(&conn);
        try tx.appendTemp("pl-a", "https://example.com/a1.mp3", "A1", null);
        try tx.appendTemp("pl-a", "https://example.com/a3.mp3", "A3", null);
        try tx.mergeAndCommit("sha256:v2");
    }

    // pl-b and its track (and bookmark) are gone.
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 2), try countTable(&conn, "tracks"));
    try std.testing.expectEqual(@as(i64, 0), try countTable(&conn, "bookmarks"));

    // a1 survives, a3 is new, a2 is gone.
    try std.testing.expectEqual(@as(i64, 2), try countTracksForPlaylist(&conn, "pl-a"));

    // New hash.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expectEqualStrings("sha256:v2", hash.?);
}

test "storage.sync_tx: rollback leaves DB unchanged" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // Seed with one playlist+track.
    {
        var tx = try q.beginSync(&conn);
        try tx.appendTemp("stable-pl", "https://example.com/stable.mp3", null, null);
        try tx.mergeAndCommit("sha256:stable");
    }

    // Start a new sync, add rows, then roll back.
    {
        var tx = try q.beginSync(&conn);
        try tx.appendTemp("new-pl", "https://example.com/new.mp3", null, null);
        tx.rollback();
    }

    // DB should be unchanged.
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "playlists"));
    try std.testing.expectEqual(@as(i64, 1), try countTable(&conn, "tracks"));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expectEqualStrings("sha256:stable", hash.?);
}

test "storage.sync_tx: after rollback temp_tracks no longer exists" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var tx = try q.beginSync(&conn);
    try tx.appendTemp("pl-rollback", "https://example.com/x.mp3", null, null);
    tx.rollback();

    try std.testing.expect(!tempTableExists(&conn));
}
