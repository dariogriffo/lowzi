/// core — shared vocabulary for the lowzi project.
///
/// No I/O threads. No vaxis. No miniaudio. Pure data types and one channel
/// primitive. Other modules import only this root.
pub const cli = @import("cli.zig");
pub const Config = @import("config.zig").Config;
pub const paths = @import("paths.zig");
pub const Track = @import("track.zig").Track;
pub const message = @import("message.zig");
pub const Channel = @import("channel.zig").Channel;
pub const Bus = @import("bus.zig").Bus;
pub const errors = @import("errors.zig");
pub const log = @import("log.zig");
