const std = @import("std");
const storage = @import("storage");

// ---------------------------------------------------------------------------
// storage.schema tests
// ---------------------------------------------------------------------------

test "storage.schema: ensure creates schema on fresh DB" {
    const gpa = std.testing.allocator;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // schema.ensure is called inside openMemory; verify version is 1.
    const ver = try storage.schema.getUserVersion(conn.db);
    try std.testing.expectEqual(@as(i32, 1), ver);
}

test "storage.schema: ensure is idempotent" {
    const gpa = std.testing.allocator;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    // Call ensure again — must not error or change version.
    try storage.schema.ensure(&conn);
    const ver = try storage.schema.getUserVersion(conn.db);
    try std.testing.expectEqual(@as(i32, 1), ver);
}

test "storage.schema: PRAGMA user_version is 1 after migration" {
    const gpa = std.testing.allocator;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const ver = try storage.schema.getUserVersion(conn.db);
    try std.testing.expectEqual(storage.schema.CURRENT_VERSION, ver);
}

test "storage.schema: all four tables exist" {
    const std_testing = std.testing;
    const gpa = std_testing.allocator;

    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();

    const c = @import("storage_c");
    const tables = [_][]const u8{ "playlists", "tracks", "bookmarks", "meta" };

    for (tables) |tbl| {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'", .{tbl});

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null);
        try std_testing.expectEqual(@as(c_int, c.SQLITE_OK), rc);
        defer _ = c.sqlite3_finalize(stmt);

        const step_rc = c.sqlite3_step(stmt);
        try std_testing.expectEqual(@as(c_int, c.SQLITE_ROW), step_rc);
    }
}
