/// Bounded MPSC channel built on std.Io.Queue (which uses Io.Mutex + Io.Condition).
///
/// API:
///   init(gpa, capacity) !Channel(T)
///   deinit(self, gpa)
///   send(self, io, value) !void       — blocks if full; error.Closed if closed
///   recv(self, io) !T                 — blocks if empty; error.Closed if closed and drained
///   tryRecv(self, io) ?T              — non-blocking; null when empty (requires io for mutex)
///   close(self, io) void
///
/// Note: `tryRecv` requires an `io` parameter because the underlying
/// std.Io.Queue uses a mutex for thread safety. The signature differs from
/// the brief's `tryRecv(self) ?T` because a truly lock-free tryRecv would
/// require a separate atomic counter and is not worth the complexity for
/// command-message channels. (The lock-free PCM ring in audio/output.zig is
/// the right tool for the audio callback.)
const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The backing storage; owned by this Channel.
        buf: []T,
        queue: std.Io.Queue(T),

        pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            const buf = try gpa.alloc(T, capacity);
            return Self{
                .buf = buf,
                .queue = std.Io.Queue(T).init(buf),
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buf);
        }

        /// Send one item, blocking if the channel is at capacity.
        /// Returns error.Closed if the channel has been closed.
        /// Returns error.Canceled on task cancellation.
        pub fn send(self: *Self, io: std.Io, value: T) (errors.ChannelError || error{Canceled})!void {
            self.queue.putOne(io, value) catch |err| switch (err) {
                error.Closed => return error.Closed,
                error.Canceled => return error.Canceled,
            };
        }

        /// Receive one item, blocking if the channel is empty.
        /// Returns error.Closed when the channel is closed and fully drained.
        /// Returns error.Canceled on task cancellation.
        pub fn recv(self: *Self, io: std.Io) (errors.ChannelError || error{Canceled})!T {
            return self.queue.getOne(io) catch |err| switch (err) {
                error.Closed => return error.Closed,
                error.Canceled => return error.Canceled,
            };
        }

        /// Non-blocking receive. Returns null when no item is immediately available.
        /// Requires io for the internal mutex; does not block waiting for items.
        pub fn tryRecv(self: *Self, io: std.Io) ?T {
            var buf: [1]T = undefined;
            // min=0: fill as much as possible without blocking.
            const n = self.queue.getUncancelable(io, &buf, 0) catch return null;
            if (n == 1) return buf[0];
            return null;
        }

        /// Close the channel. After this:
        ///   - Pending recv calls will drain buffered items then return error.Closed.
        ///   - Pending send calls return error.Closed.
        ///   - New send calls return error.Closed.
        pub fn close(self: *Self, io: std.Io) void {
            self.queue.close(io);
        }
    };
}
