/// Tests for audio.Decoder (dr_mp3 wrapper).
/// Uses a tiny embedded MP3 fixture: 1 second of 440 Hz sine at 44.1 kHz mono.
const std = @import("std");
const audio = @import("audio");

const fixture_bytes = @embedFile("fixtures/sine_440hz_1s.mp3");

test "audio.Decoder: init + basic metadata" {
    const gpa = std.testing.allocator;
    var dec = try audio.Decoder.init(gpa, fixture_bytes);
    defer dec.deinit();

    try std.testing.expectEqual(@as(u32, 44100), dec.sampleRate());
    try std.testing.expectEqual(@as(u8, 1), dec.channels());
    // Duration should be close to 1000 ms; allow generous tolerance because
    // dr_mp3_get_pcm_frame_count requires a full scan pass on VBR files.
    if (dec.durationMs()) |ms| {
        try std.testing.expect(ms >= 900 and ms <= 1200);
    }
}

test "audio.Decoder: readFrames yields PCM > 0 until EOF" {
    const gpa = std.testing.allocator;
    var dec = try audio.Decoder.init(gpa, fixture_bytes);
    defer dec.deinit();

    var scratch: [1024]i16 = undefined;
    var total_samples: usize = 0;
    var calls: usize = 0;

    while (true) {
        const n = dec.readFrames(&scratch);
        if (n == 0) break;
        total_samples += n;
        calls += 1;
    }

    // At 44100 Hz mono, 1 second ≈ 44100 samples; expect at least half that.
    try std.testing.expect(total_samples >= 20000);
    // Multiple readFrames calls should be needed for 1024-sample chunks.
    try std.testing.expect(calls >= 10);
}

test "audio.Decoder: readFrames returns 0 at EOF (idempotent)" {
    const gpa = std.testing.allocator;
    var dec = try audio.Decoder.init(gpa, fixture_bytes);
    defer dec.deinit();

    var scratch: [4096]i16 = undefined;
    while (dec.readFrames(&scratch) != 0) {}
    // Second call after EOF must also return 0.
    try std.testing.expectEqual(@as(usize, 0), dec.readFrames(&scratch));
}

test "audio.Decoder: rejects non-MP3 bytes" {
    const gpa = std.testing.allocator;
    const not_mp3 = "not an mp3 file at all";
    try std.testing.expectError(error.UnsupportedFormat, audio.Decoder.init(gpa, not_mp3));
}
