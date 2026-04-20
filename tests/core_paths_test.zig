/// Tests for core.paths: XDG-aware path resolution.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

// Use POSIX setenv/unsetenv for test setup on Linux/macOS.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ---------------------------------------------------------------------------
// dataDir tests
// ---------------------------------------------------------------------------

test "core.paths: dataDir respects XDG_DATA_HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = setenv("XDG_DATA_HOME", "/tmp/test_xdg_data", 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const dir = try core.paths.dataDir(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/test_xdg_data/lowzi", dir);
}

test "core.paths: dataDir falls back to ~/.local/share/lowzi on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    // Make sure XDG_DATA_HOME is unset so we exercise the fallback.
    _ = unsetenv("XDG_DATA_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return error.SkipZigTest, 0);

    const dir = try core.paths.dataDir(arena.allocator());

    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/.local/share/lowzi", .{home});
    try std.testing.expectEqualStrings(expected, dir);
}

// ---------------------------------------------------------------------------
// stateDir tests
// ---------------------------------------------------------------------------

test "core.paths: stateDir respects XDG_STATE_HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = setenv("XDG_STATE_HOME", "/tmp/test_xdg_state", 1);
    defer _ = unsetenv("XDG_STATE_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const dir = try core.paths.stateDir(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/test_xdg_state/lowzi", dir);
}

test "core.paths: stateDir falls back to ~/.local/state/lowzi on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = unsetenv("XDG_STATE_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return error.SkipZigTest, 0);

    const dir = try core.paths.stateDir(arena.allocator());

    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/.local/state/lowzi", .{home});
    try std.testing.expectEqualStrings(expected, dir);
}

// ---------------------------------------------------------------------------
// Derived-path helpers
// ---------------------------------------------------------------------------

test "core.paths: bookmarksPath appends bookmarks.txt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = setenv("XDG_DATA_HOME", "/tmp/bm_test", 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const path = try core.paths.bookmarksPath(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/bm_test/lowzi/bookmarks.txt", path);
}

test "core.paths: listsDir appends lists subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = setenv("XDG_DATA_HOME", "/tmp/lists_test", 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const path = try core.paths.listsDir(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/lists_test/lowzi/lists", path);
}

test "core.paths: logPath appends log file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    _ = setenv("XDG_STATE_HOME", "/tmp/log_test", 1);
    defer _ = unsetenv("XDG_STATE_HOME");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const path = try core.paths.logPath(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/log_test/lowzi/log", path);
}
