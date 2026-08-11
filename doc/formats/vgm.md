# VGM / VGZ (Video Game Music log)

**Extensions:** `.vgm`, `.vgz` (case-insensitive)
**Chip:** OPL family
**Module:** `src/formats/vgm.zig`

VGM is a chip-write log timed in 44100 Hz samples. It may contain a loop point
and GD3 metadata. VGZ contains the same VGM bytes compressed with gzip.

External reference:
[VGM Specification](https://vgmrips.net/wiki/VGM_Specification).

## Identification

sehnsucht dispatches this decoder for `.vgm` and `.vgz` paths. After that
dispatch, either extension may contain raw VGM or gzip data.

1. If the first two bytes are `1F 8B`, inflate the input as gzip.
2. Require at least `0x40` decompressed bytes.
3. Require the four bytes `Vgm ` at offset zero.
4. Resolve and validate the command data offset.
5. Require at least one supported OPL clock field before the command data.

Decompressed data is limited to 16 MiB.

## File layout

### Relevant header fields

All numeric fields are little-endian. Relative offsets are measured from the
address of their own field.

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x00` | 4 | Magic `Vgm ` |
| `0x04` | 4 | EOF offset, relative to `0x04` |
| `0x08` | 4 | BCD version, such as `0x00000171` |
| `0x14` | 4 | GD3 offset, relative to `0x14` |
| `0x18` | 4 | Total sample count at 44100 Hz |
| `0x1C` | 4 | Loop offset, relative to `0x1C` |
| `0x20` | 4 | Loop sample count |
| `0x34` | 4 | Command data offset, relative to `0x34` |
| `0x50` | 4 | YM3812 clock |
| `0x54` | 4 | YM3526 clock |
| `0x58` | 4 | Y8950 clock |
| `0x5C` | 4 | YMF262 clock |

An offset value of zero means that the optional target is absent. For example:

```text
gd3_position  = 0x14 + gd3_offset
loop_position = 0x1C + loop_offset
```

sehnsucht uses total samples for duration. It does not use loop samples, the
header rate field, volume modifiers, or the VGM 1.70 extra header.

### Command region

For version `0x150` or later, a nonzero field at `0x34` gives:

```text
data_start = 0x34 + data_offset
```

The result must be between `0x40` and the file size, inclusive. A zero data
offset, or any version before `0x150`, selects `0x40`.

The default command end is the file size. A nonzero EOF field may replace it:

```text
candidate_end = 0x04 + eof_offset
```

Use that candidate only when it is greater than `data_start` and no greater
than the file size.

Header fields at or beyond `data_start` are not read as header fields. This
prevents command bytes in short headers from being mistaken for chip clocks.

### VGZ compression

Gzip detection uses the two magic bytes `1F 8B`. Raw input is copied without
decompression. Decompressed data is the VGM file described above.

## Decoding

### OPL scope

Read each supported clock only when all four bytes precede `data_start`. Mask
the value with `0x3FFFFFFF`. At least one resulting value must be nonzero.

| Chip | Clock offset | Primary commands |
|------|-------------:|------------------|
| YM3812 | `0x50` | `0x5A`, `0xAA` |
| YM3526 | `0x54` | `0x5B`, `0xAB` |
| Y8950 | `0x58` | `0x5C`, `0xAC` |
| YMF262 | `0x5C` | `0x5E`, `0x5F`, `0xAE`, `0xAF` |

Other chip clocks may be present. Their commands are skipped. A file without a
qualifying OPL clock fails with `NonOplVgm`.

All supported chip types feed one emulated OPL device. A second OPL2-family
instance maps to bank 1. A second OPL3 instance is dropped: both banks already
belong to the first chip, and folding a second chip onto them would let the two
write streams fight over the same registers. The first chip plays correctly and
the second stays silent.

When a YMF262 clock is present, initialize OPL3 mode by writing `0x01` to
register `0x105`.

### OPL register writes

Each command below is three bytes: opcode, register, value.

| Opcode | Address written |
|-------:|-----------------|
| `0x5A`, `0x5B`, `0x5C`, `0x5E` | `register` |
| `0x5F` | `0x100 + register` |
| `0xAA`, `0xAB`, `0xAC` | `0x100 + register` |
| `0xAE`, `0xAF` | None (second YMF262, skipped) |

Y8950 ADPCM data blocks are skipped. Only its FM register writes are played.

### Wait commands

| Opcode | Wait |
|-------:|------|
| `0x61 nn nn` | Little-endian `u16` samples |
| `0x62` | 735 samples |
| `0x63` | 882 samples |
| `0x70` through `0x7F` | `(opcode & 0x0F) + 1` samples |
| `0x80` through `0x8F` | `opcode & 0x0F` samples |

Commands `0x80` through `0x8F` normally combine a YM2612 DAC write with a
wait. sehnsucht ignores the DAC write but preserves the wait. `0x80` has no
wait.

### Data transfer commands

A data block has this canonical layout:

```text
67 66 tt ss ss ss ss [data]
```

`tt` is the block type. The little-endian `u32` size begins at the fourth byte
of the command. Mask its high bit before using it:

```text
data_size = stored_size & 0x7FFFFFFF
next      = command_position + 7 + data_size
```

sehnsucht skips every block type. It does not validate the `0x66` marker or
interpret `tt`.

Opcode `0x68` is a fixed 12-byte PCM RAM write command. It is also skipped.

### Commands skipped by size

A parser must know the size of unrelated commands to remain synchronized.
Sizes include the opcode.

| Opcode or range | Size |
|-----------------|-----:|
| `0x30` through `0x3F` | 2 |
| `0x40` through `0x4E` before VGM 1.60 | 2 |
| `0x40` through `0x4E` from VGM 1.60 | 3 |
| `0x4F`, `0x50` | 2 |
| `0x51` through `0x59`, `0x5D` | 3 |
| `0x90`, `0x91`, `0x95` | 5 |
| `0x92` | 6 |
| `0x93` | 11 |
| `0x94` | 2 |
| `0xA0` through `0xA9`, `0xAD` | 3 |
| `0xB0` through `0xBF` | 3 |
| `0xC0` through `0xDF` | 4 |
| `0xE0` through `0xFF` | 5 |

Handled OPL commands, waits, and data transfers take precedence over these
ranges.

If an unknown opcode appears, or a command extends past the bounded command
region, end playback. This is a playback end rather than a load error.

### End and loop handling

Opcode `0x66` ends the command stream.

A loop offset is accepted only when it points into
`[data_start, command_end)`. The first `0x66` is eligible to loop. After a loop
jump, another jump is allowed only when a wait has produced at least one output
frame. Report one completion edge when jumping.

Otherwise finish. This guard prevents a zero-time loop from spinning forever.
A missing or invalid loop offset also causes `0x66` to finish playback.

Reaching the command end or a malformed command has the same finish behavior.
After finishing, sehnsucht returns a short silent wait on later decoder calls.

## Timing

Convert wait samples to output frames with a running remainder:

```text
numerator = wait_samples * output_rate + remainder
frames    = numerator / 44100
remainder = numerator % 44100
```

Duration is:

```text
total_samples * output_rate / 44100
```

The loop sample count does not affect this value.

## Playback

VGM uses the stream visualizer. Supported OPL writes are sent to one emulated
device using the bank mapping above. End commands and valid loop points follow
the rules under [End and loop handling](#end-and-loop-handling).

## Metadata

### GD3

The GD3 field points to this structure:

| Relative offset | Size | Field |
|----------------:|-----:|-------|
| `0x00` | 4 | Magic `Gd3 ` |
| `0x04` | 4 | GD3 version |
| `0x08` | 4 | Body byte length |
| `0x0C` | Variable | Eleven NUL-terminated UTF-16LE strings |

The body must fit in the file. The strings are:

| Index | Meaning | Used by sehnsucht |
|------:|---------|-------------------|
| 0 | English title | Yes |
| 1 | Japanese title | No |
| 2 | English game | Yes |
| 3 | Japanese game | No |
| 4 | English system | Yes |
| 5 | Japanese system | No |
| 6 | English artist | Yes |
| 7 | Japanese artist | No |
| 8 | Release date | No |
| 9 | VGM creator | No |
| 10 | Notes | No |

Strings are converted to UTF-8. Valid surrogate pairs are combined. Invalid
code units are skipped. A bad GD3 magic, range, or allocation does not prevent
the music from loading.

English GD3 title, game, system, and artist fields are shown when present. A
GD3 title is embedded metadata.

## Errors

| Error | Condition |
|-------|-----------|
| `NotVgm` | Decompressed input is short or has bad magic |
| `InvalidVgmOffset` | Computed command start is outside its valid range |
| `NonOplVgm` | No supported OPL clock appears before command data |
| `GzipFailed` | Gzip stream is invalid |
| `StreamTooLong` | Decompressed data exceeds 16 MiB |

## Compatibility notes

The decoder targets VGM versions 1.00 through 1.71. Later versions remain
readable when they use the same command sizes and header rules.

[vgz2dro](https://github.com/RealBitdancer/vgz2dro) converts OPL-family VGM and
VGZ files to DRO.
