# ROL

**Extension:** `.rol` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/rol.zig`

Visual Composer 0.4 stores separate note, instrument, volume, and pitch tracks
for each voice. Instruments come from a companion BNK file.

## Identification

The first four bytes are `00 00 04 00`, the little-endian version pair 0.4.
Other signatures are declined. A recognized file must have a nonzero
ticks-per-beat value and a supported melodic or rhythm mode.

## File layout

Integers and 32-bit floating-point values are little-endian. The fields used
by the decoder include:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | Version pair |
| 44 | 2 | Ticks per beat |
| 53 | 1 | Mode: 0 rhythm, 1 melodic |
| 197 | 4 | Base tempo in beats per minute |
| 201 | 2 | Number of tempo changes |
| 203 | variable | Tempo changes, followed by eleven voice records |

Each tempo change contains a 16-bit tick and a float multiplier. Each voice
has four tracks. The note track begins with a 15-byte name and a 16-bit length
in ticks, followed by 16-bit note/duration pairs. Note zero is a rest.
Durations must be nonzero.

The instrument track has a 15-byte name, a 16-bit event count, and records
containing a tick, a nine-byte instrument name, and three unused bytes.
Volume and pitch tracks use the same name/count prefix, followed by tick/float
pairs. Melodic mode consumes all eleven records but plays only the first nine.

## Companion bank

The named resource `rol.bank` tries `standard.bnk` and `STANDARD.BNK` beside
the song, locally or remotely. Instrument names are matched without ASCII
case. Missing names are errors. The player does not substitute another patch.

A bank has `ADLIB-` at offset 2. Its instrument count is at offset 10, followed
by 32-bit offsets to the name and patch tables at offsets 12 and 16. Name
records are twelve bytes, with a patch index and a nine-byte name. Patch
records are thirty bytes and describe two OPL operators and rhythm settings.

## Decoding and timing

The loader resolves instrument names and merges tracks into a tick-ordered
event list. At the same tick, releases precede instrument, volume, pitch,
tempo, and note events. Volume is clamped to 0 through 1. Pitch values must
be between 0 and 2, with 1 as the neutral value.

For an interval of `ticks`, the output duration is:

```text
frames = ticks * sample_rate * 60 / (base_tempo * tempo_multiplier * ticks_per_beat)
```

Fractional frames carry into the next interval. The initial tempo must be
between 1 and 1000 BPM. Tempo multipliers must be between 0.01 and 10.

## Playback and display

Melodic mode uses nine voices. Rhythm mode uses six melodic voices and five
percussion parts. The sequence visualizer shows their events, current notes,
instrument selections, and mapped OPL levels. The inspector exposes the full
event list and bank. The displayed tempo includes the current multiplier.

A same-tick run yields after 4096 events and continues on the next step.
Playback reaches a song boundary at the longest active note track. A single
ROL file plays once. Space replays it with reset channels, tempo, and event
cursor. The format supplies no song title to the shell, which uses the filename.

## Errors

| Condition | Result |
|-----------|--------|
| Different version signature | Decline (`null`) |
| Missing bank | `MissingResource` |
| Invalid BNK offsets or records | `InvalidRolBank` |
| Requested instrument absent from the bank | `MissingRolInstrument` |
| Truncated tracks, invalid timing, or unsupported mode | `InvalidMusicData` |

## References

Format reference:
[ROL specification](https://moddingwiki.shikadi.net/wiki/ROL_Format).
The bank layout is described in Tero Töttö's
[OPL programming guide](https://gist.github.com/tilhars/796fb490776e2d6d95b3).
