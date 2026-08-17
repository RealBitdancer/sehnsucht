# LDS (Loudness Sound System)

**Extensions:** `.lds`, `.ld0` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/lds.zig`

András Molnár's nine-channel OPL2 tracker. A file holds 2-op patches, a
9-column order list, and a packed 16-bit pattern pool. There is no companion
file. `.ld0` is the older layout whose patches omit the unused MIDI tail.

The format is two-operator OPL2 throughout. No command writes the OPL3 bank.

External reference:
[AdPlug LOUDNESS player](https://github.com/adplug/adplug/blob/master/src/lds.cpp),
[OpenTyrian `lds_play.c`](https://github.com/opentyrian/opentyrian/blob/master/src/lds_play.c).

## Identification

1. The path ends in `.lds` or `.ld0`, ignoring case.
2. Byte 0 (mode) is `0`, `1`, or `2`.
3. The header is at least 17 bytes.

A first byte above 2, or a header shorter than 17 bytes, declines the file, so
a typical GNU `ld` linker script is not claimed. After a recognized mode, a
zero speed, a zero pattern length, a patch count above 63, an order count of
0 or above 255, or section sizes that do not fit returns `error.InvalidLds`.
The extension has already claimed the path, so that error is not a silent
pass to another decoder.

## File layout

All multi-byte integers are little-endian.

### Header

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 1 | Mode (`0`..`2`) |
| 0x01 | 2 | Speed (PIT divisor) |
| 0x03 | 1 | Tempo |
| 0x04 | 1 | Pattern length in rows |
| 0x05 | 9 | Per-channel note delay |
| 0x0E | 1 | Written to OPL register `0xBD` |
| 0x0F | 2 | Patch count (at most 63) |

### Patches

Each patch is 46 bytes in `.lds` and 40 bytes in `.ld0`. The first 40 bytes
are the same. The last 6 bytes of a `.lds` patch are unused MIDI fields.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 5 | Modulator: misc, volume, attack/decay, sustain/release, wave |
| 5 | 5 | Carrier: same layout |
| 10 | 1 | Feedback / connection |
| 11 | 1 | Key-off delay |
| 12 | 1 | Portamento |
| 13 | 1 | Glide |
| 14 | 1 | Finetune |
| 15 | 1 | Vibrato |
| 16 | 1 | Vibrato delay |
| 17 | 1 | Modulator tremolo |
| 18 | 1 | Carrier tremolo |
| 19 | 1 | Tremolo wait |
| 20 | 1 | Arpeggio (high nibble speed, low nibble length) |
| 21 | 12 | Arpeggio table |
| 33 | 2 | Digital sample start (ignored) |
| 35 | 2 | Digital sample size (ignored) |
| 37 | 1 | `fms` (ignored) |
| 38 | 2 | Patch transpose (ignored) |
| 40 | 6 | MIDI fields (`.lds` only, ignored) |

The length nibble is 0..15. The table has 12 entries. Playback clamps the
length to 12. A stored length of 13, 14, or 15 does not walk off the table
(AdPlug reads past it into the next channel field).

A `.lds` file whose 46-byte patches do not fit is retried as `.ld0`. A `.ld0`
file is tried as 40-byte patches first.

Stored operator volume is inverted relative to the OPL total-level register.
Playback XORs the low 6 bits with `0x3F` when writing `0x40` / `0x43`.

### Order list

A little-endian `u16` order count, then that many rows of 9 slots. Each slot
is a little-endian `u16` byte offset into the pattern pool followed by a
transpose byte. The decoder divides the offset by 2 to index 16-bit words.

Transpose is a 7-bit signed value (bit 6 sign-extended). Bit 7 of the stored
byte selects the target. Clear adds it to the note. Set adds it to the
instrument number.

### Pattern pool

A little-endian `u16` digital-sound count is skipped. The rest of the file is
a pool of little-endian 16-bit words. Each channel in an order slot starts at
its own word index and walks that stream with a private cursor.

## Decoding

1. Read the header. Decline a mode above 2 or a header shorter than 17 bytes.
2. Fail a zero speed or zero pattern length.
3. Choose a patch stride that makes the order list and pool fit. Fail if
   neither stride fits, if the patch count exceeds 63, or if the order count
   is 0 or above 255.
4. Load patches, order slots, and the word pool.
5. Scan the pool for command `0xF9`. If any word has that high byte,
   `TrackInfo.loop` is true. Playback reports a song boundary only when a
   jump lands on the current order or an earlier one.
6. Initialise nine OPL2 voices, enable waveforms (`0x01` = `0x20`), write
   `0x08` = `0`, write the header `0xBD` value, and silence the nine voices.

Each `step` is one PIT tick. Effects (vibrato, tremolo, arpeggio, glide,
fade, delayed key-off) run every PIT tick. Notes and commands run on a
pattern row, when the tempo counter reaches zero. The opening countdown is 3
PIT ticks (the first row runs on step index 3). After a row, the counter
reloads from the header (or from command `0xFE`). The next row is then
*tempo* decrements later, so rows are `tempo + 1` PIT ticks apart. A tempo
of 0 means a row on every remaining step.

A note word is any nonzero word whose high byte is below `0x80`. The high
byte is the note in semitones (zero is a valid note). The low byte is the
patch index, masked to 6 bits. Frequency uses the Loudness
16-steps-per-octave table.

An out-of-range pattern cursor reads `0x8001`, matching AdPlug. That word is
a wait with extra 1: the current pattern row is silent, then one more silent
row.

Arpeggio length is clamped to the 12-entry table on every tick.

### Commands

High byte of each pattern word, except the empty-word rule:

| High | Meaning |
|------|---------|
| word `0x0000` | No event. The cursor still advances. |
| `00` (low byte nonzero) | Note on at semitone 0. Low byte is the patch. |
| `01`..`7F` | Note on. High byte is the semitone. Low byte is the patch. |
| `80` | Wait. The low byte is extra silent pattern rows after this one. |
| `F0`, `F1` | Leftover MIDI. Ignored. |
| `F2` | Tremolo stay mask. |
| `F3` | Start a fade. |
| `F4` | Set master volume. |
| `F5` | Channel finetune. |
| `F6` | Glide to the next note. |
| `F7` | Vibrato speed and depth. |
| `F8` | Clear the last tune (breaks portamento). |
| `F9` | Jump to the order index in the low byte. |
| `FA` | Break to the next order. |
| `FB` | Key off. |
| `FC` | Stop. |
| `FD` | Scale the next note's volume. |
| `FE` | Set tempo from the low 6 bits. |
| `FF` | Scale the sounding voice volume. |
| `81`..`9F` | Glide amount in the low 5 bits (AdPlug default). |

Command `0xF9` jumps to an order index. A jump to the current order or an
earlier one is a song loop. Command `0xFC` stops. Advancing past the last
order stops. A jump or advance to an index past the last order stops.

## Timing

The playback clock is the 8253 PIT. A file speed of *S* becomes:

```text
frames = rescale(S, 1193182, sample_rate)
```

Tyrian and most other published files use `S = 17152` (about 69.57 Hz). Tempo
then divides that clock. After the opening countdown of 3 PIT ticks, pattern
rows fire every `tempo + 1` PIT ticks.

## Playback

LDS always uses OPL2 and the tracker visualizer.

The on-disk order is nine pattern pointers per slot, not one shared pattern
index. `TrackerView` cannot store that. The decoder builds an identity order
list (`0`, `1`, `2`, ...) and treats each slot as one synthetic pattern of
`pattlen` rows. The packed word pool is kept as stored. When the tracker
view asks for a cell, the decoder walks that channel's stream up to the
requested row. A cell is whatever the stream does on that pattern row,
including waits. The cursor row is a pattern row, not a PIT tick and not a
packed-command index. `TrackerPos` is snapshotted on the row that just
sounded, as HSC and RAD do, so the highlight stays on that row until the
next one plays.

`TrackerPos.speed` is the tempo byte. The PIT divisor does not fit that field.

A loop jump reports a song boundary and continues from the destination. A
stop reports a song boundary and leaves the source idle until the next
`step`, which rewinds. If one channel loops and another stops on the same
row, the loop wins and playback stays at the jump destination.

## Metadata

The format contains no metadata. The shell falls back to the file name without
its extension. Labels: `LDS` or `LD0` from the path.

## Errors

| Condition | Result |
|-----------|--------|
| Mode above 2 | Decline (`null`) |
| Truncated header | Decline (`null`) |
| Zero speed or pattern length | `error.InvalidLds` |
| Patch count above 63, order count 0 or above 255, or sections that do not fit | `error.InvalidLds` |

## Compatibility notes

* LDS was added because it is self-contained OPL2 with a Modland folder
  (Tyrian, Fuzzy's World, and others). It does not need a companion bank.
* Digital sample fields and the digital-sound count are ignored. AdPlug and
  OpenTyrian do the same. sehnsucht has no PCM path for them.
* AdPlug treats only `jumppos < posplay` as a loop. A one-order song that
  jumps to itself would never report a boundary. sehnsucht treats a jump to
  the current order as a loop as well.
* AdPlug reads an arpeggio length above 12 past the table into the next
  channel field. sehnsucht clamps the length to 12.
* `TrackerCell` shows a note plus the patch index. Wait rows are empty.
  Command `0xFB` is a note-off cell. Other commands `0xF0`..`0xFF` and
  `0x81`..`0x9F` are effect cells whose argument is the command byte (the
  high byte, not the operand). Per-channel transpose is applied to the
  displayed note or patch. It is not drawn as its own column.
* Tyrian ships songs concatenated in `MUSIC.MUS`. sehnsucht plays split `.lds`
  rips, not that archive. Remote list: `playlists/lds.m3u`.
* GNU `ld` linker scripts and ld-decode captures also use `.lds`. A first
  byte above 2 declines those. A recognized mode with counts that do not fit
  is `error.InvalidLds`, not a silent skip. There is no file-size cap.
