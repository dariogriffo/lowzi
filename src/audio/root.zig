/// audio/ — miniaudio + dr_mp3 bindings, ring-buffered PCM output, and pipeline.
///
/// Public API:
///   Output   — miniaudio device wrapper with lock-free SPSC PCM ring.
///   Decoder  — dr_mp3 pull-mode decoder.
///   pipeline — async task; call pipeline.run(io, gpa, cfg, &bus).
///   c        — re-exported translate-c bindings (audio_c module).
pub const Output = @import("output.zig").Output;
pub const Ring = @import("output.zig").Ring;
pub const RING_CAPACITY = @import("output.zig").RING_CAPACITY;
pub const Decoder = @import("decoder.zig").Decoder;
pub const pipeline = @import("pipeline.zig");
pub const c = @import("c.zig").c;
