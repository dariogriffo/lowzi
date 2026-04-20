/// audio/decoder.zig — dr_mp3 pull-mode decoder wrapper.
///
/// Format detection lives here so v2 can add FLAC/OGG behind a build flag
/// without touching pipeline.zig. v0.1 supports MP3 only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

/// MP3 magic bytes (first 2 bytes of a sync frame or ID3 tag).
const MP3_SYNC_WORD: u8 = 0xFF;
const MP3_ID3_HEADER = "ID3";

fn isMP3(bytes: []const u8) bool {
    if (bytes.len < 3) return false;
    // ID3 tag header
    if (std.mem.startsWith(u8, bytes, MP3_ID3_HEADER)) return true;
    // MPEG sync word: 0xFF 0xE* or 0xFF 0xF*
    if (bytes[0] == MP3_SYNC_WORD and (bytes[1] & 0xE0) == 0xE0) return true;
    return false;
}

pub const Decoder = struct {
    mp3: c.drmp3,
    /// We keep a reference to the input bytes so they outlive the decoder.
    /// The caller must ensure mp3_bytes is valid for the lifetime of the Decoder.
    _bytes_ref: []const u8,

    /// Initialize a decoder from an in-memory MP3 byte slice.
    /// Returns error.UnsupportedFormat if the bytes do not look like MP3.
    pub fn init(gpa: Allocator, mp3_bytes: []const u8) !Decoder {
        _ = gpa; // dr_mp3 uses its own internal allocation from the C heap.
        if (!isMP3(mp3_bytes)) return error.UnsupportedFormat;

        var mp3: c.drmp3 = undefined;
        const ok = c.drmp3_init_memory(&mp3, mp3_bytes.ptr, mp3_bytes.len, null);
        if (ok == 0) return error.Corrupt;

        return Decoder{
            .mp3 = mp3,
            ._bytes_ref = mp3_bytes,
        };
    }

    pub fn deinit(self: *Decoder) void {
        c.drmp3_uninit(&self.mp3);
    }

    pub fn sampleRate(self: *const Decoder) u32 {
        return self.mp3.sampleRate;
    }

    pub fn channels(self: *const Decoder) u8 {
        return @intCast(self.mp3.channels);
    }

    /// Returns an estimate of the total duration in milliseconds, or null if
    /// the MP3 does not contain enough info to determine it ahead of decoding.
    pub fn durationMs(self: *Decoder) ?u32 {
        const frame_count = c.drmp3_get_pcm_frame_count(&self.mp3);
        if (frame_count == 0) return null;
        const sr = self.mp3.sampleRate;
        if (sr == 0) return null;
        // frame_count is in PCM frames (one per channel set).
        const ms = @as(u64, frame_count) * 1000 / @as(u64, sr);
        if (ms > std.math.maxInt(u32)) return null;
        return @intCast(ms);
    }

    /// Read up to out.len / channels() interleaved PCM frames into out.
    /// Returns the number of i16 *samples* written (frames * channels).
    /// Returns 0 at EOF.
    pub fn readFrames(self: *Decoder, out: []i16) usize {
        const ch: u64 = self.mp3.channels;
        if (ch == 0) return 0;
        const frames_to_read: u64 = @as(u64, out.len) / ch;
        if (frames_to_read == 0) return 0;
        const frames_read = c.drmp3_read_pcm_frames_s16(&self.mp3, frames_to_read, out.ptr);
        return @intCast(frames_read * ch);
    }
};
