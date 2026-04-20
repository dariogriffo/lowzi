const std = @import("std");
const c_mod = @import("c.zig");
const c = c_mod.c;
const sqliteTransient = c_mod.sqliteTransient;
const Conn = @import("conn.zig").Conn;
const execSqlZ = @import("conn.zig").execSqlZ;
const execSql = @import("conn.zig").execSql;

/// A track row returned from the DB.  String fields are arena-allocated
/// slices; the caller must free the arena when done.
pub const TrackRow = struct {
    id: i64,
    playlist_id: i64,
    url: []const u8,
    display_name: ?[]const u8,
    duration_ms: ?u32,
};

// ---------------------------------------------------------------------------
// Track selection
// ---------------------------------------------------------------------------

/// Pick a random track that is not in `exclude`.
/// Returns null when the DB has no tracks (or all tracks are excluded).
/// All string fields in the returned row are allocated from `arena`.
pub fn pickNextTrack(conn: *Conn, arena: std.mem.Allocator, exclude: []const i64) !?TrackRow {
    // Build a query with a NOT IN clause sized to the exclude list.
    // We allocate the SQL string on the stack arena to avoid a second alloc layer.
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(arena);

    try sql_buf.appendSlice(arena,
        "SELECT id, playlist_id, url, display_name, duration_ms " ++
        "FROM tracks WHERE id NOT IN (");

    if (exclude.len == 0) {
        try sql_buf.appendSlice(arena, "SELECT -1");
    } else {
        for (exclude, 0..) |_, i| {
            if (i > 0) try sql_buf.append(arena, ',');
            try sql_buf.append(arena, '?');
        }
    }
    try sql_buf.appendSlice(arena, ") ORDER BY RANDOM() LIMIT 1");
    try sql_buf.append(arena, 0); // null terminator

    const sql_z: [:0]const u8 = sql_buf.items[0 .. sql_buf.items.len - 1 :0];

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(conn.db, sql_z.ptr, -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    // Bind exclude IDs (skip if we used the SELECT -1 placeholder).
    if (exclude.len > 0) {
        for (exclude, 0..) |id, i| {
            const bind_rc = c.sqlite3_bind_int64(stmt, @intCast(i + 1), id);
            if (bind_rc != c.SQLITE_OK) return error.SqliteBindFailed;
        }
    }

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc == c.SQLITE_DONE) return null; // no rows
    if (step_rc != c.SQLITE_ROW) return error.SqliteStepFailed;

    const id = c.sqlite3_column_int64(stmt, 0);
    const playlist_id = c.sqlite3_column_int64(stmt, 1);

    const url_raw = c.sqlite3_column_text(stmt, 2);
    const url_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
    const url = try arena.dupe(u8, url_raw[0..url_len]);

    var display_name: ?[]const u8 = null;
    if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL) {
        const dn_raw = c.sqlite3_column_text(stmt, 3);
        const dn_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        display_name = try arena.dupe(u8, dn_raw[0..dn_len]);
    }

    var duration_ms: ?u32 = null;
    if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL) {
        const v = c.sqlite3_column_int64(stmt, 4);
        if (v >= 0) duration_ms = @intCast(v);
    }

    return TrackRow{
        .id = id,
        .playlist_id = playlist_id,
        .url = url,
        .display_name = display_name,
        .duration_ms = duration_ms,
    };
}

/// Returns the row with the lowest `id` in `tracks`, or null if the table is
/// empty. Strings are arena-allocated.
pub fn pickFirstTrack(conn: *Conn, arena: std.mem.Allocator) !?TrackRow {
    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(conn.db,
        "SELECT id, playlist_id, url, display_name, duration_ms FROM tracks ORDER BY id ASC LIMIT 1",
        -1, &stmt, null);
    if (prep_rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc == c.SQLITE_DONE) return null; // no rows
    if (step_rc != c.SQLITE_ROW) return error.SqliteStepFailed;

    const id = c.sqlite3_column_int64(stmt, 0);
    const playlist_id = c.sqlite3_column_int64(stmt, 1);

    const url_raw = c.sqlite3_column_text(stmt, 2);
    const url_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
    const url = try arena.dupe(u8, url_raw[0..url_len]);

    var display_name: ?[]const u8 = null;
    if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL) {
        const dn_raw = c.sqlite3_column_text(stmt, 3);
        const dn_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        display_name = try arena.dupe(u8, dn_raw[0..dn_len]);
    }

    var duration_ms: ?u32 = null;
    if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL) {
        const v = c.sqlite3_column_int64(stmt, 4);
        if (v >= 0) duration_ms = @intCast(v);
    }

    return TrackRow{
        .id = id,
        .playlist_id = playlist_id,
        .url = url,
        .display_name = display_name,
        .duration_ms = duration_ms,
    };
}

// ---------------------------------------------------------------------------
// Play / skip accounting
// ---------------------------------------------------------------------------

pub fn markTrackPlayed(conn: *Conn, track_id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "UPDATE tracks SET play_count = play_count + 1, last_played_at = strftime('%s','now') WHERE id = ?",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn markTrackSkipped(conn: *Conn, track_id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "UPDATE tracks SET skip_count = skip_count + 1 WHERE id = ?",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

// ---------------------------------------------------------------------------
// Bookmarks
// ---------------------------------------------------------------------------

pub fn addBookmark(conn: *Conn, track_id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT OR IGNORE INTO bookmarks (track_id, added_at) VALUES (?, strftime('%s','now'))",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn removeBookmark(conn: *Conn, track_id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "DELETE FROM bookmarks WHERE track_id = ?",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn isBookmarked(conn: *Conn, track_id: i64) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "SELECT 1 FROM bookmarks WHERE track_id = ? LIMIT 1",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    const step_rc = c.sqlite3_step(stmt);
    return step_rc == c.SQLITE_ROW;
}

// ---------------------------------------------------------------------------
// Manifest hash (meta table)
// ---------------------------------------------------------------------------

pub fn getManifestHash(conn: *Conn, arena: std.mem.Allocator) !?[]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "SELECT value FROM meta WHERE key = 'manifest_hash' LIMIT 1",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc == c.SQLITE_DONE) return null;
    if (step_rc != c.SQLITE_ROW) return error.SqliteStepFailed;

    const raw = c.sqlite3_column_text(stmt, 0);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    return try arena.dupe(u8, raw[0..len]);
}

pub fn setManifestHash(conn: *Conn, hash: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(conn.db,
        "INSERT INTO meta (key, value) VALUES ('manifest_hash', ?) " ++
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, hash.ptr, @intCast(hash.len), sqliteTransient());
    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

// ---------------------------------------------------------------------------
// SyncTx — bulk catalog sync inside a single transaction
// ---------------------------------------------------------------------------

pub const SyncTx = struct {
    conn: *Conn,

    /// Append one row to the temp table.
    pub fn appendTemp(
        self: *SyncTx,
        playlist_name: []const u8,
        url: []const u8,
        display_name: ?[]const u8,
        duration_ms: ?u32,
    ) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.conn.db,
            "INSERT INTO temp_tracks (playlist_name, url, display_name, duration_ms) VALUES (?,?,?,?)",
            -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, playlist_name.ptr, @intCast(playlist_name.len), sqliteTransient());
        _ = c.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), sqliteTransient());
        if (display_name) |dn| {
            _ = c.sqlite3_bind_text(stmt, 3, dn.ptr, @intCast(dn.len), sqliteTransient());
        } else {
            _ = c.sqlite3_bind_null(stmt, 3);
        }
        if (duration_ms) |d| {
            _ = c.sqlite3_bind_int64(stmt, 4, @intCast(d));
        } else {
            _ = c.sqlite3_bind_null(stmt, 4);
        }
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// Diff temp_tracks against the main tables, apply the delta, update
    /// manifest_hash, and COMMIT.  Drops temp_tracks afterwards.
    pub fn mergeAndCommit(self: *SyncTx, hash: []const u8) !void {
        const db = self.conn.db;

        // 1. Insert any new playlists from temp_tracks.
        try execSqlZ(db,
            \\INSERT OR IGNORE INTO playlists (name, url, added_at)
            \\SELECT DISTINCT playlist_name, '', strftime('%s','now')
            \\FROM temp_tracks
        );

        // 2. Delete playlists not appearing in temp_tracks (cascades to tracks/bookmarks).
        try execSqlZ(db,
            \\DELETE FROM playlists
            \\WHERE name NOT IN (SELECT DISTINCT playlist_name FROM temp_tracks)
        );

        // 3. Insert new tracks (INSERT OR IGNORE guards the UNIQUE(playlist_id, url)).
        try execSqlZ(db,
            \\INSERT OR IGNORE INTO tracks (playlist_id, url, display_name, duration_ms, added_at)
            \\SELECT p.id, t.url, t.display_name, t.duration_ms, strftime('%s','now')
            \\FROM temp_tracks t
            \\JOIN playlists p ON p.name = t.playlist_name
        );

        // 4. Delete tracks not in temp_tracks (cascades to bookmarks).
        try execSqlZ(db,
            \\DELETE FROM tracks
            \\WHERE id NOT IN (
            \\  SELECT tr.id FROM tracks tr
            \\  JOIN playlists p ON p.id = tr.playlist_id
            \\  JOIN temp_tracks tt ON tt.playlist_name = p.name AND tt.url = tr.url
            \\)
        );

        // 5. Update manifest hash.
        try setManifestHash(self.conn, hash);

        // 6. COMMIT and clean up temp table.
        try execSqlZ(db, "COMMIT");
        _ = c.sqlite3_exec(db, "DROP TABLE IF EXISTS temp_tracks", null, null, null);
    }

    /// Roll back the transaction and clean up.
    pub fn rollback(self: *SyncTx) void {
        _ = c.sqlite3_exec(self.conn.db, "ROLLBACK", null, null, null);
        _ = c.sqlite3_exec(self.conn.db, "DROP TABLE IF EXISTS temp_tracks", null, null, null);
    }
};

/// Begin a sync transaction.  Creates a temp_tracks table for staging.
pub fn beginSync(conn: *Conn) !SyncTx {
    try execSqlZ(conn.db, "BEGIN");
    errdefer _ = c.sqlite3_exec(conn.db, "ROLLBACK", null, null, null);

    // Temp table lives for the duration of this transaction.
    try execSqlZ(conn.db,
        \\CREATE TEMP TABLE temp_tracks (
        \\  playlist_name TEXT,
        \\  url           TEXT,
        \\  display_name  TEXT,
        \\  duration_ms   INTEGER
        \\)
    );

    return SyncTx{ .conn = conn };
}
