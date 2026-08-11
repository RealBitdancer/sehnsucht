# Format documentation

These documents describe the binary layouts and playback rules implemented by
sehnsucht. Each document is intended to be sufficient for an independent,
compatible parser.

See [Adding a format](../adding-a-format.md) for the decoder interface,
ownership rules, registration steps, and test checklist. Start a decoder by
copying `src/formats/template.zig`.

Copy [template.md](template.md) when documenting a new format. Keep its primary
sections in order. Add format-specific subsections where the binary layout or
decoder state requires them.

| Format | Extensions / paths | Doc |
|--------|--------------------|-----|
| HSC | `.hsc` | [hsc.md](hsc.md) |
| RAD | `.rad` | [rad.md](rad.md) |
| VGM / VGZ | `.vgm`, `.vgz` | [vgm.md](vgm.md) |
| DRO | `.dro` | [dro.md](dro.md) |
| RAW | `.raw` | [raw.md](raw.md) |
| CMF | `.cmf` | [cmf.md](cmf.md) |
| IMF / WLF | `.imf`, `.wlf`, `.adlib` | [imf.md](imf.md) |
| AudioT | `AUDIOT.*` / `AUDIO.*` / `AUDIOHED.*` | [audiot.md](audiot.md) |

Filename matching ignores ASCII case. DRO, VGM, RAW, CMF, and RAD validate file
magic. AudioT matches a basename family. HSC and plain IMF have no reliable
magic and depend on their registered paths.

Decoder modules live under `src/formats/`. Registration order is in
`src/registry.zig`.
