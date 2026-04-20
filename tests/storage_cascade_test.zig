const std = @import("std");
const storage = @import("storage");
const c = @import("storage_c");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn insertPlaylist(conn: *storage.Conn, name: []const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT INTO playlists (name, url, added_at) VALUES (?, '', strftime('%s','now'))",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), storage.sqliteTransient());
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    return c.sqlite3_last_insert_rowid(conn.db);
}

fn insertTrack(conn: *storage.Conn, playlist_id: i64, url: []const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT INTO tracks (playlist_id, url, added_at) VALUES (?, ?, strftime('%s','now'))",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, playlist_id);
    _ = c.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), storage.sqliteTransient());
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    return c.sqlite3_last_insert_rowid(conn.db);
}

fn countRows(conn: *storage.Conn, table: []const u8) !i64 {
    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf, "SELECT COUNT(*) FROM {s}", .{table});
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_step(stmt);
    return c.sqlite3_column_int64(stmt, 0);
}

fn rowExistsById(conn: *storage.Conn, table: []const u8, id: i64) !bool {
    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf,
        "SELECT 1 FROM {s} WHERE id = ? LIMIT 1", .{table});
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn bookmarkExistsForTrack(conn: *storage.Conn, track_id: i64) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db,
        "SELECT 1 FROM bookmarks WHERE track_id = ? LIMIT 1",
        -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn deletePlaylist(conn: *storage.Conn, id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "DELETE FROM playlists WHERE id = ?", -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn deleteTrack(conn: *storage.Conn, id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "DELETE FROM tracks WHERE id = ?", -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

// ---------------------------------------------------------------------------
// Cascade tests
// ---------------------------------------------------------------------------

test "storage.cascade: delete playlist cascades to tracks and bookmarks" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // foreign_keys must be ON (set by schema migration) — verify with a pragma.
    // We rely on the schema having set it; SQLite resets it per-connection.
    // Reenable to be safe for this test connection.
    // foreign_keys = ON is set by Conn.openMemory; no need to repeat here.
    const pl = try insertPlaylist(&conn, "cascade-pl");
    const tr = try insertTrack(&conn, pl, "https://example.com/g.mp3");
    try storage.queries.addBookmark(&conn, tr);

    // Verify everything is there.
    try std.testing.expect(try rowExistsById(&conn, "playlists", pl));
    try std.testing.expect(try rowExistsById(&conn, "tracks", tr));
    try std.testing.expect(try bookmarkExistsForTrack(&conn, tr));

    // Delete the playlist — should cascade.
    try deletePlaylist(&conn, pl);

    try std.testing.expect(!(try rowExistsById(&conn, "playlists", pl)));
    try std.testing.expect(!(try rowExistsById(&conn, "tracks", tr)));
    try std.testing.expect(!(try bookmarkExistsForTrack(&conn, tr)));
}

test "storage.cascade: delete one track cascades only its bookmark" {
    const gpa = std.testing.allocator;
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // foreign_keys = ON is set by Conn.openMemory; no need to repeat here.
    const pl = try insertPlaylist(&conn, "partial-cascade-pl");
    const ta = try insertTrack(&conn, pl, "https://example.com/h1.mp3");
    const tb = try insertTrack(&conn, pl, "https://example.com/h2.mp3");

    try storage.queries.addBookmark(&conn, ta);
    try storage.queries.addBookmark(&conn, tb);

    // Delete track A.
    try deleteTrack(&conn, ta);

    // Track A and its bookmark are gone; track B and its bookmark remain.
    try std.testing.expect(!(try rowExistsById(&conn, "tracks", ta)));
    try std.testing.expect(!(try bookmarkExistsForTrack(&conn, ta)));
    try std.testing.expect(try rowExistsById(&conn, "tracks", tb));
    try std.testing.expect(try bookmarkExistsForTrack(&conn, tb));

    // Playlist still exists.
    try std.testing.expect(try rowExistsById(&conn, "playlists", pl));

    // Only 1 bookmark left.
    try std.testing.expectEqual(@as(i64, 1), try countRows(&conn, "bookmarks"));
}
