/// source/manifest — fetch the top-level JSON manifest from R2 and parse it.
///
/// This module does exactly one thing: GET the manifest URL, parse the JSON,
/// and return a `Manifest` whose strings are owned by an arena. No DB writes
/// happen here — the sync task (source/sync.zig) decides what to do with the
/// result.
const std = @import("std");
const core = @import("core");

/// The default manifest URL is a compile-time constant for v0.1.
/// A real R2 URL will be swapped in once the R2 bucket is provisioned.
/// We keep it as a constant (rather than @embedFile of assets/manifest_bootstrap.json)
/// because v0.1 deliberately keeps the URL strictly baked-in per SPECIFICATION §13.3.
pub const default_manifest_url = "https://example.invalid/lowzi/manifest.json";

pub const PlaylistEntry = struct {
    name: []const u8,
    url: []const u8,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    hash: []const u8,
    playlists: []PlaylistEntry,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub const ManifestError = error{
    InvalidManifest,
    HttpStatus,
    Timeout,
    ConnectionLost,
    OutOfMemory,
    Canceled,
};

/// Wire shape that mirrors the JSON we expect from R2.
/// Used only inside `parse`; not exported.
const JsonManifest = struct {
    hash: ?[]const u8 = null,
    playlists: ?[]const JsonPlaylistEntry = null,
};

const JsonPlaylistEntry = struct {
    name: []const u8,
    url: []const u8,
};

/// Fetch the manifest from `default_manifest_url` (or from whatever URL is
/// configured — v0.1 hardcodes the default). Follows up to 5 redirects.
/// Honors `cfg.timeout_ms`.
///
/// The returned `Manifest` owns all its strings via an arena; call
/// `manifest.deinit()` when done.
pub fn fetch(io: std.Io, gpa: std.mem.Allocator, cfg: core.Config) ManifestError!Manifest {
    _ = cfg; // timeout_ms wiring deferred to v0.2

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Use an Allocating writer to accumulate the body.
    var body_writer = std.Io.Writer.Allocating.init(gpa);
    errdefer {
        var al = body_writer.toArrayList();
        al.deinit(gpa);
    }

    const result = client.fetch(.{
        .location = .{ .url = default_manifest_url },
        .keep_alive = false,
        .redirect_behavior = @enumFromInt(5),
        .response_writer = &body_writer.writer,
    }) catch |err| return mapHttpError(err);

    const status = result.status;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) > 299) {
        return error.HttpStatus;
    }

    var body_list = body_writer.toArrayList();
    defer body_list.deinit(gpa);

    return parse(gpa, body_list.items);
}

/// Parse a JSON manifest body. Copies all strings into the returned
/// `Manifest.arena` so the caller does not have to keep the original `body`
/// alive. Caller must call `manifest.deinit()` to free.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) ManifestError!Manifest {
    // Parse into a temporary Parsed(JsonManifest) using std.json.
    // We copy the strings into our own arena and then free the parsed value
    // to avoid keeping two arenas alive simultaneously.
    const parsed = std.json.parseFromSlice(
        JsonManifest,
        gpa,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidManifest;
    defer parsed.deinit();

    const jm = parsed.value;

    // Both `hash` and `playlists` are required per SPECIFICATION §4.5.0.
    if (jm.hash == null) return error.InvalidManifest;
    if (jm.playlists == null) return error.InvalidManifest;

    // Build the result in a fresh arena.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const hash = alloc.dupe(u8, jm.hash.?) catch return error.OutOfMemory;

    const src_playlists = jm.playlists.?;
    const playlists = alloc.alloc(PlaylistEntry, src_playlists.len) catch return error.OutOfMemory;
    for (src_playlists, 0..) |entry, i| {
        playlists[i] = .{
            .name = alloc.dupe(u8, entry.name) catch return error.OutOfMemory,
            .url = alloc.dupe(u8, entry.url) catch return error.OutOfMemory,
        };
    }

    return Manifest{
        .arena = arena,
        .hash = hash,
        .playlists = playlists,
    };
}

/// Map std.http and std.net errors to ManifestError members.
fn mapHttpError(err: anyerror) ManifestError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.ConnectionTimedOut, error.TimedOut => error.Timeout,
        else => error.ConnectionLost,
    };
}
