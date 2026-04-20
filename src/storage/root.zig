/// storage — SQLite catalog for lowzi.
///
/// This is the only module that opens the database or holds a *c.sqlite3
/// pointer.  All other modules query through this public API.
pub const Conn = @import("conn.zig").Conn;
pub const queries = @import("queries.zig");
pub const schema = @import("schema.zig");

/// Re-exported `SQLITE_TRANSIENT` sentinel — see src/storage/c.zig for the
/// reason this is a fn rather than the translate-c constant.
pub const sqliteTransient = @import("c.zig").sqliteTransient;
