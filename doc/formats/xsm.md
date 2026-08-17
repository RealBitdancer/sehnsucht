# XSM (eXtra Simple Music)

**Extensions:** `.xsm` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/xsm.zig`

A nine-channel OPL2 note grid written for Davey W. Taylor's QBasic FMLIB
player (`SOUND.ABC`, 1997). There is no tracker, no effect column, and no
companion file. Each channel has one instrument for the whole song.

External reference:
[AdPlug XSM player](https://github.com/adplug/adplug/blob/master/src/xsm.cpp),
[AdPlug format library](https://adplug.github.io/library/entry/ExtraSimpleMusic.html).

## Identification

1. The path ends in `.xsm`, ignoring case.
2. The first six bytes are exactly `ofTAZ!`.
3. The little-endian song length at offset 6 is in `1..=3200`.
4. The file is long enough for the header, nine instrument slots, and
   `songlen * 9` note bytes.

Wrong magic, or a song length above 3200, declines the file. A recognized
header with a zero length or a truncated instrument or note block returns
`error.InvalidXsm`.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 6 | ASCII `ofTAZ!` |
| 0x06 | 2 | Row count (`songlen`) |
| 0x08 | 144 | Nine instrument slots, 16 bytes each |
| 0x98 | `songlen * 9` | Note grid, column-major |

Bytes after the claimed grid are ignored. `fantasy1.xsm` stores extra data
there. Playback uses only `songlen` rows.

### Instruments

Each slot is 16 bytes. The first 11 are an SBI voice block. The last 5 are
padding and are not read.

| Offset | Register |
|-------:|----------|
| 0 | `0x20 + op` modulator AM/VIB/EG/KSR/MULT |
| 1 | `0x23 + op` carrier AM/VIB/EG/KSR/MULT |
| 2 | `0x40 + op` modulator KSL/TL |
| 3 | `0x43 + op` carrier KSL/TL |
| 4 | `0x60 + op` modulator AR/DR |
| 5 | `0x63 + op` carrier AR/DR |
| 6 | `0x80 + op` modulator SL/RR |
| 7 | `0x83 + op` carrier SL/RR |
| 8 | `0xE0 + op` modulator wave |
| 9 | `0xE3 + op` carrier wave |
| 10 | `0xC0 + voice` feedback / connection |

`op` is the modulator slot for that voice (`00 01 02 08 09 0A 10 11 12`).

### Note grid

The file stores every row of channel 0, then every row of channel 1, through
channel 8. Playback indexes `row * 9 + channel` after unpacking.

A cell is one byte:

| Value | Meaning |
|------:|---------|
| `0` | Rest |
| `N` | Semitone `N % 12`, octave `N / 12` |

There are no instrument changes, volumes, or effects in the grid.

## Decoding

1. Read the header and reject a length of 0 or greater than 3200.
2. Copy the first 11 bytes of each instrument slot.
3. Unpack the column-major grid into row-major order.
4. On load, write `0x01 = 0x20` (waveforms enabled) and apply all nine
   patches.
5. Each `step` plays one row.

On a cell that differs from the same channel on the previous row, write
`B0 + ch = 0` first. Then write every channel's A0/B0 for the current row.

A rest writes `A0 = 0` and `B0 = 0x20` (key-on with a zero F-number). That
matches AdPlug. The first row compares against itself, so it never keys off
before sounding.

F-numbers are the twelve-entry AdLib table also used by HSC:

```text
363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686
```

`B0` is `(fnum >> 8) | 0x20 | ((N / 12) * 4)`. For those twelve values this
is the same bit pattern as AdPlug's `fnum / 0xff`.

## Timing

The tick rate is a fixed 5 Hz. One row is one tick:

```text
frames = rescale(1, 5, sample_rate)
```

Duration is `songlen * sample_rate / 5`. The rate is not adjustable.

## Playback

XSM uses the stream visualizer and OPL2. NEW stays off. `C0` is written as
stored.

After the last row, the decoder rewinds to row 0 and reports a song
boundary (`done`). There is no native loop point in the file. The source
still reports `loop = true`, like IMF and RAW, so the shell keeps playing
from the start.

## Metadata

The format contains no metadata. Title stays unset so the shell can fall
back to the file name without its extension.

## Errors

Paths without `.xsm` are not claimed. Wrong magic or `songlen > 3200`
declines the file. A valid magic with a truncated header, a zero length, or
a note block shorter than `songlen * 9` returns `error.InvalidXsm`.

## Compatibility notes

* AdPlug also caps `songlen` at 3200 and ignores trailing bytes. The four
  known songs (`child1`, `easy1`, `fantasy1`, `jungle1`) are the FMLIB demo
  set. No later XSM files are known.
* AdPlug writes feedback as `0xC0 + op_table[i]`, so voices 3-8 land on
  `C8`, `C9`, `CA`, `D0`, `D1`, and `D2`. sehnsucht writes `0xC0 + voice`
  (`C0`..`C8`), the real OPL feedback registers, same as BAM. Channels 3-8
  will not match AdPlug's timbre.
* AdPlug's end tick resets the row counters and then plays row 0 again as
  part of that same update. sehnsucht rewinds and reports `done` without
  emitting that extra row. The next `step` after the boundary plays row 0.
* AdPlug accepts `songlen == 0` and then indexes an empty note buffer.
  sehnsucht returns `error.InvalidXsm`.
* The original QBasic player is FMLIB in the All BASIC Code archive. Davey
  W. Taylor's later FM Tracker uses an incompatible format.
