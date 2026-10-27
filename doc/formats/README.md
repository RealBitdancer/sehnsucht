# Format documentation

These documents describe the binary layouts and playback rules for each
decoder.
The user-facing list is
[Supported formats](../supported-formats.md).

See [Adding a format](../adding-a-format.md) for the decoder interface,
ownership rules, and registration steps. Start a decoder by
copying `src/formats/template.zig`. Visualizer mapping and view contracts are
in [Visualizer architecture](../visualizer-architecture.md).

Copy [template.md](template.md) when documenting a new format. Keep its primary
sections in order. Add format-specific subsections where the binary layout or
decoder state requires them. Playback sections name the visualizer, the views
the source publishes, and what remains available only through Inspect.

| Format | Extensions / paths | Visualizer | Doc |
|--------|--------------------|------------|-----|
| AdLib Tracker II | `.a2m`, `.a2t` | tracker | [a2m.md](a2m.md) |
| ADL | `.adl` | sequence | [adl.md](adl.md) |
| AudioT | `AUDIOT.*` / `AUDIO.*` / `AUDIOHED.*` | stream | [audiot.md](audiot.md) |
| BAM | `.bam` | sequence | [bam.md](bam.md) |
| CMF | `.cmf` | sequence | [cmf.md](cmf.md) |
| DRO | `.dro` | stream | [dro.md](dro.md) |
| GOT | `.got`, `SONG1`..`SONG4` / `SONG21`..`SONG25` / `SONG31`..`SONG36` / `OPENSONG` / `WINSONG` / `BOSSSONG` / `MENU` | stream | [got.md](got.md) |
| HSC / HSP | `.hsc`, `.hsp` | tracker | [hsc.md](hsc.md) |
| IMF / WLF | `.imf`, `.wlf`, `.adlib` | stream | [imf.md](imf.md) |
| JBM | `.jbm` | sequence | [jbm.md](jbm.md) |
| KSM | `.ksm` | sequence | [ksm.md](ksm.md) |
| LAA | `.laa` (iMUSE `ADL `) | sequence | [laa.md](laa.md) |
| LDS | `.lds`, `.ld0` | tracker | [lds.md](lds.md) |
| Lucasfilm AD | `.laa` (`AD` resource) | sequence | [lucasfilm.md](lucasfilm.md) |
| RAD | `.rad` | tracker | [rad.md](rad.md) |
| RAW / RAC | `.raw`, `.rac` | stream | [raw.md](raw.md) |
| ROL | `.rol` | sequence | [rol.md](rol.md) |
| SCI0 | `.sci`, `.snd` | sequence | [sci.md](sci.md) |
| SNGPlay | `.sng` | stream | [sng.md](sng.md) |
| VGM / VGZ | `.vgm`, `.vgz` | stream | [vgm.md](vgm.md) |
| MusicV | `.wm`, `.m` | sequence | [wm.md](wm.md) |
| Miles XMI | `.xmi` | sequence | [xmi.md](xmi.md) |
| XSM | `.xsm` | tracker | [xsm.md](xsm.md) |

## Shared modules

Keep each format's parser, playback, and unpacking in its decoder module.
Helpers used by more than one decoder live outside `src/formats/`:

| Module | Role |
|--------|------|
| `src/binary.zig` | Little-endian reader and text trimming used by KSM, LAA, ROL, SCI0, and XMI |
| `src/fm.zig` | OPL operator and channel register helpers |
| `src/inflate.zig` | Bounded gzip, zlib, and raw inflate (VGZ, zip members) |
| `src/midi_opl.zig` | MIDI-like voice allocation for SCI0 and XMI |
| `src/pcm.zig` | Sample voices for mixed digital PCM |
| `src/inspector.zig` | Shared I popup used by every visualizer |

`labelForPath` sets the playlist label when one decoder owns more than one
name (`HSP`, `RAC`, `VGZ`, `LD0`, `WLF`, `ADLIB`). Use the same spelling in
`TrackInfo.format_name`.

Decoder modules live under `src/formats/`. Registration order is in
`src/registry.zig`. That order is detection order when formats share a path
rule.

OPL2/OPL3 formats are listed in [Format inventory](../retromusic-formats.md).
The 1.0.0 goal is current AdPlug coverage at a minimum, plus lesser-known DOS
game formats.
