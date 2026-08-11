# RAW (Rdos / RAC raw OPL capture)

**Extensions:** `.raw` (case-insensitive)
**Chip:** OPL2 (optional second chip via bank select)
**Module:** `src/formats/raw.zig`

A register capture produced by RdosPlay and related tools (historically RAC).
Each record is a register write or a control code. Timing comes from the PC
interval timer divisor stored in the file.

External reference:
[AdPlug RAW player](https://github.com/adplug/adplug/blob/master/src/raw.cpp).

## Identification

1. The path ends in `.raw`, ignoring case.
2. The first eight bytes are exactly `RAWADATA`.
3. At least ten header bytes and one complete two-byte record are present.

A bad magic value means the input is not RAW (return `null`). Truncated bodies
after a valid magic return `error.InvalidRaw`.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 8 | ASCII `RAWADATA` |
| 0x08 | 2 | Initial timer divisor (`speed`) |
| 0x0A | … | Record stream |

A zero divisor is treated as `0xFFFF` (about 18.2 Hz).

### Records

Each record is two bytes:

| Byte | Field |
|-----:|-------|
| 0 | `param` (data / delay / control argument) |
| 1 | `command` (OPL register or control code) |

### Control codes

| `command` | `param` | Meaning |
|----------:|--------:|---------|
| `0x00` | *N* | Delay *N* ticks (*N* = 0 means 256) |
| `0x02` | `0` | Next record is the new speed: `param + (command << 8)` |
| `0x02` | *C* ≠ 0 | Select chip *C* − 1 (bank `0x100 * (C - 1)`) |
| `0xFF` | `0xFF` | End of stream |
| other | *V* | Write register `command` with value `param` on the active bank |

A delay of zero never occurs in real captures, and the format specification
does not define it. Playing it as 256 ticks is this player's defensive choice.
AdPlug's delay counter underflows instead and waits 65536 ticks.

### Optional tags

After the `FF FF` end marker, some files store:

| Marker | Content |
|--------|---------|
| `0x1A` | NUL-terminated title (up to 40 bytes) |
| `0x1B` | NUL-terminated author (up to 60 bytes) |
| `0x1C` | Description (ignored for playback) |

Older archives omit `0x1B` and place a printable author string directly after
the title. Tag bytes are never played.

## Decoding

1. Read the header and isolate the stream up to and including the first `FF FF`
   end marker. The record after a set-speed command is a 16-bit operand rather
   than a command, so a speed of `0xFFFF` is skipped instead of ending the
   stream.
2. On load, write OPL register `0x01` = `0x20` (waveforms enabled).
3. For each record, apply the control table above.
4. Register writes use bank base `0` or `0x100` for the second chip.

## Timing

Refresh rate in hertz is:

```text
rate = 1_193_180 / speed
```

where `speed` is the current divisor (header value, then any mid-stream update).
A delay of *N* ticks becomes:

```text
frames = rescale(N * speed, 1_193_180, sample_rate)
```

with the shared fractional carry used by other stream formats.

## Playback

RAW uses the stream visualizer and OPL2 (dual-chip captures set bank `0x100`).
When the stream ends, the decoder rewinds to the first record and reports a
song boundary (`done`).

## Metadata

A tag title is embedded metadata when non-empty. Author maps to the track
artist field. Files without tags report no title so the shell can fall back to
the file name.

## Errors

Paths without `.raw` are not claimed. Wrong magic declines the file. A valid
magic with a truncated header or a body shorter than one record returns
`error.InvalidRaw`.

## Compatibility notes

* Generic `.raw` dumps that are not Rdos captures are declined by the magic
  check.
* Track duration is measured by stepping a second instance of the decoder at
  load time, so mid-stream speed changes are counted exactly.
* Description tags after `0x1C` are ignored.
