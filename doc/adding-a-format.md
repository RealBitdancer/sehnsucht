# Adding a format

sehnsucht format decoders turn file data into timed OPL register writes. Copy
`src/formats/template.zig` for a minimal decoder that compiles.
Formats share the registry and template principles described in
[Plugin architecture](plugins.md).

The playback interface supports OPL2, two OPL3 instances, and optional mixed PCM. Other
chip families still need a playback interface change.

OPL3 NEW (register `0x105` bit 0) gates new writes. While it is clear, bank 1
writes other than `0x105` land in bank 0, waveforms stay in 0-3, and a C0
write turns on both speakers. Clearing NEW leaves stored state alone, so both
banks keep playing and four-operator pairing follows register `0x104`. The
stored C0 speaker bits determine whether a voice reaches either output. Dual-OPL2
captures need NEW enabled (`chip.enableNew`) and CHA/CHB added to C0 writes
(`chip.withStereoC0`) to play both banks. Native OPL3 captures must preserve
their recorded NEW and speaker bits, including intentionally silent settings.

For a second OPL3 instance, OR `0x200` into the register address passed to
`Chip.writeReg`. Register bit 8 still selects the bank within that chip.
The audio engine routes each write to its own instance. `DumpView.chip` set
to `dual_opl3` exposes 36 physical voices, with the second chip starting at
voice index 18. The single-device `chip.fromOpal` adapter accepts only the
first chip's address range. It remains useful for isolated decoder tests.
For registers handled by a source's PCM synthesizer, `Chip.traceReg` records
the write without sending it to Opal. Test sinks can omit this optional hook.

## Files to add or update

Keep each format's parser, playback, and unpacking in its decoder module.
Shared utilities live outside `src/formats/`:

| Module | Role |
|--------|------|
| `src/binary.zig` | Little-endian reader and text trimming used by KSM, LAA, ROL, SCI0, and XMI |
| `src/fm.zig` | OPL operator and channel register helpers |
| `src/inflate.zig` | Bounded gzip, zlib, and raw inflate |
| `src/midi_opl.zig` | MIDI-like voice allocation for SCI0 and XMI |
| `src/pcm.zig` | Sample voices for mixed digital PCM |
| `src/inspector.zig` | Shared I popup used by every visualizer |

1. Copy `src/formats/template.zig` to `src/formats/<name>.zig`.
2. Add the module to `format_modules` in `src/registry.zig`. The registered
   `formats` array is built from that list.
3. Copy `doc/formats/template.md` to `doc/formats/<name>.md`.
4. Add the format to `doc/formats/README.md` and
   [Supported formats](supported-formats.md).
5. If there is a remote list, add it under `playlists/` and to
   [Sample playlists](../playlists/playlists.md).

Registration order is detection order when formats share a path rule. Format
names must be unique. Distinct formats that share an extension stay in
separate modules. `load` returns null when the bytes belong to the other
format. Aliases and wrappers that unpack the same payload stay in the parent
module, as HSP does in `hsc.zig`. The registry checks for unique names
and known visualizer names. `Format.init` copies `visualizer_name` onto the
registered row, so the pane id is declared once.

## Format declaration

Every module exports one `fmt.Format` through `Format.init`, the same pattern
as visualizers and themes. These declarations describe a register-stream
decoder. The module must also implement `load`:

```zig
pub const format_name = "Example";
pub const extensions = &.{".example"};
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

pub const format = fmt.Format.init(@This());
```

`format_name`, `extensions`, `visualizer_name`, `view_caps`, and `load` are required.
`Format.init` copies `visualizer_name` onto the registered `Format`.
`MusicSource.init` stores that same name, and `info()` stamps it onto
`TrackInfo`, so a decoder does not write the pane id a second time. Use
`matchesPath` when an extension is insufficient. `companions` returns every
side-file path in one `CompanionPaths` value: `sibling` is the primary
companion, `sibling_alt` is fetched when that read fails, and `sibling2` is
a second companion read tolerantly (AudioT's dictionary). `labelForPath`
sets the playlist label when one decoder owns more than one name (`WLF`,
`ADLIB`, `VGZ`, `LD0`, `RAC`, `HSP`). Use the same spelling in
`TrackInfo.format_name`.

Export `view_caps` matching the views the decoder actually installs. The
registry checks that those caps satisfy the named visualizer's `requires`.
Use `stream` for register dumps, `tracker` for pattern grids, and `sequence`
for MIDI-like or voice-program sources.

## Loading contract

The loader signature is:

```zig
pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource
```

Return values have distinct meanings:

* Return `null` when the input belongs to another format.
* Return an error when the input is recognized but malformed, unsupported, or
  cannot be loaded.
* Return `error.OutOfMemory` unchanged when allocation fails.
* Return a source when loading succeeds.

`data`, `ctx.name`, `ctx.ext`, companion slices, and `ctx.resources` are borrowed. Copy anything the
source needs after `load` returns. The source owns every allocation stored in
its state and releases them in `deinit`.

The loader limits each input file to 16 MiB. Check offsets, counts, and
decompressed sizes before allocating. A small compressed input can request
a large output.

If a source has no `durationFrames` method, sehnsucht loads the decoder a second
time and steps that independent source to measure duration. Loading must not
depend on global mutable state or retain pointers to temporary input. Each call
must produce an independent source.

`track_index` selects a member of an archive, counting from 0. Clamp an index
past the last member to the last member rather than failing, so `--track 99`
plays the final track instead of refusing the file. `tick_rate_hz` is a
requested rate override. Companion files, when requested by `companions`,
are available through `ctx.sibling` and `ctx.sibling2`.
`ctx.sibling_is_alt` is set when the bytes in `ctx.sibling` came from
`CompanionPaths.sibling_alt` because the primary companion could not be read.
The second companion is read tolerantly, so a decoder that requires it must
check for null and fail itself.

If the loaded source still holds every archive member, implement
`selectArchiveTrack` so `,` / `.` retarget that source. The player stops the
device, passes a fresh chip, and never re-fetches. Clamp `index` the same way
as `track_index`. Rebuild any synthesized title, refresh duration for the new
member, and initialize playback on the given chip. Refresh borrowed metadata
and views after selection. Formats that keep only the selected
member (AudioT's one IMF stream) omit the method. Those keys then replay
through the loader.

`TrackInfo.title` is metadata, not a display fallback. Leave it `null` when the
file carries no title and the format synthesizes none, so the shell can fall
back to the percent-decoded file name without its extension. A format that
puts the file name there instead defeats that fallback and shows the extension
in the header. Set `title_embedded` only for a title read out of the file.

Published text is UTF-8. Text stored in a DOS file is CP437, so convert
titles, names, and descriptions with `src/cp437.zig` before publishing them.
`decode` fills a caller buffer, `decodeOptional` returns owned text or `null`
for padding alone, and both trim trailing spaces. Allow
`cp437.max_utf8_per_byte` bytes of output per input byte. Text that is already
UTF-8, such as a file name, passes through unchanged.

## Source contract

A source type provides three public methods:

```zig
pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult
pub fn info(self: *Source) fmt.TrackInfo
pub fn deinit(self: *Source, gpa: std.mem.Allocator) void
```

Create the erased interface with:

```zig
return fmt.MusicSource.init(src, visualizer_name);
```

`MusicSource.init` generates the `*anyopaque` adapter and vtable. Do not write
casts or an adapter vtable in the decoder.

Follow the style the existing decoders share: option structs instead of long
parameter rows, enums for file codes, and layout structs for fixed records.

The adapter discovers these public optional methods by name. The player
consumes `patternView`, `orderView`, `instrumentBank`, `sequenceView`,
`dumpView`, `playhead`, `sequenceState`, `channelState`, and
`selectArchiveTrack`. It also discovers the optional PCM renderer, independent
pattern cursors, and interactive branch handler.

```zig
pub fn patternView(self: *Source) view.PatternView
pub fn orderView(self: *Source) view.OrderView
pub fn instrumentBank(self: *Source) view.InstrumentBank
pub fn sequenceView(self: *Source) view.SequenceView
pub fn dumpView(self: *Source) view.DumpView
pub fn playhead(self: *Source) view.Playhead
pub fn sequenceState(self: *Source) view.SequenceStateBank
pub fn channelState(self: *Source) view.ChannelStateBank
pub fn patternCursors(self: *Source) view.PatternCursorBank
pub fn renderPcm(self: *Source, stereo: []i32) void
pub fn branch(self: *Source, label: u16, chip: fmt.Chip) bool
pub fn getTickRate(self: *Source) u32
pub fn setTickRate(self: *Source, hz: u32) void
pub fn durationFrames(self: *Source) u64
pub fn selectArchiveTrack(self: *Source, gpa: std.mem.Allocator, index: u32, chip: fmt.Chip) anyerror!void
```

`instrumentBank` may also supply `macroStep` for visible macro-table windows.
View callbacks read immutable source data. Their backing storage and borrowed
strings remain valid while that archive member is selected, until the source
is retargeted or deinitialized. Returned values are copies, and callbacks
that fill a destination use the caller's scratch buffer. After load, `step`
may write only playback scalars and voice working state.

`step` applies register writes until it reaches a delay or an end condition.
`frames` is the number of output frames before the next step. Set `done` at a
song boundary. On the next call, a looping source continues from its repeat
position with the state that the format retains. A loop need not return to
the start of the file. Frames returned with `done` still belong to the final
audible interval.

Seeking needs no decoder support. The player rebuilds the source from the same
bytes at the current tick rate, then runs `step` and `renderPcm` up to the
target without rendering the chips. `step` must therefore produce the same
writes whether or not audio was rendered in between.

Set `TrackInfo.loop` explicitly when single-file playback should repeat. It
defaults to false, which parks playback at the first song boundary. This flag
describes source behavior, including whole-file repeats without a stored loop
point. Playlist loop is a separate player setting.

Keep each call bounded, including command runs that produce no delay. Playback
and PCM rendering must not allocate or perform file or network I/O.

Metadata and static views borrow source-owned storage. Metadata strings cannot
point into the load input unless it was copied. Live playheads and channel
snapshots contain values rather than pointers and pass to the UI through the
bridge. A view callback must not read state being mutated by the audio thread.

`deinit` runs exactly once for every returned source, including duration probes
and failed higher-level loads.

## Visualizers

Declare `pub const visualizer_name` and `pub const view_caps` on the format
module. `Format.init` copies both onto the registered `Format`. Pass
`visualizer_name` into `MusicSource.init`. Do not set `TrackInfo.visualizer`
in `info()`. `MusicSource.info` stamps the pane id.

| Plugin | `requires` | Optional | Source methods |
|--------|------------|----------|----------------|
| `tracker` | `pattern` | `order`, `instruments` | `patternView`, plus `orderView` / `instrumentBank` when claimed |
| `sequence` | `sequence` | `instruments` | `sequenceView` |
| `stream` | none | `dump`, `instruments` | `dumpView` when the file has dump metadata |

Pattern grids (HSC, RAD, LDS, XSM, A2M/A2T) use `tracker`. MIDI-like and bytecode
sequencers (CMF, ADL, BAM, JBM, KSM, LAA, Lucasfilm AD, MusicV, ROL, SCI0, XMI)
use `sequence`.
Register dumps use `stream`.

`SequenceView.position_unit` defaults to `tick`. Set it to `event_index`
when `Playhead.tick` identifies a command by index, as in BAM. Timed command
lists must supply `eventAt` in stable tick order so the visualizer can find
the current passage without scanning the whole song on each frame.

`assembleTrack` checks `viz.requires.subsetOf(src.views().caps())`. A tracker
source that forgets `patternView` fails with `error.MissingVisualizerData`.
A sequence source that forgets `sequenceView` fails the same way.
`playhead` publishes the live cursor. Stream dump formats can omit every view
and still draw, because the PCM analyzer and meters come from `Bridge`.

The tracker pane is the complete module viewer. Window size may change
geometry (scroll, page, compact padding). It must not hide a provided region.
If the source exposes a field, that field stays on screen or one key away
(`CH a-b of n`, `ORDER i/len`, `Ixxx/n`, `MACRO a/b`). Below height 20 the
tracker keeps compact region strips with the grid below. Sequence scales
its mixer and spectrum down before using a single strip at the smallest
sizes. Stream pairs an OPL voice rack with its analyzer, then falls back to
a note strip or the analyzer alone when space is short. The inspector keeps
the full source details available in each layout.

## Errors

Common load errors have plain user-facing labels in `src/loaderr.zig`, including
`MissingVisualizerData` and `UnknownVisualizer`. The TUI skip row uses
`loadErrorLabel`. A custom error is shown using its Zig error name unless a
label is added there. Use a specific custom error when callers need to
distinguish a recognized malformed file from an unrelated format.

Do not discard allocation errors from optional metadata. Validate malformed
optional sections without failing the track, but propagate `error.OutOfMemory`.

## Named resources and PCM

New decoders should export
`resourceRequests(gpa, path, data) ![]fmt.ResourceRequest` for companion files.
It runs on the fetch worker after reading the primary file. Decline unrelated
bytes with an empty owned slice, even when the filename extension matches.
Each request has a name, ordered candidate paths, and a `required` flag.
`ResourceRequest.init` owns its name and paths. The worker tries candidates in
order, propagates cancellation and allocation failures, and limits combined
resource bytes to 64 MiB. `ctx.resource("name")` returns the selected bytes.
Copy or decode them before returning from `load`. The old AudioT sibling
fields remain compatible. New resources do not share their two-slot limit.

A source may provide `renderPcm(self, stereo: []i32) void`. The engine clears
this interleaved stereo buffer before calling it. Samples use signed 16-bit
amplitude with 32-bit mixing headroom. Render exactly the requested frames at
`ctx.sample_rate`, without allocation, I/O, or changing the OPL registers.
`step` controls note changes and timing. The engine never renders beyond its
current wait, sums PCM with OPL output, clamps, measures levels, and applies
the existing volume and mute controls. Pause stops both renderers.
`src/pcm.zig` supplies mono/stereo sample voices with interpolation and loops.
`src/y8950.zig` supplies the Y8950 Delta-T sample decoder.

An optional `pcmState(self) view.PcmState` publishes two sample-voice slots.
Each slot reports presence, playback and repeat state, memory or CPU mode,
speaker mute, byte addresses, effective rate, volume, and level. The engine
copies this pointer-free state to `Bridge.pcm` on the audio thread. Set
`DumpView.adpcm_voices` for the Y8950 rows in Stream. The snapshot clears with
the other live state when loading a song.

A PCM source must provide a duration when its end depends on sample rendering.
The duration probe only calls `step`. SCI0 provides its own duration.

## Live views and interactive branches

`patternCursors` returns a pointer-free `PatternCursorBank`, one optional
order, pattern, and row per logical channel. The tracker follows each active
cursor in a per-channel stream. Shared trackers can omit it.
`SequenceStateBank.voices` lists simultaneous notes and their actual OPL voice
or PCM role. The older channel slots still carry channel controls and cursors.

Sequence sources should expose `eventAt` for complete event inspection.
Voice programs can supply `bytecodePage(ctx, channel, from, skip, dest)` to
page from a stable bytecode offset without truncating at the UI's scratch
buffer. Its count describes the entire window before `skip`.
BAM and ADL use structured branch payloads for jumps, calls, returns, and loops.
BAM targets are labels with repeat counts, and ADL targets are sound-data offsets.
A note-off with note 255 means release the voice without naming a pitch.

`SequenceView.branchAt` and `branch_count` describe explicit interactive
branch targets. A source's optional `branch(label, chip) bool` executes on the
audio thread. The inspector sends a label through `Bridge.branch_request`.
A successful branch discards the outstanding wait. The source decides which
notes and loop state must be cleared. A rejected label leaves playback intact.
