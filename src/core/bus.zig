/// Bus — the single source of truth for inter-module channel wiring.
///
/// `main` is the only place that knows the full graph. All other modules
/// receive only the channel ends they need, not the entire Bus.
const std = @import("std");
const Allocator = std.mem.Allocator;
const message = @import("message.zig");
const Channel = @import("channel.zig").Channel;
const Config = @import("config.zig").Config;

pub const Bus = struct {
    ui_to_player: Channel(message.Command),
    player_to_ui: Channel(message.Event),
    player_to_source: Channel(message.SourceRequest),
    source_to_player: Channel(message.SourceResponse),
    player_to_audio: Channel(message.AudioCommand),
    audio_to_player: Channel(message.AudioEvent),
    /// Sync task → player: signals sync_completed / sync_failed so the
    /// player can start filling the queue without the signal routing
    /// through the UI-bound player_to_ui channel.
    sync_to_player: Channel(message.SyncMsg),

    /// Initialize all channels. Capacity is driven by cfg.buffer_size where
    /// it makes sense; command channels use a small fixed capacity.
    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Bus {
        const cmd_cap: usize = 16;
        const evt_cap: usize = 32;
        const src_cap: usize = cfg.buffer_size;
        const aud_cap: usize = 8;
        const sync_cap: usize = 4;

        var ui_to_player = try Channel(message.Command).init(gpa, cmd_cap);
        errdefer ui_to_player.deinit(gpa);

        var player_to_ui = try Channel(message.Event).init(gpa, evt_cap);
        errdefer player_to_ui.deinit(gpa);

        var player_to_source = try Channel(message.SourceRequest).init(gpa, src_cap);
        errdefer player_to_source.deinit(gpa);

        var source_to_player = try Channel(message.SourceResponse).init(gpa, src_cap);
        errdefer source_to_player.deinit(gpa);

        var player_to_audio = try Channel(message.AudioCommand).init(gpa, aud_cap);
        errdefer player_to_audio.deinit(gpa);

        var audio_to_player = try Channel(message.AudioEvent).init(gpa, aud_cap);
        errdefer audio_to_player.deinit(gpa);

        var sync_to_player = try Channel(message.SyncMsg).init(gpa, sync_cap);
        errdefer sync_to_player.deinit(gpa);

        return Bus{
            .ui_to_player = ui_to_player,
            .player_to_ui = player_to_ui,
            .player_to_source = player_to_source,
            .source_to_player = source_to_player,
            .player_to_audio = player_to_audio,
            .audio_to_player = audio_to_player,
            .sync_to_player = sync_to_player,
        };
    }

    pub fn deinit(self: *Bus, gpa: Allocator) void {
        self.ui_to_player.deinit(gpa);
        self.player_to_ui.deinit(gpa);
        self.player_to_source.deinit(gpa);
        self.source_to_player.deinit(gpa);
        self.player_to_audio.deinit(gpa);
        self.audio_to_player.deinit(gpa);
        self.sync_to_player.deinit(gpa);
    }
};
