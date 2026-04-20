/// audio/output.zig — miniaudio device wrapper with a lock-free SPSC PCM ring.
///
/// The miniaudio data callback runs on miniaudio's own thread and is
/// hard-realtime: no allocations, no io.* calls, no logging inside it.
/// The ring buffer is the only shared state between the pipeline task
/// (producer) and the callback (consumer).
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

// Ring capacity: ~500 ms at 44.1 kHz stereo = 44100 * 2 * 0.5 = 44100 samples.
// Round up to the next power of two for efficient index masking.
pub const RING_CAPACITY: usize = 65536; // 2^16 ≈ 742ms headroom

/// Lock-free SPSC ring buffer for i16 PCM samples.
/// Producer writes with writeSamples; consumer (miniaudio callback) reads with readSamples.
/// Uses two monotonically increasing usize atomics (head and tail) masked with (RING_CAPACITY-1).
pub const Ring = struct {
    buf: []i16,
    /// Next index to read (consumer-owned).
    head: std.atomic.Value(usize),
    /// Next index to write (producer-owned).
    tail: std.atomic.Value(usize),

    pub fn init(gpa: Allocator) Allocator.Error!Ring {
        const buf = try gpa.alloc(i16, RING_CAPACITY);
        @memset(buf, 0);
        return Ring{
            .buf = buf,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *Ring, gpa: Allocator) void {
        gpa.free(self.buf);
    }

    /// Returns how many samples are currently in the ring.
    pub fn available(self: *const Ring) usize {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        return (t -% h) & (RING_CAPACITY - 1);
    }

    /// Returns how many samples can be written without blocking.
    pub fn freeSpace(self: *const Ring) usize {
        // Leave one slot free to distinguish full from empty.
        return RING_CAPACITY - 1 - self.available();
    }

    /// Producer: write up to samples.len samples. Returns samples actually written.
    pub fn writeSamples(self: *Ring, samples: []const i16) usize {
        const t = self.tail.load(.monotonic);
        const h = self.head.load(.acquire);
        const free = (RING_CAPACITY - 1) - ((t -% h) & (RING_CAPACITY - 1));
        const count = @min(samples.len, free);
        for (0..count) |i| {
            self.buf[(t +% i) & (RING_CAPACITY - 1)] = samples[i];
        }
        if (count > 0) {
            self.tail.store((t +% count) & (RING_CAPACITY - 1), .release);
        }
        return count;
    }

    /// Consumer (callback): read up to out.len samples. Returns samples read.
    pub fn readSamples(self: *Ring, out: []i16) usize {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        const avail = (t -% h) & (RING_CAPACITY - 1);
        const count = @min(out.len, avail);
        for (0..count) |i| {
            out[i] = self.buf[(h +% i) & (RING_CAPACITY - 1)];
        }
        if (count > 0) {
            self.head.store((h +% count) & (RING_CAPACITY - 1), .release);
        }
        return count;
    }
};

/// Shared state between the Output struct and the miniaudio data callback.
/// Heap-allocated so the pointer stays valid even if Output is moved.
const SharedState = struct {
    ring: Ring,
    /// 0..100 percent; applied inside the callback via integer scale.
    volume: std.atomic.Value(u8),
    /// When true the callback writes silence instead of ring data.
    paused: std.atomic.Value(bool),
};

/// Output wraps a miniaudio playback device.
///
/// IMPORTANT: `device` is heap-allocated (via gpa.create) so that its address
/// remains stable after this struct is returned from initImpl. miniaudio's
/// internal worker thread stores a pointer to the ma_device it was given during
/// ma_device_init_ex; if the device were stored inline (by value) in Output,
/// copying the struct on return would leave that internal pointer dangling and
/// cause ma_device_uninit (or any subsequent ma_device_* call) to hang or crash.
pub const Output = struct {
    /// Heap-allocated so its address is stable for miniaudio's internal threads.
    device: *c.ma_device,
    state: *SharedState,
    gpa: Allocator,

    /// Initialize with the system default backend.
    pub fn init(gpa: Allocator) !Output {
        return initImpl(gpa, null, 0);
    }

    /// Initialize with the null (no-op) backend for use in tests.
    pub fn initNull(gpa: Allocator) !Output {
        const backends = [_]c.ma_backend{c.ma_backend_null};
        return initImpl(gpa, &backends, backends.len);
    }

    fn initImpl(gpa: Allocator, backends: ?[*]const c.ma_backend, backend_count: u32) !Output {
        const state = try gpa.create(SharedState);
        errdefer gpa.destroy(state);
        state.* = SharedState{
            .ring = try Ring.init(gpa),
            .volume = std.atomic.Value(u8).init(60),
            .paused = std.atomic.Value(bool).init(false),
        };
        errdefer state.ring.deinit(gpa);

        // Heap-allocate the device so the pointer passed to ma_device_init_ex
        // stays valid for the lifetime of this Output — miniaudio's worker thread
        // holds this pointer and must not see it invalidated by a struct copy.
        const device = try gpa.create(c.ma_device);
        errdefer gpa.destroy(device);

        var cfg = c.ma_device_config_init(c.ma_device_type_playback);
        cfg.playback.format = c.ma_format_s16;
        cfg.playback.channels = 2;
        cfg.sampleRate = 44100;
        cfg.dataCallback = dataCallback;
        cfg.pUserData = state;

        const result = c.ma_device_init_ex(backends, backend_count, null, &cfg, device);
        if (result != c.MA_SUCCESS) {
            return error.AudioDeviceInit;
        }
        errdefer c.ma_device_uninit(device);

        return Output{
            .device = device,
            .state = state,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Output) void {
        c.ma_device_uninit(self.device);
        self.gpa.destroy(self.device);
        self.state.ring.deinit(self.gpa);
        self.gpa.destroy(self.state);
    }

    pub fn start(self: *Output) !void {
        if (c.ma_device_start(self.device) != c.MA_SUCCESS) {
            return error.AudioDeviceStart;
        }
    }

    pub fn stop(self: *Output) !void {
        if (c.ma_device_stop(self.device) != c.MA_SUCCESS) {
            return error.AudioDeviceStop;
        }
    }

    pub fn setVolume(self: *Output, percent: u8) void {
        self.state.volume.store(percent, .release);
    }

    pub fn setPaused(self: *Output, paused: bool) void {
        self.state.paused.store(paused, .release);
    }

    /// Producer side. Write PCM samples into the ring buffer.
    /// Returns the number of samples actually written; if less than samples.len,
    /// the caller must retry after yielding.
    pub fn writePcm(self: *Output, samples: []const i16) usize {
        return self.state.ring.writeSamples(samples);
    }

    /// Producer signal: no more samples for the current track.
    /// The device drains naturally; there is no special marker in the ring.
    pub fn markTrackBoundary(_: *Output) void {
        // Intentionally a no-op: the pipeline task detects EOF from the decoder
        // and emits track_ended once the ring drains. No glitch occurs because
        // the callback simply fills silence on underrun.
    }

    /// Expose the ring for white-box tests (audio_output_test.zig).
    pub fn testRing(self: *Output) *Ring {
        return &self.state.ring;
    }
};

/// miniaudio data callback — runs on miniaudio's internal thread.
/// Hard-realtime context: no allocations, no io.*, no logging.
fn dataCallback(
    device: ?*c.ma_device,
    pOutput: ?*anyopaque,
    pInput: ?*const anyopaque,
    frameCount: c.ma_uint32,
) callconv(std.builtin.CallingConvention.c) void {
    _ = pInput;
    const dev = device orelse return;
    const out_ptr = pOutput orelse return;

    const state: *SharedState = @ptrCast(@alignCast(dev.pUserData));
    const sample_count: usize = @as(usize, frameCount) * 2; // stereo
    const out_samples: [*]i16 = @ptrCast(@alignCast(out_ptr));

    if (state.paused.load(.acquire)) {
        @memset(out_samples[0..sample_count], 0);
        return;
    }

    const written = state.ring.readSamples(out_samples[0..sample_count]);
    // Fill remainder with silence on underrun.
    if (written < sample_count) {
        @memset(out_samples[written..sample_count], 0);
    }

    // Apply volume as integer scale: out = sample * vol / 100.
    const vol: i32 = @intCast(state.volume.load(.acquire));
    if (vol != 100) {
        for (0..sample_count) |i| {
            const s: i32 = @intCast(out_samples[i]);
            out_samples[i] = @intCast(@divTrunc(s * vol, 100));
        }
    }
}
