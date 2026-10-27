# JBM (Johannes Bjerregaard)

**Extensions:** `.jbm` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/jbm.zig`

A per-voice OPL2 sequencer used by Johannes Bjerregaard (Jozz) in 1991-1992.
Each voice has an order list of sequences. A sequence is instrument changes and
timed notes. There is no compression and no companion file.

External reference:
[AdPlug JBM player](https://github.com/adplug/adplug/blob/master/src/jbm.cpp),
[AdPlug format library](https://adplug.github.io/library/entry/Jozz.html).

## Identification

1. The path ends in `.jbm`, ignoring case.
2. The first little-endian `u16` is `2`.
3. The file is at least 32 header bytes.
4. The sequence table, instrument table, and at least one track pointer form a
   closed layout (see below).
5. Every used track ends in `0xFF` and produces at least one timed note.

A first word other than `2` declines the file. A recognized header whose tables
or event streams do not walk returns `error.InvalidJbm`.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 2 | Format id, must be `2` |
| 0x02 | 2 | PIT divisor (`timer`) |
| 0x04 | 2 | Sequence-table file offset (`seqtable`) |
| 0x06 | 2 | Instrument-table file offset (`instable`) |
| 0x08 | 2 | Flags. Bit 0 is OPL rhythm mode |
| 0x0A | 22 | Eleven track pointers, one `u16` per voice |
| `seqtable` | `2 * seqcount` | Sequence file offsets |
| track pointers | variable | Per-voice order lists |
| sequence offsets | variable | Event streams |
| `instable` | `16 * inscount` | Instruments |

`seqcount` is `(min_used_track - seqtable) / 2`. Unused table slots after the
used sequences may hold garbage (published files do this) and are ignored.
`inscount` is `min((file_size - instable) / 16, 256)`. Leftover bytes after
the last counted instrument are ignored.

A track pointer of `0` means the voice is unused. A used pointer is a file
offset to an order list of sequence indexes, one byte each, ended by `0xFF`.

### Instruments

Each slot is 16 bytes. The first 9 are operator data. The rest is padding.

| Offset | Written as |
|-------:|------------|
| 0 | `0x20 + op` modulator AM/VIB/EG/KSR/MULT |
| 1 | `0x40 + op` modulator KSL/TL, after XOR `0x3F` |
| 2 | `0x60 + op` modulator AR/DR |
| 3 | `0x80 + op` modulator SL/RR |
| 4 | `0x23 + op` carrier AM/VIB/EG/KSR/MULT |
| 5 | `0x43 + op` carrier KSL/TL, after XOR `0x3F` |
| 6 | `0x63 + op` carrier AR/DR |
| 7 | `0x83 + op` carrier SL/RR |
| 8 | Low nibble: `0xC0 + voice` feedback / connection. Bits 4-5 modulator wave. Bits 6-7 carrier wave |

`op` is the modulator slot for that voice (`00 01 02 08 09 0A 10 11 12`).
Stored total-level bytes are inverted. XOR `0x3F` before the chip write.
Note volume uses the same invert on the carrier `0x40` register.

Rhythm-mode percussion voices 7-10 write only the first operator and the
feedback nibble, on the shared drum operator slots.

### Sequences

| Byte | Data | Meaning |
|------|------|---------|
| `0xFD` | 1 instrument | Load that patch onto the voice |
| `0xFF` | none | End of sequence. The next order-list byte is the next sequence index. `0xFF` there restarts the order list and marks the voice as having looped |
| other | 3 bytes | Note. Byte 0 is the note (`bit 7` = key off, `low 7` is 0-95). Byte 1 is volume. Bytes 2-3 are a little-endian delay. The voice waits `delay + 1` ticks |

A note with `low 7` greater than 95 is `error.InvalidJbm`.

## Decoding

1. Require id `2` and a walkable header.
2. Copy the file. Build a sequence-event index for each voice, then merge the
   indexes in stable tick order for the visualizer.
3. On load, write `0x01 = 0x20` and `0xBD = 0xC0`, or `0xE0` when rhythm is on.
4. Each `step` runs every voice whose delay is 0 until that voice has a delay,
   or 4096 ops. Then all voices wait the shortest remaining delay.
5. The sequence pane shows a timed command list and live channel meters.
   `position_unit` is `tick`. The command cursor finds the last event at or
   before the playhead tick. The tick stays on the sounding row for the
   whole wait, then advances.

Playback starts with delay 0 so the first notes are written immediately.

## Timing

The file stores a PC interval-timer divisor. One tick is

```text
hz = 1193180 / divisor
```

A stored zero divisor is `0xFFFF`. Delay `N` in the file occupies `N + 1`
ticks, including 65,536 ticks for a stored delay of 65,535.

```text
frames = rescale(ticks * divisor, 1193180, sample_rate)
```

Duration is the maximum first-playthrough tick count across used voices, as
`total_ticks * divisor * sample_rate / 1193180`.

AdPlug divides by `1193810`. That constant is a digit swap of the PIT. sehnsucht
uses the hardware rate, the same value RAW uses.

## Playback

JBM uses the sequence visualizer and OPL2 only. NEW stays off. Voices 0-8 are
melodic. When flag bit 0 is set, voices 6-10 are bass drum, snare, tom, cymbal,
and hi-hat. Cymbal maps to physical OPL channel 8 and hi-hat to channel 7.
Their independent rhythm bits allow simultaneous percussion.

The sequence pane follows events in tick order, even though the file stores
separate voice streams. Its spectrum uses the logical-to-physical mapping.
The inspector exposes the complete instrument bank, including index 255 when
that entry exists.

A voice that hits the order-list terminator restarts that list and keeps
playing. `TrackInfo.loop` is always set. `done` is reported once every used
voice has looped. The decoder then keys off sounding voices and restarts every
used voice from the start of its order list, which also clears the loop flags,
so each playthrough matches the event index.

The frequency table is the 96-word map from AdPlug (taken from Jozz `MUSIC.BIN`).

## Metadata

The format contains no metadata. Title stays unset so the shell can fall back
to the file name without its extension.

## Errors

Paths without `.jbm` are not claimed. A first word other than `2` declines the
file. A recognized header with a truncated table, an empty used track, a note
above 95, or a sequence that never ends returns `error.InvalidJbm`.
