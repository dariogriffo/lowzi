/// player/bookmark.zig — thin wrapper over storage bookmark queries.
///
/// Idempotent on both sides: toggle reads current state before mutating.
/// The ON DELETE CASCADE FK in the schema handles track-deleted cleanup.
const storage = @import("storage");

/// Toggle the bookmark state for `track_id`.
/// Returns true if the track is now bookmarked, false if it was removed.
pub fn toggle(conn: *storage.Conn, track_id: i64) !bool {
    if (try storage.queries.isBookmarked(conn, track_id)) {
        try storage.queries.removeBookmark(conn, track_id);
        return false;
    } else {
        try storage.queries.addBookmark(conn, track_id);
        return true;
    }
}
