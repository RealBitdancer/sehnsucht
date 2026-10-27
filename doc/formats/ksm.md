# KSM

**Extension:** `.ksm` (case-insensitive)
**Chip:** OPL2 with rhythm mode
**Module:** `src/formats/ksm.zig`

Ken Silverman's music format, used by Ken's Labyrinth. A song is a list of
timed note words for sixteen tracks. The instruments live in a shared bank,
`insts.dat`, beside the songs.

External reference:
[AdPlug KSM player](https://github.com/adplug/adplug/blob/master/src/ksm.cpp).

## Identification

The format has no magic value. The decoder claims every `.ksm` path. A file
must hold the 82-byte header, a nonzero note count, and that many 32-bit
note words.

## File layout

All values are little-endian.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 16 | Bank instrument for each track |
| 16 | 16 | Quantization for each track, in steps per second |
| 32 | 16 | OPL channels reserved for each track |
| 48 | 16 | Unused |
| 64 | 16 | Volume for each track, 0 to 63 |
| 80 | 2 | Note count |
| 82 | 4 × count | Note words |

A note word packs these fields:

| Bits | Field |
|------|-------|
| 0-5 | Frequency index into a 63-entry block and F-number table |
| 6-7 | 0 releases the note. 1 plays it, 2 plays it 4 steps softer, 3 plays it 4 steps louder |
| 8-11 | Track |
| 12-31 | Time in 1/240 second ticks |

## Companion bank

The loader requests `ksm.insts`. It tries `insts.dat`, then `INSTS.DAT`, in
the song's directory. The bank holds 256 records of 33 bytes: a 20-byte name,
eleven register bytes, and two unused bytes. The register bytes are the
carrier's 20, 40, 60, 80, and E0 values, the modulator's five values in the
same order, and the C0 value. A song without its bank fails with
`MissingResource`. A bank shorter than 8448 bytes fails with `InvalidKsmBank`.

## Decoding

Track 11 with a nonzero channel count turns on rhythm mode. Six melodic
channels then remain, and tracks 11 to 15 play the bass drum, snare, tom,
cymbal, and hi-hat. Otherwise nine melodic channels play. Channels go to
tracks in track order, as many as each track reserves. Channels that no track
claims stay with track 0.

A note-on from a melodic track takes the track's channel that has been idle
longest. Ties go to the higher channel. The note keys off the channel, sets
the carrier level from the track volume, and keys on the new pitch. A release
finds the track's channel playing that frequency index and keys it off.
Drum notes set the drum pitch, retrigger the drum's rhythm bit, and set its
operator level. Bass drum, snare, and hi-hat sound two octaves below their
index. Drum releases are ignored.

## Timing

The clock runs at 240 Hz. The first note plays at once, so the leading time
offset of the file is skipped. Each later note waits until its time, rounded
to the nearest multiple of 240 divided by its track's quantization. A
quantization of 0 or above 240 rounds to single ticks.

After the last note, playback returns to the first note and reports a song
boundary. Channel and drum state carry over into the next pass. Duration is
one pass through the note list.

## Playback

The sequence visualizer shows sixteen tracks. Track names are their bank
instrument names. Drum tracks show as drums in rhythm mode. Channel slots show
each track's last note. Active voices list the melodic channels and the rhythm
drums that have sounded. The inspector lists every note word and the sixteen
track instruments. The source loops, so single-file playback repeats.

## Metadata

The format contains no metadata. The shell shows the file name.

## Errors

A short header, a zero note count, or a truncated note list fails with
`InvalidKsm`. Bank errors are listed above.
