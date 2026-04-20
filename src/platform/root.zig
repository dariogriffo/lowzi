/// platform/ — OS-level integrations: signal handling, MPRIS, etc.
///
/// Only imports core/. main.zig is the only caller.
pub const signals = @import("signals.zig");
