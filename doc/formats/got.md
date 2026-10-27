# GOT (God of Thunder Music)

**Extensions:** `.got` (case-insensitive)
**Also:** game resource names `SONG1`..`SONG4`, `SONG21`..`SONG25`,
`SONG31`..`SONG36`, `OPENSONG`, `WINSONG`, `BOSSSONG`, `MENU` (no extension)
**Chip:** OPL2
**Module:** `src/formats/got.zig`

A raw OPL2 register stream used by Adept Software's 1993 DOS game God of
Thunder (Roy Davis). Events are a delay plus a register/value pair. The game
timer runs at 120 Hz in play, and at 140 Hz for the title tune.

External reference:
[God of Thunder Music Format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/God_of_Thunder_Music_Format),
[ScummVM GOT parser](https://github.com/scummvm/scummvm/blob/master/engines/got/musicparser.cpp).

## Identification

1. The path ends in `.got`, ignoring case, or the basename is one of the
   game resource names (`SONG1`, `OPENSONG`, `WINSONG`, `BOSSSONG`, `MENU`,
   and the other `SONGn` / `SONGnn` titles listed above), ignoring case.
2. The file is at least 9 bytes.
3. The last four bytes are `00 00 00 00`.
4. Walking the event stream from offset 2 finds a terminator, at least one
   register write, and a nonzero sum of event delays (including the
   terminator). At most one byte may follow the terminator (the pad).

Wrong size or a tail that is not four zeros declines the file. A terminator
that leaves more than one byte behind it also declines, so God of Thunder
save games (`SAVEGAM*.GOT`, a padded profile name plus level data) are not
claimed even when they end in zeros. A four-zero tail whose stream is
truncated mid-event returns `error.InvalidGot`.

## File layout

All multi-byte integers are little-endian.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 2 | Loop start, in words from the beginning of the file |
| 0x02 | … | Event stream |
| last 4 | 4 | Terminator (`00 00 00`) plus one padding byte |

### Loop word

| Value | Meaning |
|------:|---------|
| `0` | No loop. Play to the terminator once. |
| `N` | Restart at byte `(N - 1) * 2` of the event stream (byte `2N` of the file). |

`N = 1` restarts at the first event, which is what the shipped songs use.

A loop offset that does not land on an event start, or that lands on the
terminator, is ignored and the track is treated as non-looping.

### Events

An event is a delay, then an OPL register byte, then a value byte.

The delay is one byte when bit 7 is clear, and two bytes when bit 7 is set:

```text
if delay0 & 0x80 == 0:
    ticks = delay0
else:
    ticks = ((delay0 & 0x7F) << 8) | delay1
```

Maximum delay is `0x7FFF` ticks (about 273 seconds at 120 Hz). Published
songs keep delays in one byte. The two-byte form is the original timer
player's encoding, as documented on ModdingWiki and as ScummVM decodes it.

The delay is the wait **after** the write, until the next event. A delay of
0 means the next event runs in the same `step`.

### Terminator

Register `0` with value `0` ends the stream. That pair is not written to the
chip. The delay on the terminator is still counted. Shipped files use delay
0 there, then one extra `00` byte.

## Decoding

1. Require the size and four-zero tail. Read the loop word.
2. Walk events from offset 2. A run off the end of the file is
   `error.InvalidGot`. A stream with no write, a total delay of 0, or more
   than one byte after the terminator declines the file.
3. On load, write OPL register `0x01` = `0x20` (waveforms enabled).
4. `step` writes events until a nonzero delay, the terminator, or 4096 ops.
   Hitting the op cap returns `frames = 0` and keeps the cursor, so a storm
   of zero-delay writes cannot stall the audio thread.

## Timing

In-game songs tick at **120 Hz**. A file whose stem is `menu`, ignoring
ASCII case, ticks at **140 Hz** (the title tune in `got.exe`). `--rate` does
not apply. That flag is the IMF/WLF/AudioT 280/560/700 cycle.

```text
frames = rescale(ticks, tick_hz, sample_rate)
```

with the shared fractional carry used by other stream formats.

Duration is `total_ticks * sample_rate / tick_hz` for one pass through the
terminator, including the terminator delay.

## Playback

GOT uses the stream visualizer and OPL2 only. NEW stays off.

Playback starts at the first event even when the loop word points later, so
an intro before the loop point is heard once.

At the terminator the decoder sets the cursor to the loop point (or to the
first event when there is no loop) and reports a song boundary (`done`).
`TrackInfo.loop` is set only when a usable loop point exists. A looping
source continues from that point on the next `step`. A non-looping source
parks, and Space replays from the start.

## Metadata

The format contains no metadata. Title stays unset so the shell can fall
back to the file name without its extension.

The stream visualizer shows physical OPL voices and measured audio. Its dump
metadata includes the selected rate, loop status, and register-write count.
The terminator is not counted as a write.

## Errors

Paths without `.got` and without a known resource basename are not claimed.
A short file, a tail that is not four
zeros, a stream with no write, a total delay of 0, or more than one byte
after the terminator declines the file. A four-zero tail with a truncated
event returns `error.InvalidGot`.
