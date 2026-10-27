# MusicV (Silky's WM)

**Extensions:** `.wm`, `.m` (case-insensitive)
**Chip:** OPL3 (six 4-operator voices)
**Module:** `src/formats/wm.zig`

A six-voice OPL3 bytecode sequencer from MUSICV_2.COM, the DOS sound driver
used in visual novels by Silky's (Elf Co., Ltd.). Each voice is an independent
command stream. Instruments are 30-byte 4-operator patches. There is no
companion file.

External reference:
[AdPlug WM player](https://github.com/adplug/adplug/blob/master/src/wm.cpp),
[AdPlug format library](https://adplug.github.io/library/entry/MusicV.html).

[The sample playlist](../../playlists/wm.m3u) links to the 21 root `.wm` files
in [MusicV.zip](https://adplug.github.io/library/files/MusicV.zip). The player
can extract remote ZIP members in memory. See
[Remote files](../../README.md#remote-files) for limits. Music remains external
to the repository. The replayer's license does not license the music files.

## Identification

1. The path ends in `.wm` or `.m`, ignoring case.
2. The first 16 bytes are exactly `OPL3 DATA` followed by seven spaces.
3. The file is at least 32 header bytes and at most 65536 bytes (offsets are
   16-bit).
4. At least one of the six track offsets points at a stream at or after byte
   0x20 and before `eof`.

Wrong magic declines the file, so Ultima 6 `.m` is not claimed. A recognized
header with no usable track returns `error.InvalidWm`. A file larger than
65536 bytes is declined, matching AdPlug.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 16 | ASCII `OPL3 DATA       ` |
| 0x10 | 12 | Six track offsets, one `u16` per voice |
| 0x1C | 2 | Instrument-table file offset (`inst`) |
| 0x1E | 2 | End-of-stream marker (`eof`) |
| 0x20 | … | Track streams, then the instrument table |

`eof` below 0x20 (including 0) or past the file means the end of the file.
A track offset inside the header, at or past `eof`, or past the file is
unused. `inst` inside the header or past the file means there is no
instrument table.

The instrument table runs from `inst` to the nearest later track offset, or
to `eof`, or to the end of the file. Each slot is 30 bytes. At most 64 slots
are kept. Leftover bytes after the last whole slot are ignored.

Tracks share the flat file. There is no per-track length. Each voice reads
from its offset through `eof` and stops on `0xF0`.

### Instruments

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 20 | Four operators, five register groups each (`0x20`, `0x40`, `0x60`, `0x80`, `0xE0`) |
| 0x14 | 1 | Flags. Low two bits are the 4-op algorithm. C0 receives `flags >> 1` ORed with the xlat byte, so bit 1 is its connection and bits 2-4 its feedback. C3 takes the same value with bit 0 as its connection |
| 0x15 | 1 | Instrument id. Command `0x81` looks up this byte, not the slot index |
| 0x16 | 1 | Vibrato rate, low two bits |
| 0x17 | 1 | Vibrato speed. Zero disables the preset |
| 0x18 | 2 | Vibrato amplitude |
| 0x1A | 1 | Vibrato delay |
| 0x1B | 1 | LFO period (`lfo_lo`). Zero with `lfo_hi` disables the preset |
| 0x1C | 1 | LFO step (`lfo_hi`) |
| 0x1D | 1 | LFO delay |

Carrier operators for volume scaling come from `conn_table[flags & 3]`:
`0x08`, `0x0A`, `0x09`, `0x0D`. Volume 0..15 maps through a 16-entry
attenuation table (0 is quiet, 15 is loud).

### Voices

Six assembler channels map onto OPL3 4-operator pairs:

| Voice | OPL channel | Bank | Slot |
|------:|------------:|-----:|-----:|
| 0 | 0 | 0 | 0 |
| 1 | 1 | 0 | 1 |
| 2 | 2 | 0 | 2 |
| 3 | 9 | 1 | 0 |
| 4 | 10 | 1 | 1 |
| 5 | 11 | 1 | 2 |

Register `0x104` = `0x3F` pairs all six. Key-on uses `A0`/`B0` of the OPL
channel. Feedback lives on `C0` and `C3` of the slot.

## Decoding

1. Require the magic. Clamp `eof` and `inst`. Drop unusable track offsets.
2. Parse whole 30-byte instrument slots. Lookup at play time is by id.
3. Copy the file into a working buffer. Counted repeats (`0xF2`) rewrite a
   counter byte in that copy. Song end restores the copy from the original.
4. On load, enable NEW (`0x105` = `0x01`) first, then write `0x104` = `0x3F`
   (all six 4-operator pairs) and `0xBD` = `0x40` (tremolo and vibrato
   depth). Opal ignores bank-1 registers other than `0x105` while NEW is
   off, so pairing must come after that enable.
5. Each voice starts with `wait` = 1, volume 10, expression 0, ties factor 0,
   C-register xlat index 3, and no instrument, as MUSICV_2.COM's channel init
   leaves them. A duration-1 note reached in a voice's first fetch never keys
   on, because that init replaces it before it sounds.
6. One `step` is one tick. Every active voice is processed, then its
   frequency, vibrato, slide, and LFO are updated. A voice that never
   reaches a wait after 4096 commands yields one tick so a tight jump
   cannot stall the audio thread.
7. An invalid relative jump skips the operand instead of hanging on it.

### Commands

Bytes `00`..`7F` are notes. The next byte is duration in ticks. Ties factor
`N` keys off at `dur - dur*N/8` ticks, at least 1, unless `0x83` is pending.

| Byte | Data | Meaning |
|------|------|---------|
| `00`..`7F` | 1 duration | Note on. Retriggers unless skip-setup is set |
| `80` | 1 duration | Rest. Clears key-on |
| `81` | 1 id | Load the patch with that instrument id |
| `82` | none | No-op |
| `83` | none | Next note keeps the previous key (skip ties) |
| `84` | 1 `u16` tempo | Recalculate the tick rate (see [Timing](#timing)) |
| `85` | 1 factor | Ties factor, low three bits |
| `86` | none | No-op |
| `87` | 1 volume | Volume 0..15 |
| `88` | 1 signed | Global transpose |
| `89` | 1 index | C-register xlat index |
| `8A` | 1 value | Expression = value − 1, then volume is rewritten |
| `8B` | 1 `i16` | Pitch wheel added to the raw frequency |
| `8C` / `8D` | none | Expression up / down, 0..7 |
| `8E` / `8F` | none | Volume up / down, 0..15 |
| `90` | 2 notes, 1 duration | Slide from note to note over the duration |
| `91` | rate, speed, `i16` amp | Portamento / vibrato preset |
| `92` / `93` | none | Vibrato on / off |
| `94` | 1 delay | Portamento delay |
| `95` | 1 byte | Skip one byte |
| `A0`..`EF` | none | No-op |
| `F0` | none | End of voice. Key off |
| `F1` | 1 `i16` | Jump. Offset is relative to the operand, not to the next opcode. A backward target is the voice's master loop |
| `F2` | 1 count, 1 `i16` | Counted jump. Decrements the in-stream count. Offset is relative to after the operand |
| `F3` | 1 byte, 1 `u16` | Skip three bytes |
| `F4` | 1 value | Push onto the 16-deep parameter stack |
| `F5` | 1 `i16` | If stack top is 1, jump (F1-style) and pop, else skip the word |
| `F6` | 1 `i16` | Decrement stack top. Jump while not zero, else skip and pop |
| `F7` | 1 signed byte | If stack top minus one is 0, jump from the operand byte and pop, else skip |
| `F8` | 1 signed byte | Decrement stack top. Jump while not zero, else skip and pop |
| `F9` | 1 reg, 1 val | Raw OPL write on bank 0 |
| other `Fx` | none | No-op |

Frequency is a 16-bit phase increment from a 128-entry table, transposed,
then shifted down until it fits 10-bit F-NUM. Pitch wheel, vibrato, and
slide are added as signed 16-bit quantities and wrapped before that shift.

## Timing

Default rate is **200 Hz**. Command `0x84` with value `V` > 0 sets

```text
pit_div = max(1, 1491475 / V)
tick_rate = 1193180 / pit_div
```

using integer division, matching MUSICV_2.COM. `--rate` does not apply.

```text
frames = rescale(pit_div, 1193180, sample_rate)
```

per tick, with the shared fractional carry. Duration is that sum over one
pass that ends when every still-active voice has taken a backward `0xF1`,
or when no voice remains active (`0xF0` or the cursor ran off `eof`), or
after 2 000 000 ticks.

## Playback

MusicV uses the sequence visualizer and OPL3. NEW stays on. Voices are six
4-operator channels, not eighteen 2-operator ones.

The command list uses `position_unit = .tick`. The playhead is elapsed driver
time, while `eventAt` indexes the measured events in tick order. The visualizer
looks up the current event from its tick instead of treating the tick as an
array index.

`TrackInfo.loop` is set when the first pass ends on a master `0xF1` rather
than on every voice going inactive. At a song boundary the working copy is
restored and voices rewind to their track starts. The last tick's chip
writes still play for that tick's delay. The next `step` writes the OPL3
prologue again, then the first commands, so counted-repeat counters and
4-operator pairing start clean.

## Metadata

The format contains no metadata. Title stays unset so the shell can fall
back to the file name without its extension.

## Errors

Paths without `.wm` or `.m` are not claimed. Wrong magic declines the file.
A valid magic with a short header or no usable track returns
`error.InvalidWm`. A file larger than 65536 bytes is declined.
