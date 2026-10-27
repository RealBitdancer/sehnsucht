# Visualizer architecture

A format chooses one of three visualizers through `visualizer_name`. The
registry checks its declared capabilities against the visualizer's required
views. Loading checks the views actually returned by the source. Formats
publish data through `src/view.zig` and do not import drawing code. Visualizers
do not import format implementations.

## Current mapping

| Visualizer | Required view | Optional views | Registered formats |
|------------|---------------|----------------|--------------------|
| Tracker | Pattern | Order, instruments | HSC/HSP, RAD, A2M/A2T, LDS/LD0, XSM |
| Sequence | Sequence | Instruments | ADL, BAM, CMF, JBM, KSM, LAA, Lucasfilm AD, MusicV, ROL, SCI0, XMI |
| Stream | None | Dump, instruments | AudioT, DRO, GOT, IMF/WLF/ADLIB, RAW/RAC, SNGPlay, VGM/VGZ |

These are twenty-three format modules. Aliases and wrappers share their parent
module's view. The [format inventory](retromusic-formats.md) records proposed
mappings for formats that have not been implemented.

`ViewCaps` describes pattern, order, instrument, sequence, and dump views.
`Format.view_caps` is the compile-time declaration. `SourceViews.caps()`
describes the loaded source. A missing required view fails loading with
`MissingVisualizerData`.

## Static data and live state

Static views borrow storage owned by the loaded source. Their callbacks read
immutable patterns, events, instruments, and bytecode. Callbacks may return
values or fill a caller-owned scratch buffer. They must not read playback
state that the audio thread changes.

The audio callback publishes pointer-free playheads, channel state, sequence
voices, per-channel pattern cursors, and chip state through `Bridge`. Each
seqlock stores both its sequence counter and payload bytes atomically. A reader
accepts a snapshot only when the counter remains unchanged and even. Reads
have bounded retries. An atomic counter around ordinary mutable bytes would
still leave a data race.

The callback publishes source snapshots once per output buffer. Missing
optional snapshots are cleared. `DrawContext` borrows those snapshots and
static views for one draw call. Temporary display data belongs in `ctx.arena`.
Nothing allocated there may survive the frame.

Per-song navigation lives in `viz.Navigation`, which `DrawContext.nav` points
to. It holds channel paging, instrument selection, and every scroll offset.
`Model.setTrack` replaces it with defaults, so a new field needs only a
default value. An optional scroll offset is `null` while the view follows
playback. Any explicit position, including zero, pins the view. Home returns
to following.

Text in views and `TrackInfo` should be UTF-8. A2M, CMF, IMF, KSM, RAD, and
ROL transcode their CP437 text with `src/cp437.zig`. `paint` still accepts
invalid bytes and draws each as U+FFFD. Measuring them directly with
`Window.gwidth` can overflow inside libvaxis, so visualizers measure source
text with `paint.textWidth`.

`ChannelState.instrument` is the number a pattern cell shows for that
instrument. A channel without one publishes `view.instrument_none`.

## Tracker

`PatternView` describes channel and row counts, cell occupancy, effect
columns, optional riffs, and rate text. It also names the F-number of each
semitone in its tuning (`fnum_notes`) and how far its block numbers sit from
the shown octave (`fnum_octave_offset`), so channel heads name sounding voices
the way the grid does. A2M and LDS put C at F-number 343. HSC, RAD, and XSM
keep the default table with C at 363. `OrderView` supports shared pattern
indices, per-channel pointers, and per-channel pattern indices.
`PatternCursorBank` can supply an independent cursor for every logical channel.

The pane shows patterns, instruments, orders, and a hardware spectrum. Macro,
live-state, and riff regions appear when the source supplies them. The macro
region appears when any instrument in the bank has macros, so the auxiliary
region does not change with the playing instrument. The
instrument bank supports two-operator and four-operator OPL patches, MIDI
programs, and samples. Macro headers and steps remain inspectable.

Pattern channel count and hardware voice count are separate. RAD 2 has nine
pattern channels but can use eighteen physical OPL3 voices. A2M supports up
to twenty pattern channels. `channelInfo` supplies the physical `opl_voice`
mapping, names, and channel roles. Without it, the mapping is by index.
Four-operator patches retain all four operators and their algorithm. Gauge
labels follow the patch's operator order, including RAD's carrier-first layout.

Effect meanings belong to the decoder. HSC jump markers and A2M order markers
must not acquire meaning from a visualizer's format-name check. An order
`.jump` entry carries only `jump_to`, the target order index. Its `pattern`
field has no meaning.

Channel paging moves a page start by up to half a page to the nearest start
that keeps four-operator pairs together. The first page always starts at the
first channel and the final page always ends at the last channel, so either may
split a pair. Left and Right always move the grid to a different start.
Compact strips keep their position (`I0A/31`, `MACRO 3/16`, `LIVE 1/20`,
`RIFF 2/9`, `ORDER 10/16`), and the live strip steps through every channel.
The ORDER and auxiliary strips are as wide as their longest position. The
instrument strip keeps its `Ixx/n` head whole and cuts the patch summary and
name after it, so it keeps its total at the minimum width. A per-channel cursor bank whose active
cursors agree sets the current row for the whole frame, so the grid never mixes
two publishes. The live-state region
scrolls on its own, so every channel stays reachable even when the pattern
grid shows them all. A per-channel order list pages with the grid. Its column
is one cell wider than a shared order list, so the longest LDS ref
(`9:7FFF-64i`) prints whole. Up and Down in the
order region move a selection, and the list centers on it. Pattern
numbers use decimal in the info row and the order list. Row numbers use the
gutter's radix in both places.

Backtick cycles the available regions. Arrow and paging keys move within the
selected region. A channel column is at least as wide as its cell plus the
separator. Narrower windows page channels at that same width instead of
clipping cells.
Auxiliary regions become compact strips below height 20, and also in a taller
pane that cannot fit the full spectrum, the 26-column instrument region, and
ORDER side by side. The spectrum keeps every voice in a tall pane. When a tall
pane has no column left for the macro, live-state, or riff region, its strip
appears under the instrument title, and focusing it draws the region in the
instrument area. The inspector keeps full values accessible when they cannot
fit in a strip.

## Sequence

`SequenceKind` selects the presentation:

| Kind | Presentation | Current users |
|------|--------------|---------------|
| `linear_midi` | Events in a tick window | CMF, KSM, LAA, Lucasfilm AD, ROL, SCI0, XMI |
| `voice_programs` | Independent bytecode windows | Westwood ADL |
| `event_stream` | Indexed command list with offsets | BAM, JBM, MusicV |

`eventsInRange` uses an inclusive start and exclusive end. Instrument indices
must agree between events, live voices, and bank lookups. Same-tick events are
preserved, including a program change followed by a note. Chords show a note
count rather than silently losing all but one note.

`SequenceView.position_unit` describes the playhead. BAM uses `event_index`.
JBM and MusicV use ticks and supply `eventAt` in stable tick order. The pane
finds the last event at or before the playhead and highlights its tick group.
Elapsed ticks are not array indices.

Voice programs publish their live program counter through a snapshot.
`bytecodeWindow` and `bytecodePage` decode immutable program bytes from that
position. The latter permits complete inspection beyond the first scratch
buffer. Inactive programs use `sequence_pc_none`.

Song-level events appear in FLOW. Westwood's separate control track appears
in CTRL. A source with a control track, such as SCI0 channel 15, lists its
song-level events in CTRL beside that track's events. Both follow the playhead: they show the nearest matching events and
highlight the last one at or before it. A tick-based source is queried within
1024 ticks of the playhead, narrowed while the result overflows the buffer.
An indexed source is scanned at most 512 events in each direction. Notes use
linear semitone values, so packed format-specific pitch bytes must be
converted before publication.

A source whose song-level events are mostly delays can publish its structure
instead. `SequenceView.markerAt` returns `marker_count` markers in stream
order, each holding an event and its position in the view's `position_unit`.
FLOW then lists those markers in a 16-column panel and highlights the last
one at or before the playhead, found by binary search.
BAM publishes its labels, jumps, chorus returns, and stop this way, computed
once at load.

The grid scroll is a 32-bit tick, event, or bytecode offset. The grid uses
every visible row. A branch payload keeps its kind and repeat count in the
cell (`J` jump, `G` call, `RET`, `R` loop, `S` skip). BAM branches retain their kind,
target, and repeat count. ADL branch cells print the four-digit destination
offset, and the inspector names it as an offset rather than a label. ADL exposes wait duration, tempo, priority, call
depth, and active effects when space permits.

An event stream (BAM, JBM, MusicV) draws a piano roll in each voice row when
the row has at least 16 free columns after its meter. Each column covers 40
ms, so the window grows with the pane, and a scale above the rows shows its
span and the playhead. The roll reads events in score ticks: `duration_note`
spans its duration, `note_on` lasts until that voice's next note or
`note_off`, and a note already sounding is found by reading one window back.
Past notes are dim, the sounding note uses the key-on style, and coming notes
use the note style. Each onset is marked, so repeated notes stay distinct.
A name follows the onset only when it leaves a free column before the next
note. An indexed source places the playhead at the score tick of its current
event.

Sequence meters and spectrum bars represent logical channels. They combine
all active voices assigned to each channel, using actual OPL mappings or
measured PCM levels. CMF percussion voices remain distinct even when two drums
share a physical OPL channel. SCI0 adds a PCM lane after its sixteen MIDI
channels. PCM levels use a 0 through 255 scale and do not require a fictitious
OPL voice or note.

At 80 by 25, the pane retains a mixer and shorter spectrum. A pane narrower
than 84 columns gives the spectrum only the room CTRL or FLOW leaves, so that
panel appears at every width, and Left/Right pages the bars that do not fit.
At the minimum 46 by 15, every sequence kind uses a compact live strip and
event area. Left/Right pages channels. The inspector provides complete events
and instrument data.

## Stream

The Stream pane places an OPL voice rack beside a PCM spectrum. Each voice
shows note, two- or four-operator role, rhythm state, pan, and level with peak
hold. Left/Right pages hardware voices. Taller windows show recent register
writes. Narrow windows use a note strip, then the analyzer alone. Stereo
meters and RMS history remain below the panels.

`DumpView` supplies chip class, clocks, loop position, write count, and timing
metadata. A write count counts register writes. It excludes delays, bank
selection commands, and end records. Dual-OPL2 captures use both hardware
banks. A native OPL3 capture retains its recorded mode and panning.
Dual OPL3 uses two independent chips and 36 snapshot entries. The rack labels
each chip and local channel, and paging reaches the last voice. Register
history uses `chip:register` notation.

Y8950 captures place up to two ADPCM voices above the FM channels in the left
rack. Each has a level meter, effective rate, volume, and idle, playing,
paused, repeat, or speaker-muted state. Memory playback adds the current and end
addresses and a position bar measured from the sample's start. CPU-fed audio
has no bounded memory range, so it shows CPU DATA without a position bar.
Memory ranges that wrap retain their addresses without a percentage.
Sample playback remains visible even when no new FM registers are written.

Short racks keep the status and level rows. The four-row ADPCM layout appears
only when the FM rack still has room for every voice, so a taller pane never
shows fewer voices. Narrow windows put compact ADPCM rows above the spectrum.
Register history rereads the write counter after copying and drops any slot
the audio thread may have replaced meanwhile. A second Y8950 traces its
ADPCM registers on bank 1, beside its FM registers. FM paging accounts for the sample rows so every
hardware channel remains reachable. `Bridge.pcm` supplies all sample data.
Inspect retains the full register values and sample addresses.

## Meters and loading

OPL meters measure actual output operators. A four-operator primary uses its
paired output channel and panning. Both physical halves show that voice's
output level. Key-off removes the strike boost while leaving the release
visible. Meters follow the stored speaker bits and pairing, which NEW does not
reset.
PCM analysis and output meters are measured before volume and mute.

Starting a load stops audio and clears live snapshots, register history, PCM
analysis, and held meters. The active visualizer remains selected and dimmed.
Its immutable source views remain available to draw an idle layout. Removing
those views too early would leave Tracker and Sequence without required data.

The loader detaches borrowed views before freeing the old source. If a fetch
fails while that source is still available, playback can resume. The loader
keeps a copy of the snapshots and register history it cleared and writes them
back before it restarts the engine, so a paused or parked track shows its last
position again. A successful
replacement resets the view and live state for the new source.

## Inspector and shared drawing

`src/visualizers/common.zig` contains shared drawing and formatting helpers.
Its `describeSequenceEvent` serves the sequence pane and inspector.
`src/inspector.zig` owns the popup's state, input, and rendering alongside
`src/ui.zig`, which opens it independently of the active visualizer.

I opens a centered, bordered popup over a dimmed pane. It exposes available
metadata, instruments, macros, pattern cells, channels, events, branches,
orders, and chip state. Its event cursor is 32-bit. Long lines can be panned
to the widest line on the page and no further, and bytecode can be paged
without truncating the program. The chip section names the chip from
`DumpView.chip`, or from `TrackInfo.opl3` without a dump, and reports the NEW
bit separately. Loaders set NEW on OPL2 captures for dual-OPL2 playback, so
NEW alone does not identify the chip. Each macro table is listed up to its
own length.

The inspector reads static views and snapshots. An explicit branch selection
sends a label through `Bridge.branch_request`. The audio thread calls the
source's optional branch handler. A successful branch discards the outstanding
wait. A rejected label leaves playback intact.

All colors and text styles come from the theme. The layout takes cues from
[Cubic Player](https://www.cubic.org/player/screenshot.html) and
[ProTracker](https://16-bits.org/pt2.php): compact channel readouts, grouped
meters, panel borders, and a distinct current row.

## Input and future formats

Clickable footer controls use the same geometry as the rendered labels.
`paint.drawHotkeyHints` records only enabled, visible controls in `HotkeyHits`.
Each frame clears old hit areas. Mouse-generated keys pass through the same
transport handlers as keyboard input. The inspector captures mouse input
while open. See [Controls and playlist modes](hotkeys-and-playlist-modes.md).

The interfaces can represent mixed PCM, four-operator patches, independent
channel streams, and explicit branches. Those capabilities do not implement
an absent decoder. S3M, EdLib, SOP, HERAD, and the other unimplemented families
still need parsing, playback, and format-specific validation. Known limits of
existing decoders remain in the [format guides](formats/README.md).
