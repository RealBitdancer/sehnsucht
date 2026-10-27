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
The expanded size is bounded. The gzip CRC32 and size footer must match the
decoded bytes. A truncated or corrupt stream fails with `GzipFailed`.

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

The YMF262 clock's bit 30 declares a second OPL3 chip. Both chips have their own
Opal instance, register banks, mode bits, panning, and four-operator pairs.
The engine advances them over the same waits and mixes their stereo output.
One chip cannot overwrite the other's registers. The rack exposes all 36
voices, with chip and channel labels and horizontal paging.

A second OPL2-family instance still maps to bank 1 of the first Opal instance.

OPL2-family captures enable NEW (`0x105` = `1`) at load so a second OPL2 on
bank 1 is a real second chip. Their writes to `C0`..`C8` receive CHA/CHB
(`0x30`). Native OPL3 captures control NEW and panning through their own
register writes, including deliberate channel muting.

### OPL register writes

Each command below is three bytes: opcode, register, value.

| Opcode | Address written |
|-------:|-----------------|
| `0x5A`, `0x5B`, `0x5E` | `register` |
| `0x5C` | `register`, or `0x100 + register` beside a YM3526 or YM3812 |
| `0x5F` | `0x100 + register` |
| `0xAA`, `0xAB`, `0xAC` | `0x100 + register` |
| `0xAE` | Second chip, `register` |
| `0xAF` | Second chip, `0x100 + register` |

Second-YMF262 writes are ignored when the header does not declare that chip.
Internally, register bit 9 selects the second Opal instance. Each instance
receives only the low nine bits. The single-device adapter rejects addresses
outside its own banks.

### Y8950 ADPCM

Y8950 writes split between FM and the Delta-T decoder in `src/y8950.zig`.
Register `0x08` shares FM and ADPCM controls. Its high two bits reach FM and
its low bits select ADPCM memory and conversion options.

Playback supports external sample memory and CPU-fed bytes through `0x0F`.
Start, reset, repeat, speaker mute, Delta-N frequency, and linear volume are
applied at the recorded command times. CPU writes in memory-transfer mode
populate sample RAM. Address units are four bytes for 1-bit DRAM and 32 bytes
for ROM or 8-bit DRAM. The stored end address includes its final address unit.
Registers `0x13` and `0x14` are the memory limit. Reaching that unit wraps the
address to zero. An unwritten limit stays open (`0xFFFF`). Unpopulated memory
reads as `0xFF`.

Each declared Y8950 owns at most 2 MiB of sample memory. A dual-Y8950 header
creates two independent ADPCM voices. Allocation occurs during loading.
Playback allocates nothing. ADC recording and external input are not part of
log playback. Direct DAC conversion and VGM DAC stream-control commands are
not interpreted.

The decoder advances at the header clock divided by 72. Delta-N supplies the
fractional nibble rate. Prediction, adaptive step size, and interpolation run
at that clock, then produce output at the device sample rate. A clock above
64 MHz or a zero output rate is rejected. This bounds work for malformed
headers while leaving ample room around the normal Y8950 clock.

The PCM renderer adds both ADPCM voices to the two FM outputs before final
clipping and the player's volume controls. Pause stops all synthesis.
Stream's left rack shows sample activity, effective rate, volume, and level.
Memory playback adds sample addresses and a position bar. Short or narrow
windows use compact readouts. Inspect retains the full memory or CPU mode,
repeat, speaker state, and sample addresses.
ADPCM register writes enter the same history without being sent to Opal.

Validation compared 16,384 generated samples with the independent
[ymfm Delta-T implementation](https://github.com/aaronsgiles/ymfm/blob/main/src/ymfm_adpcm.cpp).
The comparison covered both memory address units, CPU-fed bytes, repeat,
frequency and volume changes, reset, and restart. Output matched exactly.
The reference program and generated samples are not part of the repository.

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
wait. A single `step` caps skipped and zero-wait commands at 4096 and
returns `frames = 0` so a long `0x80` or data-block run cannot stall the
audio thread.

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

Type `0x88` supplies Y8950 sample memory. Its payload starts with the total
memory size and destination byte offset, both little-endian `u32`, followed
by sample bytes. The high bit of the block size selects the second Y8950.
The destination and payload must fit the declared memory size and the chip's
2 MiB address space. Blocks are copied when their commands execute, so later
uploads and loops retain their recorded order.

Y8950 files validate block markers, sizes, and sample-memory ranges during
loading. Playback bounds-checks copies as well, including loop destinations.
Other block types are skipped.

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

The loop sample count does not affect this value. A header total of 0 yields
no native duration. The loader then probe-steps a second instance, as it
does for other formats that omit `durationFrames`.

## Playback

VGM uses the stream visualizer. Supported OPL writes use the chip and bank
mapping above. OPL2 compatibility writes and native
OPL3 mode follow the rules under [OPL scope](#opl-scope).
End commands and valid loop points follow the rules under
[End and loop handling](#end-and-loop-handling).

The dump view reports chip class, clock, loop status, register-write count,
and the number of ADPCM voices.
The count uses the same command lengths as playback and excludes waits and
commands for unsupported chips. The live rack shows physical OPL voices.

Labels: `VGM` or `VGZ` from the path.

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
| 1 | Japanese title | Fallback |
| 2 | English game | Yes |
| 3 | Japanese game | Fallback |
| 4 | English system | Yes |
| 5 | Japanese system | Fallback |
| 6 | English artist | Yes |
| 7 | Japanese artist | Fallback |
| 8 | Release date | No |
| 9 | VGM creator | No |
| 10 | Notes | No |

Strings are converted to UTF-8. Valid surrogate pairs are combined. Invalid
code units are skipped. A bad GD3 magic or range does not prevent the music
from loading. An allocation failure while converting the strings fails the
load (`error.OutOfMemory`).

English GD3 title, game, system, and artist fields are shown when present.
Each empty English field falls back to its Japanese counterpart. A GD3
title is embedded metadata.

## Errors

| Error | Condition |
|-------|-----------|
| `NotVgm` | Decompressed input is short or has bad magic |
| `InvalidVgmOffset` | Computed command start is outside its valid range |
| `NonOplVgm` | No supported OPL clock appears before command data |
| `GzipFailed` | Gzip stream is invalid |
| `StreamTooLong` | Decompressed data exceeds 16 MiB |
| `InvalidVgmClock` | Y8950 clock exceeds 64 MHz or output rate is zero |
| `InvalidVgmDataBlock` | Truncated block, invalid marker, or sample memory range outside the declared size |
| `OutOfMemory` | Allocation failed (inflate, sample memory, or GD3 strings) |
