const std = @import("std");
const c = @import("c.zig").c;
const Conn = @import("conn.zig").Conn;
const execSqlZ = @import("conn.zig").execSqlZ;

pub const CURRENT_VERSION: i32 = 1;

/// Ensure the database schema is at CURRENT_VERSION, running any needed
/// migrations.  Idempotent: safe to call on an already-migrated DB.
pub fn ensure(conn: *Conn) !void {
    const version = try getUserVersion(conn.db);
    if (version == CURRENT_VERSION) return;
    if (version == 0) {
        try migrate_0_to_1(conn.db);
        return;
    }
    // Future: add more migration cases here as version increases.
    return error.UnknownSchemaVersion;
}

/// Returns the current PRAGMA user_version.
pub fn getUserVersion(db: *c.sqlite3) !i32 {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_ROW) return error.SqliteStepFailed;

    return c.sqlite3_column_int(stmt, 0);
}

/// Apply the v1 DDL from SPECIFICATION §4.5.0.
/// Runs inside a single transaction so a partial failure leaves the DB clean.
fn migrate_0_to_1(db: *c.sqlite3) !void {
    try execSqlZ(db, "BEGIN");
    errdefer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);

    try execSqlZ(db, "PRAGMA foreign_keys = ON");

    try execSqlZ(db,
        \\CREATE TABLE playlists (
        \\  id          INTEGER PRIMARY KEY,
        \\  name        TEXT    NOT NULL UNIQUE,
        \\  url         TEXT    NOT NULL,
        \\  added_at    INTEGER NOT NULL,
        \\  last_synced INTEGER
        \\)
    );

    try execSqlZ(db,
        \\CREATE TABLE tracks (
        \\  id             INTEGER PRIMARY KEY,
        \\  playlist_id    INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        \\  url            TEXT    NOT NULL,
        \\  display_name   TEXT,
        \\  duration_ms    INTEGER,
        \\  added_at       INTEGER NOT NULL,
        \\  last_played_at INTEGER,
        \\  play_count     INTEGER NOT NULL DEFAULT 0,
        \\  skip_count     INTEGER NOT NULL DEFAULT 0,
        \\  UNIQUE (playlist_id, url)
        \\)
    );

    try execSqlZ(db,
        \\CREATE INDEX tracks_by_playlist ON tracks (playlist_id)
    );

    try execSqlZ(db,
        \\CREATE TABLE bookmarks (
        \\  id       INTEGER PRIMARY KEY,
        \\  track_id INTEGER NOT NULL UNIQUE REFERENCES tracks(id) ON DELETE CASCADE,
        \\  added_at INTEGER NOT NULL
        \\)
    );

    try execSqlZ(db,
        \\CREATE TABLE meta (
        \\  key   TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\)
    );

    // Set user_version inside the transaction so the migration is atomic.
    try execSqlZ(db, "PRAGMA user_version = 1");

    try execSqlZ(db, "COMMIT");
}
