# LAA

**Extension:** `.laa` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/laa.zig`

LucasArts iMUSE AdLib music from Monkey Island 2, Indiana Jones and the Fate
of Atlantis, and Day of the Tentacle. Each file is a SCUMM `ADL ` sound
resource. It wraps a format 2 Standard MIDI File whose system-exclusive
messages carry iMUSE commands and AdLib instruments. Older `.laa` rips from
Indiana Jones 3 and Monkey Island 1 use a different layout, described in
[Lucasfilm AD](lucasfilm.md).

External references:
ScummVM's [iMUSE player](https://github.com/scummvm/scummvm/tree/master/engines/scumm/imuse),
[MIDI parser](https://github.com/scummvm/scummvm/blob/master/audio/midiparser.cpp),
and [AdLib driver](https://github.com/scummvm/scummvm/blob/master/audio/adlib.cpp).

## Identification

The file starts with `ADL `. Other files are declined, so the Lucasfilm AD
decoder can claim them.

## File layout

Big-endian chunks follow the eight-byte `ADL ` header. Each chunk has a
four-byte id and a four-byte length. A length past the end of the file is cut
to the bytes present.

| Chunk | Content |
|-------|---------|
| `MDhd` | Optional player header: priority at 2, volume at 3, pan at 4, transpose at 5, detune at 6, speed at 7 |
| `MThd` | MIDI header. The division at offset 4 gives ticks per beat. SMPTE divisions are rejected |
| `MTrk` | One MIDI track. Format 2 files hold several independent tracks |

Priority, transpose, and detune apply only when priority, volume, or speed is
nonzero, as in ScummVM. Volume and pan are not used. A speed of 0 means 128.

## Decoding

Track events use MIDI running status. A note-on with velocity 0 is a release.
Meta `51` sets the tempo and meta `2F` ends the track. A track without an end
marker ends after its last event. The loader permits 262,144 events.

System-exclusive messages with manufacturer `7D` are iMUSE commands. A
trailing `F7` is dropped. The byte after the command byte is a raw part
number. Jump, global transpose, and loop commands skip it. Part instruments
skip one more raw byte, and global instruments read their slot number from a
third raw byte. The remaining parameters are packed as nibble pairs, high
nibble first.

| Code | Command |
|------|---------|
| `00` | Allocate a part: on flag, priority, volume, pan, transpose, detune, pitch bend range, global instrument |
| `01` | Shut down a part |
| `02` | Start of song, which shuts down every part |
| `10` | Define the part's 30-byte AdLib instrument |
| `11` | Define one of 32 global instruments |
| `30` | Hook jump to a track, beat, and tick |
| `31` | Hook global transpose |
| `32` | Hook part on or off |
| `33` | Hook part volume |
| `35` | Hook part transpose |
| `40` | Marker for the game, ignored |
| `50` | Loop a beat range a set number of times |
| `51` | End that loop |

Every hook names a hook value. The game sets these values to steer the music.
A player has no game, so only commands with hook value 0 run. Program change
selects a global instrument below 32. A global slot that was never defined
gives an all-zero instrument. A part without an instrument stays silent.

Monkey Island 2 and Indiana Jones 4 give a part its channel only through
command `00`. In a file that uses `00`, a part that was never allocated stays
silent. Day of the Tentacle rips never use `00`, and every part with an
instrument plays.

Controllers 1 (modulation), 7 (volume), 16 (pitch bend range), 17 (detune),
18 (priority), 64 (sustain), and 123 (all notes off) drive the parts.

### Instruments and voices

The 30-byte instrument holds the modulator and carrier register bytes, the
C0 byte, two effect definitions, and a duration. Attack/decay and
sustain/release are stored inverted. Output level comes from the instrument
level, the note velocity, and the part volume through ScummVM's lookup
tables.

Nine OPL2 voices serve all parts. A new note takes the next free voice in
rotation. Otherwise it steals the oldest note of the lowest-priority part.
Pitch is a note plus pitch bend times the bend range plus detune, in 1/128
semitone units, mapped to an 8-bit F-number table. A held voice keeps its
octave when a bend crosses one.

Each instrument effect is a four-stage envelope that sweeps one value: the
level, frequency multiplier, attack, release, or waveform of either operator,
the feedback, a fine or coarse pitch offset, or the other effect's depth or
speed. Effects can repeat, retrigger the key, follow the modulation wheel, and
pick random step counts.
A nonzero duration releases the note after that time.

## Timing

Timing follows ScummVM's 250 Hz callback. The MIDI position advances by
4 ms times the `MDhd` speed divided by 128 each callback. Events up to the new
position play together. Tempo is in microseconds per beat, and the default is
500,000. Effects and durations step about 51.5 times a second, on the same
fractional schedule as ScummVM.

A jump moves to beat and tick within a track, counted in 480 ticks per beat.
The jump scans from the start of the track and applies tempo changes on the
way. Notes held at the jump keep sounding until their own release would have
come.

## Playback

A hook jump back within its track, or into music already played in this
pass, is the song's loop. It reports a song boundary and playback continues.
A jump forward is not a boundary. A loop command counts as the song's loop
only when it repeats 100 times or more. Shorter loops play out first. The
end of a track stops every note and ends the song. The loader steps the song
once to find its length and whether it loops, up to 30 minutes.

The sequence visualizer shows sixteen MIDI channels. All tracks lie on one
timeline in file order, one beat apart. The playhead follows the track that
is playing. Part instrument definitions appear as program changes, and hook
jumps that run appear as jumps. Global instrument definitions and other iMUSE
commands appear as SysEx events with their names. The inspector lists every event
and every defined instrument. Instrument names give the part or global slot
that defined them.

## Metadata

The format contains no metadata. The shell shows the file name.

## Errors

A missing `MThd`, an `MTrk` before `MThd`, no tracks, an SMPTE division, or a
truncated event fails with `InvalidMusicData`.
