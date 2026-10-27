# SCI0

**Extensions:** `.sci`, `.snd` (case-insensitive)
**Chip:** OPL2, with optional digital PCM
**Module:** `src/formats/sci.zig`

SCI0 sound resources contain MIDI-like events and, in some files, a digital
sample. Playback uses the AdLib channels selected by the resource header.

## Identification and layout

The first two bytes must be `84 00`. The resource header is 35 bytes:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 2 | Sound resource signature |
| 2 | 1 | 0 for events, 2 for events with a sample |
| 3 | 32 | Sixteen two-byte channel descriptors |
| 35 | variable | Event stream |

A channel descriptor's first byte gives polyphony in its low nibble. Bit 2
of the second byte selects AdLib playback. Channel 15 is the control channel
and does not sound notes. In sample-bearing resources, bytes 33 and 34 also
give the big-endian sample offset relative to byte 3.

## Companion patches

The loader requests `sci.patch`, trying `patch.003`, `PATCH.003`, `3.pat`,
`3.PAT`, and the song's
game prefix followed by `patch.003`. The last form covers Modland names such
as `ice action.sci` and `icepatch.003`. Encoded spaces in remote URLs work.

Patch resources contain 48 or 96 instruments of 28 bytes each. A 96-instrument
bank has `AB CD` between the two groups of 48. An optional `89 00` resource
prefix is accepted. A digital-only sound does not request or require a bank.

## Decoding and timing

Events use a fixed 60 Hz clock and MIDI running status. Each event begins with
a delay. Every `F8` delay byte adds 240 ticks before the final delay byte.
`FC` ends the stream. Note, program, controller, pressure, pitch-bend, and SysEx
events are retained for inspection. SysEx and pressure do not affect synthesis.

Program changes on control channel 15 are cues. Program 127 marks the loop
position. The decoder implements volume, sustain, pitch bend, channel
polyphony changes (controller 75), and velocity enable (controller 78).
Polyphony is limited to nine OPL voices. Velocity starts disabled.

Changing channel polyphony releases excess voices immediately, including
sustained voices. Tick-to-frame conversion carries fractional frames between
intervals.

## Digital samples

The sample offset permits padding after the event stream. A zero offset uses
the data immediately after the event terminator, allowing one extra `FC` byte.
The sample header is 44 bytes. Its little-endian rate and length fields are at
offsets 14 and 32. The payload is unsigned eight-bit mono PCM, converted to
signed samples and resampled to the output rate.

The sample starts with the resource. Its tail plays to completion after the
event end marker. Reported duration includes both the event stream and sample.

## Playback and display

The sequence view keeps all sixteen MIDI channels and adds a separate PCM
lane when sample data exists. This preserves the control channel and exposes
the sample instrument and measured level in the mixer, spectrum, and inspector.
FM channel meters aggregate their active voices. Cue events remain visible.

A same-tick run yields after 4096 events and continues on the next step.
A resource with a loop marker resumes at that marker after the song boundary.
Otherwise it plays once. Space replays it after it stops. The shell uses the
filename because the decoder publishes no embedded title.

## Errors

Other signatures are declined. A recognized resource with an unsupported type
returns `UnsupportedSciVersion`. Missing required patches return
`MissingResource`. Invalid patch layouts or out-of-range programs return
`InvalidSciPatch`. Truncated events, missing end markers, and invalid sample
offsets, lengths, or rates return `InvalidMusicData`.

## References

[SCI sound subsystem](https://wiki.sierrahelp.com/index.php/SCI_Specifications:_Chapter_4_-_The_Sound_subsystem),
[AdLib patch resource](https://wiki.sierrahelp.com/index.php/Adlib_Patch_Resource_Format_Specification).
