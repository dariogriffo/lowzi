/// Tests for core.cli: argument parsing.
const std = @import("std");
const core = @import("core");

// ---------------------------------------------------------------------------
// Boolean flags (long form)
// ---------------------------------------------------------------------------

test "core.cli: --alternate sets alternate=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--alternate"});
    try std.testing.expect(cfg.alternate);
}

test "core.cli: --minimalist sets minimalist=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--minimalist"});
    try std.testing.expect(cfg.minimalist);
}

test "core.cli: --borderless sets borderless=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--borderless"});
    try std.testing.expect(cfg.borderless);
}

test "core.cli: --clock sets clock=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--clock"});
    try std.testing.expect(cfg.clock);
}

test "core.cli: --paused sets paused=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--paused"});
    try std.testing.expect(cfg.paused);
}

test "core.cli: --debug sets debug=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--debug"});
    try std.testing.expect(cfg.debug);
}

// ---------------------------------------------------------------------------
// Short flag (single)
// ---------------------------------------------------------------------------

test "core.cli: -a sets alternate=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-a"});
    try std.testing.expect(cfg.alternate);
}

test "core.cli: -m sets minimalist=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-m"});
    try std.testing.expect(cfg.minimalist);
}

test "core.cli: -b sets borderless=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-b"});
    try std.testing.expect(cfg.borderless);
}

test "core.cli: -d sets debug=true" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-d"});
    try std.testing.expect(cfg.debug);
}

// ---------------------------------------------------------------------------
// Short flag combining
// ---------------------------------------------------------------------------

test "core.cli: -amb sets alternate+minimalist+borderless" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-amb"});
    try std.testing.expect(cfg.alternate);
    try std.testing.expect(cfg.minimalist);
    try std.testing.expect(cfg.borderless);
}

test "core.cli: -mbc sets minimalist+borderless+clock" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"-mbc"});
    try std.testing.expect(cfg.minimalist);
    try std.testing.expect(cfg.borderless);
    try std.testing.expect(cfg.clock);
}

// ---------------------------------------------------------------------------
// Value flags: --name value and --name=value
// ---------------------------------------------------------------------------

test "core.cli: --fps 24 sets fps=24" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "--fps", "24" });
    try std.testing.expectEqual(@as(u32, 24), cfg.fps);
}

test "core.cli: --fps=30 sets fps=30" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--fps=30"});
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
}

test "core.cli: --width 5 sets width=5" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "--width", "5" });
    try std.testing.expectEqual(@as(u32, 5), cfg.width);
}

test "core.cli: --width=0 sets width=0" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--width=0"});
    try std.testing.expectEqual(@as(u32, 0), cfg.width);
}

test "core.cli: --buffer-size 10 sets buffer_size=10" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "--buffer-size", "10" });
    try std.testing.expectEqual(@as(u32, 10), cfg.buffer_size);
}

test "core.cli: --timeout 5000 sets timeout_ms=5000" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "--timeout", "5000" });
    try std.testing.expectEqual(@as(u32, 5000), cfg.timeout_ms);
}

test "core.cli: --track-list mylist sets track_list" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "--track-list", "mylist" });
    try std.testing.expectEqualStrings("mylist", cfg.track_list.?);
}

test "core.cli: --track-list=path/to/list sets track_list" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{"--track-list=path/to/list"});
    try std.testing.expectEqualStrings("path/to/list", cfg.track_list.?);
}

// ---------------------------------------------------------------------------
// Short value flags
// ---------------------------------------------------------------------------

test "core.cli: -f 15 sets fps=15" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "-f", "15" });
    try std.testing.expectEqual(@as(u32, 15), cfg.fps);
}

test "core.cli: -s 3 sets buffer_size=3" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{ "-s", "3" });
    try std.testing.expectEqual(@as(u32, 3), cfg.buffer_size);
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

test "core.cli: empty argv returns defaults" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = try core.cli.parse(arena.allocator(), &.{});
    try std.testing.expect(!cfg.alternate);
    try std.testing.expect(!cfg.minimalist);
    try std.testing.expect(!cfg.borderless);
    try std.testing.expect(!cfg.clock);
    try std.testing.expect(!cfg.paused);
    try std.testing.expect(!cfg.debug);
    try std.testing.expectEqual(@as(u32, 12), cfg.fps);
    try std.testing.expectEqual(@as(u32, 3), cfg.width);
    try std.testing.expectEqual(@as(u32, 5), cfg.buffer_size);
    try std.testing.expectEqual(@as(u32, 3000), cfg.timeout_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.track_list);
}

// ---------------------------------------------------------------------------
// Error cases: InvalidValue
// ---------------------------------------------------------------------------

test "core.cli: --fps abc returns InvalidValue" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = core.cli.parse(arena.allocator(), &.{ "--fps", "abc" });
    try std.testing.expectError(error.InvalidValue, result);
}

test "core.cli: --width notanumber returns InvalidValue" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = core.cli.parse(arena.allocator(), &.{ "--width", "notanumber" });
    try std.testing.expectError(error.InvalidValue, result);
}
