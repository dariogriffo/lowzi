const std = @import("std");
const storage = @import("storage");
const q = storage.queries;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Insert a playlist row and return its rowid.
fn insertPlaylist(conn: *storage.Conn, name: []const u8) !i64 {
    const c = @import("storage_c");
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT INTO playlists (name, url, added_at) VALUES (?, '', strftime('%s','now'))",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_TRANSIENT);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    return c.sqlite3_last_insert_rowid(conn.db);
}

/// Insert a track row and return its rowid.
fn insertTrack(conn: *storage.Conn, playlist_id: i64, url: []const u8) !i64 {
    const c = @import("storage_c");
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT INTO tracks (playlist_id, url, added_at) VALUES (?, ?, strftime('%s','now'))",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, playlist_id);
    _ = c.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), c.SQLITE_TRANSIENT);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    return c.sqlite3_last_insert_rowid(conn.db);
}

// ---------------------------------------------------------------------------
// Bookmark tests
// ---------------------------------------------------------------------------

test "storage.queries: addBookmark / isBookmarked / removeBookmark round-trip" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "test-pl");
    const tr = try insertTrack(&conn, pl, "https://example.com/a.mp3");

    try std.testing.expect(!(try q.isBookmarked(&conn, tr)));

    try q.addBookmark(&conn, tr);
    try std.testing.expect(try q.isBookmarked(&conn, tr));

    try q.removeBookmark(&conn, tr);
    try std.testing.expect(!(try q.isBookmarked(&conn, tr)));
}

test "storage.queries: addBookmark is idempotent (INSERT OR IGNORE)" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "test-pl2");
    const tr = try insertTrack(&conn, pl, "https://example.com/b.mp3");

    try q.addBookmark(&conn, tr);
    try q.addBookmark(&conn, tr); // second call must not error
    try std.testing.expect(try q.isBookmarked(&conn, tr));
}

test "storage.queries: removeBookmark on non-existent is a no-op" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // Should not return an error even if the row doesn't exist.
    try q.removeBookmark(&conn, 99999);
}

// ---------------------------------------------------------------------------
// Play / skip count tests
// ---------------------------------------------------------------------------

test "storage.queries: markTrackPlayed increments play_count and sets last_played_at" {
    const c = @import("storage_c");
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "pl-played");
    const tr = try insertTrack(&conn, pl, "https://example.com/c.mp3");

    try q.markTrackPlayed(&conn, tr);

    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db,
        "SELECT play_count, last_played_at FROM tracks WHERE id = ?",
        -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, tr);
    _ = c.sqlite3_step(stmt);

    const play_count = c.sqlite3_column_int64(stmt, 0);
    const last_played = c.sqlite3_column_int64(stmt, 1);

    try std.testing.expectEqual(@as(i64, 1), play_count);
    try std.testing.expect(last_played > 0);
}

test "storage.queries: markTrackSkipped increments skip_count" {
    const c = @import("storage_c");
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "pl-skip");
    const tr = try insertTrack(&conn, pl, "https://example.com/d.mp3");

    try q.markTrackSkipped(&conn, tr);
    try q.markTrackSkipped(&conn, tr);

    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db,
        "SELECT skip_count FROM tracks WHERE id = ?",
        -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, tr);
    _ = c.sqlite3_step(stmt);

    const skip_count = c.sqlite3_column_int64(stmt, 0);
    try std.testing.expectEqual(@as(i64, 2), skip_count);
}

// ---------------------------------------------------------------------------
// pickNextTrack tests
// ---------------------------------------------------------------------------

test "storage.queries: pickNextTrack returns null on empty DB" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const result = try q.pickNextTrack(&conn, arena.allocator(), &.{});
    try std.testing.expectEqual(@as(?q.TrackRow, null), result);
}

test "storage.queries: pickNextTrack never returns excluded tracks" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "pl-pick");
    const ta = try insertTrack(&conn, pl, "https://example.com/e1.mp3");
    const tb = try insertTrack(&conn, pl, "https://example.com/e2.mp3");
    const tc = try insertTrack(&conn, pl, "https://example.com/e3.mp3");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const exclude = [_]i64{ ta, tb };
    for (0..20) |_| {
        const row = try q.pickNextTrack(&conn, arena.allocator(), &exclude);
        try std.testing.expect(row != null);
        try std.testing.expectEqual(tc, row.?.id);
    }
}

test "storage.queries: pickNextTrack returns null when all tracks excluded" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const pl = try insertPlaylist(&conn, "pl-all-excl");
    const ta = try insertTrack(&conn, pl, "https://example.com/f1.mp3");
    const tb = try insertTrack(&conn, pl, "https://example.com/f2.mp3");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const exclude = [_]i64{ ta, tb };
    const result = try q.pickNextTrack(&conn, arena.allocator(), &exclude);
    try std.testing.expectEqual(@as(?q.TrackRow, null), result);
}

// ---------------------------------------------------------------------------
// Manifest hash tests
// ---------------------------------------------------------------------------

test "storage.queries: getManifestHash returns null when unset" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expectEqual(@as(?[]const u8, null), hash);
}

test "storage.queries: setManifestHash / getManifestHash round-trip" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try q.setManifestHash(&conn, "sha256:deadbeef");
    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("sha256:deadbeef", hash.?);
}

test "storage.queries: setManifestHash overwrites existing value" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try q.setManifestHash(&conn, "sha256:aaa");
    try q.setManifestHash(&conn, "sha256:bbb");

    const hash = try q.getManifestHash(&conn, arena.allocator());
    try std.testing.expectEqualStrings("sha256:bbb", hash.?);
}

// ---------------------------------------------------------------------------
// pickFirstTrack tests
// ---------------------------------------------------------------------------

test "storage.queries: pickFirstTrack returns null on empty DB" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const result = try q.pickFirstTrack(&conn, arena.allocator());
    try std.testing.expectEqual(@as(?q.TrackRow, null), result);
}

test "storage.queries: pickFirstTrack returns lowest id row with all fields" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Use SyncTx to insert tracks so we go through the same path as real usage.
    var tx = try q.beginSync(&conn);
    errdefer tx.rollback();
    try tx.appendTemp("pl-first", "https://example.com/first.mp3", "First Track", 180_000);
    try tx.appendTemp("pl-first", "https://example.com/second.mp3", "Second Track", 240_000);
    try tx.mergeAndCommit("sha256:test-first");

    const result = try q.pickFirstTrack(&conn, arena.allocator());
    try std.testing.expect(result != null);
    const row = result.?;

    // The lowest id row should be the first inserted track.
    try std.testing.expect(row.id > 0);
    try std.testing.expectEqualStrings("https://example.com/first.mp3", row.url);
    try std.testing.expect(row.display_name != null);
    try std.testing.expectEqualStrings("First Track", row.display_name.?);
    try std.testing.expectEqual(@as(?u32, 180_000), row.duration_ms);

    // Verify it is truly the lowest id by checking against the second track's id.
    // Insert a track with higher id; pickFirstTrack should still return the lowest.
    var tx2 = try q.beginSync(&conn);
    errdefer tx2.rollback();
    try tx2.appendTemp("pl-first", "https://example.com/first.mp3", "First Track", 180_000);
    try tx2.appendTemp("pl-first", "https://example.com/second.mp3", "Second Track", 240_000);
    try tx2.appendTemp("pl-first", "https://example.com/third.mp3", "Third Track", null);
    try tx2.mergeAndCommit("sha256:test-first-v2");

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const result2 = try q.pickFirstTrack(&conn, arena2.allocator());
    try std.testing.expect(result2 != null);
    // Still returns the same lowest-id row.
    try std.testing.expectEqual(row.id, result2.?.id);
    try std.testing.expectEqualStrings("https://example.com/first.mp3", result2.?.url);
}
