# AudioT (Muse archive)

**Paths:** `AUDIOT.*`, `AUDIO.*`, and `AUDIOHED.*` (case-insensitive)
**Chip:** OPL2 for IMF music
**Module:** `src/formats/audiot.zig`

Muse archives were used by many id and Apogee DOS games. An archive has an
offset table and a data file. The data may contain PC speaker effects, AdLib
effects, digitized sounds, and IMF music.

External reference:
[AudioT Format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/AudioT_Format).

sehnsucht reads uncompressed `AUDIOT.*` pairs and Huffman-compressed `AUDIO.*`
archives. The compressed form ships with Commander Keen 4-6 and the Catacomb
Adventure games and needs an `AUDIODCT.*` dictionary beside it. The original
games linked the offset table and dictionary into the executable, so playing a
compressed set requires the extracted `AUDIOHED.*` and `AUDIODCT.*` files the
modding tools produce.

## Identification

Match the basename against `AUDIOT`, `AUDIO`, or `AUDIOHED`, ignoring ASCII
case. The stem must be followed by a dot or the end of the basename, which is
what keeps `AUDIO` from swallowing `AUDIOT`, `AUDIOHED`, and `AUDIODCT`.

Accepted examples:

```text
AUDIOT.WL6
AUDIO.CK4
AUDIOHED.CK4
audiot
data/Audiot.SOD
```

Names such as `AUDIOTEST.WL6`, `AUDIOTRACK.CK4`, `AUDIODCT.CK4`, and
`AUDIOMUS.CO7` do not match. `AUDIOMUS` is digitized audio, not the IMF
archive.

Any matching file of the family may be opened. An `AUDIOHED.*` entry resolves
the uncompressed `AUDIOT.*` companion first and falls back to the compressed
`AUDIO.*` when that read fails, so a Keen directory works from either file.

## File layout

### File family

| File | Role |
|------|------|
| `AUDIOHED.ext` | Little-endian `u32` offsets into the data file |
| `AUDIOT.ext` | Concatenated raw chunks |
| `AUDIO.ext` | Concatenated Huffman-compressed chunks |
| `AUDIODCT.ext` | Huffman dictionary for `AUDIO.ext` |

Companion names replace only the leading stem and preserve the rest of the
basename:

```text
AUDIOT.WL6    <-> AUDIOHED.WL6
AUDIOT        <-> AUDIOHED
AUDIO.CK4      -> AUDIOHED.CK4 and AUDIODCT.CK4
AUDIOHED.CK4   -> AUDIOT.CK4, falling back to AUDIO.CK4, plus AUDIODCT.CK4
```

Resolve companions in the same directory. The same rule applies to URL paths.
The decoder performs no I/O: it declares the companions through
`companions`, which returns a `CompanionPaths` value, and the player hands
it the bytes in `LoadContext.sibling` and `LoadContext.sibling2`, with
`LoadContext.sibling_is_alt` reporting when the fallback was the file that
loaded. The dictionary read is tolerant: for an
uncompressed set its absence is normal, and the decoder demands it only when
the compressed data file is the one in hand.

### AUDIOHED layout

`AUDIOHED` is an array of little-endian `u32` offsets. Its byte size must be a
multiple of four and at least eight. This provides at least two boundaries.

With `N` offsets, examine the `N - 1` consecutive pairs:

```text
start = offset[i]
end   = offset[i + 1]
chunk = AUDIOT[start .. end]
```

Apply these checks to each pair:

1. Skip it when `end < start`.
2. Skip it when either boundary is greater than the `AUDIOT` size.
3. Skip it when `start == end`.
4. Otherwise retain the half-open range `[start, end)`.

The final offset is only an end boundary. Invalid pairs are skipped rather than
causing the whole archive to fail. The archive is empty if no valid pair
remains.

Muse archives may contain `0xFFFFFFFF` placeholders and `!ID!` section tags.
Valid chunks retain their original slot indexes so section boundaries can
guide music selection.

### Compressed chunks

In an `AUDIO.ext` archive every chunk is Huffman-compressed:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | Expanded size, little-endian `u32` |
| 4 | Rest | Huffman bit stream |

`AUDIODCT.ext` holds the dictionary: 255 nodes of two little-endian `u16`
links, 1020 bytes, usually padded to 1024. Decoding starts at node 254 and
consumes source bits least-significant first. A link value below 256 emits
that byte and returns to the root. Any other value minus 256 is the next
node index. Decoding stops when the expanded size is reached.

A chunk whose bit stream ends early, or a dictionary that is short or points
at a node index of 255 or higher, invalidates that chunk. Bad chunks are
skipped the same way invalid offset pairs are.

## Decoding

### Chunk types

Games normally arrange chunks as PC speaker effects, AdLib effects, digitized
sound slots, then IMF music. The exact starting slot for music belongs to the
game executable or its generated C header. It is not stored as a portable
field in the archive.

When the first two `!ID!` section endings identify equal-sized PC-speaker
and AdLib groups, and the following digitized group contains only empty
slots or section tags, music starts after those three groups. Earlier chunks
are skipped. Otherwise the decoder examines every valid chunk.

Each candidate must contain complete IMF records, recognized OPL2 register
addresses, and at least one nonzero delay. Length headers must fit the chunk.
Short songs are accepted. Size alone cannot turn a sound effect into music,
and a malformed candidate cannot prevent a later valid song from loading.
Accepted streams remain in header order.

Archives without usable section markers still lack explicit type information.
Record validation cannot distinguish arbitrary data deliberately arranged to
look exactly like an IMF stream. The decoder does not claim otherwise.

Compressed chunks are validated after expansion. Expanded data and the two
slice entries retained per song share a 16 MiB budget (the player's input
cap). An expansion that cannot fit is skipped. Chunks smaller than one IMF
record are skipped without expansion.

Candidate scanning has a separate budget of twice the input cap. It counts
compressed bytes before each Huffman walk, or raw chunk bytes before record
validation. Failed and discarded candidates retain their charge. A chunk
larger than the remaining budget ends the scan. This bounds repeated work
when a malformed offset table refers to overlapping ranges.

### Track numbering

Track numbers refer to the filtered music candidates, not raw Muse slot
numbers.

| Input | Result |
|-------|--------|
| No `--track` | First candidate |
| `--track N` | Candidate N, counting from 1 |
| `--track 0` | Command-line error |
| N greater than candidate count | Last candidate |

Examples:

```text
sehnsucht AUDIOT.WL6
sehnsucht --track 2 AUDIOT.WL6
sehnsucht AUDIOHED.CK4
```

The **,** / **.** keys select the previous / next candidate and wrap after
the last one. AudioT keeps only the selected IMF stream, so those keys still
go through the loader (fetch, decode, duration). Extra presses while that
fetch is in flight update the pending subtrack on the same bytes. They do
not start a second download or cancel a playlist advance. That index is per
archive: advancing to another playlist entry, jumping, or opening a file
from Browse starts the new archive at track 1. Replaying the same file (rate
change, oneshot Space) keeps the current index. An R rate chosen on this
archive stays for those reloads. A playlist skip or Enter jump clears it
unless you launched with `--rate`.

### IMF inside a chunk

The selected stream uses the plain IMF records described in
[imf.md](imf.md). AudioT validates framing before adding a song to its list.
The `ADLIB` metadata wrapper is not checked inside AudioT.

1. Require at least four bytes.
2. Try the two-byte length, then the early four-byte length. The declared
   stream must fit exactly, optionally followed by an 88-byte Muse footer
   and a `!ID!` section tag. Matching bytes inside the declared stream remain
   music data.
3. If neither length fits, a leading zero word permits a bare command stream,
   with a trailing section tag removed.
4. Require complete four-byte records and at least one nonzero delay.
   Register addresses must belong to the OPL2 control, operator, frequency,
   rhythm, feedback, or waveform ranges. Register zero permits dummy writes.

Muse footer padding is not required to be zero. Real files contain unused
bytes left by the editor. Those bytes do not become register writes. A
truncated length-prefixed stream is rejected rather than clamped.

## Timing

The rate comes from the opened path's extension. Opening `AUDIOHED.WL6` or
`AUDIOT.WL6` both see `.wl6`.

| Extension | Default |
|-----------|--------:|
| `.wl1`, `.wl6`, `.sod`, `.sdm`, `.sd1`, `.sd2`, `.sd3` | 700 Hz |
| `.bs1`, `.bs6`, `.vsi`, `.co7`, `.bc` | 700 Hz |
| Any other extension (Keen `.ck*` included) | 560 Hz |

Extension matching ignores case. A configured rate overrides the default.
Valid overrides are 280, 560, and 700 Hz. The **R** key cycles those values
during playback. Replay and `,` / `.` keep the choice. A playlist skip or
Enter jump returns to the path default unless you launched with `--rate`.

## Playback

The selected command stream uses the IMF decoder, OPL2, and the stream
visualizer. A single archive repeats the selected member. A multi-entry
playlist advances at its song boundary. The display shows OPL voices,
register activity, and the selected IMF rate. Digitized sounds and PC-speaker
effects in the same archive are not played.

## Metadata

The synthesized title is:

```text
decoded data-file basename + " track " + selected_number + "/" + candidate_count
```

Opening `AUDIO.CK4` yields `AUDIO.CK4 track 1/N`. Opening `AUDIOHED.WL6` with
the uncompressed companion yields `AUDIOT.WL6 track 1/N`.

The format label is `AudioT`. The synthesized title is not embedded metadata,
so a playlist title may replace it in the player header.

## Errors

| Condition | Result |
|-----------|--------|
| The offset table's bytes were not supplied | `AudioTNeedsSibling` |
| A compressed archive without dictionary bytes | `AudioTNeedsDict` |
| AUDIOHED size is invalid | `BadAudioHed` |
| No valid offset pair | `EmptyAudioT` |
| No chunk passes the music filter | `NoMusicInAudioT` |

Companion file read errors propagate from the underlying file or network I/O.
A corrupt dictionary or a truncated compressed chunk skips that chunk rather
than failing the archive.

## Validation

The Wolfenstein shareware archive yields eleven songs and the compressed
Keen 4 shareware archive yields six. Every selected stream matched the
independently extracted register records and total timing, and produced
nonzero audio during a five-second render. Tests cover short songs, long
length fields, Muse footers, sound-effect lookalikes, section markers,
input ownership, and scan and expansion limits.
