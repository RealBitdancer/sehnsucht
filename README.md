# sehnsucht

A terminal player for classic **OPL2/OPL3** game music.

[![Linux](https://github.com/RealBitdancer/sehnsucht/actions/workflows/linux.yml/badge.svg)](https://github.com/RealBitdancer/sehnsucht/actions/workflows/linux.yml)
[![macOS](https://github.com/RealBitdancer/sehnsucht/actions/workflows/macos.yml/badge.svg)](https://github.com/RealBitdancer/sehnsucht/actions/workflows/macos.yml)
[![Windows](https://github.com/RealBitdancer/sehnsucht/actions/workflows/windows.yml/badge.svg)](https://github.com/RealBitdancer/sehnsucht/actions/workflows/windows.yml)

## What it does

A single file loops until you quit. A track with no native loop point plays
once, parks at the end, and Space replays it. A multi-entry playlist with
loop off parks on the last track the same way.

FM synthesis is [opal](https://github.com/RealBitdancer/opal) via
[opal-zig](https://github.com/RealBitdancer/opal-zig). Audio out is
[zaudio](https://github.com/zig-gamedev/zaudio) (miniaudio). The TUI is
[libvaxis](https://github.com/rockorager/libvaxis).

Every meter and spectrum band comes from real chip or PCM state.

**Stream visualizer** (DRO, VGM, IMF, and the other stream formats): full-pane
spectrum, info strip, and master meters.

![Stream visualizer](doc/img/stream.png)

**Tracker visualizer** (HSC, RAD, and LDS): pattern, order list, instruments, and
OPL channel meters.

![Tracker visualizer](doc/img/tracker.png)

Themes are Midnight Azure (default), LCD Ink, and High Contrast. T in the
menu opens the theme browser.

## Why it exists

I built sehnsucht to put [opal](https://github.com/RealBitdancer/opal) through
a real workload. The `examples/player` that ships with opal works, but it is
too small to show what the core can do. A full terminal player was the better
test.

The name sehnsucht is deliberate. It reminds me of the Amiga and DOS years,
when the gaming and demo scenes produced impressive work and games still
surprised you.

## The road ahead

sehnsucht is nowhere near feature complete. The seek bar in the status frame is
a clear example: today it only paints elapsed time against duration. It ought
to let you click or drag to an arbitrary position in the track, and it does
not yet.

I also plan to keep adding formats, visualizers, and themes. The plugin layout
is there for that. Contributions of the same kind are welcome (see
[CONTRIBUTING.md](CONTRIBUTING.md)).

## Supported formats

| Format | Extensions / paths | Visualizer | Notes |
|--------|--------------------|------------|--------|
| HSC-Tracker | `.hsc` | tracker | OPL2, fixed 18.2 Hz tick |
| RAD | `.rad` | tracker | Reality Adlib Tracker v1.0 / v2.1 |
| LDS | `.lds`, `.ld0` | tracker | Loudness Sound System (OPL2). Tyrian and other mid-90s DOS games |
| VGM / VGZ | `.vgm`, `.vgz` | stream | OPL-family chips only, GD3 metadata |
| DRO | `.dro` | stream | DOSBox Raw OPL (v1 / early header / v2) |
| RAW | `.raw` | stream | Rdos / RAC raw OPL capture (`RAWADATA`) |
| BAM | `.bam` | stream | Bob's Adlib Music (`CBMF`). Uncompressed OPL2 events at 25 Hz |
| XSM | `.xsm` | stream | eXtra Simple Music (`ofTAZ!`). Nine OPL2 channels, one instrument each, 5 Hz |
| CMF | `.cmf` | stream | Creative Music File (Sound Blaster) |
| IMF | `.imf`, `.adlib` | stream | Default 560 Hz. Override with `--rate` or R. Modland `ADLIB` metadata wrapper supported |
| WLF | `.wlf` | stream | Default 700 Hz. Override with `--rate` or R |
| AudioT | `AUDIOT.*` / `AUDIO.*` / `AUDIOHED.*` | stream | Muse archives, including Huffman-compressed `AUDIO.*` with an `AUDIODCT.*` dictionary (Keen 4-6). Music chunks are IMF and rate-adjustable like IMF |

Non-OPL VGMs are rejected. DRO is a millisecond register capture (including
output from [vgz2dro](https://github.com/RealBitdancer/vgz2dro)).

Per-format layout: [doc/formats/](doc/formats/).
Adding a format: [doc/adding-a-format.md](doc/adding-a-format.md).
Plugins: [doc/plugins.md](doc/plugins.md).
Hotkeys and playlist modes:
[doc/hotkeys-and-playlist-modes.md](doc/hotkeys-and-playlist-modes.md).

## Playlists

Pass an `.m3u` or `.m3u8` file instead of a single track. One path per line.
`#` starts a comment. Relative paths resolve against the playlist's location.
Unsupported extensions are dropped.

`#EXTINF` titles name the rows. An `#EXTINF` tag may also carry `rate=280`,
`rate=560`, or `rate=700` for IMF, WLF, and AudioT. That per-entry rate
wins over the extension default and loses to `--rate`. `#PLAYLIST` names
the list on the Playlist view title line. Without that directive, the
playlist file name is used.

Tracks play in order and advance at each song end. Loop (**L**) wraps at
both ends. Off, the list plays through once and parks on the last track.
Space replays that last song. Shuffle (**S**) builds a random order with
no repeats until the list is exhausted. **]** and **[** skip.

Played rows this session dim. Failed loads get a red ✗ and are skipped.
Enter on a marked row retries it. A load failure never quits a running
session.

## Remote files

Any file, playlist, or playlist entry may be an `http://` or `https://` URL.
The bytes download into memory (16 MiB cap, redirects followed) and play like
a local file. A stall with no bytes for 30 seconds is abandoned. A slow
server that keeps delivering is not.

Relative entries in a remote playlist resolve against the playlist URL.
Unsupported schemes are dropped. A playlist fetched over http(s) keeps only
http(s) entries.

Percent-encoded names show decoded (`dune%201.dro` as `dune 1.dro`). Fetching
uses the URL as written.

`file://` is a local path, not a download. Drive forms (`file:///C:/...`)
and UNC (`file://host/share`) unwrap the same way.

Downloads run in the background. The header reads `[Loading]`, keys still
work, and skip passes over a slow entry. Starting with a URL opens the UI at
once.

## Building

Requires **Zig 0.16.0** (see `.minimum_zig_version` in `build.zig.zon`).

```sh
zig build                 # -> zig-out/bin/sehnsucht[.exe]
zig build test            # run unit tests
```

Default optimize mode is **ReleaseSafe**. Dependencies are fetched on first
build.

The UI is truecolor only (24-bit SGR). There is no 256-color or 16-color
fallback. On a console without truecolor (Apple's Terminal.app is the usual
case) the player draws in black and white. Use a terminal that supports
truecolor (iTerm2, Ghostty, Kitty, WezTerm, Alacritty, Windows Terminal, and
most Linux terminals).

## Sample playlists

There is no sample audio in the tree. Remote lists under `playlists/` stream
from Modland, the [OPL Archive](https://opl.wafflenet.com/), and the Internet
Archive. They need network access.

```sh
zig build run -- playlists/bitdance.m3u
```

| Path | What |
|------|------|
| `playlists/bitdance.m3u` | 52 mixed IMF, DRO, HSC, LDS, and VGZ tracks |
| `playlists/hsc.m3u` | 234 HSC modules (mostly Hannes Seifert) |
| `playlists/rad.m3u` | 127 RAD modules |
| `playlists/lds.m3u` | 185 tracks (184 Modland `.lds` plus AdPlug `GENORI.LD0`) |
| `playlists/vgm.m3u` | 1341 OPL-family VGZ dumps |
| `playlists/dro.m3u` | 2 DRO captures |
| `playlists/raw.m3u` | 316 RAW captures |
| `playlists/bam.m3u` | 29 BAM tracks |
| `playlists/xsm.m3u` | 4 XSM demos (the known corpus) |
| `playlists/cmf.m3u` | 443 CMF songs |
| `playlists/imf.m3u` | 240 IMF and ADLIB tracks |
| `playlists/wlf.m3u` | 27 Wolfenstein 3D WLF rips (`jpb1991`) |
| `playlists/audiot.m3u` | 3 Muse archives (Wolf3D, Blake Stone shareware, Spear of Destiny demo) |

Keen AudioT on Archive.org is only the compressed `AUDIO.CK4` lump. The header
and Huffman dictionary stay inside the EXE, so that set is not playable
remotely.

## Usage

```sh
sehnsucht [files... | playlist | directory | URL]
sehnsucht                       # Browse view in the current directory
sehnsucht ~/adlib               # Browse view in the given directory
sehnsucht favorites.m3u         # Playlist view, plays the first entry
sehnsucht a.hsc b.vgm c.dro     # several files become a playlist
sehnsucht https://example.com/tune.vgz
sehnsucht --rate 700 tune.imf
sehnsucht --track 2 AUDIOT.WL6
sehnsucht --version           # -v works too
sehnsucht --help              # -h works too
```

A playlist or directory must be the only argument. Wildcards are the shell's
job, so cmd.exe users must list files explicitly.

### In-player keys

Transport keys are the ones the status frame shows. They work from every view
and every focus state. Nothing else in the player binds them.

| Key | Action |
|-----|--------|
| Space | Pause / resume. Replays a parked one-shot or the last song of a finished playlist pass |
| + / - | Volume up / down, 2.4 dB per press (`=` is also `+`) |
| M | Mute / unmute |
| R | Cycle IMF/WLF/AudioT tick rate 280 → 560 → 700 (rate-adjustable sources only). Replay and archive steps keep the choice |
| `,` / `.` | Previous / next music track in an AudioT archive (multi-track only) |
| `]` | Next track (playlists only) |
| `[` | Previous track (playlists only) |
| S | Toggle shuffle (playlists) |
| L | Toggle playlist loop |

Everything else is shell navigation.

| Key | Action |
|-----|--------|
| Ctrl+C or Alt+Q | Quit |
| F10 or Alt | Toggle menu focus |
| Alt+B / Alt+P / Alt+V / Alt+T | Activate a menu item directly |
| B (menu focused) | Browse filesystem |
| P (menu focused) | Playlist list view |
| V (menu focused) | Visualizer view |
| T (menu focused) | Open the theme browser |
| Q (menu focused) | Quit |
| Tab / Shift+Tab | Open the next / previous menu view, or focus action-only items |
| ← / → | Parent dir / open selection (Browse, like ranger), or move menu focus. On Windows, parent from a drive root opens a Drives list |
| ↑ / ↓ | Move list cursor (Browse / Playlist) |
| PgUp / PgDn | Page list cursor (Browse / Playlist) |
| Home / End | First / last list entry (Browse / Playlist) |
| Enter | Open dir / play file (Browse), play track (Playlist), or activate the focused menu item |
| Backspace | Parent directory (Browse) |

Where the terminal reports mouse events, click a menu item to open it, click a
list row to select it, click the selected row again to open or play it, and
scroll lists with the wheel.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Bitdancer
(github.com/RealBitdancer).

Third-party code (opal, libvaxis, zaudio/miniaudio) is summarized in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
