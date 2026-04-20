/// platform/signals.zig — SIGINT/SIGTERM handler that posts Command.quit.
///
/// The signal handler is C-callable and reentrant: it just sets an atomic flag.
/// A polling task (returned as SignalWatcher) checks the flag every ~100ms and
/// sends Command.quit on the bus when it flips.
///
/// On Windows (v0.1): install() returns a no-op SignalWatcher with a warning log.
/// Ctrl-C in cooked-mode terminals kills the process via OS default; we lose
/// graceful shutdown but get a working binary.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

// ---------------------------------------------------------------------------
// File-scoped static pointer to the shared atomic flag.
// The C-callable signal handler can only reach global/static state.
// This is the one allowed global in the codebase (AGENTS.md §0.1).
// ---------------------------------------------------------------------------
var g_flag: ?*std.atomic.Value(bool) = null;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const SignalWatcher = struct {
    flag: *std.atomic.Value(bool),
    gpa: std.mem.Allocator,
    // The io.async polling task handle.  On non-POSIX builds this is null
    // and deinit is a no-op.
    task: if (builtin.os.tag != .windows) ?std.Io.Future(anyerror!void) else void,

    /// Cancel the polling task and free all allocations.
    pub fn deinit(self: *SignalWatcher, io: std.Io) void {
        if (builtin.os.tag != .windows) {
            if (self.task) |*t| {
                _ = t.cancel(io) catch {};
            }
        }
        self.gpa.destroy(self.flag);
        // Free the SignalWatcher itself (allocated by install).
        self.gpa.destroy(self);
    }

    /// Test hook: set the flag as if a signal arrived.
    /// Use only in tests — do NOT call from production code.
    pub fn _testTriggerForTesting(self: *SignalWatcher) void {
        self.flag.store(true, .release);
    }
};

// ---------------------------------------------------------------------------
// install — public entry point
// ---------------------------------------------------------------------------

/// Install SIGINT/SIGTERM handlers that forward to Command.quit via the bus.
/// Returns a SignalWatcher that must be kept alive and deinit'd on shutdown.
pub fn install(
    io: std.Io,
    gpa: std.mem.Allocator,
    bus: *core.Bus,
) !*SignalWatcher {
    // Heap-allocate the flag so the C handler can reach it via g_flag.
    const flag = try gpa.create(std.atomic.Value(bool));
    flag.* = std.atomic.Value(bool).init(false);
    errdefer gpa.destroy(flag);

    const watcher = try gpa.create(SignalWatcher);
    errdefer gpa.destroy(watcher);

    if (builtin.os.tag != .windows) {
        // Store in the global so the C-callable handler can reach it.
        g_flag = flag;

        // Install handlers for SIGINT and SIGTERM.
        const handler = std.posix.Sigaction{
            .handler = .{ .handler = sig_handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &handler, null);
        std.posix.sigaction(std.posix.SIG.TERM, &handler, null);

        // Spawn the polling task.
        const task = io.async(pollLoop, .{ io, flag, bus });

        watcher.* = SignalWatcher{
            .flag = flag,
            .gpa = gpa,
            .task = task,
        };
    } else {
        // Windows v0.1 stub: no graceful signal handling.
        // Ctrl-C will kill the process the OS way.
        std.log.warn("platform/signals: graceful signal handling not implemented on Windows (v0.1)", .{});

        watcher.* = SignalWatcher{
            .flag = flag,
            .gpa = gpa,
            .task = {},
        };
    }

    return watcher;
}

// ---------------------------------------------------------------------------
// C-callable signal handler — sets the atomic flag only.
// Must be reentrant: no allocations, no locks, no I/O.
// ---------------------------------------------------------------------------

// On POSIX, `std.posix.SIG` is the platform's native signal-number type
// (e.g. `os.linux.SIG__enum_*`).  On Windows it aliases `void`, which is
// not a valid fn parameter type.  We declare `sigHandler` inside a comptime
// container that exists only on non-Windows targets so its signature is
// never semantically analyzed when targeting Windows.
const sig_handler = if (builtin.os.tag != .windows) struct {
    fn handler(sig: std.posix.SIG) callconv(std.builtin.CallingConvention.c) void {
        _ = sig;
        if (g_flag) |f| {
            f.store(true, .release);
        }
    }
}.handler else {};

// ---------------------------------------------------------------------------
// Polling task — checks the flag every 100ms and sends Command.quit once.
// Declared as returning `anyerror!void` so Future(anyerror!void) matches.
// ---------------------------------------------------------------------------

fn pollLoop(
    io: std.Io,
    flag: *std.atomic.Value(bool),
    bus: *core.Bus,
) anyerror!void {
    while (true) {
        if (flag.load(.acquire)) {
            bus.ui_to_player.send(io, .quit) catch {};
            return;
        }
        std.Io.sleep(
            io,
            .{ .nanoseconds = 100 * std.time.ns_per_ms },
            .awake,
        ) catch |err| {
            // error.Canceled means the watcher was deinit'd — exit cleanly.
            if (err == error.Canceled) return;
            return err;
        };
    }
}
