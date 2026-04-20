/// Tests for platform.signals.
///
/// We do NOT deliver real SIGINT/SIGTERM to the test process — that would kill
/// the test runner. Instead we use the test hook
/// `watcher._testTriggerForTesting()` to set the atomic flag directly and
/// verify the polling task sends Command.quit on the bus.
const std = @import("std");
const core = @import("core");
const platform = @import("platform");

// ---------------------------------------------------------------------------
// Io lifecycle — one instance shared across the file.
// ---------------------------------------------------------------------------

test "zunit:beforeAll" {
    std.testing.io_instance = .init(std.heap.page_allocator, .{});
}

test "zunit:afterAll" {
    std.testing.io_instance.deinit();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "platform.signals: install returns a non-null SignalWatcher" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var bus = try core.Bus.init(gpa, .{});
    defer bus.deinit(gpa);

    const watcher = try platform.signals.install(io, gpa, &bus);
    // deinit frees the watcher struct itself (heap-allocated).
    watcher.deinit(io);
}

test "platform.signals: trigger via test hook sends Command.quit to bus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var bus = try core.Bus.init(gpa, .{});
    defer bus.deinit(gpa);

    const watcher = try platform.signals.install(io, gpa, &bus);
    defer watcher.deinit(io);

    // Simulate a signal arriving by setting the atomic flag directly.
    watcher._testTriggerForTesting();

    // The polling task should detect the flag and send Command.quit.
    // Give it up to ~500ms to do so (10 attempts x 50ms).
    var received: bool = false;
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        if (bus.ui_to_player.tryRecv(io)) |cmd| {
            if (cmd == .quit) {
                received = true;
                break;
            }
        }
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch break;
    }

    try std.testing.expect(received);
}

test "platform.signals: deinit cancels the polling task cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var bus = try core.Bus.init(gpa, .{});
    defer bus.deinit(gpa);

    const watcher = try platform.signals.install(io, gpa, &bus);
    // deinit must not panic or hang.
    watcher.deinit(io);
    // If we reach here, the cancel completed without error.
}
