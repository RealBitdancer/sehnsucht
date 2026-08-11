# Adding a format

sehnsucht format decoders turn file data into timed OPL register writes. Copy
`src/formats/template.zig` for a minimal decoder that compiles and has a test.
Formats share the registry and template principles described in
[Plugin architecture](plugins.md).

The current playback interface supports OPL2 and OPL3. A format that produces
PCM or targets another chip needs a playback interface change first.

## Files to add or update

1. Copy `src/formats/template.zig` to `src/formats/<name>.zig`.
2. Add the module to `format_modules` in `src/registry.zig`. The registered
   `formats` array is built from that list, so the module is the only place
   the new format has to be named.
3. Copy `doc/formats/template.md` to `doc/formats/<name>.md`.
4. Add the format to `doc/formats/README.md`.

Add the new module to the list in `src/tests.zig`. Registration alone does not
put its tests in the suite: Zig reaches a test only through a module the test
root actually analyzes, and a module missing from that list stops being tested
without failing the build.

Registration order is detection order when formats share a path rule. Format
names and extensions must be unique. The registry tests enforce unique names,
unique extensions, and known visualizer names, and a `comptime` block in
`src/registry.zig` fails the build when a `Format.visualizer` disagrees with
its module's `visualizer_name`.

## Format declaration

Every module exports one `fmt.Format`:

```zig
pub const visualizer_name = "stream";

pub const format = fmt.Format{
    .name = "Example",
    .extensions = &.{".example"},
    .visualizer = visualizer_name,
    .load = load,
};
```

`name`, `extensions`, `visualizer`, and `load` are required. Use
`matches_path` when an extension is insufficient. `sibling_path` requests a
companion file, `sibling_alt_path` a fallback fetched when the primary read
fails, and `sibling2_path` a second companion for formats that need two
(AudioT's dictionary). `label_for_path` changes the label shown before
loading.

The registered visualizer is part of validation. Use `visualizer_name` in both
the format declaration and `TrackInfo`, which the build enforces, because the
shell picks the pane from `TrackInfo` while the registry only declares it. Use
`stream` for
register streams and `tracker` for formats that provide `TrackerView`.

## Loading contract

The loader signature is:

```zig
fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource
```

Return values have distinct meanings:

* Return `null` when the input is not the format or a supported variant.
* Return an error when the input is recognized but malformed, unsupported, or
  cannot be loaded.
* Return `error.OutOfMemory` unchanged when allocation fails.
* Return a source when loading succeeds.

`data`, `ctx.name`, `ctx.ext`, and `ctx.sibling` are borrowed. Copy anything the
source needs after `load` returns. The source owns every allocation stored in
its state and releases them in `deinit`.

If a source has no `durationFrames` method, sehnsucht loads the decoder a second
time and steps that independent source to measure duration. Loading must not
depend on global mutable state or retain pointers to temporary input. Each call
must produce an independent source.

`track_index` selects a member of an archive, counting from 0. Clamp an index
past the last member to the last member rather than failing, so `--track 99`
plays the final track instead of refusing the file. `tick_rate_hz` is a
requested rate override. Companion files, when requested by `sibling_path` and
`sibling2_path`, are available through `ctx.sibling` and `ctx.sibling2`.
`ctx.sibling_is_alt` is set when the bytes in `ctx.sibling` came from
`sibling_alt_path` because the primary companion could not be read. The second
companion is read tolerantly, so a decoder that requires it must check for
null and fail itself.

`TrackInfo.title` is metadata, not a display fallback. Leave it `null` when the
file carries no title and the format synthesizes none, so the shell can fall
back to the percent-decoded file name without its extension. A format that
puts the file name there instead defeats that fallback and shows the extension
in the header. Set `title_embedded` only for a title read out of the file.

## Source contract

A source type provides three public methods:

```zig
pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult
pub fn info(self: *Source) fmt.TrackInfo
pub fn deinit(self: *Source, gpa: std.mem.Allocator) void
```

Create the erased interface with:

```zig
return fmt.MusicSource.init(src);
```

`MusicSource.init` generates the `*anyopaque` adapter and vtable. Do not write
casts or an adapter vtable in the decoder.

The shared style the existing decoders follow (option structs instead of long
parameter rows, enums for file codes, layout structs for fixed records) is
listed under [Decoder conventions](architecture.md#decoder-conventions).

The adapter also discovers these public optional methods by name:

```zig
pub fn pos(self: *Source) fmt.TrackerPos
pub fn trackerView(self: *Source) fmt.TrackerView
pub fn getTickRate(self: *Source) u32
pub fn setTickRate(self: *Source, hz: u32) void
pub fn durationFrames(self: *Source) u64
```

`step` applies register writes until it reaches a delay or an end condition.
`frames` is the number of output frames before the next step. Set `done` at a
song boundary. A looping source rewinds its decoder state before returning that
boundary.

Every slice and pointer returned by `info`, `pos`, or `trackerView` must remain
valid until `deinit`. In particular, metadata strings cannot point into the
borrowed load input unless that input was copied into source-owned storage.

`deinit` runs exactly once for every returned source, including duration probes
and failed higher-level loads.

## Visualizers

`TrackInfo.visualizer` is required. `stream` needs no additional interface.
`tracker` requires `trackerView` and should also provide `pos`.

A tracker view contains borrowed pointers into the source. Its channel, row,
pattern, order, cell, and instrument data must remain valid for the source
lifetime.

## Errors

Common load errors have plain user-facing labels in `src/loaderr.zig`. A custom
error is shown using its Zig error name unless a label is added there. Use a
specific custom error when callers need to distinguish a recognized malformed
file from an unrelated format.

Do not discard allocation errors from optional metadata. Validate malformed
optional sections without failing the track, but propagate `error.OutOfMemory`.

## Tests

At minimum, test:

* The smallest valid file.
* Truncated headers and command records.
* Invalid offsets, lengths, counts, and indexes.
* End-of-stream and loop behavior.
* Duration and fractional timing.
* Metadata lifetime and cleanup.
* Allocation failure with `std.testing.checkAllAllocationFailures` when the
  decoder has several ownership transfers.

Run:

```text
zig fmt --check .
zig build test
zig build
```
