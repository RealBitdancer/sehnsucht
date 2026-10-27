# SNGPlay

**Extensions:** `.sng` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/sng.zig`

A raw OPL2 register stream from SNG Player v1.0 by BUGSY of OBSESSiON (1994).
Each record is a value and a register. Register 0 is a delay, not a chip write.
The original player clocks a row off VGA retrace, which AdPlug takes as 70 Hz.

External reference:
[AdPlug SNG player](https://github.com/adplug/adplug/blob/master/src/sng.cpp),
[AdPlug format library](https://adplug.github.io/library/entry/SNGPlay.html).

## Identification

1. The path ends in `.sng`, ignoring case.
2. The first four bytes are exactly `ObsM`.
3. The file is at least 12 header bytes plus one complete two-byte record.
4. The start and loop offsets land inside the kept record stream.
5. Walking from the start reaches a delay. A stream of only writes never yields.

Wrong magic declines the file, so Faust (`FMC!`) and Adlib Tracker 1.0 (a
36000-byte note grid) are not claimed. A recognized `ObsM` header with a
truncated body, an out-of-range start or loop, or no delay returns
`error.InvalidSng`.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 4 | ASCII `ObsM` |
| 0x04 | 2 | Stream length in bytes (`length`) |
| 0x06 | 2 | Playback start in bytes (`start`) |
| 0x08 | 2 | Loop point in bytes (`loop`) |
| 0x0A | 1 | Intro delay in ticks (`delay`) |
| 0x0B | 1 | Compressed flag (nonzero means packed delays) |
| 0x0C | … | Record stream |

`length`, `start`, and `loop` are byte offsets into the record stream, not
into the file. Divide by two to get a record index. An odd `length` drops the
stray byte. The kept stream is

```text
take = min(length, file_size - 12) / 2 * 2
```

Bytes after `take` are ignored. `PLAYMUS1.SNG` claims four bytes past the
file. `PLAYMUS2.SNG` stores two leftover bytes after a matching length.

### Records

Each record is two bytes:

| Byte | Field |
|-----:|-------|
| 0 | `val` |
| 1 | `reg` |

| `reg` | Meaning |
|------:|---------|
| `0` | Delay. See [Timing](#timing). |
| other | Write OPL register `reg` with value `val`. |

## Decoding

1. Require `ObsM`. Clamp the stream as above. Reject a start or loop that is
   not a record in that stream.
2. Walk from `start`. Continue from `loop` when the cursor moves past the last
   record, including in the middle of a row of writes. A pass that never hits
   a delay is `error.InvalidSng`.
3. On load, write OPL register `0x01` = `0x20` (waveforms enabled).
4. If the file is compressed and the intro byte is not zero, the first `step`
   waits that many ticks and writes nothing.
5. Later `step` calls write records until a delay, a song boundary, or 4096
   ops. Hitting the op cap returns `frames = 0` and keeps the cursor, so a
   storm of writes cannot stall the audio thread.

A delay record is never written to the chip.

## Timing

One tick is **70 Hz**. That is AdPlug's `getrefresh()` and the original
player's `WaitRetrace`. `--rate` does not apply.

```text
frames = rescale(ticks, 70, sample_rate)
```

with the shared fractional carry used by other stream formats.

| Compressed | Delay `val` | Ticks for that row |
|:----------:|------------:|-------------------:|
| yes | `N` ≠ 0 | `N` (the row plus `N - 1` wait ticks) |
| yes | `0` | 1 |
| no | any | 1 |

Uncompressed files ignore the intro byte. Compressed files count it once, at
the start of playback, not again after a loop.

Duration is `total_ticks * sample_rate / 70` for the intro (if any) plus one
pass that ends on the first wrap.

## Playback

SNGPlay uses the stream visualizer and OPL2 only. NEW stays off.
The display shows physical OPL voices, register activity, and measured audio.
Its dump view reports the 70 Hz clock and register-write count, excluding
delay records.

Playback starts at `start`, even when `loop` points elsewhere. At the first
wrap the decoder reports a song boundary (`done`) and leaves the cursor on
the record after that wrapping delay. The next `step` continues from there.
`TrackInfo.loop` is always set.

A wrap in the middle of a write run keeps writing from the loop point in the
same `step`. Those loop-point writes are part of the ending row, so the next
playthrough starts after the delay that closed it.

## Metadata

The format contains no metadata. Title stays unset so the shell can fall
back to the file name without its extension.

## Errors

Paths without `.sng` are not claimed. Wrong magic declines the file. A valid
magic with a short header, no complete record, a start or loop past the
stream, or a pass that never delays returns `error.InvalidSng`.
