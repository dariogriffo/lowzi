/// Tests for player/controller.zig
///
/// Uses in-memory SQLite + fake BodyFetchFn + fake audio channel interactions.
/// The controller runs as an io.async task; tests drive it via bus channels.
const std = @import("std");
const player = @import("player");
const storage = @import("storage");
const core = @import("core");

// ---------------------------------------------------------------------------
// Io lifecycle — one instance shared across the file.
// ---------------------------------------------------------------------------

test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn defaultCfg() core.Config {
    // Use buffer_size=2 so queue fills quickly in tests.
    var cfg = core.Config{};
    cfg.buffer_size = 2;
    return cfg;
}

/// Seed a DB with one playlist and N tracks.
fn seedDb(conn: *storage.Conn, n: usize) !void {
    const c = @import("storage_c");
    {
        const rc = c.sqlite3_exec(conn.db,
            "INSERT INTO playlists (id, name, url, added_at) VALUES (1, 'test', 'http://x.com/pl.m3u8', 0)",
            null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf,
            "INSERT INTO tracks (id, playlist_id, url, display_name, duration_ms, added_at) " ++
            "VALUES ({d}, 1, 'http://x.com/{d}.mp3', 'Track {d}', 180000, 0)",
            .{ i, i, i });
        const r = c.sqlite3_exec(conn.db, sql.ptr, null, null, null);
        if (r != c.SQLITE_OK) return error.SqliteExecFailed;
    }
}

/// Read the skip_count for a track.
fn getSkipCount(conn: *storage.Conn, track_id: i64) !i64 {
    const c = @import("storage_c");
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(conn.db, "SELECT skip_count FROM tracks WHERE id = ?", -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, track_id);
    _ = c.sqlite3_step(stmt);
    return c.sqlite3_column_int64(stmt, 0);
}

/// Fake BodyFetchFn: returns static MP3-like bytes for any URL.
fn fakeFetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = cfg;
    _ = url;
    return alloc.dupe(u8, "fake-mp3");
}

/// Fake BodyFetchFn: always fails.
fn alwaysFailFetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = alloc;
    _ = cfg;
    _ = url;
    return error.ConnectionLost;
}

/// Receive one event, blocking (for synchronisation in tests).
fn recvEvent(bus: *core.Bus, io: std.Io) !core.message.Event {
    return bus.player_to_ui.recv(io);
}

// ---------------------------------------------------------------------------
// Test 1: empty DB — network_stalled after sync_completed with no tracks
// ---------------------------------------------------------------------------

test "player.controller: empty DB after sync emits sync_completed to UI" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();
    // DB is empty — no tracks.

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, fakeFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Notify sync_completed (empty catalog).
    try bus.sync_to_player.send(io, .completed);

    // Controller should forward sync_completed to UI.
    const evt1 = try recvEvent(&bus, io);
    switch (evt1) {
        .sync_completed => {},
        else => return error.TestExpectedSyncCompleted,
    }

    // Quit cleanly.
    try bus.ui_to_player.send(io, .quit);
    // Consume the AudioCommand.quit and respond so the controller can drain.
    const audio_cmd = try bus.player_to_audio.recv(io);
    switch (audio_cmd) {
        .quit => {},
        else => {},
    }
    try bus.audio_to_player.send(io, .track_ended);
    _ = ctrl_task.await(io) catch {};
}

// ---------------------------------------------------------------------------
// Test 2: sync_completed with seeded DB — controller issues AudioCommand.play
// ---------------------------------------------------------------------------

test "player.controller: sync_completed triggers fill and AudioCommand.play" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();
    try seedDb(&conn, 3);

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, fakeFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Signal sync_completed — now the controller will fill the queue.
    try bus.sync_to_player.send(io, .completed);

    // Receive sync_completed forwarded to UI.
    const evt1 = try recvEvent(&bus, io);
    switch (evt1) {
        .sync_completed => {},
        else => return error.TestExpectedSyncCompleted,
    }

    // An AudioCommand.play should arrive when the first track is fetched.
    const audio_cmd = try bus.player_to_audio.recv(io);
    switch (audio_cmd) {
        .play => |t| {
            try std.testing.expect(t.bytes != null);
            // Simulate audio acknowledging the track started.
            try bus.audio_to_player.send(io, .{ .track_started = .{ .duration_ms = 180000 } });
        },
        else => return error.TestExpectedPlayCommand,
    }

    // Receive track_started event.
    const evt2 = try recvEvent(&bus, io);
    switch (evt2) {
        .track_started => {},
        else => return error.TestExpectedTrackStarted,
    }

    // Quit cleanly.
    try bus.ui_to_player.send(io, .quit);
    const qcmd = try bus.player_to_audio.recv(io);
    switch (qcmd) {
        .quit => {},
        else => {},
    }
    try bus.audio_to_player.send(io, .track_ended);
    _ = ctrl_task.await(io) catch {};
}

// ---------------------------------------------------------------------------
// Test 3: Command.skip — marks skipped, sends stop_current
// ---------------------------------------------------------------------------

test "player.controller: skip marks skip_count and stops current" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();
    try seedDb(&conn, 3);

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, fakeFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Signal sync_completed.
    try bus.sync_to_player.send(io, .completed);
    _ = try recvEvent(&bus, io); // consume sync_completed

    // Wait for play command.
    const play_cmd = try bus.player_to_audio.recv(io);
    const first_track_id: i64 = switch (play_cmd) {
        .play => |t| @intCast(t.id),
        else => return error.TestExpectedPlayCommand,
    };

    // Simulate track_started so the controller records current.
    try bus.audio_to_player.send(io, .{ .track_started = .{ .duration_ms = null } });
    _ = try recvEvent(&bus, io); // consume track_started event

    // Now skip.
    try bus.ui_to_player.send(io, .skip);

    // The controller should send stop_current to audio.
    const stop_cmd = try bus.player_to_audio.recv(io);
    switch (stop_cmd) {
        .stop_current => {},
        else => return error.TestExpectedStopCommand,
    }

    // Simulate audio acknowledging the track ended after stop.
    try bus.audio_to_player.send(io, .track_ended);

    // After track_ended the controller advances to the next track (track 2)
    // and sends AudioCommand.play.  Consume it so the channel doesn't fill up.
    const play2_cmd = try bus.player_to_audio.recv(io);
    _ = play2_cmd;

    // Quit cleanly.
    try bus.ui_to_player.send(io, .quit);
    const qcmd = try bus.player_to_audio.recv(io);
    switch (qcmd) {
        .quit => {},
        else => {},
    }
    try bus.audio_to_player.send(io, .track_ended);
    _ = ctrl_task.await(io) catch {};

    // Verify skip_count AFTER the controller has fully stopped to avoid
    // concurrent SQLite access (conn.db is accessed by both the controller
    // background thread and the test thread if checked earlier).
    const skip_count = try getSkipCount(&conn, first_track_id);
    try std.testing.expectEqual(@as(i64, 1), skip_count);
}

// ---------------------------------------------------------------------------
// Test 4: Command.bookmark toggles bookmark
// ---------------------------------------------------------------------------

test "player.controller: bookmark command toggles and emits events" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();
    try seedDb(&conn, 2);

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, fakeFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Signal sync_completed.
    try bus.sync_to_player.send(io, .completed);
    _ = try recvEvent(&bus, io); // consume sync_completed

    // Wait for play.
    const play_cmd = try bus.player_to_audio.recv(io);
    const track_id: i64 = switch (play_cmd) {
        .play => |t| @intCast(t.id),
        else => return error.TestExpectedPlayCommand,
    };
    try bus.audio_to_player.send(io, .{ .track_started = .{ .duration_ms = null } });
    _ = try recvEvent(&bus, io); // consume track_started event

    // First bookmark: should emit bookmark_added.
    try bus.ui_to_player.send(io, .bookmark);
    const evt1 = try recvEvent(&bus, io);
    switch (evt1) {
        .bookmark_added => {},
        else => return error.TestExpectedBookmarkAdded,
    }

    // Second bookmark: should emit bookmark_removed.
    try bus.ui_to_player.send(io, .bookmark);
    const evt2 = try recvEvent(&bus, io);
    switch (evt2) {
        .bookmark_removed => {},
        else => return error.TestExpectedBookmarkRemoved,
    }

    // Quit.
    try bus.ui_to_player.send(io, .quit);
    const qcmd = try bus.player_to_audio.recv(io);
    switch (qcmd) {
        .quit => {},
        else => {},
    }
    try bus.audio_to_player.send(io, .track_ended);
    _ = ctrl_task.await(io) catch {};

    // Verify bookmark state AFTER the controller has fully stopped to avoid
    // concurrent SQLite access on conn.db.
    try std.testing.expect(!(try storage.queries.isBookmarked(&conn, track_id)));
}

// ---------------------------------------------------------------------------
// Test 5: Command.quit — sends AudioCommand.quit and Event.quit
// ---------------------------------------------------------------------------

test "player.controller: quit sends audio quit and emits Event.quit" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, fakeFetch },
    );

    // Send quit immediately (before any sync).
    try bus.ui_to_player.send(io, .quit);

    // Controller sends AudioCommand.quit; we must respond to unblock its drain loop.
    const audio_cmd = try bus.player_to_audio.recv(io);
    switch (audio_cmd) {
        .quit => {},
        else => {},
    }
    // Simulate audio confirming it ended.
    try bus.audio_to_player.send(io, .track_ended);

    // Controller should now emit Event.quit and return.
    const quit_evt = try recvEvent(&bus, io);
    switch (quit_evt) {
        .quit => {},
        else => return error.TestExpectedQuitEvent,
    }

    try ctrl_task.await(io);
}

// ---------------------------------------------------------------------------
// Test 6: fetch failure — emits network_stalled
// ---------------------------------------------------------------------------

test "player.controller: fetch failure emits network_stalled" {
    const g = std.testing.allocator;
    const io = std.testing.io;

    var conn = try storage.Conn.openMemory(g);
    defer conn.close();
    try seedDb(&conn, 2);

    const cfg = defaultCfg();
    var bus = try core.Bus.init(g, cfg);
    defer bus.deinit(g);

    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, g, cfg, &bus, &conn, alwaysFailFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Signal sync_completed; controller will try to fill but fetch fails.
    try bus.sync_to_player.send(io, .completed);

    // We should receive sync_completed forwarded to UI.
    const evt1 = try recvEvent(&bus, io);
    switch (evt1) {
        .sync_completed => {},
        else => return error.TestExpectedSyncCompleted,
    }

    // Then network_stalled.
    const evt2 = try recvEvent(&bus, io);
    switch (evt2) {
        .network_stalled => {},
        else => return error.TestExpectedNetworkStalled,
    }

    // No AudioCommand.play should have been sent.
    const maybe_play = bus.player_to_audio.tryRecv(io);
    try std.testing.expect(maybe_play == null);

    // Quit.
    try bus.ui_to_player.send(io, .quit);
    const qcmd = try bus.player_to_audio.recv(io);
    switch (qcmd) {
        .quit => {},
        else => {},
    }
    try bus.audio_to_player.send(io, .track_ended);
    _ = ctrl_task.await(io) catch {};
}
