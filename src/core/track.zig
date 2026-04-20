/// Track — a single audio entry.
///
/// `bytes` is owned by the Track when non-null. Call `deinit` to release it.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Track = struct {
    /// Unique numeric ID derived from the URI hash.
    id: u64,
    /// Human-readable display name (e.g. "lofi - sample 01").
    display_name: []const u8,
    /// Absolute URI for this track (http(s):// or file://).
    source_uri: []const u8,
    /// Optional duration hint in milliseconds, populated from the tracklist or
    /// from the decoder after download.
    duration_hint: ?u32,
    /// Owned byte payload. Null until the track has been downloaded.
    bytes: ?[]u8,
    /// When true, display_name and source_uri are also gpa-owned and freed
    /// by deinit. String slices borrowed from an arena should leave this false.
    owned_strings: bool = false,

    /// Release owned resources. Safe to call on partially-initialized tracks.
    /// Frees `bytes` always. If `owned_strings` is true, also frees
    /// `display_name` and `source_uri`.
    pub fn deinit(self: *Track, gpa: Allocator) void {
        if (self.bytes) |b| gpa.free(b);
        self.bytes = null;
        if (self.owned_strings) {
            gpa.free(self.display_name);
            gpa.free(self.source_uri);
            self.owned_strings = false;
        }
    }
};
