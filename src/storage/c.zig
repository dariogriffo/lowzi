/// Re-export of the translate-c'd sqlite3 amalgamation.
/// Other storage sub-modules import this file to get sqlite3 symbols.
/// No @cImport — that is deprecated in Zig 0.16 (AGENTS.md §0.1).
pub const c = @import("storage_c");

/// SQLite's `SQLITE_TRANSIENT` sentinel — `(sqlite3_destructor_type)-1`.
///
/// translate-c emits this as a comptime int-to-fn-pointer cast which fails
/// on aarch64-macos because the resulting address (0xFFFF…FFFF) does not
/// meet the 4-byte alignment Zig enforces for typed function pointers at
/// comptime.  We compute the same sentinel at runtime instead, with safety
/// disabled so the equivalent runtime alignment check is also skipped.
///
/// SQLite never dereferences this value — it is a pointer-sized sentinel
/// used as a sentinel only.  Returning it through a fn keeps Zig from
/// folding the cast back into comptime.
pub fn sqliteTransient() c.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var addr: usize = @bitCast(@as(isize, -1));
    _ = &addr;
    return @ptrFromInt(addr);
}
