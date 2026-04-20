/// source — manifest fetch + sync + per-track download.
///
/// Each sub-module is independent; root.zig is the barrel.
pub const Manifest = @import("manifest.zig").Manifest;
pub const manifest = @import("manifest.zig");
pub const m3u8 = @import("m3u8.zig");
pub const downloader = @import("downloader.zig");
pub const sync = @import("sync.zig");
