/// XDG-aware path resolution for lowzi data and state directories.
///
/// Platform rules (§4.1 of the spec):
///   Linux:   $XDG_DATA_HOME/lowzi  or  ~/.local/share/lowzi
///            $XDG_STATE_HOME/lowzi or  ~/.local/state/lowzi
///   macOS:   ~/Library/Application Support/lowzi (data)
///            ~/Library/Application Support/lowzi (state — no separate concept)
///   Windows: %APPDATA%\lowzi  (data + state)
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");

/// Return the lowzi data directory, creating the path string in `arena`.
/// Honors $XDG_DATA_HOME on Linux.
pub fn dataDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => linuxDataDir(arena),
        .macos => macosDataDir(arena),
        .windows => windowsDataDir(arena),
        else => linuxDataDir(arena), // best-effort fallback
    };
}

/// Return the lowzi state directory (for logs, etc.), in `arena`.
/// Honors $XDG_STATE_HOME on Linux.
pub fn stateDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => linuxStateDir(arena),
        .macos => macosDataDir(arena), // macOS uses same dir for state
        .windows => windowsDataDir(arena),
        else => linuxStateDir(arena),
    };
}

/// Return the bookmarks file path: <data_dir>/bookmarks.txt
pub fn bookmarksPath(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    const base = try dataDir(arena);
    return std.fs.path.join(arena, &.{ base, "bookmarks.txt" });
}

/// Return the named-lists directory: <data_dir>/lists
pub fn listsDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    const base = try dataDir(arena);
    return std.fs.path.join(arena, &.{ base, "lists" });
}

/// Return the debug log path: <state_dir>/log
pub fn logPath(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    const base = try stateDir(arena);
    return std.fs.path.join(arena, &.{ base, "log" });
}

// ---------------------------------------------------------------------------
// Platform implementations
// ---------------------------------------------------------------------------

fn linuxDataDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    if (getEnv("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(arena, &.{ xdg, "lowzi" });
    }
    const home = getEnv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(arena, &.{ home, ".local", "share", "lowzi" });
}

fn linuxStateDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    if (getEnv("XDG_STATE_HOME")) |xdg| {
        return std.fs.path.join(arena, &.{ xdg, "lowzi" });
    }
    const home = getEnv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(arena, &.{ home, ".local", "state", "lowzi" });
}

fn macosDataDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    const home = getEnv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(arena, &.{ home, "Library", "Application Support", "lowzi" });
}

fn windowsDataDir(arena: Allocator) (errors.PathError || Allocator.Error)![]const u8 {
    const appdata = getEnv("APPDATA") orelse return error.NoHomeDir;
    return std.fs.path.join(arena, &.{ appdata, "lowzi" });
}

/// Thin wrapper around std.c.getenv that returns a Zig slice.
/// Safe on Linux/macOS since we link libc.
fn getEnv(key: []const u8) ?[]const u8 {
    // Null-terminate the key on the stack for the C call.
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const result = std.c.getenv(@ptrCast(buf[0..key.len :0]));
    if (result) |r| return std.mem.sliceTo(r, 0);
    return null;
}
