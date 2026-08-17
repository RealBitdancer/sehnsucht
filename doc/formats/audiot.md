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

Names such as `AUDIOTEST.WL6`, `AUDIOTRACK.CK4`, and `AUDIODCT.CK4` do not
match. Any file of the family may be opened. An `AUDIOHED.*` entry resolves
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
`Format.sibling_path`, `Format.sibling_alt_path`, and `Format.sibling2_path`,
and the player hands it the bytes in `LoadContext.sibling` and
`LoadContext.sibling2`, with `LoadContext.sibling_is_alt` reporting when the
fallback was the file that loaded. The dictionary read is tolerant: for an
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
sehnsucht gives them no special meaning beyond the checks above.

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

sehnsucht does not parse the sound-effect formats. It finds music candidates
with this rule:

```text
chunk_size >= 400 AND first_four_bytes != "RIFF"
```

Candidates remain in header order. This is a practical filter, not part of the
Muse container specification. A large non-IMF chunk may pass it, and an
unusually small IMF chunk may not.

In a compressed archive the rule applies to the expanded data. Chunks whose
expanded size is below the threshold are skipped without decompression. All
expansions of one archive share a 16 MiB budget (the player's input cap):
a chunk whose expanded size does not fit in the remaining budget is skipped,
so a hostile header that lists the same byte range many times cannot expand
without bound.

Expansion attempts share a second budget of twice the input cap, charged by
compressed size before each Huffman walk. An attempt that fails or is
discarded afterwards keeps its charge, and a chunk larger than the remaining
budget ends the scan. A hostile header can therefore neither retain unbounded
output nor buy unbounded decompression work. Chunks rejected by the size
checks above never reach the Huffman walker and cost no work budget.

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
the last one. That index is per archive: advancing to another playlist
entry, jumping, or opening a file from Browse starts the new archive at
track 1. Replaying the same file (rate change, oneshot Space) keeps the
current index. An R rate chosen on this archive stays for those reloads. A
playlist skip or Enter jump clears it unless you launched with `--rate`.

### IMF inside a chunk

The selected chunk uses the plain IMF framing described in
[imf.md](imf.md). The `ADLIB` metadata wrapper is not checked inside AudioT.

1. Require at least four chunk bytes.
2. Read the first little-endian `u16`.
3. If it is zero, use the whole chunk as a type-0 command stream.
4. Otherwise use bytes after the prefix, clamped to the declared type-1 byte
   length.
5. Decode complete four-byte IMF records.

Type-1 lengths normally exclude Muse footer data. Type-0 chunks do not provide
that boundary, so trailing bytes may be interpreted as commands.

Early archives can use a four-byte IMF length. sehnsucht does not implement
that variant and reads only the two-byte form.

## Timing

The rate comes from the opened path's extension. Opening `AUDIOHED.WL6` or
`AUDIOT.WL6` both see `.wl6`.

| Extension | Default |
|-----------|--------:|
| `.wl1`, `.wl6`, `.sod`, `.sdm` | 700 Hz |
| `.sd1`, `.sd2`, `.sd3`, `.bs1`, `.bs6` | 700 Hz |
| Any other extension | 560 Hz |

Extension matching ignores case. A configured rate overrides the default.
Valid overrides are 280, 560, and 700 Hz. The **R** key cycles those values
during playback. Replay and `,` / `.` keep the choice. A playlist skip or
Enter jump returns to the path default unless you launched with `--rate`.

## Playback

The selected command stream uses the IMF decoder, OPL2, and the stream
visualizer. It loops like standalone IMF.

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
| Selected chunk cannot enter IMF framing | `BadImfInAudioT` |

A candidate that passes the size and `RIFF` filter can still fail IMF framing.
That fails the archive. The decoder does not try the next candidate.

Companion file read errors propagate from the underlying file or network I/O.
A corrupt dictionary or a truncated compressed chunk skips that chunk rather
than failing the archive.

## Compatibility notes

Four-byte early IMF lengths are unsupported. Music detection uses the size and
`RIFF` filter described above rather than game-specific `STARTMUSIC` tables.
Compressed sets need the extracted `AUDIOHED.*` and `AUDIODCT.*` files beside
`AUDIO.*`, since the originals live inside the game executable.
