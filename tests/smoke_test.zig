/// Smoke test — gated by -Dsmoke=true.
///
/// Boots the full audio path with a real miniaudio device.  Plays 5 seconds
/// of the embedded 440 Hz sine wave, then sends Command.quit and asserts the
/// pipeline shut down cleanly.
///
/// If the host has no audio device (CI without hardware), miniaudio will fail
/// to open and the pipeline emits Event.audio_device_lost.  In that case the
/// test prints a warning and returns error.SkipZigTest.
///
/// Run with:
///   zig build test -Dsmoke=true
const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const player = @import("player");
const audio = @import("audio");

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
// Fixtures
// ---------------------------------------------------------------------------

/// Embedded 440 Hz sine wave MP3 — 1 second, ~17 KB.
const FIXTURE_MP3 = @embedFile("fixtures/sine_440hz_1s.mp3");

/// Fake BodyFetchFn: returns the embedded sine MP3 for the fixture URL
/// and errors for any other URL.
fn fixtureFetchFn(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = cfg;
    if (std.mem.eql(u8, url, "fixture://sine")) {
        return alloc.dupe(u8, FIXTURE_MP3);
    }
    return error.UnknownFixtureUrl;
}

/// Seed one playlist + one track using raw SQLite so we don't depend on
/// the sync machinery.
fn seedDb(conn: *storage.Conn) !void {
    const c = @import("storage_c");
    const rc1 = c.sqlite3_exec(
        conn.db,
        "INSERT INTO playlists (id, name, url, added_at) VALUES (1, 'smoke', 'fixture://sine', 0)",
        null, null, null,
    );
    if (rc1 != c.SQLITE_OK) return error.SqliteExecFailed;

    const rc2 = c.sqlite3_exec(
        conn.db,
        "INSERT INTO tracks (id, playlist_id, url, display_name, duration_ms, added_at) VALUES " ++
        "(1, 1, 'fixture://sine', 'Sine 440Hz', 1000, 0)",
        null, null, null,
    );
    if (rc2 != c.SQLITE_OK) return error.SqliteExecFailed;
}

// ---------------------------------------------------------------------------
// Helper task: sleeps 5 s then sends Command.quit on ui_to_player.
// ---------------------------------------------------------------------------

fn quitAfterDelay(io: std.Io, bus: *core.Bus) void {
    std.Io.sleep(io, .{ .nanoseconds = 5 * std.time.ns_per_s }, .awake) catch {};
    bus.ui_to_player.send(io, .quit) catch {};
}

// ---------------------------------------------------------------------------
// The smoke test
// ---------------------------------------------------------------------------

test "smoke: real audio device plays sine wave for 5 seconds and shuts down cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // ---- 1. In-memory DB ----
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    // ---- 2. Bus ----
    const cfg = core.Config{ .buffer_size = 2 };
    var bus = try core.Bus.init(gpa, cfg);
    defer bus.deinit(gpa);

    // ---- 3. Notify sync_completed so player starts filling immediately. ----
    try bus.sync_to_player.send(io, .completed);

    // ---- 4. Set volume low (5%) before the player processes commands. ----
    // We send this before spawning so it sits in the channel and the player
    // applies it as soon as it starts.
    try bus.ui_to_player.send(io, .{ .volume_delta = -55 }); // 60 - 55 = 5

    // ---- 5. Spawn tasks ----

    // Player controller with the fixture fetch function.
    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, gpa, cfg, &bus, &conn, fixtureFetchFn },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Real audio pipeline — may fail if no device is present.
    var audio_task = io.async(audio.pipeline.runReal, .{ io, gpa, cfg, &bus });
    defer _ = audio_task.cancel(io) catch {};

    // Helper task: quit after 5 seconds.
    var quit_task = io.async(quitAfterDelay, .{ io, &bus });
    defer quit_task.cancel(io);

    // ---- 6. Collect events from player_to_ui ----
    // We observe events concurrently while awaiting tasks.
    // Use a simple collector running in its own task.
    const EventTag = std.meta.Tag(core.message.Event);
    var observed: std.ArrayList(EventTag) = .empty;
    defer observed.deinit(gpa);

    // Drain events with a bounded poll loop until we see quit or a timeout.
    // Timeout is slightly above 5 s to give the quit path time to drain.
    var device_lost_seen = false;
    var track_started_seen = false;
    var quit_seen = false;

    // Poll player_to_ui for up to ~7 seconds (7000 polls × 1ms).
    var poll: u32 = 0;
    while (poll < 7000) : (poll += 1) {
        while (bus.player_to_ui.tryRecv(io)) |evt| {
            const tag = std.meta.activeTag(evt);
            observed.append(gpa, tag) catch {};
            switch (evt) {
                .track_started => track_started_seen = true,
                .audio_device_lost => device_lost_seen = true,
                .quit => {
                    quit_seen = true;
                    break;
                },
                else => {},
            }
        }
        if (quit_seen or device_lost_seen) break;
        std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_ms }, .awake) catch break;
    }

    // Await tasks — audio/ctrl should have returned by now.
    _ = ctrl_task.await(io) catch |err| if (err != error.Canceled) return err;
    _ = audio_task.await(io) catch |err| if (err != error.Canceled) return err;
    quit_task.await(io);

    // Drain any remaining events after tasks finish.
    while (bus.player_to_ui.tryRecv(io)) |evt| {
        const tag = std.meta.activeTag(evt);
        observed.append(gpa, tag) catch {};
        switch (evt) {
            .track_started => track_started_seen = true,
            .audio_device_lost => device_lost_seen = true,
            .quit => quit_seen = true,
            else => {},
        }
    }

    // ---- 7. Handle no-device case ----
    if (device_lost_seen) {
        std.debug.print(
            "\nsmoke_test: WARNING — audio device not available on this host; " ++
            "skipping real-audio assertions.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    // ---- 8. Assertions ----
    try std.testing.expect(track_started_seen);
    try std.testing.expect(quit_seen);
}
