const std = @import("std");
const core = @import("core");
const c = @import("c.zig").c;
const schema = @import("schema.zig");

/// A single SQLite connection.  One process, one Conn — no other module
/// should open the DB or hold a *c.sqlite3 pointer directly.
pub const Conn = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,

    /// Open (or create) the lowzi database at <data_dir>/lowzi.db.
    /// Runs schema migrations to bring it up to CURRENT_VERSION.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, cfg: core.Config) !Conn {
        _ = cfg;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const data_dir = try core.paths.dataDir(arena);

        // Ensure the directory exists. In Zig 0.16, std.fs.makeDirAbsolute is
        // gone; use std.Io.Dir.createDirAbsolute instead.
        std.Io.Dir.createDirAbsolute(io, data_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const db_path = try std.fs.path.joinZ(arena, &.{ data_dir, "lowzi.db" });

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var conn = Conn{
            .db = db.?,
            .gpa = gpa,
        };

        // Enable foreign keys per-connection — this PRAGMA is not persisted in
        // the DB file; it must be set every time a connection opens.
        try execSqlZ(conn.db, "PRAGMA foreign_keys = ON");
        try schema.ensure(&conn);
        return conn;
    }

    /// Open an in-memory database — used exclusively by tests.
    pub fn openMemory(gpa: std.mem.Allocator) !Conn {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(":memory:", &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var conn = Conn{
            .db = db.?,
            .gpa = gpa,
        };

        // Enable foreign keys per-connection.
        try execSqlZ(conn.db, "PRAGMA foreign_keys = ON");
        try schema.ensure(&conn);
        return conn;
    }

    /// Close the database connection.
    pub fn close(self: *Conn) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Execute `f(ctx, db)` inside a BEGIN/COMMIT transaction.
    /// On any error the transaction is rolled back before returning.
    pub fn withTx(self: *Conn, ctx: anytype, comptime f: anytype) !void {
        try execSql(self.db, "BEGIN");
        errdefer _ = c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        try f(ctx, self.db);
        try execSql(self.db, "COMMIT");
    }
};

/// Execute a single SQL statement with no result rows.
pub fn execSql(db: *c.sqlite3, sql: []const u8) !void {
    // sqlite3_exec requires null termination.
    var buf: [4096]u8 = undefined;
    if (sql.len >= buf.len) return error.SqlTooLong;
    @memcpy(buf[0..sql.len], sql);
    buf[sql.len] = 0;
    const rc = c.sqlite3_exec(db, buf[0..sql.len :0].ptr, null, null, null);
    if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
}

/// Execute a null-terminated SQL literal directly (comptime strings).
pub fn execSqlZ(db: *c.sqlite3, comptime sql: [:0]const u8) !void {
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);
    if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
}
