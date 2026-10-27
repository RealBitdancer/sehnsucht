# AdLib Tracker II

**Extensions:** `.a2m`, `.a2t` (case-insensitive)
**Chip:** OPL2 for versions 1 through 4, OPL3 for versions 5 through 14
**Module:** `src/formats/a2m.zig`

A2M stores instruments, patterns, an order list, and, in newer versions,
instrument macros. A2T stores the same musical data in separate, compact
blocks without names or other text metadata. Both containers support
versions 1 through 14 and share playback and Tracker views in this module.

Remote samples: [playlists/a2m.m3u](../../playlists/a2m.m3u).

External references:
[format description](https://adlibtracker.net/files/techinfo.htm),
[current manual](https://adlibtracker.net/files/adtrack2.htm),
[original OPL2 manual in version 2.0.27](https://adlibtracker.net/files/at2r27s1.zip),
[revision history](https://adlibtracker.net/files/revision.htm).

## Identification

A2M starts with the ten-byte signature `_A2module_`. A2T starts with the
fifteen-byte signature `_A2tiny_module_`. Matching ignores ASCII case.
A different signature declines the file. Recognized headers with unsupported
versions or invalid data return an error. Browse, Playlist, and track
information label tiny modules as A2T.

## A2M file layout

All multi-byte fields are little-endian. Offset 10 holds a four-byte CRC,
offset 14 the version, and offset 15 the pattern count. Block lengths follow
at offset 16. Block zero is song data. The remaining blocks hold patterns.

- Versions 1 through 4 have five 16-bit lengths and a 26-byte header.
  Each pattern block holds up to 16 patterns.
- Versions 5 through 8 have nine 16-bit lengths and a 34-byte header.
  Each pattern block holds up to eight patterns.
- Versions 9 through 14 have seventeen 32-bit lengths and an 84-byte header.
  Each pattern block holds up to eight patterns.

Every length slot is read for the checksum. Only lengths needed by the pattern
count are checked and unpacked. Some early files have uninitialized values in
unused length slots. Required blocks must fit inside
the input and expand to complete records.

Song-data sizes are `0x2dc4` for versions 1 through 4, `0x2dc5` for 5 through
8, `0x1128a5` for 9, `0x1128ba` for 10, `0x115a1e` for 11, `0x115e9f` for
12 and 13, and `0x115ea2` for 14. These are decoded sizes.

### Song data

Title and composer are Pascal strings with 43 bytes each, at offsets 0 and
43. Instrument names begin at 86. Early files have 250 names of 33 bytes.
Modern files have 255 names of 43 bytes, including version 9. Published
version-9 tables that list 250 names of 33 bytes do not match version-9 files.

Early instrument records begin at `0x2090` and have 13 bytes. Modern records
begin at `0x2b2b` and have 14 bytes. Bytes 0 through 9 alternate modulator
and carrier values for characteristics, level, attack/decay, sustain/release,
and waveform. Byte 10 holds connection and feedback. Byte 11 is panning,
byte 12 is signed fine-tuning, and byte 13 is the modern percussion field.

The 128-byte order list begins at `0x2d42` in early files and `0x11281d` in
modern files. Tempo and speed follow it. Versions 5 onward add common flags.
Modern files then store row count as a word, channel count as a byte, and
macro speed multiplier as a word. Versions 10 onward add the six pairing
bits and twenty initial track-lock bytes. Versions 11 onward store 128
pattern names at `0x1128ba`, followed by 255 sets of 28 disabled macro-column
bytes at `0x113e3a`.

Version 14 adds rows per beat at `0x115e9f` and a signed 16-bit tempo adjustment
at `0x115ea0`. The adjustment is in hertz, separate from instrument fine-tuning.

## A2T file layout

The CRC begins at offset 15, the version at 19, and the pattern count at 20.
Initial tempo and speed occupy bytes 21 and 22. Versions 5 onward add common
flags at 23. Versions 9 onward add row count at 24, channel count at 26, and
a 16-bit macro-speed multiplier at 27. Versions 10 onward add pairing flags
at 29 and twenty track-lock bytes at 30.

- Versions 1 through 4 have six 16-bit block lengths at offset 23 and a
  35-byte header. Instruments and orders precede four pattern groups.
- Versions 5 through 8 have ten 16-bit lengths at offset 24 and a 44-byte
  header. Instruments and orders precede eight pattern groups.
- Version 9 has twenty 32-bit lengths at offset 29 and a 109-byte header.
  Instruments, FM macros, pitch macros, and orders precede sixteen groups.
- Version 10 keeps that block order, with lengths at offset 50 and a
  130-byte header.
- Versions 11 through 14 have twenty-one 32-bit lengths at offset 50 and
  a 134-byte header. A disabled-macro-columns block precedes the order block.

Instrument and macro blocks can omit unused trailing records. Omitted records
remain zeroed. Instrument numbering stays one-based, and the displayed bank
contains only the stored instruments plus the empty zero slot. Nonempty order
blocks shorter than 128 bytes are accepted, with the remainder returning to
order zero. The original tracker distribution includes such a file.

Versions 12 and 13 prefix the instrument block with 129 four-operator
instrument flags and 1024 reserved bytes. Version 14 puts rows per beat and
the signed 16-bit tempo adjustment before that prefix. The record sizes,
pattern grouping, and compression algorithms otherwise match A2M.

The online description lists a one-byte macro-speed multiplier and aPLib for
version 12. External decoder checks require the word-sized field and LZH.
These differences affect every later header offset. The loader follows the
working layout.

A2T blocks are assembled into the same owned song data used by A2M. Playback
and visualization therefore use one implementation for notes, effects,
macros, channel pairing, and timing.

## Shared musical data

### Patterns

Versions 1 through 4 store 64 rows of nine four-byte events, in row order.
Versions 5 through 8 store eighteen tracks of 64 four-byte events.
Modern files store twenty tracks of 256 six-byte events, even when the song
uses fewer tracks or rows.

An event contains note, instrument, effect command, and parameter. Modern
events add a second command and parameter. Notes 1 through 96 cover C-0
through B-7. Zero leaves the note alone, `0xff` releases it, and adding
`0x90` marks a fixed note. Instrument zero reuses the current instrument.

Order values below 128 select a pattern. Values from 128 onward jump to
the order indexed by their low seven bits.

### Macros

Modern FM macros begin at `0x391d`. There are 255 records of 3831 bytes.
Each starts with length, loop start, loop length, key-off position,
arpeggio-table number, and vibrato-table number. The remaining 255 steps
have fifteen bytes each. They contain eleven operator bytes, a signed
16-bit frequency change, panning, and duration. Macro level bytes store
volume rather than OPL attenuation. Version 11 adds the retrigger flag in
bit 7 of the feedback byte.

Arpeggio and vibrato tables begin at `0xf2126`. Each of the 255 pairs has
521 bytes. The first 260 bytes hold arpeggio length, speed, loop start,
loop length, key-off position, and 255 values. The remaining 261 bytes hold
vibrato length, speed, initial delay, loop start, loop length, key-off
position, and 255 signed values. Positions are one-based. Zero disables a
position or table reference.

## Decoding

The decoder owns both decoded blocks. Names are converted once at load time.
Playback and view callbacks do not allocate.

Unpacking stays in this module as private helpers.
The version dispatch and AT2-specific aPLib and LZH variants belong to the
format decoder.

- Versions 1 and 5 use Sixpack. Its bitstream reads high bits first from
  little-endian words. Adaptive symbols encode literals, end of stream,
  and six distance ranges with match lengths from 3 through 255.
- Versions 2 and 6 use LZW, with low-bit-first codes growing from 9 to 13
  bits. Codes 256 and 257 reset the dictionary and end the block.
- Versions 3 and 7 use LZSS, with low-bit-first literal flags and a
  4096-byte circular history. Matches may overlap or cross the ring boundary.
- Versions 4 and 8 store blocks without compression.
- Versions 9 through 11 use the older aPLib encoding. Its repeat-distance
  code does not depend on the preceding token type.
- Versions 12 through 14 use AT2's modified LZH encoding. A leading byte
  and a 32-bit output size precede the bitstream. The Huffman table fields
  differ from ordinary LH5.

Every decoder checks input reads, output capacity, and match distances.
Pattern blocks may include unused trailing patterns, but must contain every
pattern named by the header. Loading rejects zero tempo or speed, row counts
outside 1 through 256, and channel counts outside 1 through 20.

### Checksums

Both containers verify their stored CRC before allocating or unpacking song
data. The calculation uses the reflected CRC-32 polynomial `0xedb88320`,
an initial value of `0xffffffff`, and no final XOR. Packed blocks are processed
in file order. The low two bytes of every block-length field follow them,
including unused slots. Modern lengths occupy four bytes, but their upper
two bytes are not part of the CRC.

Only blocks required by the pattern count enter the payload checksum.
Trailing file bytes are ignored. Version, pattern count, and A2T playback
header fields are outside the checksum. Their structural checks still apply.
A zero stored CRC is checked normally, not treated as an opt-out.

The calculation uses Zig's standard CRC implementation. Validation loaded
and stepped 302 real and generated modules, including 277 A2M files, the
historical A2T sample, and generated variants covering all fourteen versions.
Changing the stored checksum caused each file to be rejected.

## Timing

Tempo is main ticks per second. Speed is ticks per row. Macro speed divides
each main tick into equal sub-ticks. Integer sample conversion carries its
remainder between steps and rescales that remainder when tempo changes.
The first row starts immediately. There is no initial silent row delay.
Version-14 tempo adjustment and the `ZE7` playback-speed slides change the
effective tick rate without replacing the base tempo. The tracker displays
that rate and BPM, calculated from speed and rows per beat.

Pattern delays extend the current row. Pattern loops remain inside the
current order. Re-entering an order that has already played marks the end of
a pass. The last row receives its full duration before that boundary is
reported. Repetition preserves instruments, effects, volume, tempo, and the
jump destination. The common speed-reset flag restores the initial speed
when playback returns to order zero.

## Playback

The player implements two effect columns, pitch and volume changes,
portamento, arpeggio, vibrato, tremolo, retrigger, delays, pattern loops,
operator changes, and instrument macros. Early OPL2 effect numbers are
translated using the original manual. Versions 5 through 8 keep the older
manual slide at M, a fine tune up by `x`, or down by `y` when `x` is zero.

Logical tracks follow AT2's OPL3 pair ordering. The lower hardware voice of
a four-operator pair controls pitch and key state. Rhythm mode assigns the
last five logical tracks to bass drum, snare, tom, cymbal, and hi-hat. Their
key bits are combined in register `0xbd`.

Unchanged registers are not written again. Tracks sharing a rhythm pitch
register only update it when their own pitch or key state changes. This
avoids repeated writes between two static percussion pitches.

The tracker visualizer exposes both effect columns, order jumps,
instrument and pattern names, operator settings, macro definitions, and live
macro positions through the shared source views and live snapshots.

Pitch macros wait one sub-tick before their first step. Vibrato also respects
its initial delay. A release starts at the held pitch and the macro's key-off
position. When key-off looping is enabled, it repeats the release section
instead of returning to the sustain loop.

## Metadata

Strings use their Pascal length byte, bounded by the field size. CP437 bytes
are converted to UTF-8. Control bytes become spaces. Trailing spaces are
removed. Empty titles remain absent so the player can use the filename.
A2T has no stored title, composer, instrument names, or pattern names. Its
views leave those fields empty while retaining the musical data.

## Errors

- `InvalidA2m` means a required header, block, or dimension is invalid.
- `InvalidA2mChecksum` means the stored CRC does not match the packed data
  and length words.
- `InvalidA2mCompression` means compressed data is truncated or invalid,
  or would read or write outside its buffers.
- `UnsupportedA2mVersion` covers versions outside 1 through 14.
- Allocation failures remain `OutOfMemory`.
