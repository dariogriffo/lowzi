/// audio/pipeline.zig — async task that ties decoder + ring buffer together.
///
/// Run with io.async(pipeline.run, .{ io, gpa, cfg, &bus }).
/// Consumes AudioCommand from bus.player_to_audio, decodes Track.bytes
/// chunk by chunk, pushes PCM via output.writePcm, and emits AudioEvents
/// on bus.audio_to_player.
///
/// error.Canceled is the clean shutdown path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Output = @import("output.zig").Output;
const Decoder = @import("decoder.zig").Decoder;

/// Scratch buffer size in samples (interleaved stereo): 4096 * 2 = 8192 samples.
const DECODE_BUF_SAMPLES: usize = 8192;

/// Milliseconds between progress events.
const PROGRESS_INTERVAL_MS: u32 = 1000;

pub fn run(io: std.Io, gpa: Allocator, cfg: core.Config, bus: *core.Bus) !void {
    return runWith(io, gpa, cfg, bus, false);
}

/// Same as run but initializes the real audio device instead of the null backend.
/// Used by the smoke test (-Dsmoke=true) which actually plays audio.
pub fn runReal(io: std.Io, gpa: Allocator, cfg: core.Config, bus: *core.Bus) !void {
    return runWith(io, gpa, cfg, bus, true);
}

fn runWith(io: std.Io, gpa: Allocator, cfg: core.Config, bus: *core.Bus, real_device: bool) !void {
    _ = cfg;

    var output = if (real_device) try Output.init(gpa) else try Output.initNull(gpa);
    defer output.deinit();
    try output.start();

    var volume: u8 = 60;
    var paused: bool = false;

    outer: while (true) {
        const cmd = bus.player_to_audio.recv(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return,
        };

        switch (cmd) {
            .quit => {
                // Acknowledge quit so the player controller can exit.
                // Without this, the controller's quitting loop would never
                // see track_ended/device_lost and would hang.
                bus.audio_to_player.send(io, .track_ended) catch {};
                return;
            },
            .pause => |p| {
                paused = p;
                output.setPaused(paused);
            },
            .set_volume => |v| {
                volume = v;
                output.setVolume(volume);
            },
            .stop_current => {
                // Drain the ring so the next track starts cleanly.
                _ = output.testRing().readSamples(
                    &([_]i16{0} ** 0),
                );
            },
            .play => |track| {
                const bytes = track.bytes orelse continue :outer;

                var decoder = Decoder.init(gpa, bytes) catch |err| {
                    const msg: []const u8 = switch (err) {
                        error.UnsupportedFormat => "unsupported format",
                        error.Corrupt => "corrupt data",
                    };
                    bus.audio_to_player.send(io, .{ .decode_failed = msg }) catch {};
                    continue :outer;
                };
                defer decoder.deinit();

                const duration = decoder.durationMs();
                bus.audio_to_player.send(io, .{ .track_started = .{ .duration_ms = duration } }) catch |err| switch (err) {
                    error.Closed => return,
                    error.Canceled => return,
                };

                var scratch: [DECODE_BUF_SAMPLES]i16 = undefined;
                var elapsed_samples: u64 = 0;
                const sample_rate = decoder.sampleRate();
                const ch = decoder.channels();
                const samples_per_progress: u64 = if (sample_rate > 0 and ch > 0)
                    @as(u64, sample_rate) * @as(u64, ch) * PROGRESS_INTERVAL_MS / 1000
                else
                    std.math.maxInt(u64);
                var last_progress_samples: u64 = 0;

                decode_loop: while (true) {
                    // Check for incoming commands (non-blocking) before decoding.
                    while (bus.player_to_audio.tryRecv(io)) |incoming| {
                        switch (incoming) {
                            .quit => {
                                bus.audio_to_player.send(io, .track_ended) catch {};
                                return;
                            },
                            .stop_current => break :decode_loop,
                            .pause => |p| {
                                paused = p;
                                output.setPaused(paused);
                            },
                            .set_volume => |v| {
                                volume = v;
                                output.setVolume(volume);
                            },
                            .play => {
                                // New track while current is playing: discard and restart.
                                // (player should send stop_current first, but handle gracefully.)
                                break :decode_loop;
                            },
                        }
                    }

                    const n = decoder.readFrames(&scratch);
                    if (n == 0) break :decode_loop; // EOF

                    // Push PCM with backpressure: retry until all samples are written.
                    var written: usize = 0;
                    while (written < n) {
                        const w = output.writePcm(scratch[written..n]);
                        written += w;
                        if (written < n) {
                            // Ring is full; sleep 1ms to let the callback drain some.
                            // io.sleep is cancelable, so this also acts as a cooperative
                            // cancellation point.
                            std.Io.sleep(
                                io,
                                std.Io.Duration.fromMilliseconds(1),
                                .awake,
                            ) catch return;
                        }
                    }

                    elapsed_samples += n;
                    if (elapsed_samples - last_progress_samples >= samples_per_progress) {
                        last_progress_samples = elapsed_samples;
                        const elapsed_ms: u32 = if (sample_rate > 0 and ch > 0)
                            @intCast(@min(
                                elapsed_samples * 1000 / (@as(u64, sample_rate) * @as(u64, ch)),
                                std.math.maxInt(u32),
                            ))
                        else
                            0;
                        bus.audio_to_player.send(io, .{ .progress = elapsed_ms }) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return,
                        };
                    }
                }

                output.markTrackBoundary();
                bus.audio_to_player.send(io, .track_ended) catch |err| switch (err) {
                    error.Closed => return,
                    error.Canceled => return,
                };
            },
        }
    }
}
