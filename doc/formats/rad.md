# RAD (Reality Adlib Tracker)

**Extensions:** `.rad` (case-insensitive)
**Chip:** OPL2 (v1.0), OPL3-capable layout (v2.1)
**Module:** `src/formats/rad.zig`

A nine-channel tracker module from Reality Adlib Tracker. Version 1.0 stores
compact 2-op instruments and pointer-based patterns. Version 2.1 adds optional
BPM, instrument names, 4-op algorithms, and riffs. sehnsucht plays both file
versions for the main order list and patterns. Instrument riffs and channel
riffs in v2 are skipped at load time.

External reference:
public-domain RAD player by Shayde/Reality (embedded in
[AdPlug `rad2.cpp`](https://github.com/adplug/adplug/blob/master/src/rad2.cpp)).

## Identification

1. The path ends in `.rad`, ignoring case.
2. Bytes 0..15 are exactly `RAD by REALiTY!!`.
3. Byte 16 is `0x10` (file version 1.0) or `0x21` (file version 2.1).

Wrong magic declines the file. Other version bytes return
`error.UnsupportedRadVersion`. A truncated header, instrument list, or order
list returns `error.InvalidRad`. A v2 pattern whose size field is missing or
overruns the file is also `error.InvalidRad`. A line that starts validly but
runs out of note bytes does not: see
[Damaged pattern tails](#damaged-pattern-tails).

## File layout

All multi-byte integers are little-endian.

### Header

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 16 | `RAD by REALiTY!!` |
| 0x10 | 1 | Version (`0x10` or `0x21`) |
| 0x11 | 1 | Flags |

Flags:

| Bit | Meaning |
|----:|---------|
| 0..4 | Initial speed (minimum 1) |
| 5 | v2: BPM word follows flags |
| 6 | Slow timer (18.2 Hz instead of 50 Hz) |
| 7 | v1: description present. Always present in v2 |

Optional BPM (v2, flag bit 5): little-endian `u16`. The decoder does not
clamp the Reality range 46..300. Hertz for playback is `bpm * 2 / 5` when
flag bit 6 is clear. A stored zero becomes a one-denominator tick.

Optional description: NUL-terminated text. Control byte `0x01` means newline in
some editors. sehnsucht stores the first line (text before the first control
byte) as the track title when non-empty.

### Instruments

Repeated until instrument number `0`:

**v1 (11 bytes after the instrument number):**

| Byte | Field |
|-----:|-------|
| 0 | Carrier characteristic |
| 1 | Modulator characteristic |
| 2 | Carrier scaling / level |
| 3 | Modulator scaling / level |
| 4 | Carrier attack / decay |
| 5 | Modulator attack / decay |
| 6 | Carrier sustain / release |
| 7 | Modulator sustain / release |
| 8 | Algorithm (bit 0) and feedback (bits 1..3) |
| 9 | Carrier wave |
| 10 | Modulator wave |

**v2:** name length, name bytes, algorithm byte, then either 23 bytes of 2/4-op
data or 6 bytes of MIDI data, optional riff payload when algorithm bit 7 is set.
sehnsucht keeps the first two operators for playback and skips riff bodies.

Instrument numbers are 1-based. Missing numbers stay blank.

### Order list

| Field | Size |
|-------|-----:|
| Order count | 1 |
| Entries | count bytes |

Bit 7 set means a jump marker: low 7 bits are the new order index. The jump
is applied when playback advances onto that slot, not when the slot is the
one currently playing. Playing a jump slot uses the low 7 bits as a pattern
index.

### Patterns

**v1:** 32 little-endian offsets from the start of the file. Zero means empty.
Each pattern is a packed line stream (see below).

**v2:** sequence of `(pattern_number, size, data)` until pattern number `0xFF`.
Pattern numbers are 0..99.

### Packed line stream

```text
linedef: bit7 = last line, bits0..6 = row (0..63)
  chandef: bit7 = last channel, bits0..3 = channel
    note / instrument / effect bytes (version-dependent)
```

**v1 channel data:** always note byte, then instrument/effect nibble byte. If
the effect nibble is non-zero, one parameter byte follows. Note high bit adds
16 to the instrument number.

**v2 channel data:** optional note (chandef bit 6), optional instrument (bit 5),
optional effect+param (bit 4). Note high bit retriggers that channel's last
instrument. Reality stores this as `CChannel.LastInstrument` and resolves it
while playing, not while unpacking the file. The tracker view draws a
retriggered note 1..12 as an ordinary note. A retrigger with note 0 (invalid
in Reality's validator) still loads the last instrument and is drawn as an
instrument-set with argument 0.

Note values 1..12 are C..B. Note 15 is key-off. A pattern holds at most 64
lines. Streams with more are invalid.

### Damaged pattern tails

Archived RAD files are sometimes a byte or two short, leaving the final note of
the final pattern without its parameter byte. If the line header and the bytes
before that gap already decoded, the decoder keeps those cells, ends that
pattern there, and plays the tune. The reference player rejects the whole file
instead. This follows the same rule the IMF decoder applies to a partial
trailing record: drop the incomplete tail, not the file.

A v2 pattern whose two-byte size is missing, or whose declared size runs past
the end of the file, is not a short last note. That file is `error.InvalidRad`.

## Decoding

1. Validate magic and version.
2. Read flags, optional BPM, optional description.
3. Load instruments and order list.
4. Unpack every pattern into sparse line lists and a dense tracker view.
5. Initialise OPL registers (waveforms on, no drums). v2 also enables OPL3 mode
   register `0x105`.

Each `step` advances the tracker by one timer tick: decrement speed counter,
play the current line when it expires, then apply continuous slides.

### Effects (main track)

| Code | Meaning |
|-----:|---------|
| 1 | Portamento up |
| 2 | Portamento down |
| 3 | Tone slide |
| 5 | Tone slide + volume slide |
| A | Volume slide |
| C | Set volume (0..64) |
| D | Jump to line |
| F | Set speed |

## Timing

| Condition | Rate |
|-----------|------|
| Default | 50 Hz |
| Flag bit 6 | 18.2 Hz (`5/91` second ticks). Wins over BPM if both are set |
| v2 BPM present, bit 6 clear | `bpm * 2 / 5` Hz |

Speed is the number of ticks per row. Frame conversion uses
`rescale(tick_num, tick_den, sample_rate)`.

## Playback

RAD uses the tracker visualizer. Order wrap and jump markers set a song
boundary so playlists can advance. Single-file play loops from the start of the
order list.

Instrument load is the only event that sets key-on (Reality `fKeyOn`). A note
in 1..12 without an instrument byte (and without the retrigger bit) changes
pitch on a channel that is already keyed, and does not bounce the key. The
retrigger bit is the usual way a later note reloads the last patch and bounces.
An instrument byte still updates that channel's last-instrument latch even when
the row is a tone slide (Reality records `LastInstrument` in `UnpackNote` before
`PlayNote` skips the load), and even when that number is past the highest
instrument defined in the file. A later retrigger then has nothing to load,
instead of bouncing the previous valid patch.

## Metadata

The first line of a non-empty description is the embedded title. The format
has no separate artist field.

## Errors

| Condition | Result |
|-----------|--------|
| Wrong magic | Decline (`null`) |
| Version not 1.0 or 2.1 | `error.UnsupportedRadVersion` |
| Truncated or oversized header, instruments, or order list | `error.InvalidRad` |
| Pattern with more than 64 lines, or a row past 63 | `error.InvalidRad` |
| v2 pattern size missing or past the end of the file | `error.InvalidRad` |
| Truncated note payload after a valid line | Keep the decoded cells and play |

## Compatibility notes

* v2 instrument riffs, channel riffs, MIDI instruments, and full 4-op voice
  pairing are not expanded during playback. Main-order 2-op patterns still play.
* Only the first description line becomes the title. Later lines and control
  codes are dropped.
* v2 instrument panning is ignored. Every channel plays centred with both
  outputs enabled.
* Pattern numbers referenced in the order list but missing from the file are
  treated as empty patterns.
* A file whose last line is short of a parameter byte still plays, losing only
  that tail. A v2 pattern header whose size word is missing or overruns is
  rejected. The reference player treats a short last parameter as unplayable.
