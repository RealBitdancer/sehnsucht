# IMF / WLF (id Software Music Format)

**Extensions:** `.imf`, `.wlf`, `.adlib` (case-insensitive)
**Chip:** OPL2
**Module:** `src/formats/imf.zig`

IMF stores OPL2 register writes and delays. The file does not store its tick
rate. The original game supplied that value.

External reference:
[IMF Format (ModdingWiki)](https://moddingwiki.shikadi.net/wiki/IMF_Format).

## Identification

sehnsucht uses this procedure:

1. Require an IMF-family extension.
2. Look for the `ADLIB` wrapper described below.
3. If the wrapper is not valid, apply plain type-0 or type-1 framing.
4. Decode complete four-byte command records.

The wrapper check runs for every IMF-family extension, not only `.adlib`.

## File layout

### ADLIB metadata wrapper

Some Modland and AdPlug rips use this wrapper:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 5 | ASCII `ADLIB` |
| 5 | 1 | Version, must be `0x01` |
| 6 | Variable | NUL-terminated track name |
| After track name | Variable | NUL-terminated game name |
| After game name | 1 | Filler, ignored |
| After filler | 4 | Command byte length, little-endian `u32` |
| After length | Variable | Raw command stream |

Both strings must terminate before the length field. The filler value is not
validated.

A zero payload length means all remaining bytes. A nonzero length selects:

```text
body[0 .. min(payload_length, body_size)]
```

The selected payload must contain at least four bytes. It is already a raw
command stream. Do not apply type-0 or type-1 framing inside it.

If any wrapper check fails, sehnsucht tries the same bytes as a plain IMF file.
An empty track name is treated as no title. An empty game name means that no
game metadata is present.

### Plain framing

Plain files use a simple first-word test. The input must contain at least four
bytes before this test.

#### Type 0

If the first little-endian `u16` is zero, the entire file is the command
stream. There is no two-byte header to skip. Bytes 0 and 1 are the register and
value of the first command.

Under this rule every type-0 file begins with `00 00`, so the first command
is a write of 0 to register 0. That write is harmless on the original
hardware.

#### Type 1

If the first little-endian `u16` is nonzero, it is the command stream length in
bytes. The prefix itself is not part of the length.

```text
declared_length = u16_le(file[0..2])
available       = file_size - 2
stream          = file[2 .. 2 + declared_length]
```

A declared length that overruns the file is clamped to the data that actually
arrived, since files in the wild (Rise of the Triad's `titlermx.imf` among
them) lost their last records in transit. A trailing partial record is
dropped. The stream is rejected only when no complete four-byte record
remains.

Bytes after the selected stream may carry a tag footer (below). Anything else
there is ignored.

The first-word test is intentionally simple. A type-0 file whose first two
command bytes form a nonzero word will be read as type 1. Historical tools use
several heuristics, but the file format provides no unambiguous marker.

#### Tag footers

Two unofficial tag blocks appear after type-1 streams in the wild, and AdPlug
reads both:

* Adam Nielsen's tag: marker byte `0x1A`, then title, author, and remarks as
  NUL-terminated strings, then nine bytes naming the tagging program. The
  block is at most 778 bytes.
* Muse tag: exactly 88 bytes. Two unknown bytes, a 16-byte title field, a
  64-byte remarks field (both NUL-terminated), and six unknown bytes.

A nonempty tag title becomes the embedded title. A Nielsen author becomes the
track artist. Remarks are not exposed. Type-0 files have no length prefix, so
they cannot carry a footer. A footer inside an `ADLIB` wrapper is not parsed,
because the wrapper already names the track.

### Command stream

Commands are four bytes:

| Byte | Field |
|-----:|-------|
| 0 | OPL2 register |
| 1 | Register value |
| 2 to 3 | Delay in ticks, little-endian `u16` |

## Decoding

Write the value to the register, then wait for the given number of ticks. A
zero delay means no wait. Continue processing zero-delay commands in the same
tick until a nonzero delay or the end of the stream.

Each register is an eight-bit OPL2 address. IMF has no OPL3 bank selector.

The isolated stream must contain complete four-byte commands and at least one
nonzero delay. Playback rewinds to byte zero when the stream ends.

## Timing

### Tick rate

The rate is external to the file.

| Rate | Common use |
|-----:|------------|
| 280 Hz | Duke Nukem II |
| 560 Hz | Commander Keen, Bio Menace, Monster Bash, Catacomb 3-D |
| 700 Hz | Wolfenstein 3D family, Cosmo's Cosmic Adventure |

sehnsucht defaults to 560 Hz for `.imf` and `.adlib`, and 700 Hz for `.wlf`.
The extension comparison ignores case. A configured rate overrides the
extension.

The accepted override rates are 280, 560, and 700 Hz:

```text
sehnsucht --rate 700 tune.imf
sehnsucht --rate=280 tune.imf
```

The **R** key cycles 280, 560, and 700 Hz while a rate-adjustable track is
loaded, including while paused. Space replay and AudioT `,` / `.` keep the
chosen rate. A playlist skip or Enter jump starts the next file at `--rate`
or the path default. If you launched with `--rate`, R updates that session
override instead.

### Frame conversion

Convert a delay to output frames with a running remainder:

```text
numerator = delay * sample_rate + remainder
frames    = numerator / tick_rate
remainder = numerator % tick_rate
```

The remainder persists across commands and resets when the tick rate changes.
At a 44100 Hz output rate, 560 successive one-tick delays at 560 Hz produce
exactly 44100 frames.

Changing the rate changes tempo, not operator pitch. A wrong rate is therefore
easy to hear and easy to misdiagnose.

## Playback

IMF always uses OPL2 and the stream visualizer. It loops when the isolated
command stream ends.

## Metadata

Bare files report no title, so the shell falls back to the decoded file name
without its extension. A valid `ADLIB` wrapper may supply a track title and a
game name. A type-1 tag footer may supply a title and an author. Titles from
either source are embedded metadata only when nonempty.

Labels follow the path (`IMF`, `WLF`, `ADLIB`). A file loaded at 700 Hz is
labelled `WLF`. Cycling the rate later does not change that label.

## Errors

Paths without an IMF-family extension are not claimed. Plain inputs shorter
than four bytes are rejected. A malformed `ADLIB` wrapper falls back to plain
framing. An overrunning declared length is clamped and a trailing partial
record is dropped rather than rejected. A stream is rejected when no complete
command record remains or all command delays are zero.

## Compatibility notes

* Early AudioT archives may use a four-byte music length. The plain IMF parser
  only understands the two-byte type-1 length.
* Free-form text footers without a recognized tag block are ignored.
* `.adlib` selects a default rate of 560 Hz. Some `.adlib` rips came from
  700 Hz games and need an override.
