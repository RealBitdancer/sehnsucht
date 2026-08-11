# Changelog

All notable changes to this project are documented here.

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
