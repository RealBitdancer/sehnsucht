# BAM (Bob's Adlib Music)

**Extensions:** `.bam` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/bam.zig`

An uncompressed OPL2 event stream created by BriTech / Hamster Republic for
Bob's Adlib Music and later used by OHRRPGCE. Commands turn voices on and off,
load 11-byte SBI patches, mark labels, and jump. There is no companion file
and no compression.

External reference:
[BAM Format (Hamster Republic)](https://rpg.hamsterrepublic.com/ohrrpgce/BAM_Format),
[AdPlug BAM player](https://github.com/adplug/adplug/blob/master/src/bam.cpp).

## Identification

1. The path ends in `.bam`, ignoring case.
2. The first four bytes are exactly `CBMF` (Creative Bob's Music File).
3. The command stream after the magic, if any, is well formed.

Wrong magic declines the file, so a bioinformatics `.bam` is not claimed. A
recognized magic with a truncated operand or a reserved command returns
`error.InvalidBam`.

## File layout

All integers are unsigned 8-bit values. There is no endianness.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 4 | ASCII `CBMF` |
| 0x04 | … | Command stream |

A command is one byte, optionally followed by data. Voices and labels use the
low nibble. The format reserves 16 voices and 16 labels. Current files use
voices 0-8 and labels 0-15. A player that cannot drive voices 9-15 still
consumes their operands and ignores the action.

### Commands

| Byte | Data | Meaning |
|------|------|---------|
| `0x00` | none | Stop. End of file is also a stop. |
| `0x01`–`0x0F` | none | Reserved. sehnsucht rejects the file. |
| `0x10`–`0x1F` | 1 frequency | Start note on voice `byte - 0x10`. Frequency is an index 0-127 into the table below. |
| `0x20`–`0x2F` | none | Stop note on voice `byte - 0x20`. |
| `0x30`–`0x3F` | 11 SBI bytes | Assign an instrument to voice `byte - 0x30`. |
| `0x40`–`0x4F` | none | Reserved. sehnsucht rejects the file. |
| `0x50`–`0x5F` | none | Set label `byte - 0x50` to the next command. |
| `0x60`–`0x6F` | 1 kind | Jump to label `byte - 0x60`. See [Jumps](#jumps). |
| `0x70` | none | End of chorus (return from a `0xFF` jump). |
| `0x71`–`0x7E` | none | Reserved. sehnsucht rejects the file. |
| `0x7F` | none | Zero-length delay. Published files use this as a no-op (notably `rvalkyry.bam`). |
| `0x80`–`0xFF` | none | Wait `byte - 127` ticks. `0x9F` (159) is one whole note (32 ticks). |

### Instrument bytes

The 11-byte payload is the SBI voice block, in this register order:

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

### Frequency table

Index 0-127. Each value stores the OPL F-number in the low 10 bits and the
block in bits 10-12. Key-on (`B0` bit 5) is applied when the note starts, not
stored in the table. Indices 115-127 are clamped at 8191.

```text
  172,  182,  193,  205,  217,  230,  243,  258,  274,  290,  307,  326,
  345,  365,  387,  410,  435,  460,  489,  517,  547,  580,  614,  651,
 1369, 1389, 1411, 1434, 1459, 1484, 1513, 1541, 1571, 1604, 1638, 1675,
 2393, 2413, 2435, 2458, 2483, 2508, 2537, 2565, 2595, 2628, 2662, 2699,
 3417, 3437, 3459, 3482, 3507, 3532, 3561, 3589, 3619, 3652, 3686, 3723,
 4441, 4461, 4483, 4506, 4531, 4556, 4585, 4613, 4643, 4676, 4710, 4747,
 5465, 5485, 5507, 5530, 5555, 5580, 5609, 5637, 5667, 5700, 5734, 5771,
 6489, 6509, 6531, 6554, 6579, 6604, 6633, 6661, 6691, 6724, 6758, 6795,
 7513, 7533, 7555, 7578, 7603, 7628, 7657, 7685, 7715, 7748, 7782, 7819,
 7858, 7898, 7942, 7988, 8037, 8089, 8143, 8191, 8191, 8191, 8191, 8191,
 8191, 8191, 8191, 8191, 8191, 8191, 8191, 8191
```

This is the AdPlug chromatic map. Indices 24-107 are the 12-23 row with
`block = (index / 12) - 1` added into bits 10-12.

## Decoding

1. Require `CBMF`. Copy the remainder as the command stream.
2. Parse that stream into events (note, instrument, label, jump, wait, stop).
   A reserved byte or a command that runs off the end is `error.InvalidBam`.
   A song-loop jump (`0xFE`) marks the file as looping.
3. On load, write OPL register `0x01` = `0x20` (waveforms enabled).
4. `step` runs events until a wait, a song boundary, or 4096 ops. Hitting
   the op cap returns `frames = 0` and keeps the cursor, so a storm of
   zero-time commands cannot stall the audio thread.

Label 0 starts at the first command. Other labels start unset. Setting a
label stores the position after that command. It does not clear a finite-loop
counter already attached to that label.

### Jumps

The kind byte after a jump command is:

| Kind | Meaning |
|-----:|---------|
| `0` | Leave the jump. Used as an explicit end-of-loop marker. |
| `1`–`253` | Finite loop. The first visit stores `kind - 1` remaining jumps on the label. Later visits decrement that counter until it is already 0, then the jump is skipped and the counter is cleared so the next pass starts fresh. |
| `254` | Infinite loop. Jump to the label, drop any open chorus return, and report a song boundary (`done`). The next `step` continues from the target. |
| `255` | Chorus (one level). Save the return address, jump to the label, and resume at `0x70`. A chorus while already in a chorus is ignored. `0x70` outside a chorus is ignored. |

A jump to an undefined label is skipped. sehnsucht consumes the command and
continues. AdPlug leaves the cursor on that jump and can spin. A `0xFE` jump
anywhere in the stream still sets `TrackInfo.loop`, even if that label is
never defined.

The finite-loop counter lives on the label. Nested loops to different labels
work. Two loops that share one label clobber each other. No published BAM in
the Modland set does that.

## Timing

One wait unit is one tick at **25 Hz**, the AdPlug refresh rate. The published
spec only says that 32 ticks are a whole note. It does not name a tempo, so
sehnsucht follows the established player.

```text
frames = rescale(ticks, 25, sample_rate)
```

with the shared fractional carry used by other stream formats.

Track duration is measured by stepping a second instance to the first song
boundary, so finite loops and choruses are counted exactly.

## Playback

BAM uses the stream visualizer and OPL2 only. Rhythm mode is never enabled.

Start note writes `A0` and `B0` for that voice (`B0` includes key-on) and
remembers the block/F-number high byte. Stop note writes that stored `B0`
with key-on clear. It does not write `B0 = 0`, which would slam the pitch
to octave 0 while the release is still audible. Voices 9-15 are ignored
after their operands are consumed.

A stop command or end of file rewinds labels, chorus state, and the cursor to
the start and reports `done`. Files in the wild put an infinite jump to label 0
just before a trailing stop, so the stop is never reached.

## Metadata

The format contains no metadata. The shell falls back to the file name without
its extension.

## Errors

Paths without `.bam` are not claimed. Wrong magic declines the file. A valid
magic with a reserved command or a truncated operand returns `error.InvalidBam`.

## Compatibility notes

* Bioinformatics BAM files share the extension and are declined by the `CBMF`
  check.
* Command `0x7F` is reserved in a strict reading of the spec. The authors
  documented it as a zero-length delay so existing songs play. sehnsucht does
  that.
* AdPlug hangs on a jump to a label that has not been set. sehnsucht skips it.
* AdPlug writes `B0 = 0` on stop-note. The original BAM kit (`Fm.asm` `KeyOff`,
  and `fmsynth.e` `fm_voice_off`) writes the previous block/F-number with
  key-on clear. sehnsucht follows the kit. Writing zero produces a click on
  every note-off (very audible on `arab.bam`).
* Finite-loop visit counts match AdPlug: a kind of `N` jumps `N` extra times
  after the first pass through the labelled section.
* sehnsucht does not implement AdPlug's same-label nested-loop clobber as a
  feature. It is a consequence of storing the counter on the label.
