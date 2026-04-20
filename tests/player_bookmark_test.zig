/// Tests for player/bookmark.zig
const std = @import("std");
const player = @import("player");
const storage = @import("storage");

const gpa = std.testing.allocator;

// ---------------------------------------------------------------------------
// Seed a minimal DB (one playlist, one track).
// ---------------------------------------------------------------------------

fn seedDb(conn: *storage.Conn) !void {
    const c = @import("storage_c");
    {
        const rc = c.sqlite3_exec(conn.db,
            "INSERT INTO playlists (id, name, url, added_at) VALUES (1, 'p', 'http://x.com/p.m3u8', 0)",
            null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }
    {
        const rc = c.sqlite3_exec(conn.db,
            "INSERT INTO tracks (id, playlist_id, url, display_name, duration_ms, added_at) VALUES (1, 1, 'http://x.com/t.mp3', 'Track 1', null, 0)",
            null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }
}

// ---------------------------------------------------------------------------
// toggle
// ---------------------------------------------------------------------------

test "player.bookmark: toggle adds then removes bookmark" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    // Initially not bookmarked.
    try std.testing.expect(!(try storage.queries.isBookmarked(&conn, 1)));

    // First toggle: should bookmark.
    const after_first = try player.bookmark.toggle(&conn, 1);
    try std.testing.expect(after_first); // now bookmarked
    try std.testing.expect(try storage.queries.isBookmarked(&conn, 1));

    // Second toggle: should remove.
    const after_second = try player.bookmark.toggle(&conn, 1);
    try std.testing.expect(!after_second); // now unbookmarked
    try std.testing.expect(!(try storage.queries.isBookmarked(&conn, 1)));
}

test "player.bookmark: toggle is idempotent when called many times" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    // Should alternate: true, false, true, false, ...
    var expected: bool = true;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const result = try player.bookmark.toggle(&conn, 1);
        try std.testing.expectEqual(expected, result);
        expected = !expected;
    }
}

test "player.bookmark: toggle on non-existent track returns error" {
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    // FK constraint: track_id 999 does not exist; addBookmark should fail.
    try std.testing.expectError(
        error.SqliteStepFailed,
        player.bookmark.toggle(&conn, 999),
    );
}
