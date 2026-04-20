/// player/queue.zig — queue fill helpers.
///
/// Pure-ish: only calls into storage/ and the injected fetch function.
/// No channel I/O — the controller does that. Tests inject a fake fetch_fn
/// via fetchTrackBody so no real HTTP ever runs.
const std = @import("std");
const core = @import("core");
const storage = @import("storage");

pub const FillError = error{
    CatalogEmpty,
    OutOfMemory,
    // storage errors
    SqlitePrepFailed,
    SqliteBindFailed,
    SqliteStepFailed,
    SqliteExecFailed,
    SqlTooLong,
    // downloader errors
    Timeout,
    ConnectionLost,
    HttpStatus,
    TooManyRedirects,
    BodyTooLarge,
    Canceled,
};

/// A function pointer type for fetching a track body.
/// The controller passes `source.downloader.fetch` for production;
/// tests pass a fake that returns static bytes.
pub const BodyFetchFn = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8;

// ---------------------------------------------------------------------------
// Candidate selection
// ---------------------------------------------------------------------------

/// Ask storage for the next playback candidate, excluding recently-played IDs.
/// Returns null when the catalog has no eligible tracks.
/// All string fields in the returned row are arena-allocated.
pub fn pickCandidate(
    conn: *storage.Conn,
    arena: std.mem.Allocator,
    exclude: []const i64,
) !?storage.queries.TrackRow {
    return storage.queries.pickNextTrack(conn, arena, exclude);
}

// ---------------------------------------------------------------------------
// Track body fetch
// ---------------------------------------------------------------------------

/// Download the MP3 body for a candidate row.  Returns a gpa-owned []u8.
/// The caller (controller) is responsible for freeing the bytes via gpa.free.
pub fn fetchTrackBody(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    row: storage.queries.TrackRow,
    fetch_fn: BodyFetchFn,
) ![]u8 {
    return fetch_fn(io, gpa, cfg, row.url);
}
