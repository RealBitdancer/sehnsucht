# CMF (Creative Music File)

**Extensions:** `.cmf` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/cmf.zig`

Creative's Sound Blaster music format. A header points at an instrument block
and a MIDI-like music block. Instruments are 16-byte SBI-style patches. The
music stream is Standard MIDI File style events with Creative-specific
controllers for rhythm mode and transpose.

The format is two-operator OPL2 throughout. A patch stores one modulator and
one carrier, and no event or controller reaches the OPL3 register bank, so
four-operator voices and OPL3 features cannot be expressed in a CMF at all.

External reference:
[CMF Format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/CMF_Format),
[AdPlug CMF player](https://github.com/adplug/adplug/blob/master/src/cmf.cpp).

## Identification

1. The path ends in `.cmf`, ignoring case.
2. Bytes 0..3 are `CTMF`.
3. Version word at offset 4 is `0x0100` (v1.0) or `0x0101` (v1.1).

Wrong magic or version declines the file. A truncated header or bad offsets
after a recognized magic and version return `error.InvalidCmf`.

## File layout

All multi-byte integers are little-endian.

### Header

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 4 | `CTMF` |
| 0x04 | 2 | Version (`0x0100` or `0x0101`) |
| 0x06 | 2 | Instrument block offset |
| 0x08 | 2 | Music block offset |
| 0x0A | 2 | Ticks per quarter note |
| 0x0C | 2 | Ticks per second |
| 0x0E | 2 | Title string offset (0 = none) |
| 0x10 | 2 | Composer string offset (0 = none) |
| 0x12 | 2 | Remarks string offset (0 = none) |
| 0x14 | 16 | Channel-in-use flags |
| 0x24 | 1 or 2 | Instrument count (1 byte in v1.0, 2 bytes in v1.1) |
| 0x25/0x26 | 0 or 2 | Tempo (v1.1 only, not used for playback rate) |

Tag offsets that land at or past the instrument block are treated as zero.

### Instruments

Each instrument is 16 bytes:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 1 | Modulator characteristic + multiplier |
| 1 | 1 | Carrier characteristic + multiplier |
| 2 | 1 | Modulator scaling / output level |
| 3 | 1 | Carrier scaling / output level |
| 4 | 1 | Modulator attack / decay |
| 5 | 1 | Carrier attack / decay |
| 6 | 1 | Modulator sustain / release |
| 7 | 1 | Carrier sustain / release |
| 8 | 1 | Modulator wave select |
| 9 | 1 | Carrier wave select |
| 10 | 1 | Feedback / connection |
| 11..15 | 5 | Padding |

A file that declares zero instruments uses Creative's 16 default patches.

### Music block

MIDI-style event stream. Each event is preceded by a variable-length quantity
(VLQ) delay in ticks. Status bytes may use running status. Supported message
classes:

| Status | Meaning |
|--------|---------|
| `8n` | Note off |
| `9n` | Note on (velocity 0 = note off) |
| `Bn` | Controller |
| `Cn` | Program change (modulo instrument count) |
| `En` | Pitch bend |
| `F0` / `F7` | SysEx / escape (length-prefixed skip) |
| `FF 2F` | End of track |
| `FC` | Stop |

### Controllers

| Controller | Meaning |
|-----------:|---------|
| `0x63` | AM + VIB depth bits in register `0xBD` |
| `0x67` | Rhythm mode on/off (full melodic re-init) |
| `0x68` | Transpose up (1/128 semitone units) |
| `0x69` | Transpose down |

MIDI channels 11..15 are Creative rhythm channels when rhythm mode is on.
Some GM conversions drive drums on channel 9 without program changes. Those
files are detected at load time and remapped onto channels 11..15.

## Decoding

1. Parse the header and load instruments.
2. Dup the music block and optional title/composer strings.
3. Initialise nine melodic voices with Creative's default instrument, enable
   waveforms (`0x01` = `0x20`), and set AM+VIB depth (`0xBD` = `0xC0`).
4. Each `step` drains zero-delay events, then waits the next VLQ delay.

Voice allocation matches the Creative driver tiers: reuse a released voice on
the same MIDI channel, then never-used, then any released, then steal the
oldest sounding voice. Velocity scales the carrier output level.

Note frequency uses the driver's tables: a block/note table for the octave and
semitone, and a 768-entry F-number table in 1/64ths of a semitone. Pitch bend
spans one semitone either way on that scale. Transpose adds a quarter of the
controller value, so full deflection is just under half a semitone.

## Timing

The playback clock is `ticks_per_second` from the header (default 96 if zero).
A delay of *D* ticks becomes:

```text
frames = rescale(D, ticks_per_second, sample_rate)
```

## Playback

CMF always uses OPL2 and the stream visualizer. End of track rewinds the music
pointer, silences every voice, restores the load-time rhythm mode, and clears
patches, pitch bend, and transpose before reporting a song boundary, so a loop
pass starts from the same state as the first.

## Metadata

Title and composer offsets, when valid, supply embedded title and artist.
Remarks are not exposed in the shell today.

## Errors

| Condition | Result |
|-----------|--------|
| Wrong magic or version | Decline (`null`) |
| Truncated header | `error.InvalidCmf` |
| Bad instrument or music offsets | `error.InvalidCmf` |

## Compatibility notes

* Polyphonic key pressure and channel pressure are ignored.
* Transpose applies a quarter of the controller value in 1/64-semitone steps,
  following AdPlug. Full deflection is just under half a semitone.
