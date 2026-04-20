/// Tests for source.manifest: JSON parsing and Manifest lifecycle.
///
/// `fetch` is NOT exercised against a real network here. Gate real-network
/// tests behind -Dsmoke=true (see SPECIFICATION §9.1).
const std = @import("std");
const source = @import("source");
const manifest_mod = source.manifest;

// ---------------------------------------------------------------------------
// Happy path: valid fixture with two playlists
// ---------------------------------------------------------------------------

test "source.manifest.parse: valid fixture returns correct hash and playlists" {
    const gpa = std.testing.allocator;

    const body =
        \\{
        \\  "hash": "sha256:abc123",
        \\  "playlists": [
        \\    { "name": "chillhop-relaxing", "url": "https://audio.lowzi.xxx/playlists/chillhop-relaxing.m3u8" },
        \\    { "name": "lofi-focus",        "url": "https://audio.lowzi.xxx/playlists/lofi-focus.m3u8" }
        \\  ]
        \\}
    ;

    var m = try manifest_mod.parse(gpa, body);
    defer m.deinit();

    try std.testing.expectEqualStrings("sha256:abc123", m.hash);
    try std.testing.expectEqual(@as(usize, 2), m.playlists.len);
    try std.testing.expectEqualStrings("chillhop-relaxing", m.playlists[0].name);
    try std.testing.expectEqualStrings("https://audio.lowzi.xxx/playlists/chillhop-relaxing.m3u8", m.playlists[0].url);
    try std.testing.expectEqualStrings("lofi-focus", m.playlists[1].name);
    try std.testing.expectEqualStrings("https://audio.lowzi.xxx/playlists/lofi-focus.m3u8", m.playlists[1].url);
}

// ---------------------------------------------------------------------------
// Missing `hash` field → error.InvalidManifest
// ---------------------------------------------------------------------------

test "source.manifest.parse: missing hash field returns InvalidManifest" {
    const gpa = std.testing.allocator;

    const body =
        \\{
        \\  "playlists": [
        \\    { "name": "chillhop-relaxing", "url": "https://audio.lowzi.xxx/playlists/chillhop-relaxing.m3u8" }
        \\  ]
        \\}
    ;

    const result = manifest_mod.parse(gpa, body);
    try std.testing.expectError(error.InvalidManifest, result);
}

// ---------------------------------------------------------------------------
// Missing `playlists` field → error.InvalidManifest
// ---------------------------------------------------------------------------

test "source.manifest.parse: missing playlists field returns InvalidManifest" {
    const gpa = std.testing.allocator;

    const body =
        \\{ "hash": "sha256:deadbeef" }
    ;

    const result = manifest_mod.parse(gpa, body);
    try std.testing.expectError(error.InvalidManifest, result);
}

// ---------------------------------------------------------------------------
// Empty playlists array → success, len == 0
// ---------------------------------------------------------------------------

test "source.manifest.parse: empty playlists array is valid" {
    const gpa = std.testing.allocator;

    const body =
        \\{ "hash": "sha256:deadbeef", "playlists": [] }
    ;

    var m = try manifest_mod.parse(gpa, body);
    defer m.deinit();

    try std.testing.expectEqualStrings("sha256:deadbeef", m.hash);
    try std.testing.expectEqual(@as(usize, 0), m.playlists.len);
}

// ---------------------------------------------------------------------------
// Malformed JSON → error.InvalidManifest (no crash)
// ---------------------------------------------------------------------------

test "source.manifest.parse: malformed JSON returns InvalidManifest cleanly" {
    const gpa = std.testing.allocator;

    const body = "{ this is not valid json @@@ ";

    const result = manifest_mod.parse(gpa, body);
    try std.testing.expectError(error.InvalidManifest, result);
}

// ---------------------------------------------------------------------------
// deinit releases everything (testing-allocator leak check)
// The testing allocator will report a leak if deinit is missing or broken.
// ---------------------------------------------------------------------------

test "source.manifest.Manifest.deinit: no memory leak after deinit" {
    const gpa = std.testing.allocator;

    const body =
        \\{
        \\  "hash": "sha256:leakcheck",
        \\  "playlists": [
        \\    { "name": "test-playlist", "url": "https://example.com/test.m3u8" }
        \\  ]
        \\}
    ;

    var m = try manifest_mod.parse(gpa, body);
    // If deinit is omitted, the testing allocator will detect the leak.
    m.deinit();
}

// ---------------------------------------------------------------------------
// Unknown extra fields are ignored (forward-compatibility)
// ---------------------------------------------------------------------------

test "source.manifest.parse: extra unknown fields are ignored" {
    const gpa = std.testing.allocator;

    const body =
        \\{
        \\  "hash": "sha256:xyz",
        \\  "playlists": [],
        \\  "version": 2,
        \\  "future_field": "ignored"
        \\}
    ;

    var m = try manifest_mod.parse(gpa, body);
    defer m.deinit();

    try std.testing.expectEqualStrings("sha256:xyz", m.hash);
    try std.testing.expectEqual(@as(usize, 0), m.playlists.len);
}
