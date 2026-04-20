/// headless.zig — v0.1 non-TUI front end and permanent smoke-test fixture.
///
/// Reads cooked-mode lines from stdin, translates the first non-whitespace
/// character to a Command, and sends it on bus.ui_to_player.
/// Concurrently reads Events from bus.player_to_ui and prints one line per
/// event to stdout in a stable, parseable form.
///
/// This is also the permanent smoke-test harness (Step 9): scriptable via
/// stdin pipes, observable via stdout pipes, easy to assert against in CI.
///
/// See SPECIFICATION §4.5a and AGENTS.md "Brief: headless harness (Step 6h)".
const std = @import("std");
const core = @import("core");
const message = core.message;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Main entry point — spawned by main as an io.async task.
///
/// Runs two sub-tasks:
///   - reader: stdin → Command → bus.ui_to_player
///   - printer: bus.player_to_ui → Event → stdout
///
/// Returns when either sub-task returns.  On Event.quit the printer task
/// prints "EVT quit", flushes, and returns; the reader is then cancelled.
/// On error.Canceled, returns cleanly (normal shutdown path).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    bus: *core.Bus,
) !void {
    _ = gpa;
    _ = cfg;

    var reader_task = io.async(readerTask, .{ io, bus });
    defer _ = reader_task.cancel(io) catch {};

    var printer_task = io.async(printerTask, .{ io, bus });
    defer _ = printer_task.cancel(io) catch {};

    // Wait for whichever task finishes first.
    // The printer exits on Event.quit; the reader exits on stdin EOF.
    // Either way we cancel the other via the defer above and return.
    const Result = union(enum) {
        reader: anyerror!void,
        printer: anyerror!void,
    };
    _ = Result; // used conceptually; we use io.anyOf below if available

    // In Zig 0.16's Io.Threaded model we don't have io.select across tasks.
    // Instead: await printer first (it's the canonical exit path), then let
    // defer cancel the reader.  If the reader finishes first (stdin closed),
    // the printer will get error.Closed on the next recv and return, then the
    // await here completes.
    printer_task.await(io) catch |err| return err;
}

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests)
// ---------------------------------------------------------------------------

/// Parse the first non-whitespace character of `line` into a Command.
/// Returns null if no recognised character or if the line is empty/whitespace.
///
/// Case-sensitive: 'Q' does not match 'q'.
pub fn parse(line: []const u8) ?message.Command {
    // Find first non-whitespace byte.
    const ch: u8 = blk: {
        for (line) |byte| {
            if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
                break :blk byte;
            }
        }
        return null;
    };

    return switch (ch) {
        's' => .skip,
        'p' => .toggle_pause,
        '+' => .{ .volume_delta = 10 },
        '-' => .{ .volume_delta = -10 },
        'b' => .bookmark,
        'q' => .quit,
        else => null,
    };
}

/// Format `evt` into `buf` and return the written slice (no trailing newline).
/// Caller is responsible for adding a newline before writing to output.
///
/// Format is stable and parseable:
///   EVT <name>  [field=value ...]
///
/// String fields (name=, reason=) are double-quoted with basic backslash
/// escaping (" → \" and \ → \\).
pub fn formatEvent(buf: []u8, evt: message.Event) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);

    switch (evt) {
        .track_started => |t| {
            try w.writeAll("EVT track_started");
            try w.writeAll("  name=");
            try writeQuotedString(&w, t.display_name);
            if (t.duration_hint) |d| {
                try w.print("  duration_ms={d}", .{d});
            }
        },
        .track_progress => |p| {
            try w.print("EVT track_progress  elapsed_ms={d}", .{p.elapsed_ms});
        },
        .track_ended => {
            try w.writeAll("EVT track_ended");
        },
        .paused => |v| {
            try w.print("EVT paused  value={s}", .{if (v) "true" else "false"});
        },
        .volume_changed => |v| {
            try w.print("EVT volume_changed  value={d}", .{v});
        },
        .bookmark_added => |name| {
            try w.writeAll("EVT bookmark_added");
            try w.writeAll("  name=");
            try writeQuotedString(&w, name);
        },
        .bookmark_removed => |name| {
            try w.writeAll("EVT bookmark_removed");
            try w.writeAll("  name=");
            try writeQuotedString(&w, name);
        },
        .network_stalled => {
            try w.writeAll("EVT network_stalled");
        },
        .decode_failed => |reason| {
            try w.writeAll("EVT decode_failed");
            try w.writeAll("  reason=");
            try writeQuotedString(&w, reason);
        },
        .audio_device_lost => {
            try w.writeAll("EVT audio_device_lost");
        },
        .sync_in_progress => {
            try w.writeAll("EVT sync_in_progress");
        },
        .sync_completed => {
            try w.writeAll("EVT sync_completed");
        },
        .sync_failed => |reason| {
            try w.writeAll("EVT sync_failed");
            try w.writeAll("  reason=");
            try writeQuotedString(&w, reason);
        },
        .quit => {
            try w.writeAll("EVT quit");
        },
    }

    return w.buffered();
}

// ---------------------------------------------------------------------------
// Internal task bodies
// ---------------------------------------------------------------------------

/// Reads stdin one line at a time, parses each line, sends non-null Commands.
fn readerTask(io: std.Io, bus: *core.Bus) !void {
    var buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
    // Access the Io.Reader interface to get takeDelimiter and tossBuffered.
    const r = &stdin_reader.interface;

    while (true) {
        // takeDelimiter returns null on EOF with no remaining bytes.
        // error.Canceled is surfaced as error.ReadFailed at this level.
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return,
            error.StreamTooLong => {
                // Line longer than buffer: discard it and continue.
                r.tossBuffered();
                continue;
            },
        } orelse return; // EOF

        if (parse(line)) |cmd| {
            bus.ui_to_player.send(io, cmd) catch |err| switch (err) {
                error.Closed, error.Canceled => return,
            };
        }
    }
}

/// Receives Events from bus.player_to_ui and writes one line per event to
/// stdout.  Returns (cleanly) after writing "EVT quit\n".
fn printerTask(io: std.Io, bus: *core.Bus) !void {
    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    // Access the Io.Writer interface for writeAll/writeByte/flush.
    const w = &stdout_writer.interface;

    var fmt_buf: [1024]u8 = undefined;

    while (true) {
        const evt = bus.player_to_ui.recv(io) catch |err| switch (err) {
            error.Closed, error.Canceled => return,
        };

        const line = formatEvent(&fmt_buf, evt) catch {
            // Buffer overflow for a single event line: skip it rather than crash.
            continue;
        };

        try w.writeAll(line);
        try w.writeByte('\n');
        try w.flush();

        // Quit is the clean exit signal: we've already printed "EVT quit".
        if (evt == .quit) return;
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Write `s` as a double-quoted string with minimal backslash escaping.
/// Replaces \ with \\ and " with \".  All other bytes pass through verbatim.
fn writeQuotedString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |byte| {
        switch (byte) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}
