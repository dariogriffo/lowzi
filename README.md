# lowzi

> A minimal, terminal-native lofi player written in Zig.

<p align="left">
  <img alt="version"  src="https://img.shields.io/badge/version-0.1.0-blueviolet">
  <img alt="zig"      src="https://img.shields.io/badge/zig-0.16.0-f7a41d">
  <img alt="tests"    src="https://img.shields.io/badge/tests-196%20passing-brightgreen">
  <img alt="platform" src="https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20windows-lightgrey">
  <img alt="license"  src="https://img.shields.io/badge/license-MIT-blue">
</p>

lowzi streams a curated catalog of lofi tracks from a JSON manifest, keeps a
local SQLite catalog, and plays MP3 through a lock-free audio pipeline. No
browser, no Electron, no account — just a binary, your terminal, and the
music.

---

## Highlights

- **One small binary.** Single executable, no runtime, no daemon.
- **Offline-first catalog.** SQLite at `$XDG_DATA_HOME/lowzi/lowzi.db`;
  manifest syncs in the background and only downloads what changed.
- **Lock-free audio.** `miniaudio` + `dr_mp3`, SPSC PCM ring between the
  decoder and the device — no stutter on the UI thread because there is
  no UI thread.
- **Message-passing core.** Built on Zig 0.16's `std.Io` async tasks and
  typed channels; every module is independently testable.
- **Two front ends.**
  - `lowzi` — headless stdin/stdout harness (v0.1 front end; permanent smoke
    fixture).
  - `lowzi-basic` — pick the first track, play it, exit. Good as a demo and a
    CI canary.
- **Bring-your-own content.** Point the manifest URL at anything that
  serves the documented JSON + M3U8 format (Cloudflare R2, S3, a LAN
  `python3 -m http.server`, whatever).

---

## Quickstart

```bash
# Requires Zig 0.16.0 exact.
git clone https://github.com/dariogriffo/lowzi
cd lowzi

zig build                       # produces zig-out/bin/lowzi(-basic)
zig build test                  # 196 unit tests across ~30 suites
zig build test -Dsmoke=true     # + 1 real-device smoke (5s 440 Hz sine)
```

Run the headless player:

```bash
$ printf 'q\n' | ./zig-out/bin/lowzi
EVT sync_failed reason="..."    # placeholder manifest isn't reachable
EVT quit
```

> First run will emit `EVT sync_failed` until you configure a reachable
> manifest URL — see [Configuration](#configuration).

---

## Usage

lowzi speaks a line-oriented protocol over stdio. Commands in, events out.

**Input (stdin):**

| Command          | Meaning                               |
| ---------------- | ------------------------------------- |
| `play`           | Start or resume playback              |
| `pause`          | Pause the current track               |
| `next` / `prev`  | Skip forward / back                   |
| `playlist <id>`  | Switch to a playlist                  |
| `bookmark`       | Save current position                 |
| `q` / `quit`     | Graceful shutdown (also `SIGINT`)     |

**Output (stdout):**

```
EVT started     track_id=42 title="rain at 3am"
EVT position    ms=18240
EVT track_ended track_id=42
EVT sync_ok     added=3 removed=0
EVT quit
```

The format is `EVT <name> key=value` — greppable, scriptable, boringly
stable.

---

## Configuration

v0.1 is bring-your-own-manifest. The placeholder lives at
[`src/source/manifest.zig:14`](src/source/manifest.zig). Point it at a
reachable URL and rebuild:

```zig
pub const default_manifest_url = "https://your-host.example/manifest.json";
```

**Manifest format** (`manifest.json`):

```json
{
  "hash": "sha256-of-the-playlists-section",
  "playlists": [
    { "name": "mellow mornings", "url": "https://…/mellow.m3u8" },
    { "name": "deep focus",      "url": "https://…/focus.m3u8"  }
  ]
}
```

Each playlist URL returns an [RFC 8216](https://datatracker.ietf.org/doc/html/rfc8216)
subset M3U8 — `#EXTINF` plus one track URL per entry. Full contract in
[`docs/SPECIFICATION.md §4.5`](docs/SPECIFICATION.md).

**Local test recipe** (no cloud required):

```bash
mkdir ~/lowzi-test && cd ~/lowzi-test
# author manifest.json + one.m3u8, drop MP3s alongside them
python3 -m http.server 8000 &
# edit src/source/manifest.zig:14 → http://localhost:8000/manifest.json
zig build && ./zig-out/bin/lowzi
```

---

## Architecture

```
                    ┌────────────┐
                    │  manifest  │  one URL, JSON
                    └─────┬──────┘
                          │
                    ┌─────▼──────┐    ┌──────────────┐
                    │  sync task │───▶│  SQLite cat. │
                    └─────┬──────┘    └──────┬───────┘
                          │ events           │ queries
                          ▼                  ▼
   stdin ──▶  ┌──────────────────┐    ┌─────────────┐      ┌──────────┐
              │   controller     │───▶│   player    │─────▶│  audio   │──▶ device
   stdout ◀── │  (selector loop) │◀───│  (state sm) │◀─────│ (ring)   │
              └──────────────────┘    └─────────────┘      └──────────┘
```

Modules under `src/`:

| Module          | Responsibility                                                 |
| --------------- | -------------------------------------------------------------- |
| `core/`         | Config, CLI, Bus, `Channel(T)`, message unions                 |
| `storage/`      | Vendored SQLite + schema + migrations + `SyncTx`               |
| `source/`       | Manifest fetcher, M3U8 parser, sync reconciler, downloader     |
| `audio/`        | miniaudio + dr_mp3 + lock-free SPSC PCM ring                   |
| `player/`       | State machine, queue, bookmarks, selector-pattern controller   |
| `headless.zig`  | v0.1 front end — stdin → Command, Event → stdout               |
| `platform/`     | POSIX signal → `Command.quit` (Windows stubbed)                |
| `main.zig`      | Wires it together; spawns four `io.async` tasks                |
| `basic.zig`     | `lowzi-basic` — play first track and exit                      |

Vendored via `translate-c` under `third_party/`: `miniaudio`, `dr_mp3`, and
the SQLite amalgamation (serialized threadsafe mode).

---

## Development

```bash
zig build                       # build both binaries
zig build test                  # unit tests
zig build test -Dsmoke=true     # + real-audio smoke test
zig build lint                  # advisory (zlint; does not fail the build)
```

The canonical docs for contributors live in [`docs/`](docs/):

- [`SPECIFICATION.md`](docs/SPECIFICATION.md) — architecture, schema,
  contracts, build matrix.
- [`AGENTS.md`](docs/AGENTS.md) — operational guide for code-writing
  agents and a running list of Zig 0.16 gotchas.

A pre-commit hook runs `zig fmt` automatically; contributors and agents
should leave formatting alone.

---

## Roadmap

**v0.1 (current):** feature-complete; headless front end; needs a hosted
manifest to stream in production.

**v0.2 and beyond:**

- libvaxis TUI (waiting on 0.16 support landing upstream)
- MPRIS + `playerctl` shim for Linux media keys
- FLAC and OGG decoding (`-Dextra-audio-formats=true`)
- Periodic / on-demand sync (`--sync`)
- Windows signal handling hardening
- CI matrix across Linux / macOS / Windows

---

## License

MIT © 2025 Dario Griffo. See [`LICENSE.txt`](LICENSE.txt).

Built on top of the excellent
[miniaudio](https://miniaud.io),
[dr_libs](https://github.com/mackron/dr_libs),
[SQLite](https://sqlite.org), and
[zunit](https://github.com/dariogriffo/zunit).
