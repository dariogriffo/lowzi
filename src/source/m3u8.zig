const std = @import("std");

pub const Entry = struct {
    url: []const u8,
    display_name: ?[]const u8,
    duration_ms: ?u32,
};

pub const Playlist = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Playlist) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    InvalidM3u8,
    OutOfMemory,
};

/// Parse an M3U8 body. Caller-managed `gpa` backs the result's arena.
/// Supports: #EXTM3U header check, #EXTINF annotations, LF and CRLF endings.
/// Unknown #EXT* tags are silently ignored.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) ParseError!Playlist {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;

    var found_header = false;
    // Pending EXTINF data for the next URL line.
    var pending_display: ?[]const u8 = null;
    var pending_duration: ?u32 = null;

    var iter = std.mem.splitAny(u8, body, "\n");
    while (iter.next()) |raw_line| {
        // Trim CR so CRLF works identically to LF.
        const line = trimEnd(raw_line);

        if (line.len == 0) continue; // blank line

        if (std.mem.startsWith(u8, line, "#")) {
            // Handle known tags.
            if (std.mem.eql(u8, line, "#EXTM3U")) {
                if (!found_header) {
                    found_header = true;
                }
                continue;
            }

            if (!found_header) {
                // First non-blank line was a comment other than #EXTM3U.
                return error.InvalidM3u8;
            }

            if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                const rest = line["#EXTINF:".len..];
                // Split on first comma to separate seconds from optional display name.
                if (std.mem.indexOfScalar(u8, rest, ',')) |comma_pos| {
                    const secs_str = rest[0..comma_pos];
                    const display_raw = rest[comma_pos + 1 ..];
                    pending_duration = parseSeconds(secs_str);
                    if (display_raw.len > 0) {
                        pending_display = try alloc.dupe(u8, display_raw);
                    } else {
                        pending_display = null;
                    }
                } else {
                    // No comma: seconds only, no display name.
                    pending_duration = parseSeconds(rest);
                    pending_display = null;
                }
            }
            // All other #EXT* lines are ignored (forgiving per RFC 8216 subset).
            continue;
        }

        // URL line.
        if (!found_header) {
            return error.InvalidM3u8;
        }

        const url = try alloc.dupe(u8, line);
        try entries.append(alloc, Entry{
            .url = url,
            .display_name = pending_display,
            .duration_ms = pending_duration,
        });
        // Reset pending annotation.
        pending_display = null;
        pending_duration = null;
    }

    if (!found_header) {
        return error.InvalidM3u8;
    }

    return Playlist{
        .arena = arena,
        .entries = try entries.toOwnedSlice(alloc),
    };
}

/// Parse a float seconds string and convert to milliseconds with rounding.
/// Returns null if parsing fails; we are forgiving.
fn parseSeconds(s: []const u8) ?u32 {
    const f = std.fmt.parseFloat(f64, s) catch return null;
    const ms = @round(f * 1000.0);
    if (ms < 0) return null;
    if (ms > @as(f64, std.math.maxInt(u32))) return null;
    return @intFromFloat(ms);
}

/// Trim trailing space, tab, and CR from the right of a slice.
fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, &[_]u8{ ' ', '\t', '\r' });
}
