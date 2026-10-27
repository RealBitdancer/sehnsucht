# Miles XMI

**Extension:** `.xmi` (case-insensitive)
**Chip:** OPL2 or OPL3, selected by the timbre bank
**Module:** `src/formats/xmi.zig`

AIL XMIDI sequences in bare `FORM XMID` or `FORM XDIR` / `CAT XMID` containers.
Comma and period select sequences without downloading the archive again.

## Identification and layout

The file begins with `FORM`, a big-endian length, and `XMID` or `XDIR`.
IFF chunk lengths exclude the eight-byte chunk header. Odd-length payloads
have one padding byte. A directory container can hold several `FORM XMID`
sequences inside `CAT XMID`.

| Chunk | Content |
|-------|---------|
| `EVNT` | Required event stream, one per sequence |
| `TIMB` | Optional little-endian count followed by program/bank pairs |
| `RBRN` | Optional little-endian count followed by 16-bit labels and 32-bit event offsets |

Branch offsets must identify event status bytes in `EVNT`. Duplicate branch
labels and missing timbres are rejected. The loader permits up to 256
sequences and 262,144 events per sequence. Nested containers are bounded.

## Companion timbres

The loader requests `xmi.timbres`. It tries the song stem with `.opl` and `.ad`,
then `standard.opl`, `standard.ad`, `standard.gtl`, `sample.opl`, and `sample.ad`
in the same directory. Standard and sample names also have uppercase fallbacks.
The bank must contain the requested program and bank pairs. Both 14-byte
two-operator and 25-byte four-operator GTL entries are supported, including
melodic transposition and percussion pitch. Banks and songs remain external files.

The GTL directory stores a program byte, bank byte, and little-endian 32-bit
patch offset for each entry. Program `FF` terminates the directory. A patch
begins with its little-endian size and a transpose or percussion-pitch byte.
Bank 127 supplies percussion patches indexed by note number.

## Decoding and timing

Timing follows the fixed 120 Hz event clock. Bytes below `80` add to the delay
before the next status byte. A note-on carries a variable-length duration
after its note and velocity. It does not use ordinary MIDI running status.
Tempo metadata is inspectable but does not replace the XMIDI clock.

Note durations schedule releases during waits. Playback supports four nested
FOR/NEXT loops, break and indefinite loops, program and bank changes, volume,
expression, sustain, pitch bend, and voice protection. Controller 114 selects
the bank, 112 controls voice
protection, and 116/117 implement FOR/NEXT. An indefinite loop reports a song
boundary at its repeat. Pending duration notes are released before the final
end marker completes playback.

## Playback and display

A bank containing four-operator patches enables eighteen physical OPL3 voices.
Four-operator patches reserve both halves of a hardware pair, including
during sustain.
Volume changes affect every carrier in the selected algorithm. Pan selects
left, both, or right output on both halves.

A same-tick run yields after 4096 events and continues on the next step.
The sequence visualizer shows sixteen logical MIDI channels. Its mixer and
spectrum combine the active voices assigned to each channel. The inspector
exposes the complete event list, timbre operators, and branch targets.
The inspector's branch section selects an explicit target. A branch clears
old notes and pending loop state before continuing.

`--track` uses one-based sequence numbers. Comma and period change the selected
sequence with a fresh playback state. The source is marked non-looping, so
single-file playback stops at the first song boundary, including an indefinite
loop's repeat point. Space replays the selected sequence. The header shows the
selected member and total count. No embedded title is published, so the shell
uses the filename.

## Errors

Unrelated signatures are declined. Missing banks return `MissingXmiBank`.
Out-of-range directory entries, patch lengths past the bank, or a bank with
no entries return `InvalidXmiBank`. A directory that ends before its `FF`
terminator returns `InvalidMusicData`. Unsupported patch sizes return
`UnsupportedXmiTimbre`. Absent program/bank pairs return
`MissingXmiTimbre`. Invalid loop nesting and branch offsets return
`InvalidXmiLoop` and `InvalidXmiBranch`, but a FOR still open at the end of the
track returns `InvalidMusicData`. Malformed containers and event records
return `InvalidMusicData`. A directory with no sequences returns
`InvalidTrackIndex`.

## References

[AIL XMIDI documentation](https://github.com/Mindwerks/wildmidi/blob/master/docs/formats/XMIFileFormat-AIL.txt).
The GTL record layouts and `.OPL` bank convention come from the original
[Miles Yamaha driver definitions](https://github.com/Tronix286/AIL2/blob/master/YAMAHA.INC).
