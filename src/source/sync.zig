/// source/sync — background catalog reconciler.
///
/// Spawned from `main` as an `io.async` task. Runs once at startup:
///   1. Fetch the manifest.
///   2. Compare its hash against what is stored in meta.manifest_hash.
///   3. If hashes differ, download every M3U8, diff-merge into SQLite in one
///      transaction, and update the stored hash.
///   4. Emit Event.sync_completed (or Event.sync_failed on error) to the bus.
///
/// Never blocks the player — the entire reconciliation is a single background
/// task that does I/O and then commits one SQLite transaction.
const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const manifest_mod = @import("manifest.zig");
const m3u8_mod = @import("m3u8.zig");
const downloader = @import("downloader.zig");

pub const SyncError = error{
    InvalidManifest,
    HttpStatus,
    Timeout,
    ConnectionLost,
    OutOfMemory,
    Canceled,
    TooManyRedirects,
    BodyTooLarge,
    InvalidM3u8,
    SqlitePrepFailed,
    SqliteBindFailed,
    SqliteStepFailed,
    SqliteExecFailed,
    SqlTooLong,
    SqliteOpenFailed,
};

// ---------------------------------------------------------------------------
// Manifest fetcher interface — allows tests to inject a fake.
// ---------------------------------------------------------------------------

/// A function-pointer type for manifest fetching.
/// The real implementation calls manifest_mod.fetch; tests supply their own.
pub const ManifestFetchFn = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
) anyerror!manifest_mod.Manifest;

/// A function-pointer type for per-playlist body fetching.
/// Mirrors downloader.Fetcher but at a higher level: takes `url` and returns
/// the body. The real implementation calls downloader.fetch; tests supply their own.
pub const BodyFetchFn = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8;

// ---------------------------------------------------------------------------
// Public entry point — uses real network back-ends.
// ---------------------------------------------------------------------------

/// One-shot background reconciler. Returns cleanly on success. Returns
/// error.Canceled on clean shutdown (task was cancelled).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    conn: *storage.Conn,
    bus: *core.Bus,
) !void {
    return runWith(io, gpa, cfg, conn, bus, manifest_mod.fetch, downloader.fetch);
}

// ---------------------------------------------------------------------------
// Parameterized inner — used by both `run` and tests.
// ---------------------------------------------------------------------------

/// Like `run` but accepts injected manifest and body fetchers.
/// Tests pass fakes here; `run` passes the real implementations.
pub fn runWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    conn: *storage.Conn,
    bus: *core.Bus,
    manifest_fn: ManifestFetchFn,
    fetch_fn: BodyFetchFn,
) !void {
    // On any error other than Canceled: send sync_failed then return.
    // Cancellation is a clean shutdown — the player is no longer listening.
    runInner(io, gpa, cfg, conn, bus, manifest_fn, fetch_fn) catch |err| {
        if (err == error.Canceled) return err;
        // Build a short reason string from the error name.
        // We use a stack buffer so no allocation is needed at the error path.
        var reason_buf: [128]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "{s}", .{@errorName(err)}) catch "SyncFailed";
        // Send is best-effort here: if the channel is full or closed we still
        // return the original error so the task's exit code is non-zero.
        bus.player_to_ui.send(io, .{ .sync_failed = reason }) catch {};
        // Also signal the player directly. reason lives on the stack so it is
        // valid for the duration of these two sends.
        bus.sync_to_player.send(io, .{ .failed = reason }) catch {};
        return err;
    };
}

fn runInner(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    conn: *storage.Conn,
    bus: *core.Bus,
    manifest_fn: ManifestFetchFn,
    fetch_fn: BodyFetchFn,
) !void {
    // Step 1: fetch the manifest.
    var manifest = try manifest_fn(io, gpa, cfg);
    defer manifest.deinit();

    // Step 2: get the stored hash and compare.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const stored = try storage.queries.getManifestHash(conn, arena.allocator());
    if (stored != null and std.mem.eql(u8, stored.?, manifest.hash)) {
        // Hashes match: no work needed. Still emit sync_completed so the
        // player knows it can start picking tracks.
        try bus.player_to_ui.send(io, .sync_completed);
        // Also signal the player directly via its dedicated channel.
        bus.sync_to_player.send(io, .completed) catch {};
        return;
    }

    // Step 3: open the sync transaction.
    var tx = try storage.queries.beginSync(conn);
    errdefer tx.rollback();

    // Step 4: for each playlist entry, download the M3U8 and ingest rows.
    for (manifest.playlists) |entry| {
        const body = try fetch_fn(io, gpa, cfg, entry.url);
        defer gpa.free(body);

        var playlist = try m3u8_mod.parse(gpa, body);
        defer playlist.deinit();

        for (playlist.entries) |m3u8_entry| {
            try tx.appendTemp(
                entry.name,
                m3u8_entry.url,
                m3u8_entry.display_name,
                m3u8_entry.duration_ms,
            );
        }
    }

    // Step 5: diff-merge and commit.
    try tx.mergeAndCommit(manifest.hash);

    // Step 6: notify the bus.
    try bus.player_to_ui.send(io, .sync_completed);
    // Also signal the player directly via its dedicated channel.
    bus.sync_to_player.send(io, .completed) catch {};
}
