# OPL2 / OPL3 format inventory

The goal for sehnsucht 1.0.0 is, at a minimum, to support every OPL2/OPL3
format current AdPlug plays. 1.0.0 also aims to cover lesser-known OPL2/OPL3
formats used by older DOS games.

The sehnsucht column describes the current source tree. For an unimplemented row, the
module name and visualizer are proposed assignments, not files or plugins
already present. This is a working inventory, not an exhaustive list of every
game driver. AdPlug coverage was checked against its
[player registry](https://github.com/adplug/adplug/blob/master/src/adplug.cpp)
on 2026-10-27. A `yes` describes the format family, not a guarantee for every
variant or extension.

Aliases and wrappers that unpack or relabel the same inner payload share the
parent module. A2T lives in `a2m.zig`, HSP in `hsc.zig`, VGZ in `vgm.zig`, RAC in `raw.zig`,
WLF and ADLIB in `imf.zig`, and LD0 in `lds.zig`. The same rule assigns future
XMS support to `amd.zig`, IMPlay to `mus.zig`, and HSQ/SQX to `herad.zig`.
Naked Easy AdLib (`.bmf`) and XAD-wrapped BMF share the proposed `bmf.zig`. Version
families of one format stay in one module (DRO, AdLib Tracker 2, Surprise!
Adlib Tracker).

Distinct formats keep distinct modules even when they share an extension, or
when one format's extension is already used as a sub-format of another.
Coktel `.adl` would use `coktel.zig`, and MacsOpera `.cmf` would use
`cmfmcsop.zig`. Faust, Adlib Tracker 1.0, and SNGPlay need separate `.sng`
decoders. Accolade MUS and AdLib MUS also remain separate. MusicV (`.wm`, `.m`)
uses `wm.zig`, while Ultima 6 (`.m`) is assigned `u6m.zig`. XAD Flash, Hybrid,
Hypnosis, PSI, and rat are assigned their own modules. Shared-extension detection is
magic or layout. `load` returns null for the other format. Registration
order is the try order.

LAA and Lucasfilm AD share `.laa`. LAA claims iMUSE `ADL ` resources and
Lucasfilm AD the older `AD` resources. The uniqueness check covers names, not
extensions, so a colliding pair can be registered without merging modules.

| Format | Ext | Chip | Viz | Module | sehnsucht | AdPlug |
|--------|-----|------|-----|--------|-----------|--------|
| ADLIB | `.adlib` | OPL2 | stream | `imf.zig` | yes | yes |
| ADL | `.adl` | OPL2 | sequence | `adl.zig` | yes | yes |
| Accolade MUS | `.mus` | OPL2 | sequence | `accolade.zig` | no | no |
| AdLib MUS | `.mus`, `.mdy` | OPL2 | sequence | `mus.zig` | no | yes |
| AdLib Tracker 2 | `.a2m`, `.a2t` | OPL2/3 | tracker | `a2m.zig` | yes | yes |
| Adlib Tracker 1.0 | `.sng` | OPL2 | tracker | `adtrack.zig` | no | yes |
| AMUSIC | `.amd` | OPL2 | tracker | `amd.zig` | no | yes |
| AudioT | `AUDIOT.*` / `AUDIO.*` / `AUDIOHED.*` | OPL2 | stream | `audiot.zig` | yes | no |
| BAM | `.bam` | OPL2 | sequence | `bam.zig` | yes | yes |
| Beni Tracker | `.pis` | OPL2 | tracker | `pis.zig` | no | yes |
| BoomTracker | `.cff` | OPL2 | tracker | `cff.zig` | no | yes |
| CDFM | `.670` | OPL2 | tracker | `cdfm.zig` | no | no |
| CMF | `.cmf` | OPL2 | sequence | `cmf.zig` | yes | yes |
| Coktel | `.adl` | OPL2 | stream | `coktel.zig` | no | yes |
| DeFy | `.dtm` | OPL2 | tracker | `dtm.zig` | no | yes |
| Digital-FM | `.dfm` | OPL2 | tracker | `dfm.zig` | no | yes |
| DRO | `.dro` | OPL2/3 | stream | `dro.zig` | yes | yes |
| Drum Traker | `.dtl` | OPL2 | tracker | `dtl.zig` | no | no |
| Easy AdLib | `.bmf` | OPL2 | tracker | `bmf.zig` | no | yes |
| EdLib | `.d00` | OPL2 | tracker | `d00.zig` | no | yes |
| EdLib + samples | `.d01` | OPL2 | tracker | `d01.zig` | no | no |
| EdLib work | `.edl` | OPL2 | tracker | `edl.zig` | no | no |
| Faust | `.sng` | OPL2 | tracker | `fmc.zig` | no | yes |
| FM Tracker | `.fmt` | OPL2 | tracker | `fmt.zig` | no | no |
| FM-Kingtracker | `.fmk` | OPL2 | tracker | `fmk.zig` | no | yes |
| God of Thunder | `.got` | OPL2 | stream | `got.zig` | yes | yes |
| HERAD | `.agd`, `.sdb`, `.ha2` | OPL2/3 | sequence | `herad.zig` | no | yes |
| HSC | `.hsc` | OPL2 | tracker | `hsc.zig` | yes | yes |
| HSC Packed | `.hsp` | OPL2 | tracker | `hsc.zig` | yes | yes |
| HSQ | `.hsq` | OPL2/3 | sequence | `herad.zig` | no | yes |
| IMF | `.imf` | OPL2 | stream | `imf.zig` | yes | yes |
| IMPlay | `.ims` | OPL2 | sequence | `mus.zig` | no | yes |
| JBM | `.jbm` | OPL2 | sequence | `jbm.zig` | yes | yes |
| Ken Silverman | `.ksm` | OPL2 | sequence | `ksm.zig` | yes | yes |
| KLM | `.klm` | OPL2 | stream | `klm.zig` | no | no |
| LDS | `.lds` | OPL2 | tracker | `lds.zig` | yes | yes |
| LD0 | `.ld0` | OPL2 | tracker | `lds.zig` | yes | yes |
| Lemmings | `.lem` | OPL2 | stream | `lem.zig` | no | no |
| LucasArts | `.laa` | OPL2 | sequence | `laa.zig` | yes | yes |
| Lucasfilm AD | `.laa` | OPL2 | sequence | `lucasfilm.zig` | yes | yes |
| MacsOpera | `.cmf` | OPL2 | tracker | `cmfmcsop.zig` | no | yes |
| Master Tracker | `.mtr` | OPL2 | tracker | `mtr.zig` | no | yes |
| MIDI | `.mid` | OPL2 | sequence | `mid.zig` | no | yes |
| MIDIPlay | `.mdi` | OPL2 | sequence | `mdi.zig` | no | yes |
| Miles XMI | `.xmi` | OPL2/3 | sequence | `xmi.zig` | yes | yes |
| MKJamz | `.mkj` | OPL2 | tracker | `mkj.zig` | no | yes |
| Mlat | `.mad` | OPL2 | tracker | `mad.zig` | no | yes |
| MSC | `.msc` | OPL2 | sequence | `msc.zig` | no | yes |
| MPU-401 Trakker | `.mtk` | OPL2 | tracker | `mtk.zig` | no | yes |
| MusicV | `.wm`, `.m` | OPL3 | sequence | `wm.zig` | yes | yes |
| Note Sequencer | `.sop` | OPL3 | sequence | `sop.zig` | no | yes |
| Palladix | `.plx` | OPL2 | stream | `plx.zig` | no | yes |
| Pixel Painters FMF | `.fmf` | OPL2 | stream | `fmf.zig` | no | no |
| Pixel Painters FTF | `.ftf` | OPL2 | tracker | `ftf.zig` | no | no |
| RAC | `.rac` | OPL2 / dual OPL2 | stream | `raw.zig` | yes | yes |
| RAD | `.rad` | OPL2/3 | tracker | `rad.zig` | yes | yes |
| RAW | `.raw` | OPL2 / dual OPL2 | stream | `raw.zig` | yes | yes |
| RIX | `.rix`, `.mkf` | OPL2 | stream | `rix.zig` | no | yes |
| SCI0 | `.sci`, `.snd` | OPL2 + PCM | sequence | `sci.zig` | yes | yes |
| Scream Tracker 3 | `.s3m`, `.as3m` | OPL2 | tracker | `s3m.zig` | no | yes |
| Shadowlands | `.cal` | OPL2 | stream | `cal.zig` | no | no |
| SNGPlay | `.sng` | OPL2 | stream | `sng.zig` | yes | yes |
| Sound Images Gen. 2 | `.sig` | OPL2 | stream | `sig.zig` | no | no |
| SQX | `.sqx` | OPL2/3 | sequence | `herad.zig` | no | yes |
| Surprise! Adlib Tracker | `.sat`, `.sa2` | OPL2 | tracker | `sa2.zig` | no | yes |
| TBSA | `.bsa` | OPL2 | tracker | `bsa.zig` | no | no |
| Twin TrackPlayer | `.dmo` | OPL2 | tracker | `dmo.zig` | no | yes |
| Ultima 6 | `.m` | OPL2 | stream | `u6m.zig` | no | yes |
| VGM / VGZ | `.vgm`, `.vgz` | OPL2/3 | stream | `vgm.zig` | yes | yes |
| Vibrants | `.vib` | OPL2 | stream | `vib.zig` | no | no |
| Visual Composer | `.rol` | OPL2 | sequence | `rol.zig` | yes | yes |
| WLF | `.wlf` | OPL2 | stream | `imf.zig` | yes | yes |
| XAD BMF | `.xad` | OPL2 | tracker | `bmf.zig` | no | yes |
| XAD Flash | `.xad` | OPL2 | tracker | `flash.zig` | no | yes |
| XAD Hybrid | `.xad` | OPL2 | tracker | `hybrid.zig` | no | yes |
| XAD Hypnosis | `.xad` | OPL2 | stream | `hyp.zig` | no | yes |
| XAD PSI | `.xad` | OPL2 | stream | `psi.zig` | no | yes |
| XAD rat | `.xad` | OPL2 | tracker | `rat.zig` | no | yes |
| XMS-Tracker | `.xms` | OPL2 | tracker | `amd.zig` | no | yes |
| XSM | `.xsm` | OPL2 | tracker | `xsm.zig` | yes | yes |

## AdLib Tracker II files without a song

AdLib Tracker II 2.4.25 loads 13 song formats, one pattern format, and 12
instrument or bank formats. Every song format appears in the table above.
The rest hold no song. The pattern fits the tracker. No visualizer shows
instrument or bank files yet.

| Format | Ext | Content | Module |
|--------|-----|---------|--------|
| AT2 pattern | `.a2p` | one pattern, a name from version 10, no instruments | `a2m.zig` |
| AT2 instrument | `.a2i` | one instrument and name, a four-operator half from version 10 | `a2m.zig` |
| AT2 macro instrument | `.a2f` | instrument, name, and FM-register macro | `a2m.zig` |
| AT2 bank | `.a2b` | 250 or 255 named instruments | `a2m.zig` |
| AT2 macro bank | `.a2w` | instruments with FM, arpeggio, and vibrato macros | `a2m.zig` |
| AdLib bank | `.bnk` | named instruments, the ROL companion | `rol.zig` |
| BoomTracker instrument | `.cif` | one instrument and name | `cff.zig` |
| FM-Kingtracker instrument | `.fin` | one instrument with waveforms 0-7 | `fmk.zig` |
| FM-Kingtracker bank | `.fib` | FIN records | `fmk.zig` |
| Creative Labs instrument | `.sbi` | one named instrument | `sbi.zig` |
| Creative Labs bank | `.ibk` | 128 SBI instruments and names | `sbi.zig` |
| Raw instrument | `.ins` | FM bytes in HSC, SAdT, or AdLib order | `ins.zig` |
| Sound Generator instrument | `.sgi` | 26 parameter bytes | `sgi.zig` |

AdLib Tracker 1.0 also uses `.ins`, as the companion of its `.sng` songs.
Detection by size and layout keeps the two apart.

## The RetroMusic collection

The RetroMusic test collection held 5314 files, 4816 of them unique, when it
was surveyed on 2026-10-25. Every music extension in it appears in the
table above except `.snm`, a SnevenTracker module that is not an OPL format.
It also holds companion files: Sierra `patch.003` banks for SCI, the KSM
`insts.dat` bank, EdLib `.s01` samples for `.d01`, and the Keen 4 `AUDIODCT`
Huffman dictionary.
