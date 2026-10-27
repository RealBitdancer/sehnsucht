# Sample playlists

The lists contain URLs.
Remote tracks download into memory from
[Modland](https://modland.com/), the [OPL Archive](https://opl.wafflenet.com/),
the [Internet Archive](https://archive.org/),
[DiscMaster](https://discmaster.textfiles.com/), AdPlug's GitHub repository
and site, an ftp.mpoli.fi mirror, and an AIL archive on GitHub.
They need network access.

```sh
zig build run -- playlists/bitdance.m3u
```

| Path | What |
|------|------|
| `playlists/bitdance.m3u` | 23 tracks, one per format, each tagged with a fitting theme |
| `playlists/hsc.m3u` | 234 HSC modules (mostly Hannes Seifert) |
| `playlists/hsp.m3u` | 2 HSC Packed files |
| `playlists/rad.m3u` | 127 RAD modules |
| `playlists/a2m.m3u` | 277 AdLib Tracker II modules from Modland |
| `playlists/lds.m3u` | 185 tracks (184 Modland `.lds` plus AdPlug `GENORI.LD0`) |
| `playlists/vgm.m3u` | 1341 OPL-family VGZ dumps |
| `playlists/dro.m3u` | 2 DRO captures |
| `playlists/raw.m3u` | 316 RAW captures |
| `playlists/rac.m3u` | 34 original RAC / RdosPlay sample captures (DiscMaster Audio Toolkit CD) |
| `playlists/bam.m3u` | 29 BAM tracks |
| `playlists/xsm.m3u` | 4 XSM demos from FMLIB |
| `playlists/xmi.m3u` | Original AIL demo archive with three sequences and its remote `SAMPLE.AD` bank |
| `playlists/cmf.m3u` | 443 CMF songs |
| `playlists/imf.m3u` | 240 IMF and ADLIB tracks |
| `playlists/wlf.m3u` | 27 Wolfenstein 3D WLF rips (`jpb1991`) |
| `playlists/audiot.m3u` | 3 Muse archives (Wolf3D, Blake Stone shareware, Spear of Destiny demo) |
| `playlists/adl.m3u` | 43 Westwood ADL files (Dune II, Kyrandia 1, Eye of the Beholder I/II) |
| `playlists/got.m3u` | 7 GOT tracks (shareware episode 1 from GOTRES.DAT) |
| `playlists/sng.m3u` | 2 SNGPlay streams shipped with SNG Player v1.0 |
| `playlists/jbm.m3u` | 9 Johannes Bjerregaard tracks |
| `playlists/ksm.m3u` | 41 Ken Silverman songs (Ken's Labyrinth and others). Each folder's `insts.dat` loads beside the song |
| `playlists/laa.m3u` | 284 LucasArts AdLib songs (Indy 3 and 4, Monkey Island 1 and 2, Day of the Tentacle) |
| `playlists/wm.m3u` | 21 MusicV songs (root `.wm` files in AdPlug [MusicV.zip](https://adplug.github.io/library/files/MusicV.zip)). The player unpacks the zip when the host does not |

Keen AudioT on Archive.org is only the compressed `AUDIO.CK4` lump. The header
and Huffman dictionary stay inside the EXE, so that set is not playable
remotely.

How playlists work in the player is in the
[README](../README.md#playlists) and in
[Hotkeys and playlist modes](../doc/hotkeys-and-playlist-modes.md).

The XMI list points to the original AIL demo preserved in
[XMI2MID's reference archive](https://github.com/mattseabrook/XMI2MID/tree/main/Reference/AIL2).
Its three sequences are "Couple Days Off", "Row, Row, Row Your Boat", and
"An Die Freude". Use comma and period to select a sequence. The player fetches
`SAMPLE.AD` beside `DEMO.XMI`. The PC-speaker demo is not included.
