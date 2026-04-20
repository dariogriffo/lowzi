const std = @import("std");
const m3u8 = @import("source").m3u8;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseExpectOk(body: []const u8) !m3u8.Playlist {
    return m3u8.parse(std.testing.allocator, body);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "source.m3u8: minimal — single entry no metadata" {
    var pl = try parseExpectOk("#EXTM3U\nhttps://example.com/a.mp3\n");
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqualStrings("https://example.com/a.mp3", pl.entries[0].url);
    try std.testing.expectEqual(@as(?[]const u8, null), pl.entries[0].display_name);
    try std.testing.expectEqual(@as(?u32, null), pl.entries[0].duration_ms);
}

test "source.m3u8: EXTINF annotation" {
    var pl = try parseExpectOk("#EXTM3U\n#EXTINF:180.5,Chill 1\nhttps://example.com/a.mp3\n");
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqualStrings("Chill 1", pl.entries[0].display_name.?);
    try std.testing.expectEqual(@as(?u32, 180_500), pl.entries[0].duration_ms);
}

test "source.m3u8: mixed entries (2 with EXTINF, 2 without)" {
    const body =
        "#EXTM3U\n" ++
        "#EXTINF:90.0,Track One\n" ++
        "https://example.com/one.mp3\n" ++
        "https://example.com/two.mp3\n" ++
        "#EXTINF:120.0,Track Three\n" ++
        "https://example.com/three.mp3\n" ++
        "https://example.com/four.mp3\n";
    var pl = try parseExpectOk(body);
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 4), pl.entries.len);
    try std.testing.expectEqualStrings("Track One", pl.entries[0].display_name.?);
    try std.testing.expectEqual(@as(?u32, 90_000), pl.entries[0].duration_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), pl.entries[1].display_name);
    try std.testing.expectEqual(@as(?u32, null), pl.entries[1].duration_ms);
    try std.testing.expectEqualStrings("Track Three", pl.entries[2].display_name.?);
    try std.testing.expectEqual(@as(?u32, 120_000), pl.entries[2].duration_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), pl.entries[3].display_name);
}

test "source.m3u8: display name containing a comma" {
    var pl = try parseExpectOk("#EXTM3U\n#EXTINF:90,Hello, World\nhttps://x.mp3\n");
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqualStrings("Hello, World", pl.entries[0].display_name.?);
}

test "source.m3u8: unknown EXT-X tags are ignored" {
    const body =
        "#EXTM3U\n" ++
        "#EXT-X-VERSION:3\n" ++
        "#EXT-X-TARGETDURATION:10\n" ++
        "https://example.com/track.mp3\n";
    var pl = try parseExpectOk(body);
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqual(@as(?[]const u8, null), pl.entries[0].display_name);
}

test "source.m3u8: missing EXTM3U header returns error" {
    const result = m3u8.parse(std.testing.allocator, "https://x.mp3\n");
    try std.testing.expectError(error.InvalidM3u8, result);
}

test "source.m3u8: empty body returns error" {
    const result = m3u8.parse(std.testing.allocator, "");
    try std.testing.expectError(error.InvalidM3u8, result);
}

test "source.m3u8: CRLF parses identically to LF" {
    const lf_body = "#EXTM3U\n#EXTINF:60.0,A Track\nhttps://example.com/a.mp3\n";
    const crlf_body = "#EXTM3U\r\n#EXTINF:60.0,A Track\r\nhttps://example.com/a.mp3\r\n";

    var lf_pl = try parseExpectOk(lf_body);
    defer lf_pl.deinit();
    var crlf_pl = try parseExpectOk(crlf_body);
    defer crlf_pl.deinit();

    try std.testing.expectEqual(lf_pl.entries.len, crlf_pl.entries.len);
    try std.testing.expectEqualStrings(lf_pl.entries[0].url, crlf_pl.entries[0].url);
    try std.testing.expectEqualStrings(
        lf_pl.entries[0].display_name.?,
        crlf_pl.entries[0].display_name.?,
    );
    try std.testing.expectEqual(lf_pl.entries[0].duration_ms, crlf_pl.entries[0].duration_ms);
}

test "source.m3u8: trailing whitespace on URL is trimmed" {
    var pl = try parseExpectOk("#EXTM3U\nhttps://x.mp3   \n");
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqualStrings("https://x.mp3", pl.entries[0].url);
}

test "source.m3u8: missing trailing newline is OK" {
    var pl = try parseExpectOk("#EXTM3U\nhttps://example.com/a.mp3");
    defer pl.deinit();
    try std.testing.expectEqual(@as(usize, 1), pl.entries.len);
    try std.testing.expectEqualStrings("https://example.com/a.mp3", pl.entries[0].url);
}
