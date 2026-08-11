# HSC tracker format

**Extension:** `.hsc` (case-insensitive)
**Chip:** OPL2
**Tick rate:** 91/5 Hz
**Module:** `src/formats/hsc.zig`

HSC is a tracker format by Hannes Seifert. A file contains 128 instruments, a
51-byte order list, and up to 50 patterns. It has no magic value. A parser must
use the extension and structural limits.

External reference:
[HSC format notes (libxmp)](https://github.com/cmatsuoka/libxmp/blob/master/docs/formats/hsc.txt).

## Identification

sehnsucht accepts a file when all of these conditions hold:

1. The path ends in `.hsc`, ignoring case.
2. The file is at least 2739 bytes.
3. The file is no larger than 59188 bytes.
4. At least one complete pattern follows the 1587-byte header.

The pattern count is:

```text
min(floor((file_size - 1587) / 1152), 50)
```

Bytes after the last complete pattern are ignored.

## File layout

All values are bytes. There are no multi-byte integers in the container.

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
byte[3]  = byte[3] XOR ((byte[3] AND 0x40) << 1)
pitch    = byte[11] >> 4
```

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
| `0x80` to `0xB1` | Jump to order position `value & 0x7F` |
| `0xB2` to `0xFF` | End of song |

sehnsucht builds a 128-byte working order list. It copies the 51 file bytes and
fills the remaining entries with `0xFF`. It then applies two repairs:

* A pattern number greater than or equal to the loaded pattern count becomes
  `0xFF`.
* Every value from `0xB2` through `0xFE` becomes `0xFF`.

Sequential playback advances order positions modulo 50. It therefore visits
positions 0 through 49. The byte at position 50 is retained for file fidelity
but is not reached by this decoder.

When an order jump is read, playback sets the order position to `value & 0x7F`,
resets the row to zero, and reads the target order entry. The jump also marks a
song boundary for loop counting. Only one jump is resolved during a processed
row. A target that is itself a jump or end marker is not interpreted until a
later row update.

An end marker marks a song boundary, resets the order position to zero, and
continues from the first order entry.

### Pattern cells

#### Note byte

| Note value | Meaning |
|-----------:|---------|
| `0x00` | No note. The effect still runs |
| Bit 7 set | Set the channel instrument to the full effect byte |
| `0x7F` | Note off |
| Other valid value | Encoded note |

For an ordinary note:

```text
n        = note - 1
semitone = n % 12
octave   = n / 12
note     = 1 + semitone + 12 * octave
```

Octaves 0 through 7 are valid. A value outside that range acts as note off.
Setting an instrument consumes the entire cell. No effect or note is processed
after it. Instrument indices 128 through 255 are ignored.

Every nonzero note with bit 7 clear resets the channel's accumulated slide.
This includes note-off and invalid-octave values.

#### Effect byte

The high nibble selects the command. The low nibble is its argument.

| Effect | Meaning |
|-------:|---------|
| `0x01` | Break the pattern after this row |
| `0x03` | Start the fade helper at 31 |
| `0x05` | Set the decoder's rhythm-mode flag |
| `0x06` | Clear the decoder's rhythm-mode flag |
| `0x1n` | Add `n` to frequency and accumulated slide |
| `0x2n` | Subtract `n` from frequency and accumulated slide |
| `0x5n` | Set percussion state |
| `0x6n` | Set feedback to `n` while preserving the connection bit |
| `0xAn` | Set carrier attenuation to `n << 2` |
| `0xBn` | Set modulator attenuation to `n << 2` |
| `0xCn` | Set carrier attenuation, plus modulator in additive mode, to `n << 2` |
| `0xDn` | Set the order position to `n`, then break the pattern |
| `0xFn` | Set speed to `n + 1` |

For `0x1n` and `0x2n`, an effect-only cell writes the adjusted frequency
immediately. A cell containing a note applies the accumulated slide to that
note instead.

`0xDn` assigns order position `n` before normal pattern-break advancement.
The next order position is therefore `(n + 1) % 50`.

`0x6n` writes `(n << 1) | (instrument_byte_8 & 1)` to the channel's `0xC0`
register.

For `0x5n`, arguments 0 through 4 enable rhythm mode and write
`0x20 | (1 << n)` to the rhythm state. Arguments 5 through 7 write `1 << n`.
Argument 5 also enables rhythm mode. Arguments 8 through 15 leave the stored
state unchanged but still write it to register `0xBD`.

Effects `0x05` and `0x06` do not write register `0xBD` or clear its stored
percussion bits.

The fade helper decreases before each processed row when it was already
active. Effect `0x03` resets it to 31 during channel processing. It therefore
affects that channel and later channels on the same row, but not earlier ones.
While active, it sets carrier attenuation to `fade * 2`. It sets modulator
attenuation to the same value for additive instruments and restores the
instrument's modulator level otherwise. Instrument-set cells skip this work.

Unknown effects do nothing.

## Decoding

### Pitch and key handling

The semitone frequency table is:

```text
363 385 408 432 458 485 514 544 577 611 647 686
```

For a note, calculate:

```text
fnum = frequency[semitone] + instrument_pitch + channel_slide
block = octave << 2
```

Frequency and slide arithmetic wraps. The channel slide is an 8-bit signed
value. It is sign-extended to 16 bits, reinterpreted as unsigned, and added to
the 16-bit frequency. Saturating arithmetic produces different music.

Key-on is bit `0x20` of the channel's `0xB0` register. Ordinary melodic notes
set it. Note off clears it. Before each valid note, write zero to the channel's
`0xB0` register, then write the frequency and new key state. This forced
key-off edge retriggers repeated notes.

### Rhythm mode

Channels 0 through 5 remain melodic in rhythm mode. Channels 6 through 8 omit
the normal key-on bit and trigger percussion through register `0xBD`.

| Channel | Rhythm trigger changes |
|--------:|------------------------|
| 6 | Clear bit 4, then set bits 4 and 5 |
| 7 | Clear bit 0, then set bits 0 and 5 |
| 8 | Clear bit 1, then set bits 1 and 5 |

The decoder writes the cleared state first and the asserted state second. This
creates a fresh percussion edge.

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
decrease delay and process another row only when it reaches zero. Effect
`0xFn` changes speed to `n + 1`.

## Playback

Initialize OPL2 with these writes:

```text
register 0x01 = 0x20
register 0x08 = 0x80
register 0xBD = 0x00
```

Assign channel `i` to instrument `i` for all nine channels and program those
instruments before playback starts.

For each processed row:

1. Resolve the current order entry.
2. Process channels 0 through 8 in order.
3. Apply each cell's effect before its note.
4. Advance the row, or apply a pattern break.
5. Advance the order position when the row wraps from 63 to 0.

Song boundaries report one completion edge, then playback continues from the
resolved order position.

## Metadata

HSC stores no title or other text, and sehnsucht synthesizes none, so the
decoder reports no title at all and the shell falls back to the decoded file
name without its extension. The decoder exposes the order position, row,
pattern, speed, last triggered instrument, instrument data, and decoded cells
to the tracker visualizer.

## Errors

Wrong extensions and files outside the accepted size range are not claimed as
HSC. Invalid pattern references and order end values are repaired as described
under [Order list](#order-list). Incomplete trailing pattern bytes are ignored.

## Compatibility notes

HSC is OPL2 only. It does not contain OPL3 four-operator voices, PCM data, or a
register log.
