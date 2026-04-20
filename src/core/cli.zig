/// Hand-rolled CLI argument parser.
///
/// Implements §7.1 of the specification:
///   - Long flags: --name / --name=value / --name value
///   - Short flags can be combined: -amb ⇔ --alternate --minimalist --borderless
///   - Unknown flag → print usage + exit 2
///   - --help / -h → print usage + exit 0
///   - --version → print version + exit 0
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const errors = @import("errors.zig");

const VERSION = "0.1.0";
const USAGE =
    \\Usage: lowzi [OPTIONS]
    \\
    \\A minimal lofi music player.
    \\
    \\Options:
    \\  -a, --alternate          Use alternate screen buffer
    \\  -m, --minimalist         Hide the controls hint bar
    \\  -b, --borderless         Render without borders
    \\  -c, --clock              Show a wall clock
    \\  -p, --paused             Start paused
    \\  -f, --fps <N>            UI refresh rate (default 12)
    \\  -w, --width <N>          Player width tier 0..32 (default 3)
    \\  -t, --track-list <name>  Use named list or path (default: embedded)
    \\  -s, --buffer-size <N>    Tracks to buffer ahead (default 5)
    \\      --timeout <ms>       Per-request HTTP timeout ms (default 3000)
    \\  -d, --debug              Verbose logging
    \\  -h, --help               Print this help and exit
    \\      --version            Print version and exit
    \\
;

pub fn printUsage(writer: anytype) void {
    writer.writeAll(USAGE) catch {};
}

pub fn printVersion(writer: anytype) void {
    writer.print("lowzi {s}\n", .{VERSION}) catch {};
}

/// Parse argv (excluding argv[0]) into a Config.
/// Uses arena for any allocated strings (e.g. track_list path).
/// On --help / --version prints to stderr/stdout and calls std.process.exit.
/// On unknown flag prints usage and exits with code 2.
pub fn parse(arena: Allocator, argv: []const []const u8) (errors.CliError || Allocator.Error)!Config {
    var cfg = Config{};
    var i: usize = 0;

    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            i = try parseLong(&cfg, argv, i, arena);
        } else if (arg.len >= 2 and arg[0] == '-') {
            i = try parseShorts(&cfg, argv, i, arena);
        } else {
            // Positional argument — not expected; treat as unknown.
            std.debug.print("lowzi: unexpected argument '{s}'\n", .{arg});
            std.debug.print("{s}", .{USAGE});
            std.process.exit(2);
        }
    }

    return cfg;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Parse a long flag starting at argv[i]. Returns the next index to process.
fn parseLong(
    cfg: *Config,
    argv: []const []const u8,
    i: usize,
    arena: Allocator,
) (errors.CliError || Allocator.Error)!usize {
    const raw = argv[i];
    // Split on first '=' if present: --name=value
    const eq = std.mem.indexOfScalar(u8, raw, '=');
    const name = if (eq) |e| raw[2..e] else raw[2..];
    const inline_val: ?[]const u8 = if (eq) |e| raw[e + 1 ..] else null;

    // Booleans (no value argument)
    if (std.mem.eql(u8, name, "alternate")) {
        cfg.alternate = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "minimalist")) {
        cfg.minimalist = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "borderless")) {
        cfg.borderless = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "clock")) {
        cfg.clock = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "paused")) {
        cfg.paused = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "debug")) {
        cfg.debug = true;
        return i + 1;
    }
    if (std.mem.eql(u8, name, "help")) {
        std.debug.print("{s}", .{USAGE});
        std.process.exit(0);
    }
    if (std.mem.eql(u8, name, "version")) {
        std.debug.print("lowzi {s}\n", .{VERSION});
        std.process.exit(0);
    }

    // Flags that take a value argument
    if (std.mem.eql(u8, name, "fps")) {
        const val = try requireValue(argv, i, inline_val, "fps");
        cfg.fps = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
        return if (inline_val != null) i + 1 else i + 2;
    }
    if (std.mem.eql(u8, name, "width")) {
        const val = try requireValue(argv, i, inline_val, "width");
        cfg.width = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
        return if (inline_val != null) i + 1 else i + 2;
    }
    if (std.mem.eql(u8, name, "buffer-size")) {
        const val = try requireValue(argv, i, inline_val, "buffer-size");
        cfg.buffer_size = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
        return if (inline_val != null) i + 1 else i + 2;
    }
    if (std.mem.eql(u8, name, "timeout")) {
        const val = try requireValue(argv, i, inline_val, "timeout");
        cfg.timeout_ms = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
        return if (inline_val != null) i + 1 else i + 2;
    }
    if (std.mem.eql(u8, name, "track-list")) {
        const val = try requireValue(argv, i, inline_val, "track-list");
        cfg.track_list = try arena.dupe(u8, val);
        return if (inline_val != null) i + 1 else i + 2;
    }

    std.debug.print("lowzi: unknown flag '--{s}'\n", .{name});
    std.debug.print("{s}", .{USAGE});
    std.process.exit(2);
}

/// Parse one or more short flags combined (e.g. -amb). Returns next index.
fn parseShorts(
    cfg: *Config,
    argv: []const []const u8,
    i: usize,
    arena: Allocator,
) (errors.CliError || Allocator.Error)!usize {
    const raw = argv[i];
    // raw[0] == '-', raw[1..] are the flags
    var j: usize = 1;
    while (j < raw.len) : (j += 1) {
        switch (raw[j]) {
            'a' => cfg.alternate = true,
            'm' => cfg.minimalist = true,
            'b' => cfg.borderless = true,
            'c' => cfg.clock = true,
            'p' => cfg.paused = true,
            'd' => cfg.debug = true,
            'h' => {
                std.debug.print("{s}", .{USAGE});
                std.process.exit(0);
            },
            // Value-taking short flags: must be last in the combined group.
            'f' => {
                // Remainder of this arg is the value (-f12) or next arg.
                const inline_val: ?[]const u8 = if (j + 1 < raw.len) raw[j + 1 ..] else null;
                const val = try requireValue(argv, i, inline_val, "fps");
                cfg.fps = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
                return if (inline_val != null) i + 1 else i + 2;
            },
            'w' => {
                const inline_val: ?[]const u8 = if (j + 1 < raw.len) raw[j + 1 ..] else null;
                const val = try requireValue(argv, i, inline_val, "width");
                cfg.width = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
                return if (inline_val != null) i + 1 else i + 2;
            },
            't' => {
                const inline_val: ?[]const u8 = if (j + 1 < raw.len) raw[j + 1 ..] else null;
                const val = try requireValue(argv, i, inline_val, "track-list");
                cfg.track_list = try arena.dupe(u8, val);
                return if (inline_val != null) i + 1 else i + 2;
            },
            's' => {
                const inline_val: ?[]const u8 = if (j + 1 < raw.len) raw[j + 1 ..] else null;
                const val = try requireValue(argv, i, inline_val, "buffer-size");
                cfg.buffer_size = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
                return if (inline_val != null) i + 1 else i + 2;
            },
            else => {
                std.debug.print("lowzi: unknown flag '-{c}'\n", .{raw[j]});
                std.debug.print("{s}", .{USAGE});
                std.process.exit(2);
            },
        }
    }
    return i + 1;
}

/// Return the value for a flag: prefer the inline_val (--flag=val), otherwise
/// take the next argv element. Returns error.MissingValue if neither exists.
fn requireValue(
    argv: []const []const u8,
    i: usize,
    inline_val: ?[]const u8,
    flag_name: []const u8,
) errors.CliError![]const u8 {
    if (inline_val) |v| return v;
    if (i + 1 < argv.len) return argv[i + 1];
    std.debug.print("lowzi: flag '--{s}' requires a value\n", .{flag_name});
    std.debug.print("{s}", .{USAGE});
    std.process.exit(2);
}
