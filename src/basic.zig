/// basic.zig — lowzi-basic entry point.
///
/// Minimal player: opens the SQLite catalog, plays the first track in the
/// `tracks` table, exits on track-end or Ctrl-C. No UI, no skip, no sync.
/// Catalog must already be populated (run `lowzi` first to sync, or seed
/// the DB manually).
const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const source = @import("source");
const audio = @import("audio");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // 1. Parse args; reuse core.cli.parse and pull fields we need from cfg.
    const raw_args = try init.minimal.args.toSlice(arena);
    const argv: []const []const u8 = if (raw_args.len > 1) blk: {
        var list: std.ArrayList([]const u8) = .empty;
        for (raw_args[1..]) |a| try list.append(arena, a);
        break :blk list.items;
    } else &.{};
    const cfg = try core.cli.parse(arena, argv);
    try core.log.init(gpa, io, cfg);

    // 2. Open DB; call ensure() defensively — idempotent if lowzi already ran.
    var conn = try storage.Conn.open(gpa, io, cfg);
    defer conn.close();
    try storage.schema.ensure(&conn);

    // 3. Pick the first track. Empty catalog → friendly error + exit.
    const maybe_row = try storage.queries.pickFirstTrack(&conn, arena);
    const row = maybe_row orelse {
        const stderr = std.Io.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writerStreaming(io, &buf);
        try w.interface.writeAll(
            "lowzi-basic: catalog is empty. Run `lowzi` first to sync, or " ++
                "manually seed the database.\n",
        );
        try w.interface.flush();
        return;
    };

    // 4. Download the track bytes; print a "playing X" line so the user sees something.
    {
        const stdout = std.Io.File.stdout();
        var buf: [512]u8 = undefined;
        var w = stdout.writerStreaming(io, &buf);
        const name = row.display_name orelse row.url;
        try w.interface.print("lowzi-basic: playing {s}\n", .{name});
        try w.interface.flush();
    }
    const body = try source.downloader.fetch(io, gpa, cfg, row.url);
    defer gpa.free(body);

    // 5. Stand up the bus + spawn the real audio pipeline task.
    var bus = try core.Bus.init(gpa, cfg);
    defer bus.deinit(gpa);

    var audio_task = io.async(audio.pipeline.runReal, .{ io, gpa, cfg, &bus });
    defer _ = audio_task.cancel(io) catch {};

    // 6. Build the Track and send AudioCommand.play.
    //    bytes is gpa.free'd above; owned_strings stays false (strings live in arena).
    const track = core.Track{
        .id = @intCast(row.id),
        .display_name = row.display_name orelse row.url,
        .source_uri = row.url,
        .duration_hint = row.duration_ms,
        .bytes = body,
        .owned_strings = false,
    };
    try bus.player_to_audio.send(io, .{ .play = track });

    // 7. Wait for the track_ended event. Ignore other events.
    while (true) {
        const evt = bus.audio_to_player.recv(io) catch |err| switch (err) {
            error.Closed, error.Canceled => break,
        };
        switch (evt) {
            .track_ended => break,
            .decode_failed, .device_lost => break,
            else => {},
        }
    }

    // 8. Tell audio to quit, await, exit.
    try bus.player_to_audio.send(io, .quit);
    try audio_task.await(io);
}
