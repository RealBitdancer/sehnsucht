# Changelog

All notable changes to this project are documented here.

## [0.3.0] - 2026-10-27

Twelve new decoder families, three themes, a Sequence visualizer, shared
inspection, seeking, and dual-OPL3 and Y8950 playback. Building from source
requires Zig 0.17.0.

### Added

- A2M and A2T playback for versions 1 through 14. Patterns, orders,
  instruments, macros, compact instruments, channel pairing, and timing are
  kept. The stored CRC is checked before unpacking. Both use the tracker.
  A2T carries no text metadata.
- ROL with a BNK bank, SCI0 with AdLib patches and digital PCM, and XMI with
  an OPL2 or OPL3 timbre bank, duration notes, loops, archive selection,
  explicit branches, four-operator patches, and `.OPL` banks.
- Westwood ADL archives for Dune II, Kyrandia, and Eye of the Beholder. Comma,
  period, and `--track` select a program. The sequence view keeps the
  conductor apart from the programs.
- MusicV (`.wm`, `.m`), six four-operator OPL3 voices. Ultima 6 files that
  share `.m` are declined.
- JBM (`.jbm`), per-voice OPL2 sequences with PIT timing and rhythm mode.
- SNGPlay (`.sng`), the `ObsM` register stream at 70 Hz. Other SNG formats
  are declined.
- God of Thunder, from `.got` or the original resource names, at 120 Hz
  (140 Hz for `menu`). Playback follows two-byte delays and the stored loop.
  Save files are declined.
- HSP packed HSC, and the RAC alias for RAWADATA captures.
- RAD v2 instrument and channel riffs, four-operator routing, panning,
  detune, and operator commands.
- VGM playback on two independent OPL3 chips, with stereo mixing and a
  36-voice rack. Y8950 ADPCM plays from sample memory and from CPU data
  writes, with rate, volume, repeat, and speaker controls.
- Sequence visualizer for MIDI-like events, command lists, and voice
  programs. BAM, JBM, and MusicV show command lists.
- Inspect (I) for metadata, instruments, macros, pattern cells, channels,
  events, orders, branches, and chip state.
- Clickable status controls, and Browse, Playlist, and Theme footers.
- Cyberpunk, Neo Tokyo, and Tron Ares themes. Cyberpunk takes its colors
  from Cyberpunk 2077 and Neo Tokyo from the Neo-Tokyo of Akira.
- Remote playlists for the new formats, including the three-sequence AIL
  demo and its bank. An `archive.zip/member` URL is fetched as written, then
  unpacked in memory when the host does not serve the member. A bad gzip
  checksum, a truncated deflate stream, or a ZIP member whose size or CRC32
  does not match is a load error. ZIP64 is not supported.
- BAM's FLOW panel lists the song structure (labels, jumps with repeat
  counts, chorus calls and returns, the song loop, and the stop) instead of
  its one-tick waits, and highlights the section being played. Sources
  publish structure through the new optional `SequenceView.markerAt`.
- Click or drag the progress bar to seek within a track.
- KSM (Ken Silverman) songs play with their `insts.dat` bank.
- LAA (LucasArts AdLib) songs play: iMUSE resources from Monkey Island 2,
  Indiana Jones 4, and Day of the Tentacle, and the older Lucasfilm AD
  resources from Indiana Jones 3 and Monkey Island 1.
- `playlists/ksm.m3u` and `playlists/laa.m3u` list the Modland rips.
- BAM, JBM, and MusicV voice rows show a piano roll of past and coming notes
  around the playhead, with note names where they fit. BAM events now carry
  score ticks, which also corrects the tick column and length in the
  inspector.
- A `theme="Neo Tokyo"` attribute on `#EXTINF` switches the theme when that
  playlist entry starts.

### Changed

- Requires Zig 0.17.0. `-Doptimize` takes the new mode names (`debug`, `safe`,
  `fast`, `small`), and the old names still work. `safe` stays the default.
- opal-zig moves to 3.0.0-1, and libvaxis and zaudio move to their Zig 0.17
  commits. opal 3.0.0 is a new emulation core, so rendered output is not
  bit-identical to 0.2.1.
- OPL meters and the voice rack follow the stored speaker bits and
  four-operator pairing. As in opal 3.0.0, clearing NEW resets neither.
- In the Tracker pattern and order regions, Home restores following playback.
  Any other move pins the view, even at row zero, which no longer means
  "follow".
- The Tracker info row prints pattern numbers in decimal, as the order list
  does, and row numbers in the gutter's radix.
- Themes are listed in alphabetical order. Midnight Azure stays the default.
- Stream shows the OPL voice rack beside the PCM spectrum and stereo meters.
  ADPCM voices sit in the left rack with level, rate, volume, and sample
  position. Sequence keeps its mixer and spectrum at 80 by 25.
- Inspect opens as a centered popup on a dimmed background.
- BAM shows offsets, waits, calls, returns, and repeat counts. HSC shows
  live channel state, sounded pitch, operator levels, and distinct break
  and speed marks.
- Meters follow the audible carriers and the effective pan, including
  four-operator algorithms, and they hold a short release tail.
- Aliases and compressed wrappers share the parent decoder. Formats that
  only share an extension stay separate modules.
- Release archives include the documentation, contribution and security
  policies, license notices, and playlists. A version tag is checked against
  the package version and this changelog before the six targets are built.
- `playlists/bitdance.m3u` is a tour of one track per format, each tagged
  with a fitting theme, so one pass shows every visualizer and theme.

### Removed

- The Windows shutdown workaround that injected a key into the console. libvaxis
  now stops its input reader with an event instead of a terminal query.

### Fixed

- A repeating RAW capture returns to the PIT divisor from its header instead
  of keeping a speed change from later in the stream.
- A native OPL3 DRO or VGM capture keeps the file's speaker bits and mode
  changes. Other captures still force both speakers on a feedback register.
- An empty English GD3 field uses the Japanese text.
- IMF files with a four-byte length prefix play, on their own and as AudioT
  songs.
- AudioT selects songs from Muse `!ID!` markers and keeps a chunk only when
  it is a valid IMF stream. Short songs stay. Sound-effect chunks are skipped.
- The bundled playlists follow modland's rename of its `- unknown` folders to
  `_unknown`. The old paths left 471 entries failing with HTTP 404.
- Text that is not valid UTF-8 no longer crashes the player. Invalid bytes
  show as U+FFFD.
- IMF and CMF titles, artists, and game names, and RAD descriptions and
  instrument names, show their CP437 box drawing and accented letters, as A2M
  already did.
- Tracker channel paging reaches the last channel of 18- and 20-channel A2M
  songs at every width.
- Tracker LIVE scrolls through every channel, numbers channels from one, and
  shows instruments above 7F.
- Tracker operator gauges keep both columns at 80 columns. The compact strip
  no longer reserves the full spectrum width, and the channel range stays in
  view.
- Order lists keep three-digit entries inside the panel, and RAD jumps show
  their target order. Per-channel orders stay out of the pattern area, page
  with the grid, and print full LDS offsets.
- Sequence scrolling reaches ticks and events beyond 65535. CTRL follows the
  playhead instead of listing the first events of the song. Every sequence
  kind keeps a live strip at the minimum size, tall panes fill every row, and
  branches keep their kind and repeat count.
- The inspector stops panning at the widest event line, names the chip from
  the dump instead of the NEW bit, and lists each macro table to its own
  length.
- Register history drops entries the audio thread may be overwriting. The
  second Y8950 of a dual capture shows its ADPCM registers on bank 1 instead
  of a chip 2 that does not exist. A taller pane no longer shows fewer FM
  voices beside ADPCM.
- A2M: Sixpack blocks decode as Gage's SIXPACK does. An order that names an
  unsaved pattern plays empty rows instead of ending the song. Volume slides
  also run on the row tick. Legacy effect 9 sets only the named operator. The
  v5 to v8 manual slide fine-tunes as AT2 imports it. Songs before version 10
  take their volume and peak locks from the common flags. Retrigger follows
  AT2's counter, and legacy `F9x` retriggers with `x + 1`.
- A2M: `ZF0` releases the sustaining note as AT2 does. FM macro steps with
  duration 0 change nothing. A note without an instrument number keeps the
  current volume. Vibrato and tremolo restart their phase after a row without
  them. Downward slides and vibrato stop at C-0.
- A2M: Repeating the current instrument number keeps the patch changes that
  effects made. A delayed note loads its instrument on the row tick. Arpeggio
  continues its cycle across arpeggio rows and after an empty row. Retrigger
  restarts the note at its own pitch, leaves a released note silent, and
  resumes its count after an empty row. A zero parameter reuses only the last
  continuing effect of the same family.
- ADL: Hostile modulation sizes and program offsets no longer crash. Rhythm
  setup takes drum levels from the channel that runs it, so drums no longer
  start muted. A program started on the caller's own channel keeps the caller
  running, which restores Kyrandia 2a track 3. A rewind no longer races the
  display.
- ADL: The instrument bank ends at the instrument table. Jumps, calls, and
  repeat checks show their destination offset. Only the two tempo opcodes
  read as tempo. Pitch bends show on the shared 14-bit scale, and the mixer
  shows the live bend. Stops read as End. The inspector no longer reports
  zero events.
- BAM's OFFSET column shows file offsets.
- CMF lists its GM drum fallbacks in the instrument bank, and drum voices name
  them. A program change renames the held voices it reloads.
- HSC no longer lists an instrument used only in a trailing partial pattern
  as unused.
- IMF reads a type-0 file whose first record has a delay as type 0, so it
  plays whole. IMF, AudioT, and DRO apply a run of zero-delay writes in one
  step, so long runs no longer insert a pause.
- JBM voices with different loop lengths restart together at the song
  boundary, and the event index stops at the song end. A voice without an
  instrument shows no program.
- LDS channel refs report their order slot as the pattern. Vibrato macros show
  even when the patch has no arpeggio.
- MIDI playback for XMI and SCI0: Released notes keep their pitch while they
  decay. CC 120 on channel 0 stops only that channel's voices. Pitch bend
  spans twelve semitones, as in the AIL and Sierra drivers.
- RAD riffs keep their own last-instrument latch. The slow timer hides the BPM
  it overrides. Retriggered notes show `R` as documented. Algorithm 6 patches
  read as additive. A note that names an undefined instrument loads a blank
  patch, as Reality's player does.
- RAW ignores chip selects other than 1 and 2.
- ROL shows neutral pitch as the centre bend, and pitch events bend one
  semitone each way, as in the AdLib driver. Rhythm mode tunes the tom and
  snare as the driver does. Voice and instrument names show their CP437
  characters.
- SCI0's instrument panel follows only notes that start an FM voice.
- SNG reports its loop offset as a count of register writes.
- VGM gives a Y8950 beside a YM3526 or YM3812 its own bank. A second OPL2's
  timer and IRQ writes no longer reach OPL3 registers `0x104` and `0x105` in
  VGM and dual-OPL2 DRO captures. Long write bursts play in one step.
- MusicV: A song-boundary rewind keys every voice off. The sequence view uses
  the measured tick rate. Program events name the bank slot the instrument
  panel shows. The live state shows a `0x90` slide's note. The instrument bank
  reports the feedback the chip receives.
- MusicV: An instrument load before a repeated pitch still keys the note on.
  Vibrato and slides keep the block and high F-number bits current. Voices
  start at volume 10 and ties factor 0, and `0x84` uses the driver's tempo
  divisor, as in every MUSICV driver.
- XMI program events name timbre-table indices. A bank select applies to later
  program changes, as in AIL. The instrument panel follows the last timbre that
  sounded. Note velocity follows the AIL velocity table.
- The Y8950 ADPCM address wraps at the end of memory instead of crashing.
- The stream rack shows the second half of a four-operator voice at its pair's
  pitch.
- Sequence: Grid cells keep a note when a controller, bend, or aftertouch shares
  its tick. Channel paging reaches the last channels beside the live region.
  The piano roll keeps every note on wide panes, and its scale shows the
  clamped window at the song start. End no longer scrolls past the last row.
- Sequence: The compact voice strip shows SCI0's PCM lane, and entries for
  channels 10 and up keep their octave and level. A scrolled bytecode view
  stays where it was put. The event-stream info row reports the live window.
  Scrolling after the pane grows starts from the visible position, and Left
  works at once after the pane widens.
- Sequence: CTRL and FLOW stay visible at 80 by 25 and at 80 columns with 11
  or more channels. CTRL keeps song-level events beside a control track, so
  SCI0 cues and loop markers show. CMF, XMI, and SCI0 meters keep their release
  tails.
- Tracker: Channel paging keeps four-operator pairs together where it can, and
  Left works at once after the pane widens. Compact strips show their position.
  The cursor row no longer mixes two publishes. Channel heads name A2M and LDS
  notes as the grid does.
- Tracker: OPL3 A2M keeps its second operator column at 80 columns, and tall
  narrow panes keep ORDER and the auxiliary region. Per-channel order lists
  number channels from one. Pattern, order, and live scrolling start from the
  visible position.
- Tracker: The compact ORDER strip is no longer clipped, and the compact
  instrument strip keeps its patch summary. The tall LIVE column shows channels
  10 to 20 whole. When all channels fit, the separator keeps its column. The
  auxiliary column no longer flips between MACROS and LIVE as instruments
  change.
- Tracker: Paged channel columns no longer reserve an extra cell for A2M and
  HSC. Per-channel ORDER lines keep long LDS transpositions whole.
- The inspector pans by display columns and shows a dual-OPL2 capture as two
  chips. C changes the channel only in the events section.
- Text is measured by grapheme, as it is drawn, so emoji sequences line up.
  Long grapheme clusters no longer crash the display, a line feed no longer
  drops the rest of a line, and long text draws quickly again.
- If the audio device fails to start while a playlist advances, the display no
  longer keeps a freed track. A detached load that runs out of memory frees
  its path once.
- Opening another file from Browse resets the R rate. A failed skip or reload
  keeps the old track's R rate and, while paused, its display.
- A failed playing row in the playlist draws its ▶ cell on the row background.
- Files whose names look like AudioT archives but match another format's
  extension load as that format, with that format's companions.
- A remote zip is no longer downloaded again for every missing member.
- Archive keys pressed during a pending reload step from the pending member.
- The new VGM load errors have readable messages.

### Compatibility notes

- SCI1, and a game's mix of several sequences at once, are not implemented.
- KSM, ROL, SCI0 FM, and XMI need a matching instrument bank beside the
  song.

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
- CI links on explicitly cross-compiled macOS targets, matching `zig build`
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
