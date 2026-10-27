# ADL (Westwood AdLib)

**Extensions:** `.adl` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/adl.zig`

Westwood Studios' AdLib music and sound format. A file holds a track table,
program offsets, instrument offsets, and bytecode programs for nine OPL2
voices plus one control channel. The music was written in AdLib Visual
Composer and converted into this packed sequencer. There is no companion
file.

Playback uses the sequence visualizer. Channels 0-8 are the nine OPL2 voices.
Channel 9 is the conductor and appears in CTRL. Each window begins at its
published program counter and includes the stop instruction. The normal pane
and the inspector both scroll through the complete program.

The mixer shows instrument, sounded note, wait duration, tempo, priority,
call depth, remaining operations, and active slide/vibrato/modulation effects
as space permits. The info strip's tempo is the global callback increment,
not BPM. Grid notes show written pitch and hexadecimal duration. The sounded
note can differ because the driver applies transposition and nibble wrapping.
The inspector exposes instruments and events. The source also publishes
program bytes through `SequenceView.programAt` for consumers that need them.

External reference:
[ADL Format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/ADL_Format),
[ADL (Westwood) (VGMPF)](https://vgmpf.com/Wiki/index.php?title=ADL_(Westwood)).

## Identification

1. The path ends in `.adl`, ignoring case.
2. There is no magic. The decoder inspects the track table and program
   offset table.

A file shorter than 720 bytes declines. Offsets that cannot belong to any
supported table layout also decline. Coktel Vision `.adl` is a different
format that is not implemented here. After a recognized layout, a
track table with no playable program returns `error.InvalidAdl`.

Versions:

| Version | Games | Track table | Program offsets | Instrument offsets | First program |
|--------:|-------|-------------|-----------------|--------------------|---------------|
| 1 | Eye of the Beholder | 120 bytes | 150 words | 150 words | 600 |
| 2 / 3 | EOB II, Kyrandia 1, Dune II | 120 bytes | 250 words | 250 words | 1000 |
| 4 | Kyrandia 2, Lands of Lore | 250 words | 500 words | 500 words | 2000 |

Version 4 vs 1/2/3: every 16-bit track-table entry is below 500 or `0xFFFF`.
A word in `500..0xFFFE` is a v1/v2/v3 program offset sitting where a v4
track table would be.

Version 1 vs 2/3: a program offset in `600..999` is v1. Version 2 and 3 share
the same file layout. They differ only in how jump-to-subroutine encodes its
target (absolute in v2, relative in v3). sehnsucht treats the 250-program
layout as v3. Eye of the Beholder II files in the known corpus do not use
that opcode.

## File layout

All multi-byte integers are little-endian unless a command says otherwise.

```
+------------------+ +-----------------+--------------------+-----------+
| track table      | | program offsets | instrument offsets | bytecode  |
+------------------+ +-----------------+--------------------+-----------+
```

The player reads the track table. The sequencer reads everything after it.
Program and instrument offsets are relative to the start of that second
region (`soundData`), not the start of the file.

### Track table

v1/v2/v3: 120 bytes. Each byte is a program index, or `0xFF` for empty.

v4: 250 little-endian words. `0xFFFF` is empty.

The archive list is every track-table slot whose program starts on control
channel 9, has priority below 50, and issues a start-program opcode (2) for a
real program index. `--track` and `,` / `.` count from 1 over that list. The
first entry is the default. `,` / `.` retarget the in-memory source. They do
not re-fetch or show the loader spinner. Duration for a newly visited song is
probed from a clone of that source and then cached. The live driver is replaced
with a fresh one, so extra-level-2 from the previous song does not carry over
(a same-song rewind still keeps it).

That rule skips silence and fade slots, including a stop program whose
priority is below 50 (Eye of the Beholder `eob - sound.adl` table index 0).
A file with no such song falls back to every valid track.

### Offset tables

Each program or instrument slot is a little-endian word. `0` and an offset
at or past the end of `soundData` are empty. A live program offset must not
fall inside the offset tables themselves (that is the minimum first-program
value in the table above). Instrument offsets are not checked against the
tables.

### Instrument record

11 bytes, used by the setup-instrument command:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 1 | Modulator AM/VIB/EG/KSR/MULT (`0x20`) |
| 1 | 1 | Carrier AM/VIB/EG/KSR/MULT (`0x23`) |
| 2 | 1 | Feedback / connection (`0xC0`). Bit 0 is additive |
| 3 | 1 | Modulator waveform (`0xE0`) |
| 4 | 1 | Carrier waveform (`0xE3`) |
| 5 | 1 | Modulator KSL/TL (`0x40`) |
| 6 | 1 | Carrier KSL/TL (`0x43`) |
| 7 | 1 | Modulator attack/decay (`0x60`) |
| 8 | 1 | Carrier attack/decay (`0x63`) |
| 9 | 1 | Modulator sustain/release (`0x80`) |
| 10 | 1 | Carrier sustain/release (`0x83`) |

## Decoding

A program begins with two bytes, channel then priority, then a stream of
opcodes. Channel 9 is the control channel. It starts the other programs
and does not drive an OPL voice. Channels 0-8 map to OPL channels 0-8.

An opcode with the high bit set is a function. The low 7 bits index a 75-entry
table. Most unused slots stop the channel. Opcodes 59 and 64 are nops (continue
without stopping). Opcodes 63 and 73 have handlers. An opcode with the high bit
clear is a note. The next byte is its duration.

A function's return value is (the decoder names these `more`, `wait`,
and `wait_no_fx`):

* `0` continue reading opcodes
* `1` wait for the current duration, then run slide/vibrato/modulate
* `2` wait, and skip those effects this tick

A note with duration 0 also continues. A note with a non-zero duration waits
and always runs effects.

Starting a program on a channel that is already playing succeeds only when
the new priority is greater or equal. The new program resets that channel
except extra-level-2, which is kept, and re-initializes the OPL operators
(`0x60`/`0x80` to `0xFF`, `B0` 0 then `0x20`). Opcode 2 (start program) keeps
the caller's instruction pointer, as AdPlug and ScummVM do. If the target is
the current channel, that channel restarts and the caller carries on.

### Timing inside a channel

Each callback adds the channel tempo to the channel timer. When the timer
wraps, duration decreases by one. At `spacing2` or `spacing1` the note keys
off. When duration hits zero, more opcodes run.

The global tempo wraps a separate callback timer used by the beat commands.

### Jump encoding

Jump and jump-to-subroutine take a signed 16-bit operand.

* v1: both are absolute offsets into `soundData`, minus 191
* v2: jump is relative to the current pointer. Jump-to-subroutine is absolute
  minus 191
* v3 / v4: both are relative to the pointer after the operand

191 is the offset the original real-mode driver assumed for `XLAT`. Secondary
effect tables use the same bias.

Slide step and the random-note mask are big-endian. Every other 16-bit field
is little-endian.

### Primary opcodes

| Low 7 bits | Args | Action |
|-----------:|-----:|--------|
| 0 | 1 | Set repeat counter |
| 1 | 2 | Decrement repeat. Non-zero: relative jump |
| 2 | 1 | Start program (channel/priority at the target) |
| 3 | 1 | Note spacing |
| 4 | 2 | Jump |
| 5 | 2 | Jump to subroutine (4-deep stack) |
| 6 | 0 | Return |
| 7 | 1 | Base octave |
| 8 | 0 | Stop channel |
| 9 | 1 | Rest (key off, set duration) |
| 10 | 2 | Write OPL register |
| 11 | 2 | Set note and duration without key-on |
| 12 | 1 | Base note |
| 13 | 5 | Secondary register modulate |
| 14 | 1 | Stop another channel |
| 15 | 1 | Wait until another program's channel is idle |
| 16 | 1 | Setup instrument |
| 17 | 3 | Frequency slide (tempo, big-endian step) |
| 18 | 0 | Remove slide |
| 19 | 1 | Base frequency addend |
| 21 | 4 | Vibrato |
| 26 | 1 | Priority |
| 28 | 1 | Set global beat divider |
| 29 | 1 | Wait for beat mask |
| 30 | 1 | Extra level 1 |
| 32 | 1 | Duration only |
| 33 | 1 | Key on with duration |
| 36 | 1 | Fractional spacing (low 3 bits) |
| 38 | 1 | Global tempo |
| 39 | 0 | Remove secondary effect |
| 41 | 1 | Channel tempo |
| 43 | 1 | Extra level 3 |
| 44 | 2 | Extra level 2 on another channel |
| 45 | 2 | Add to extra level 2 |
| 46 | 1 | AM depth bit of `0xBD` |
| 47 | 1 | Vibrato depth bit of `0xBD` |
| 48 | 1 | Add to extra level 1 |
| 51 | 1 | Clear another channel |
| 53 | 2 | Add a masked random value to the current F-number |
| 54 | 0 | Remove vibrato |
| 57 | 1 | Pitch bend, then retune the current note |
| 58 | 0 | Copy global tempo onto the channel |
| 59 | 0 | Nop |
| 60 | 1 | Duration randomness mask |
| 61 | 1 | Signed tempo delta, clamped to 1..255 |
| 63 | 2 | Set callback tables (table pointers, optional `A0` write) |
| 64 | 0 | Nop |
| 65 | 9 | Enable rhythm section on channels 6-8 |
| 66 | 1 | Play rhythm bits |
| 67 | 0 | Disable rhythm section |
| 68-70 | 2 | Rhythm operator levels |
| 71 | 1 | Sound trigger (stored, not used for playback) |
| 72 | 1 | Tempo-reset flag (copy global tempo every tick) |
| 73 | 2 | Store two unused channel bytes |

An opcode stream that runs more than 256 functions on one channel in one
tick yields, so a hostile file cannot pin the audio callback.

## Timing

The driver ticks at 72 Hz. sehnsucht converts each tick with
`fmt.rescale` and a fractional carry into the output sample rate.

Most Westwood songs are linear: the control program starts the voices, each
voice plays through and stops. That stop is the song boundary. The source
rewinds and returns `done`, with `loop` set, so a single file repeats and a
playlist advances.

A program that jumps backward, or to its current pointer, is a song boundary
once every remaining channel is repeating (AdPlug's song-end rule). The source
rewinds and returns `done`,
same as a linear stop, so the progress bar, file loop, and playlist see an
end. The load-time duration probe uses that same boundary.

## Playback

On load the chip is reset: waveform select `0x20`, CSW `0`, rhythm `0`,
every operator total level `0x3F`. Starting a track queues its program.
The queue holds 16 entries. A start is delayed by two ticks after the
previous start so stacked sound effects keep their priorities. Music is
played at full velocity. The original driver's per-effect velocity patch
is not applied.

F-numbers come from a 12-entry table (`0x0134`..`0x0246`) plus base
frequency and a pitch-bend table indexed by the raw note nibble.

## Metadata

The format contains no metadata. A file with more than one music program
gets a synthesized title `stem track n/m`. That title is not embedded, and
a playlist EXTINF name covers it. The header format tag and the sequence
info strip still show `n/m` (1-based) whenever `,` / `.` can change songs.

## Errors

| Condition | Result |
|-----------|--------|
| Too short, or offsets that match no version | decline (`null`) |
| Recognized layout with no playable track | `error.InvalidAdl` |
| Truncated opcode operands at run time | that channel stops |
