/// main.zig — lowzi entry point.
///
/// Wires all modules together:
///   1. Parse CLI args.
///   2. Init logging.
///   3. Open the SQLite DB and run migrations.
///   4. Build the inter-task bus.
///   5. Install OS signal handlers (SIGINT/SIGTERM → Command.quit).
///   6. Spawn the four long-running tasks.
///   7. Await them in dependency order; cancel sync on shutdown.
///
/// See SPECIFICATION §4.7 and AGENTS.md "Brief: platform/signals + main (Step 8)".
const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const source = @import("source");
const audio = @import("audio");
const player = @import("player");
const headless = @import("headless");
const platform = @import("platform");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // 1. Parse CLI arguments (skip argv[0] which is the program name).
    // Args.toSlice returns []const [:0]const u8; we collect into an ArrayList
    // of plain []const u8 slices so cli.parse sees the type it expects.
    const raw_args = try init.minimal.args.toSlice(arena);
    // raw_args[0] is the program name — skip it.
    const argv: []const []const u8 = if (raw_args.len > 1) blk: {
        var list: std.ArrayList([]const u8) = .empty;
        for (raw_args[1..]) |a| try list.append(arena, a);
        break :blk list.items;
    } else &.{};

    const cfg = try core.cli.parse(arena, argv);
    try core.log.init(gpa, io, cfg);

    // 2. Open the DB; ensure() runs migrations.
    var conn = try storage.Conn.open(gpa, io, cfg);
    defer conn.close();

    // 3. Build the bus (channels for inter-task signaling).
    var bus = try core.Bus.init(gpa, cfg);
    defer bus.deinit(gpa);

    // 4. Install signal handlers (SIGINT/SIGTERM → Command.quit).
    var sigwatcher = try platform.signals.install(io, gpa, &bus);
    defer sigwatcher.deinit(io);

    // 5. Spawn the four long-running tasks.
    //    Defer-cancel covers panics and early returns; the cancel is a no-op if
    //    the task has already returned normally.
    var front_task = io.async(headless.run, .{ io, gpa, cfg, &bus });
    defer _ = front_task.cancel(io) catch {};

    var player_task = io.async(player.controller.run, .{ io, gpa, cfg, &bus, &conn });
    defer _ = player_task.cancel(io) catch {};

    var audio_task = io.async(audio.pipeline.run, .{ io, gpa, cfg, &bus });
    defer _ = audio_task.cancel(io) catch {};

    var sync_task = io.async(source.sync.run, .{ io, gpa, cfg, &conn, &bus });
    defer _ = sync_task.cancel(io) catch {};

    // 6. Await each task in dependency order.
    //    - front exits first (user quit or stdin EOF).
    //    - player drains and exits after receiving Command.quit.
    //    - audio drains and exits after receiving AudioCommand.quit.
    //    - sync is best-effort: cancel and ignore error.Canceled.
    try front_task.await(io);
    try player_task.await(io);
    try audio_task.await(io);
    // Sync is best-effort. It has already emitted Event.sync_failed on the bus
    // for any error it encountered, so we do not propagate sync errors to the
    // process exit code — they are expected (e.g., placeholder URL unreachable
    // on first run, or network unavailable). Only propagate Canceled as a clean
    // shutdown signal if needed, but since sync already handles its own cleanup,
    // we drop all sync errors here.
    _ = sync_task.await(io) catch {};
}
