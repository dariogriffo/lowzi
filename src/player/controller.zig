/// player/controller.zig — the player task body.
///
/// Spawns three selector tasks that each recv on one external channel and
/// forward into a single internal Channel(InternalMsg).  The main loop pulls
/// from the internal channel and dispatches.
///
/// For testability, `run` delegates to `runWith` which accepts an injectable
/// fetch function.  Tests supply a fake; production uses downloader.fetch.
const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const source = @import("source");
const queue_mod = @import("queue.zig");
const bookmark_mod = @import("bookmark.zig");
const state_mod = @import("state.zig");

pub const BodyFetchFn = queue_mod.BodyFetchFn;

// ---------------------------------------------------------------------------
// Internal message type — all external channels funnel into this.
// ---------------------------------------------------------------------------

const InternalMsg = union(enum) {
    user_cmd: core.message.Command,
    audio_evt: core.message.AudioEvent,
    track_ready: core.Track,
    fetch_failed,
    sync_msg: core.message.SyncMsg,
};

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Production entry point. Uses the real HTTP downloader.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    bus: *core.Bus,
    conn: *storage.Conn,
) !void {
    return runWith(io, gpa, cfg, bus, conn, defaultFetchFn);
}

/// Testable entry point — caller supplies a fake BodyFetchFn.
pub fn runWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    bus: *core.Bus,
    conn: *storage.Conn,
    fetch_fn: BodyFetchFn,
) !void {
    // Internal multiplex channel — all selector tasks send here.
    var internal = try core.Channel(InternalMsg).init(gpa, 64);
    // Cleanup ordering (LIFO defers):
    //   1. internal.close      — declared LAST, runs FIRST, unblocks workers
    //   2. fetch_group.cancel  — waits for workers (they can now exit)
    //   3. *_sel_task.cancel   — cancel selectors
    //   4. drainInternal       — free any track_ready messages left in buffer
    //   5. internal.deinit     — declared FIRST, runs LAST, frees ring buffer
    defer internal.deinit(gpa);
    // Drain residual track_ready messages so their bytes are freed before
    // internal.deinit frees the ring buffer.  This runs just before deinit
    // (LIFO: declared 2nd → runs 2nd-to-last, after all task cancels).
    defer drainInternalTrackReady(&internal, gpa, io);

    // --- Selector task 1: ui_to_player → internal ---
    const UiSel = struct {
        fn run(sio: std.Io, ch_ui: *core.Channel(core.message.Command), ch_int: *core.Channel(InternalMsg)) void {
            while (true) {
                const cmd = ch_ui.recv(sio) catch return;
                ch_int.send(sio, .{ .user_cmd = cmd }) catch return;
            }
        }
    };
    var ui_sel_task = io.async(UiSel.run, .{ io, &bus.ui_to_player, &internal });
    defer ui_sel_task.cancel(io);

    // --- Selector task 2: audio_to_player → internal ---
    const AudioSel = struct {
        fn run(sio: std.Io, ch_audio: *core.Channel(core.message.AudioEvent), ch_int: *core.Channel(InternalMsg)) void {
            while (true) {
                const evt = ch_audio.recv(sio) catch return;
                ch_int.send(sio, .{ .audio_evt = evt }) catch return;
            }
        }
    };
    var audio_sel_task = io.async(AudioSel.run, .{ io, &bus.audio_to_player, &internal });
    defer audio_sel_task.cancel(io);

    // --- Selector task 3: sync_to_player → internal ---
    const SyncSel = struct {
        fn run(sio: std.Io, ch_sync: *core.Channel(core.message.SyncMsg), ch_int: *core.Channel(InternalMsg)) void {
            while (true) {
                const msg = ch_sync.recv(sio) catch return;
                ch_int.send(sio, .{ .sync_msg = msg }) catch return;
            }
        }
    };
    var sync_sel_task = io.async(SyncSel.run, .{ io, &bus.sync_to_player, &internal });
    defer sync_sel_task.cancel(io);

    // Group for fire-and-forget fetch workers.  Cancelled when the controller
    // exits; tasks that have already posted their result just return early.
    var fetch_group = std.Io.Group.init;
    // NOTE: fetch_group and internal cleanup are performed explicitly below to
    // ensure we drain the internal channel AFTER all tasks have stopped.
    // The defer order here (internal.close first) unblocks workers before
    // fetch_group.cancel waits for them.
    defer fetch_group.cancel(io);
    defer internal.close(io);

    // Main controller state.
    var state = state_mod.State{};
    defer state.deinit(gpa);

    // True when a fetch worker is in flight; we allow at most one at a time.
    var in_flight: bool = false;
    // True after we've emitted network_stalled once in the current fill pass.
    // Reset when sync_completed arrives so we can emit again if needed.
    var catalog_empty_notified: bool = false;
    // Set to true when the user has requested quit. We continue processing
    // the internal channel until we get the audio ack, then return.
    var quitting: bool = false;

    // Kick the first fill pass — at startup state.sync_in_progress == true
    // so fill will be a no-op until sync_completed arrives.
    maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);

    // -------------------------------------------------------------------------
    // Main dispatch loop
    // -------------------------------------------------------------------------
    while (true) {
        const msg = internal.recv(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return;
        };

        // While quitting, only care about audio events that confirm shutdown.
        // We still free any track_ready bytes to avoid leaks.
        if (quitting) {
            switch (msg) {
                .audio_evt => |evt| switch (evt) {
                    .track_ended, .device_lost => {
                        bus.player_to_ui.send(io, .quit) catch {};
                        return;
                    },
                    else => {},
                },
                .track_ready => |track| {
                    // Free all worker-owned fields; we won't play them.
                    var t = track;
                    t.deinit(gpa);
                    in_flight = false;
                },
                else => {},
            }
            continue;
        }

        switch (msg) {

            // -----------------------------------------------------------------
            // Front-end commands
            // -----------------------------------------------------------------

            .user_cmd => |cmd| {
                switch (cmd) {
                    .quit => {
                        // Tell audio to quit and wait for the ack via our
                        // selector task (avoids racing with AudioSel on
                        // audio_to_player).
                        bus.player_to_audio.send(io, .quit) catch {};
                        quitting = true;
                    },

                    .skip => {
                        if (state.current) |cur| {
                            // Mark as skipped in the DB.
                            storage.queries.markTrackSkipped(conn, @intCast(cur.id)) catch {};
                            // Ask audio to stop. We do NOT advance yet — we
                            // wait for the audio track_ended echo to avoid a
                            // race between stop_current and the next play.
                            bus.player_to_audio.send(io, .stop_current) catch {};
                        }
                    },

                    .toggle_pause => {
                        if (state.applyCommand(cmd)) |evt| {
                            bus.player_to_audio.send(io, .{ .pause = state.paused }) catch {};
                            bus.player_to_ui.send(io, evt) catch {};
                        }
                    },

                    .volume_delta => {
                        if (state.applyCommand(cmd)) |evt| {
                            bus.player_to_audio.send(io, .{ .set_volume = state.volume }) catch {};
                            bus.player_to_ui.send(io, evt) catch {};
                        }
                    },

                    .bookmark => {
                        if (state.current) |cur| {
                            const track_id: i64 = @intCast(cur.id);
                            const now_bookmarked = bookmark_mod.toggle(conn, track_id) catch false;
                            if (now_bookmarked) {
                                bus.player_to_ui.send(io, .{ .bookmark_added = cur.display_name }) catch {};
                            } else {
                                bus.player_to_ui.send(io, .{ .bookmark_removed = cur.display_name }) catch {};
                            }
                        }
                    },
                }
            },

            // -----------------------------------------------------------------
            // Audio events
            // -----------------------------------------------------------------

            .audio_evt => |evt| {
                switch (evt) {
                    .track_started => |info| {
                        _ = info;
                        if (state.current) |cur| {
                            state.recordRecent(@intCast(cur.id));
                            bus.player_to_ui.send(io, .{ .track_started = cur }) catch {};
                        }
                    },

                    .progress => |elapsed_ms| {
                        const dur: ?u32 = if (state.current) |c| c.duration_hint else null;
                        bus.player_to_ui.send(io, .{
                            .track_progress = .{
                                .elapsed_ms = elapsed_ms,
                                .duration_ms = dur,
                            },
                        }) catch {};
                    },

                    .track_ended => {
                        if (state.current) |cur| {
                            storage.queries.markTrackPlayed(conn, @intCast(cur.id)) catch {};
                        }
                        if (state.advance(gpa)) |next| {
                            bus.player_to_audio.send(io, .{ .play = next }) catch {};
                        }
                        maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);
                    },

                    .decode_failed => |reason| {
                        bus.player_to_ui.send(io, .{ .decode_failed = reason }) catch {};
                        if (state.advance(gpa)) |next| {
                            bus.player_to_audio.send(io, .{ .play = next }) catch {};
                        }
                        maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);
                    },

                    .device_lost => {
                        bus.player_to_ui.send(io, .audio_device_lost) catch {};
                    },
                }
            },

            // -----------------------------------------------------------------
            // Fetch worker results
            // -----------------------------------------------------------------

            .track_ready => |track| {
                in_flight = false;
                var t = track;
                const pushed = state.pushTrack(gpa, cfg.buffer_size, t) catch blk: {
                    t.deinit(gpa);
                    break :blk false;
                };
                if (pushed) {
                    if (state.current == null) {
                        if (state.advance(gpa)) |next| {
                            bus.player_to_audio.send(io, .{ .play = next }) catch {};
                        }
                    }
                } else {
                    t.deinit(gpa);
                }
                maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);
            },

            .fetch_failed => {
                in_flight = false;
                bus.player_to_ui.send(io, .network_stalled) catch {};
            },

            // -----------------------------------------------------------------
            // Sync signals
            // -----------------------------------------------------------------

            .sync_msg => |smsg| {
                switch (smsg) {
                    .completed => {
                        state.sync_in_progress = false;
                        catalog_empty_notified = false;
                        bus.player_to_ui.send(io, .sync_completed) catch {};
                        maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);
                    },
                    .failed => |reason| {
                        state.sync_in_progress = false;
                        bus.player_to_ui.send(io, .{ .sync_failed = reason }) catch {};
                        maybeFill(io, gpa, cfg, conn, &state, &internal, &fetch_group, &in_flight, &catalog_empty_notified, fetch_fn);
                    },
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Fill-queue helper
// ---------------------------------------------------------------------------

/// Attempt to schedule a fetch if conditions are met:
///   - queue is not full
///   - no fetch is in flight
///   - sync has completed (DB may have tracks)
fn maybeFill(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    conn: *storage.Conn,
    state: *state_mod.State,
    internal: *core.Channel(InternalMsg),
    fetch_group: *std.Io.Group,
    in_flight: *bool,
    catalog_empty_notified: *bool,
    fetch_fn: BodyFetchFn,
) void {
    if (state.sync_in_progress) return;
    if (in_flight.*) return;
    if (state.queue.items.len >= cfg.buffer_size) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const row_or_null = queue_mod.pickCandidate(conn, arena.allocator(), state.recent_ids.slice()) catch return;
    if (row_or_null == null) {
        if (!catalog_empty_notified.*) {
            catalog_empty_notified.* = true;
        }
        return;
    }

    const row = row_or_null.?;

    // Duplicate strings so the worker owns them (the arena above is freed
    // before the worker runs).
    const url_copy = gpa.dupe(u8, row.url) catch return;
    const display_copy: ?[]u8 = if (row.display_name) |dn| gpa.dupe(u8, dn) catch null else null;
    const track_id: u64 = @bitCast(row.id);
    const dur = row.duration_ms;

    in_flight.* = true;
    catalog_empty_notified.* = false;

    const FetchWorker = struct {
        fn run(
            wio: std.Io,
            wgpa: std.mem.Allocator,
            wcfg: core.Config,
            wurl: []u8,
            wdisplay: ?[]u8,
            wtid: u64,
            wdur: ?u32,
            wfetch_fn: BodyFetchFn,
            ch: *core.Channel(InternalMsg),
        ) void {
            // NOTE: wurl and wdisplay ownership is transferred to the track on
            // success.  We must free them only on failure paths.

            const bytes = wfetch_fn(wio, wgpa, wcfg, wurl) catch {
                // Fetch failed — release our allocations and signal caller.
                wgpa.free(wurl);
                if (wdisplay) |dn| wgpa.free(dn);
                ch.send(wio, .fetch_failed) catch {};
                return;
            };

            // Choose display name: prefer DB value, fall back to URL basename.
            // We need an independent gpa-owned copy distinct from wurl because
            // Track.deinit (owned_strings=true) will free both display_name
            // and source_uri separately.
            const name: []u8 = if (wdisplay) |dn| dn else blk: {
                const tail = std.fs.path.basename(wurl);
                // If dupe fails, fall back to duplicating the full URL rather
                // than aliasing wurl (which would cause a double-free).
                break :blk wgpa.dupe(u8, tail) catch wgpa.dupe(u8, wurl) catch {
                    // Truly OOM: free everything and bail out.
                    wgpa.free(wurl);
                    wgpa.free(bytes);
                    ch.send(wio, .fetch_failed) catch {};
                    return;
                };
            };

            var track = core.Track{
                .id = wtid,
                .display_name = name,
                .source_uri = wurl,
                .duration_hint = wdur,
                .bytes = bytes,
                .owned_strings = true,
            };

            ch.send(wio, .{ .track_ready = track }) catch {
                // Channel closed — we still own the track; free everything via deinit.
                // Also free source_uri (wurl) since deinit won't duplicate the free.
                track.deinit(wgpa);
            };
            // On success ownership of wurl/name/bytes is held by the track
            // inside the channel message.
        }
    };

    // Spawn in the group: fire-and-forget. The group is cancelled when the
    // controller exits, which signals any blocked send with error.Canceled.
    fetch_group.async(io, FetchWorker.run, .{
        io, gpa, cfg, url_copy, display_copy, track_id, dur, fetch_fn, internal,
    });
}

// ---------------------------------------------------------------------------
// Internal channel drain helper
// ---------------------------------------------------------------------------

/// Drain all messages remaining in the internal channel and free the bytes
/// of any .track_ready messages.  Called as a defer just before
/// `internal.deinit(gpa)` so that no allocated track data is leaked when the
/// controller exits while a fetch worker result is still buffered.
fn drainInternalTrackReady(ch: *core.Channel(InternalMsg), gpa: std.mem.Allocator, io: std.Io) void {
    while (true) {
        const msg = ch.tryRecv(io) orelse break;
        switch (msg) {
            .track_ready => |track| {
                var t = track;
                t.deinit(gpa);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Default fetch function wrapping the real downloader
// ---------------------------------------------------------------------------

fn defaultFetchFn(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) anyerror![]u8 {
    return source.downloader.fetch(io, gpa, cfg, url);
}
