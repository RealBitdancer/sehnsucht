# Changelog

All notable changes to this project are documented here.

## [Unreleased]

## [0.2.1] - 2026-08-20

Bug-fix release, no new features.

### Fixed

- HSC playback follows HSC-Tracker HSCOBJ 1.4 / HSCPLAY. Unmatched effects
  including `0x3n`, `0x5n`, `0x6n`, and `0xDn` set speed. `0x08` is `0x40`.
  Notes use the original 16-bit frequency word. `0x1n`/`0x2n` slide the low
  byte by `n + 1`. `0xAn`/`0xBn`/`0xCn` replace the level byte without keeping
  KSL. An instrument-set with slide 0 leaves the key off. A repeat
  instrument-set of the current patch is a no-op. Out-of-range order indexes
  play empty rows instead of looping. The 51st order slot is played. The KSL
  xor applies to the carrier always, and to the modulator only in additive
  mode. Checked against all 234 modules in `playlists/hsc.m3u`.
- HSC tracker cells show `effect & 0x7F` for an instrument-set and the
  unclamped octave `n / 12`, matching playback.
- RAD v2 note-retrigger uses each channel's last instrument at play time
  (Reality `CChannel.LastInstrument`), not a load-time latch shared across
  channels and reset per pattern. A note without an instrument change no
  longer forces a key-on bounce. An instrument byte still updates the latch
  when the patch is missing or the row is a tone slide.
- CMF General-MIDI channel-9 drum remap loads AdPlug's five fallback
  percussion patches onto rhythm channels 11..15, instead of file
  instrument 0. The fallbacks live in a side table, so they cannot collide
  with file patch numbers.
- AudioT archives with Wolf-engine extensions `.vsi` (Blake Stone: Planet
  Strike), `.co7` (Corridor 7), and `.bc` (Operation Body Count) default to
  the 700 Hz IMF timer, not Keen's 560 Hz.

### Changed

- Format guides for HSC, RAD, CMF, and AudioT describe HSCOBJ playback,
  Reality last-instrument retrigger, GM drum fallbacks, and Wolf-engine
  AudioT rates.

## [0.2.0] - 2026-08-16

### Added

- LDS (Loudness Sound System, `.lds` / `.ld0`). Nine-channel OPL2 tracker with
  packed pattern streams, native `0xF9` loops, and the tracker visualizer.
  Remote playlist at `playlists/lds.m3u` (Modland `.lds` plus AdPlug
  `GENORI.LD0`)
- LCD Ink theme. Dark ink on a green-grey backplane
- BAM (Bob's Adlib Music, `.bam`). Uncompressed OPL2 events with `CBMF` magic,
  25 Hz waits, labels, finite loops, and one-level chorus. Remote playlist at
  `playlists/bam.m3u`
- XSM (eXtra Simple Music, `.xsm`). Nine-channel OPL2 note grid with `ofTAZ!`
  magic, one SBI patch per channel, and a fixed 5 Hz tick. Remote playlist at
  `playlists/xsm.m3u`
- Remote per-format playlists for HSC, RAD, LDS, VGM/VGZ, DRO, RAW, BAM, XSM,
  CMF, IMF/ADLIB, WLF, and AudioT (`playlists/hsc.m3u`, `rad.m3u`, `lds.m3u`,
  `vgm.m3u`, `dro.m3u`, `raw.m3u`, `bam.m3u`, `xsm.m3u`, `cmf.m3u`, `imf.m3u`,
  `wlf.m3u`, `audiot.m3u`)

### Fixed

- Playlist and header labels: `LD0`, `VGZ`, `ADLIB` (not the parent name)
- HSC instrument-set keys off without writing `B0 = 0`, so release keeps the
  stored block and F-number
- After a track loops in place, the progress bar and elapsed time restart from the start of the song instead of climbing past duration
- Hostile RAW streams that pack huge runs of register writes before any delay no longer stall a single `step` on the audio thread (work is capped per step and yields with zero frames)
- Hostile CMF streams with long zero-delay MIDI event chains are capped the same way, so the audio thread yields and the load-time duration probe can hit its step caps
- LDS patches whose arpeggio length exceeds the 12-entry table no longer abort playback
- Dual OPL2 VGM, DRO, and RAW no longer fold the second chip onto the first.
  Those captures enable NEW and set CHA/CHB on `C0` so bank 1 is a real
  second chip
- A failed last-track load no longer wraps to an earlier song when playlist
  loop is off
- Space on the last looping track of a finished pass reloads it, and a jump
  or wrap-advance from that parked state starts the new track instead of
  staying silent
- Hostile VGM streams of `0x80` waits and data-block skips no longer stall
  a single `step` (work is capped per step, like RAW and CMF)
- CMF loops keep the file's leading delay, including zero, instead of
  inserting one extra silent tick
- The LDS tracker highlight stays on the sounding row instead of jumping
  ahead on the same tick
- An LDS loop jump on the same row as a stop continues at the jump
  destination instead of rewinding to the start
- A BAM song-loop no longer keeps a leftover chorus return
- A mid-song CMF rhythm toggle keys off hanging notes
- Dual OPL2 DRO files show Dual OPL2 in the header, not OPL2
- Load-skip notices use plain phrases for bad VGM, DRO, and AudioT files
  instead of Zig error names. A mid-download read failure says
  "download interrupted", not `ReadFailed`
- Extra `]` / `[` presses while a track is loading skip further down the
  list instead of only one extra file
- R keeps the chosen tick rate across replay and archive track steps. A
  playlist skip or Enter jump starts the next file at its default (or
  `--rate`)

### Changed

- OPL synthesis is opal 2.0.2 via opal-zig 2.0.2-1. NEW (register 105h bit 0)
  is a live mode bit. Bank 1, waveforms 4-7, CHA/CHB, and four-operator pairing
  apply only while it is set. NEW with C0 missing CHA/CHB is silent
- Remote playlists are per-format. The mixed Modland showcase
  (`playlists/modland.m3u`) is gone. Use `playlists/bitdance.m3u` for a mixed
  sample, or a per-format list
- Documentation: the format guide states the live NEW rule. Every OPL VGM,
  Dual OPL2/OPL3 DRO, and dual-chip RAW enable NEW at load and set CHA/CHB on
  C0. CMF, RAW, and VGM describe the per-step work cap
- Documentation: format guides match the decoders (LDS tempo, wait units,
  arpeggio clamp, tracker highlight, and F9+FC, RAD tail vs size-word, VGM GD3
  OOM, CMF transpose and rhythm toggle, RAW AdPlug delay-0, BAM 8191 indices
  and song-loop chorus, XSM AdPlug C0+op_table). README tracker caption
  includes LDS. The hotkeys note covers parked Space replay,
  skip-while-loading, and R keeping the tick rate

## [0.1.1] - 2026-08-11

Bug-fix release, no new features.

### Fixed

- On Windows, Browse stopped at the drive root with no way to switch volumes. Parent from a drive root now opens a virtual Drives list
- Drive-relative arguments such as `D:` or `C:music` on Windows print a clean error instead of crashing
- A crafted Huffman-compressed AudioT archive could freeze the player during load. Expansion work is now budgeted alongside retained memory
- The theme browser title was rendered from a dead stack buffer and could show garbage
- Slow but healthy downloads were killed by a 30-second wall-clock timeout. The timeout now applies only to transfers that stop delivering bytes
- Playlist entries carrying terminal control bytes are dropped, and `#EXTINF` / `#PLAYLIST` text is scrubbed, so a hostile playlist cannot inject escape sequences into the terminal
- A colon inside an ordinary filename (`a:song.hsc`) no longer makes a playlist entry absolute
- In shuffle mode the transport row could advertise a previous-track step that did nothing when pressed
- A track scan whose candidates all failed no longer forgets which archive subtrack was playing, so a later replay resumes the right one
- Losing the audio device mid-session no longer crashes the player on the next track switch
- The tracker instrument panel's wave gauge scales to the full OPL3 waveform range 0-7 instead of pegging at 4 and above
- DRO v2 duration no longer counts delay time past an invalid codemap index that playback never reaches

### Changed

- The per-OS CI workflows request a read-only token
- `zig build test` links on explicitly cross-compiled macOS targets, matching `zig build`
- Documentation: the IMF error rules describe the parser's tolerant length clamping, the hotkeys document matches the code again (theme naming, and the shuffle `canStep` rules without the removed soft previous step), the AudioT notes describe the expansion work budget, and the hotkeys document is linked from the README

## [0.1.0] - 2026-08-10

First public release.

- Terminal OPL2/OPL3 player with a three-frame TUI (header, content, status)
- Formats: HSC, RAD, VGM/VGZ (OPL family), DRO, RAW, CMF, IMF/WLF/ADLIB, and AudioT archives
- Single files, multi-file arguments, M3U/M3U8 playlists, and directory Browse
- Playlist shuffle and loop, skip, jump, played/unplayable markers, and `#EXTINF` / `#PLAYLIST` titles
- Remote `http://` and `https://` files and playlists, plus `file://` local paths
- Async loading with a spinner so slow downloads never freeze the UI
- Tracker and stream visualizers driven by real chip and PCM state
- Pluggable themes (Midnight Azure default, High Contrast)
- Volume, mute, transport keys from every view, mouse clicks and scroll
- IMF/WLF/AudioT tick-rate control (280 / 560 / 700 Hz) and AudioT multi-track keys
- Cross-platform builds (Linux, macOS, Windows) with ReleaseSafe by default
