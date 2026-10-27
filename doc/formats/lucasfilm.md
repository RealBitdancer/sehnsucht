# Lucasfilm AD

**Extension:** `.laa` (case-insensitive)
**Chip:** OPL2 with optional rhythm mode
**Module:** `src/formats/lucasfilm.zig`

AdLib music from SCUMM games before iMUSE, such as Indiana Jones and the Last
Crusade and The Secret of Monkey Island. Each file is an `AD` sound resource
with up to eight instruments and a MIDI-like command stream. Later `.laa`
rips use the iMUSE layout in [LAA](laa.md).

External reference:
ScummVM's [Player_AD](https://github.com/scummvm/scummvm/blob/master/engines/scumm/players/player_ad.cpp).

## Identification

Bytes 4 and 5 hold `AD`. The music data starts at offset 6, and its byte 2
must be `80`. Sound effect resources use other values and are declined. The
file must reach the command stream at music offset 147 (`0x93`). The LAA decoder runs
first and declines these files.

## File layout

Offsets below count from the music data at file offset 6.

| Offset | Size | Field |
|--------|------|-------|
| 2 | 1 | `80` for music |
| 3 | 1 | Timer increment |
| 4 | 1 | 0 when the song loops |
| 5 | 2 | Little-endian loop start, relative to offset 147 |
| 10 | 1 | Instrument count, at most 8 are used |
| 11 | count | MIDI channel plus 1 for each instrument |
| 19 + 16 i | 16 | Instrument i |
| 147 (`0x93`) | | Command stream |

An instrument holds the rhythm frequency bytes for A0 and B0, the C0 byte, the
modulator's 20, 40, 60, 80, and E0 values, the carrier's five values, and at
byte 13 a rhythm instrument: 0 for melodic, 1 to 5 for bass drum, snare, tom,
cymbal, and hi-hat. Any rhythm instrument turns on rhythm mode, which leaves
six melodic channels.

## Decoding

Each command is followed by a delay. A delay byte of 0 means the next command
runs at once. Otherwise the delay is one byte, or two when the first has bit 7
set, and the wait is half of it in music ticks, at least one.

| Command | Meaning |
|---------|---------|
| `90`-`9F` + note + velocity | Note on for the instrument of that channel |
| below `90` + note + velocity | Note off. The note ends on the voice playing it from channel command + 16 |
| `FF 2F` | End of track. A looping song continues at the loop start with no delay |
| `FF 51` + length + data | Tempo. The timer increment becomes `73000` hex divided by the first two data bytes, at most 256 |
| `FF 58` | Five data bytes are skipped |
| `FF` + other + length + data | Skipped |

A melodic note takes the first free channel. When every channel is busy, the
note is dropped. Otherwise it loads the instrument and plays the note at the
F-number for note minus 31, with the octave in the block. A rhythm instrument
loads its drum operator, sets the drum's fixed pitch from the instrument, and
sets its rhythm bit. A note off with no matching melodic voice clears that drum
bit.

## Timing

The player runs a 472 Hz callback. Each callback adds the timer increment to a
counter, and a music tick passes each time the counter reaches 256. At most one
music tick passes per callback. The first command waits 40 music ticks.

## Playback

A looping song reports a song boundary at the end of track. The next step
continues at the loop start. Otherwise the end of track releases every note and
the song ends. The loader steps the song once to find its length, up to 30
minutes.

The sequence visualizer shows sixteen MIDI channels. Active voices list the
melodic channels and the drums. The inspector lists every command, the
instruments, and the loop as a jump at the end of track.

## Metadata

The format contains no metadata. The shell shows the file name.

## Errors

A command or delay cut off by the end of the file fails with
`InvalidMusicData`. A stream that runs out without an end of track ends there.
