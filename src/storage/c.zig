/// Re-export of the translate-c'd sqlite3 amalgamation.
/// Other storage sub-modules import this file to get sqlite3 symbols.
/// No @cImport — that is deprecated in Zig 0.16 (AGENTS.md §0.1).
pub const c = @import("storage_c");
