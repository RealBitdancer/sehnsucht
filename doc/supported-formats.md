# Supported formats

The player registers twenty-three format families for OPL2 and OPL3 playback.
Aliases and compressed wrappers appear separately where their names matter.

| Format | Extensions / paths | Visualizer | Notes |
|--------|--------------------|------------|--------|
| AdLib Tracker II | `.a2m`, `.a2t` | tracker | Versions 1 through 14. A2T omits names and other text metadata |
| ADL | `.adl` | sequence | Westwood AdLib archives. `,` / `.` and `--track` select a program |
| AudioT | `AUDIOT.*` / `AUDIO.*` / `AUDIOHED.*` | stream | Muse IMF archives. Huffman `AUDIO.*` needs `AUDIODCT.*` |
| BAM | `.bam` | sequence | Bob's Adlib Music (`CBMF`) at 25 Hz |
| CMF | `.cmf` | sequence | Creative Music File |
| DRO | `.dro` | stream | DOSBox Raw OPL v1 / early header / v2 |
| GOT | `.got`, `SONG1`..`SONG4` / `SONG21`..`SONG25` / `SONG31`..`SONG36` / `OPENSONG` / `WINSONG` / `BOSSSONG` / `MENU` | stream | God of Thunder. 120 Hz in-game, 140 Hz for `menu` |
| HSC-Tracker | `.hsc` | tracker | OPL2, 18.2 Hz |
| HSC Packed | `.hsp` | tracker | Packed HSC. Playlist label HSP |
| IMF | `.imf`, `.adlib` | stream | Default 560 Hz. Override with `--rate` or R |
| JBM | `.jbm` | sequence | Johannes Bjerregaard, PIT timing |
| KSM | `.ksm` | sequence | Ken Silverman, 240 Hz. Requires `insts.dat` |
| LAA | `.laa` | sequence | LucasArts iMUSE `ADL ` resources (MI2, Indy 4, DOTT) |
| LDS | `.lds`, `.ld0` | tracker | Loudness Sound System (OPL2) |
| Lucasfilm AD | `.laa` | sequence | Older SCUMM `AD` resources (Indy 3, Monkey Island 1) |
| RAC | `.rac` | stream | RAWADATA. AdPlug alias for RAC TSR output |
| RAD | `.rad` | tracker | Reality Adlib Tracker v1.0 and v2.1 |
| RAW | `.raw` | stream | Rdos RAWADATA, including dual OPL2 |
| ROL | `.rol` | sequence | Visual Composer 0.4. Requires a BNK bank |
| SCI0 | `.sci`, `.snd` | sequence | Optional digital PCM. FM needs a patch bank |
| SNGPlay | `.sng` | stream | `ObsM` at 70 Hz. Faust and Adlib Tracker 1.0 are not claimed |
| VGM / VGZ | `.vgm`, `.vgz` | stream | OPL-family chips, dual OPL3, Y8950 ADPCM, GD3 metadata |
| WLF | `.wlf` | stream | Default 700 Hz. Override with `--rate` or R |
| MusicV | `.wm`, `.m` | sequence | Six 4-operator OPL3 voices. Ultima 6 `.m` is not claimed |
| Miles XMI | `.xmi` | sequence | AIL sequences. Requires an OPL2 or OPL3 GTL bank |
| XSM | `.xsm` | tracker | eXtra Simple Music (`ofTAZ!`) at 5 Hz |

Filename matching ignores ASCII case.

KSM requires the `insts.dat` bank. ROL requires a matching BNK bank. SCI0 requires AdLib patches when the resource
uses FM. XMI requires matching program/bank entries in an OPL2 or OPL3 GTL bank.
The loader searches beside the song, including for remote URLs. Individual
guides list candidate names and errors.

Non-OPL VGMs are not supported. In mixed-chip files, only supported OPL-family
chips and Y8950 ADPCM contribute audio.
SCI1 and later layouts are not SCI0. XMI plays one sequence at a time and does
not emulate a game's complete AIL runtime.

DRO is a millisecond register capture, including output from
[vgz2dro](https://github.com/RealBitdancer/vgz2dro).

Per-format layouts: [formats/](formats/). Adding a format:
[adding-a-format.md](adding-a-format.md). The 1.0.0 goal is in
[Format inventory](retromusic-formats.md).
