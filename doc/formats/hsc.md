# HSC tracker format

**Extensions:** `.hsc`, `.hsp` (case-insensitive)
**Chip:** OPL2
**Tick rate:** 91/5 Hz
**Module:** `src/formats/hsc.zig`

HSC is a tracker format by Hannes Seifert. A file contains 128 instruments, a
51-byte order list, and up to 50 patterns. It has no magic value. A parser must
use the extension and structural limits. `.hsp` is the same bytes packed with
RLE by Number Six / Aegis (`HSCOMP` / `hsc2hsp`). A `.hsp` path reports format
name `HSP`.

External reference:
HSC-Tracker 1.5 `HSCPLAY.EXE` (HSCOBJ 1.4). File-layout notes also appear in
[libxmp's hsc.txt](https://github.com/cmatsuoka/libxmp/blob/master/docs/formats/hsc.txt).
That text describes AdPlug-style effects. Playback here follows HSCOBJ 1.4.
Packed files use Aegis HSC Interface 1.1 (`agshsc.doc`) as their reference.

## Identification

sehnsucht dispatches this decoder for `.hsc` and `.hsp` paths.

For `.hsc`:

1. The file is at least 2739 bytes.
2. The file is no larger than 59188 bytes.
3. At least one complete pattern follows the 1587-byte header.

For `.hsp`:

1. The file is at least two bytes.
2. The little-endian word at offset 0 is the uncompressed size. It is in
   `1..=59188`.
3. The RLE stream that follows unpacks to a valid HSC file.

The pattern count is:

```text
min(floor((file_size - 1587) / 1152), 50)
```

Bytes after the last complete pattern do not count toward the pattern view.
Playback still reads any whole cells there when the order list reaches that
pattern. A size word of 0, or a
size above 59188, declines a `.hsp` file. A recognized size word whose
unpacked bytes would not load as HSC returns `error.InvalidHsp`.

## File layout

Unpacked HSC uses only bytes. There are no multi-byte integers in that
container. Packed `.hsp` prefixes those bytes with a little-endian size word
and RLE runs, described below.

| Offset | Size | Content |
|-------:|-----:|---------|
| 0 | 1536 | 128 instruments, 12 bytes each |
| 1536 | 51 | Order list |
| 1587 | 1152 per pattern | Pattern data |

A pattern has 64 rows and 9 channels. Each cell is two bytes. Cells are stored
by row, then by channel.

```text
cell_offset = 1587 + pattern * 1152 + (row * 9 + channel) * 2
note        = file[cell_offset]
effect      = file[cell_offset + 1]
```

Valid row numbers are 0 through 63. Valid channel numbers are 0 through 8.

### Packed (`.hsp`)

A packed file is little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 2 | Uncompressed size (`orgsize`) |
| 2 | rest | RLE runs |

Each run is two bytes. Byte 0 is the count (`0..=255`). Byte 1 is the value.
A count of 0 writes nothing. Runs continue until `orgsize` bytes are written
or the stream ends. A trailing odd byte is ignored. If a run would pass
`orgsize`, only the remaining bytes are written. If the stream ends early,
the actual unpacked length is kept.

### Instruments

Each instrument is a direct set of OPL2 register values plus a pitch offset.

| Byte | Meaning | OPL register for channel 0 |
|-----:|---------|----------------------------|
| 0 | Carrier characteristics | `0x23` |
| 1 | Modulator characteristics | `0x20` |
| 2 | Carrier KSL and level | `0x43` |
| 3 | Modulator KSL and level | `0x40` |
| 4 | Carrier attack and decay | `0x63` |
| 5 | Modulator attack and decay | `0x60` |
| 6 | Carrier sustain and release | `0x83` |
| 7 | Modulator sustain and release | `0x80` |
| 8 | Feedback and connection | `0xC0` |
| 9 | Carrier waveform | `0xE3` |
| 10 | Modulator waveform | `0xE0` |
| 11 | Pitch offset in the high nibble | None |

Apply these transformations when loading an instrument:

```text
byte[2]  = byte[2] XOR ((byte[2] AND 0x40) << 1)
if byte[8] bit 0 is set:
    byte[3]  = byte[3] XOR ((byte[3] AND 0x40) << 1)
pitch    = byte[11] >> 4
```

The xor flips bit 7 when bit 6 is set. It is the closed form of the original
player's volume flush: `0x3F` minus the byte, keep bits 7-6, invert the low
six bits again. That flush always runs for the carrier. It runs for the
modulator only when the instrument is additive (`byte[8]` bit 0). An FM
modulator is written as the file byte, so its KSL bits stay as stored. AdPlug
xors both operators at load, which turns an FM modulator `0xC0` into `0x40`
and makes high notes on that patch much louder.

The characteristics byte uses the normal OPL2 layout. Bits 7 through 4 are
tremolo, vibrato, sustain, and key-scale rate. Bits 3 through 0 are the
frequency multiplier.

The level byte stores KSL in bits 7 and 6 and attenuation in bits 5 through 0.
Attack, decay, sustain, and release each occupy one nibble. The waveform number
is the low three bits. In byte 8, bit 0 selects additive synthesis and bits 3
through 1 hold feedback.

The operator offsets for channels 0 through 8 are:

```text
00 01 02 08 09 0A 10 11 12
```

Add the channel's operator offset to each register shown in the table.

### Order list

The order list begins at offset 1536 and contains 51 bytes.

| Value | Meaning |
|------:|---------|
| `0x00` to `0x31` | Pattern 0 through 49 |
| `0x32` to `0x7F` | Invalid pattern reference |
| `0x80` to `0xB0` | Jump to order position `value & 0x7F` |
| `0xB1` | Jump to order position 0 |
| `0xB2` to `0xFF` | End of song |

The decoder copies the 51 file bytes and turns values from `0xB2` through
`0xFE` into `0xFF`. The tracker order pane uses that copy but only through the
first `0xFF`, so the terminator and any bytes after it are not extra rows.
Playback does not use that copy. It reads
`file[1536 + order_pos]` the same way HSCOBJ indexes the order table. A
pattern number at or past the loaded pattern count still plays: cells past
the end of the file are empty. After a pattern finishes (row 64, or effect
`0x01`), the order position increases by one. If that slot has bit 7 set, it
is a jump or end marker, not a pattern. `0xFF` and jump targets of 49 or
above go to position 0. Targets 0 through 48 are used as written. The jump
marks a song boundary for loop counting. Bit 7 is not read in the middle of a
pattern, only after the position advances. Order position 51 and above can
land in pattern bytes, which matches HSCOBJ.

### Pattern cells

#### Note byte

| Note value | Meaning |
|-----------:|---------|
| `0x00` | No note. The effect still runs |
| `0x80` | Set the channel instrument to `effect & 0x7F` |
| `0x7F` | Note off |
| Other valid value | Encoded note |

For an ordinary note:

```text
n        = note - 1
semitone = n % 12
octave   = n / 12
note     = 1 + semitone + 12 * octave
```

Octave is `n / 12` in eight-bit arithmetic. HSCOBJ does not treat large
octaves as note off. Setting an instrument consumes the entire cell. No
effect or note is processed after it.

The original player handles the note before the effect. A new note replaces the
channel's 16-bit frequency word, then `0x1n` / `0x2n` slide that new word.

#### Effect byte

The exact byte `0x01` is pattern break. Every other non-zero effect is split
into a high nibble (command) and a low nibble (argument).

| Effect | Meaning |
|-------:|---------|
| `0x01` | Break the pattern after this row |
| `0x1n` | Add `n + 1` to the low byte of the channel frequency word |
| `0x2n` | Subtract `n + 1` from that low byte |
| `0xAn` | Write `n << 2` to the carrier level register |
| `0xBn` | Write `n << 2` to the modulator level register |
| `0xCn` | Write `n << 2` to the carrier, and to the modulator if additive |
| other | Set speed to `n + 1` |

HSCOBJ has no pattern-effect handlers for fade, rhythm, feedback, or order
jump. Bytes such as `0x03`, `0x05`, `0x06`, `0x5n`, `0x6n`, and `0xDn` fall
through to speed, the same as `0x3n` and `0xFn`. Fade is player function
`ah = 3`, not a pattern cell. Register `0xBD` is written once at init (`0`).
AdPlug treats `0x5n` as percussion, `0x6n` as feedback, `0xDn` as a jump, and
`0x03` as fade.

For `0x1n` and `0x2n` the add wraps in the low eight bits and does not carry
into the block or key-on bits. The original player uses `n + 1`, not `n`.
AdPlug adds `n` to a 16-bit F-number and can change the high F-number bits.

`0xAn`, `0xBn`, and `0xCn` replace the whole level byte. They do not keep the
instrument's KSL bits. For `n << 2` in `0x00` through `0x3C` that is the same
value HSCOBJ's volume flush would store.

## Decoding

A `.hsp` file is unpacked first. The rest of this section is the HSC
bytes, packed or not.

### Pitch and key handling

The original player stores a 16-bit word per channel:

```text
word = frequency[semitone] + (octave << 10) + 0x2000
```

`0x2000` is key-on (bit 5 of `0xB0`). Octave lives in bits 10 through 12, which
become bits 2 through 4 of `0xB0`. The twelve F-numbers are:

```text
363 385 408 432 458 485 514 544 577 611 647 686
```

C-0 is `0x216B`. B-6 is `0x3AAE`. Note off clears bit `0x2000` of the stored
word.

When writing the chip, `0xA0` gets the low byte plus the instrument pitch
offset (file byte 11, high nibble). That add wraps in eight bits and does not
change `0xB0`. `0xB0` gets the high byte of the stored word.

A new note writes `0xB0 = 0` first, then replaces the stored word and marks
the channel dirty. After all nine channels, the player writes `0xA0`/`0xB0`
only when the channel is dirty or the current instrument's slide is not
zero. An instrument-set cell writes `0xB0 = 0` and programs the patch, but
it does not mark the channel dirty. With slide 0 the key stays off until the
next note. With a non-zero slide the end-of-row write restores the stored
word. If the channel already uses that instrument, HSCOBJ skips the cell
entirely, so the key stays on.

### Rhythm mode

Register `0xBD` is `0` after init. Pattern cells do not write it. Melody
notes always use the key-on bit in the frequency word.

## Timing

The decoder runs at 91/5 ticks per second. Convert one decoder tick to output
frames with:

```text
numerator = sample_rate * 5 + remainder
frames    = numerator / 91
remainder = numerator % 91
```

The initial speed is 2 and the initial delay is 1. The first decoder tick
processes a row. After a row is processed, delay is reset to speed. Later ticks
decrease delay and process another row only when it reaches zero. Every
unmatched effect, including `0xFn`, `0x3n`, `0x5n`, `0x6n`, and `0xDn`,
changes speed to `n + 1`.

## Playback

Initialize OPL2 with these writes:

```text
register 0x01 = 0x20
register 0x08 = 0x40
register 0xBD = 0x00
```

`0x08 = 0x40` is NOTE-SEL. The original player writes that value. AdPlug writes
`0x80` (CSM) instead.

Assign channel `i` to instrument `i` for all nine channels and program those
instruments before playback starts.

For each processed row:

1. Read the current order entry as a pattern index. Jump and end markers are
   not interpreted here.
2. Process channels 0 through 8 in order.
3. For each cell: if the note is `0x80`, set the instrument and skip the
   rest. Otherwise play the note, then apply the effect.
4. Write `0xA0`/`0xB0` on channels that are dirty or have a non-zero slide.
5. Advance the row, or apply a pattern break.
6. Advance the order position when the row wraps from 63 to 0, then resolve
   a jump or end marker in that slot.

Song boundaries report one completion edge after the last played row, then
playback continues from the resolved order position. The sehnsucht shell
treats that edge as the end of the current file. A single file still loops
until quit, and a multi-entry list advances or parks on the last track when
list loop is off. Parking waits for that last row's audio and tracker
cursor before pause.

## Metadata

HSC stores no title or other text. The shell uses the decoded filename without
its extension. The decoder exposes order position, row, pattern, speed,
last triggered instrument, instrument data, decoded cells, and live channel state
(instrument, key-on, last note, programmed modulator and carrier levels) to
the tracker visualizer. The pattern strip prints `Pattern xx/nn` in decimal, the
fixed tick as `Rate 18.2 Hz`, and nibble effects keep the stored byte. Pattern
break is marked `01!`. Speed, including fallthrough bytes such as `03` and
`53`, is marked with a trailing `s` (`F3s`, `53s`). Slide and volume bytes are
unmarked hex. Channel heads show the sounded OPL pitch when that voice is
keyed, otherwise `-n-`. LIVE shows `{ch} Ixx {carrier TL}` when the last `0xB0`
write left key-on, and `{ch} Ixx --` when it did not. An instrument-set with
slide 0 writes `0xB0 = 0`. LIVE follows that write even if the stored frequency
word still has key-on. Unused
instrument slots (not 0 through 8 and never referenced by an `Ixx` cell) show
as `UNUSED`. Instrument slide is `SL` on the instrument title. Operator
columns are labeled MOD then CAR. Instrument-set cells show `effect & 0x7F`.
Ordinary notes use `octave = n / 12` without wrapping to 0..7, matching
`noteWord`.

## Errors

Wrong extensions and files outside the accepted size range are not claimed as
HSC. A `.hsp` size word outside `1..=59188` is not claimed. A recognized
packed size whose unpacked bytes HSC would decline returns `error.InvalidHsp`.
Order end values are folded to `0xFF` only in the order pane's copy, as
described under [Order list](#order-list). Invalid pattern references are not
repaired. They play, and cells past the end of the file are empty. Incomplete
trailing pattern bytes are left out of the pattern count but still play when
the order list reaches them.
