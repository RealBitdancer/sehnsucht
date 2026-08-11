# Changelog

All notable changes to this project are documented here.

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
