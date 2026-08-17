# DRO (DOSBox Raw OPL)

**Extensions:** `.dro` (case-insensitive)
**Chip:** OPL2, Dual OPL2, or OPL3 as captured
**Module:** `src/formats/dro.zig`

A millisecond-resolution OPL register capture produced by DOSBox. Every write
a game made is stored with delays between them. Magic signature `DBRAWOPL`
(8 bytes at offset 0).

External reference:
[DRO format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/DRO_Format).

sehnsucht accepts the three header shapes found in the wild and both command
encodings (v1 stream and v2 codemap).

## Identification

All files begin with the exact eight bytes `DBRAWOPL`. The magic is not
NUL-terminated. Read the little-endian `u32` at offset `0x08` and choose a
layout in this order:

| Value at `0x08` | Layout |
|----------------:|--------|
| `0` or `0x00010000` | Versioned v1 |
| `2` | Version 2.0 |
| Any other value | Oldest 17-byte layout |

At least 12 bytes are required to identify a DRO file. A bad magic value means
the input is not DRO. A selected layout may impose a larger minimum size.

## File layout

All multi-byte integers are little-endian.

### Oldest 17-byte capture

Some very early DOSBox builds wrote no version field. After the magic, offset 8
is already the song length in milliseconds.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 8 | `DBRAWOPL` |
| 0x08 | 4 | length in milliseconds |
| 0x0C | 4 | length of command stream in bytes |
| 0x10 | 1 | hardware type |
| 0x11 | … | command stream |

The command encoding is the same as versioned v1. The rule is ambiguous. An
oldest-layout capture whose duration is 0, 2, or 65536 milliseconds will be
read as a versioned layout. There is no extra marker with which to settle the
argument.

### Versioned v0.1 / v1.0

Called v1.0 before DOSBox 0.73 and v0.1 after. The on-disk layout is the same.
The version dword is either `0x00010000` (bytes `00 00 01 00`) or `0` for a
misordered “version 0” variant that still uses this header.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 8 | `DBRAWOPL` |
| 0x08 | 4 | version (`0` or `0x00010000`) |
| 0x0C | 4 | length in milliseconds |
| 0x10 | 4 | length of command stream in bytes |
| 0x14 | 1 | hardware type |
| 0x15 | 3 | padding (must be zero in modern files) |
| 0x18 | … | command stream (24-byte header) |

**21-byte or 24-byte header.** Hardware type is at offset `0x14`. For a file of
at least 24 bytes, read a little-endian `u32` at `0x14`. If
`value & 0xFFFFFF00` is nonzero, the three bytes after hardware type are command
data and the stream begins at `0x15`. Otherwise they are padding and the stream
begins at `0x18`. Files shorter than 24 bytes use the 21-byte layout.

Modern writers zero the padding. This lets readers distinguish a padded header
from early files without consulting an oracle.

### Version 2.0

Version dword at offset 8 is `2`.

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x00` | 8 | `DBRAWOPL` |
| `0x08` | 4 | Version, value `2` |
| `0x0C` | 4 | Pair count |
| `0x10` | 4 | Length in milliseconds |
| `0x14` | 1 | Hardware type |
| `0x15` | 1 | Data format, must be 0 |
| `0x16` | 1 | Compression, must be 0 |
| `0x17` | 1 | Short-delay code |
| `0x18` | 1 | Long-delay code |
| `0x19` | 1 | Codemap length `N` |
| `0x1A` | N | Codemap of OPL register numbers |
| `0x1A + N` | Variable | Command pairs `(index, value)` |

sehnsucht rejects nonzero format or compression bytes.

The v2 header must contain at least `26 + N` bytes. The specification limits
the codemap to 128 entries. sehnsucht accepts a larger table if it fits, though
command indices can address only its first 128 entries.

## Decoding

### Stream bounds

For the oldest and versioned v1 layouts, begin with all bytes after the chosen
header. If command length is between 1 and the available byte count, keep
exactly that many bytes. If it is zero or larger than the available data, use
the full remainder.

For v2, the command stream has:

```text
min(remaining_file_bytes, pair_count * 2)
```

bytes. Compute the multiplication in a type wide enough to avoid overflow.
Bytes beyond that range are ignored.

The header duration is informational in every layout. A decoder should sum the
delay commands in the bounded stream.

### Hardware type

For v0.1 / v1.0 as DOSBox and [vgz2dro](https://github.com/RealBitdancer/vgz2dro)
write it:

| Value | Meaning |
|------:|---------|
| 0 | OPL2 |
| 1 | OPL3 |
| 2 | Dual OPL2 |

DOSBox 0.73+ (v2.0) swapped the encoding:

| Value | Meaning |
|------:|---------|
| 0 | OPL2 |
| 1 | Dual OPL2 |
| 2 | OPL3 |

sehnsucht decodes the byte according to the version. Unknown values are shown
as OPL2. The command stream still controls register banks.

### Register addressing

Maintain a bank base of `0x000` or `0x100`. Playback begins at `0x000`.
Register writes use:

```text
address = bank + register
```

In v1, commands `0x02` and `0x03` select the bank. sehnsucht honors them
regardless of the hardware-type byte. In v2, bit 7 of a register index selects
bank `0x100`.

### Command stream (v1 / oldest)

Playback starts in bank 0.

| Encoding | Meaning |
|----------|---------|
| `00 NN` | delay `NN+1` milliseconds (1…256) |
| `01 LL HH` | delay `(HH<<8\|LL)+1` ms (1…65536) |
| `02` | select bank 0 (OPL3 port 0, or Dual OPL2 chip 0) |
| `03` | select bank 1 (OPL3 port 1, or Dual OPL2 chip 1) |
| `04 RR VV` | escaped write to `bank + RR` for registers `0x00` through `0x04` |
| `RR VV` | write `VV` to `bank + RR` for `RR` from `0x05` through `0xFF` |

Delay codes store the duration minus one, so a stored zero means one
millisecond.

If an opcode lacks its required operand bytes, end the current pass.

### Command stream (v2)

Each command is two bytes `(index, value)`.

- If `index` equals the short-delay code, wait `value + 1` milliseconds. The
  range is 1 through 256 ms.
- If `index` equals the long-delay code, wait `(value + 1) << 8` milliseconds.
  The range is 256 through 65536 ms in steps of 256.
- Otherwise, use the low seven bits as a codemap index. Bit 7 selects bank
  `0x100`.

Delay codes are compared with the raw index before interpreting its bank bit.
If fewer than two bytes remain, end the pass. If a register index is outside
the codemap, also end the pass.

## Timing

Millisecond delays convert to device frames as
`ms * sample_rate / 1000` with a fractional remainder. At 44100 Hz, one
thousand 1 ms delays produce exactly 44100 frames.

Duration is the sum of decoded stream delays. The header duration is not used.

## Playback

- End of the bounded stream rewinds to the start, resets bank to 0, and reports a `done`
  edge so the engine loop counter advances. The player loops indefinitely.

sehnsucht uses the stream visualizer and sends both register banks to one
emulated OPL device. Dual OPL2 and OPL3 captures enable NEW at load.
Writes to `C0`..`C8` get CHA/CHB (`0x30`) so bank 1 is audible.

## Metadata

The format contains no text metadata. sehnsucht synthesizes a title such as
`DRO v1 (OPL2)` or `DRO v2 (Dual OPL2)`. The title is not embedded metadata.
The playlist column is `DRO`. After load the tag is `DRO` or `DRO2`.

## Errors

Bad magic or a file shorter than 12 bytes is not DRO. A truncated selected
header produces `TruncatedDro`. Nonzero v2 format or compression values produce
`UnsupportedDro2`. A truncated command or invalid codemap index ends the
current pass.

## Compatibility notes

- No side files. The capture is self-contained.
- Dual OPL3 is not representable in DRO v0.1. Converters that fold a second
  OPL3 chip onto one chip’s two banks preserve writes but not true dual-chip
  timing.
- Pair with [vgz2dro](https://github.com/RealBitdancer/vgz2dro) to turn
  OPL-family VGM/VGZ into DRO for playback here.
