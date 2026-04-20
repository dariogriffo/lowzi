/// Re-export the translate-c generated audio_c module.
/// Other files in audio/ import this as `@import("c.zig").c`.
pub const c = @import("audio_c");
