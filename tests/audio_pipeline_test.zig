/// Tests for audio/pipeline module.
///
/// The pipeline.run function opens a miniaudio device and interacts with the
/// Io.Threaded scheduler. Full integration tests that exercise device start/stop
/// live in the smoke test (-Dsmoke=true) to avoid CI hangs.
///
/// The tests here verify the pipeline's constituent components:
///   1. The pipeline entry point has the correct signature.
///   2. Decoder + Output ring integration (decode → writePcm, no device start).
///   3. Output.initNull succeeds without starting the device.
const std = @import("std");
const core = @import("core");
const audio = @import("audio");

const fixture_bytes = @embedFile("fixtures/sine_440hz_1s.mp3");

test "audio.pipeline: run function has correct signature" {
    // Verify the pipeline.run entry point is callable with the expected types.
    // Compile-time check — fails if the signature drifts.
    const RunFn = *const fn (std.Io, std.mem.Allocator, core.Config, *core.Bus) anyerror!void;
    const run_ptr: RunFn = &audio.pipeline.run;
    _ = run_ptr;
}

test "audio.pipeline: Output.initNull constructs and deinits" {
    // Verify that initNull (null miniaudio backend) does not hang or crash.
    // We intentionally do NOT call start() here — that spawns the device thread
    // and blocks until the thread signals startEvent, which requires the miniaudio
    // worker thread to be scheduled. In CI we have no guarantee about timing, and
    // actual device start/stop is tested in the smoke test.
    const gpa = std.testing.allocator;
    var output = try audio.Output.initNull(gpa);
    output.deinit();
}

test "audio.pipeline: Decoder decodes fixture and fills Output ring without starting device" {
    const gpa = std.testing.allocator;
    var decoder = try audio.Decoder.init(gpa, fixture_bytes);
    defer decoder.deinit();

    var output = try audio.Output.initNull(gpa);
    defer output.deinit();
    // NOTE: we do NOT call output.start() — we're testing the ring-fill logic,
    // not the actual audio playback. The ring is purely memory-based and works
    // without a started device.

    var scratch: [4096]i16 = undefined;
    var total_written: usize = 0;
    var frames_decoded: usize = 0;

    while (true) {
        const n = decoder.readFrames(&scratch);
        if (n == 0) break;
        frames_decoded += n;
        var written: usize = 0;
        while (written < n) {
            const w = output.writePcm(scratch[written..n]);
            written += w;
            if (written < n) {
                // Ring full; drain manually to unblock (in the real pipeline the
                // miniaudio callback drains it, but we don't have a running device).
                var drain: [1024]i16 = undefined;
                _ = output.testRing().readSamples(&drain);
            }
        }
        total_written += n;
    }

    try std.testing.expect(frames_decoded > 0);
    try std.testing.expect(total_written > 0);
}
