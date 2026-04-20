/// Integration smoke test (Step 8, not gated by -Dsmoke).
///
/// Exercises the core graph: storage seeded with a fake playlist + tracks,
/// player controller + audio pipeline driven through Command.skip then
/// Command.quit, asserts Event.quit is emitted.
///
/// Real audio device is not used: audio/pipeline uses Output.initNull
/// which discards PCM without touching hardware.
/// Real network is not used: a fake BodyFetchFn returns embedded MP3 bytes.
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

/// Embedded sine-wave MP3 used as fake audio data for the player.
const FIXTURE_MP3 = @embedFile("fixtures/sine_440hz_1s.mp3");

/// Fake BodyFetchFn: returns the embedded MP3 fixture for any URL.
fn fakeAudioFetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    _ = io;
    _ = cfg;
    _ = url;
    return alloc.dupe(u8, FIXTURE_MP3);
}

/// Seed the DB with one playlist and two tracks.
fn seedDb(conn: *storage.Conn) !void {
    const c = @import("storage_c");
    const rc1 = c.sqlite3_exec(
        conn.db,
        "INSERT INTO playlists (id, name, url, added_at) VALUES (1, 'test-playlist', 'http://example.com/pl.m3u8', 0)",
        null, null, null,
    );
    if (rc1 != c.SQLITE_OK) return error.SqliteExecFailed;

    const rc2 = c.sqlite3_exec(
        conn.db,
        "INSERT INTO tracks (id, playlist_id, url, display_name, duration_ms, added_at) VALUES " ++
        "(1, 1, 'http://example.com/track1.mp3', 'Test Track 1', 1000, 0)," ++
        "(2, 1, 'http://example.com/track2.mp3', 'Test Track 2', 1000, 0)",
        null, null, null,
    );
    if (rc2 != c.SQLITE_OK) return error.SqliteExecFailed;
}

// ---------------------------------------------------------------------------
// Integration test
// ---------------------------------------------------------------------------

test "integration: player + audio pipeline process skip then quit and emit Event.quit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Set up in-memory DB with tracks.
    var conn = try storage.Conn.openMemory(gpa);
    defer conn.close();
    try seedDb(&conn);

    const cfg = core.Config{ .buffer_size = 2 };
    var bus = try core.Bus.init(gpa, cfg);
    defer bus.deinit(gpa);

    // Notify sync_completed right away so the player starts filling.
    // We do this before spawning so the message is in the channel.
    try bus.sync_to_player.send(io, .completed);

    // Spawn player controller with the fake fetch function.
    var ctrl_task = io.async(
        player.controller.runWith,
        .{ io, gpa, cfg, &bus, &conn, fakeAudioFetch },
    );
    defer _ = ctrl_task.cancel(io) catch {};

    // Spawn audio pipeline with the null backend.
    var audio_task = io.async(audio.pipeline.run, .{ io, gpa, cfg, &bus });
    defer _ = audio_task.cancel(io) catch {};

    // Drain events until the player emits sync_completed forwarded to UI
    // or up to a bounded number of iterations.
    var max_iters: u32 = 50;
    while (max_iters > 0) : (max_iters -= 1) {
        const maybe = bus.player_to_ui.tryRecv(io);
        if (maybe) |evt| {
            if (evt == .sync_completed) break;
        }
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch break;
    }

    // Send quit. The pipeline and controller should both shut down.
    try bus.ui_to_player.send(io, .quit);

    // Await both tasks.
    _ = ctrl_task.await(io) catch |err| if (err != error.Canceled) return err;
    _ = audio_task.await(io) catch |err| if (err != error.Canceled) return err;

    // Drain player_to_ui and look for Event.quit.
    var found_quit = false;
    while (bus.player_to_ui.tryRecv(io)) |evt| {
        if (evt == .quit) {
            found_quit = true;
            break;
        }
    }

    try std.testing.expect(found_quit);
}
