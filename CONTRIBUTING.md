# Contributing

Contributions are welcome. sehnsucht is an OPL2/OPL3 terminal player, not a
general chiptune suite, and that scope is deliberate. Within it, the project is
meant to grow through plugins and playback quality rather than through one-off
shell features.

## What fits

### Plugins (formats, visualizers, themes)

These are the normal way to extend sehnsucht. New formats, visualizers, and
themes are expected and encouraged.

They share one compile-time model: an interface module, one implementation
file, a row in `src/registry.zig`, and registry checks. Scaffolding lives in
the `template.zig` file of each plugin directory. Templates that declare
tests are listed in `src/tests.zig`.

| Kind | Start here |
|------|------------|
| Format | [doc/adding-a-format.md](doc/adding-a-format.md), [doc/formats/](doc/formats/), copy `src/formats/template.zig` |
| Visualizer | [doc/plugins.md](doc/plugins.md), copy `src/visualizers/template.zig` |
| Theme | [doc/plugins.md](doc/plugins.md), copy `src/themes/template.zig` |

A format should target OPL2/OPL3 music. Decoders can publish registers and
use the optional PCM renderer for digital samples, as SCI0 does. Other chip
families remain outside the current scope. Ship tests or verified sample
paths, and document a new format under `doc/formats/` the same way the
existing ones are documented.
List it in [doc/supported-formats.md](doc/supported-formats.md). A remote
playlist belongs in `playlists/` and in
[playlists/playlists.md](playlists/playlists.md).

The 1.0.0 goal is, at a minimum, the AdPlug OPL2/OPL3 set (AdPlug `yes`,
sehnsucht `no` in [doc/retromusic-formats.md](doc/retromusic-formats.md)).
1.0.0 also aims at lesser-known OPL formats used by older DOS games.

### Playback accuracy and robustness

Fixes that make a supported file sound right, or keep a hostile file from
hanging the audio callback or crashing the UI, are always high value. Bring
evidence when you can: a misbehaving file, OPL register traces against a
reference, or a citation of the format layout. Another player's different
behavior is a starting point, not proof by itself.

Malformed input should fail with a clear error, never by corrupting state.

### Everything else

Build fixes, CI fixes, documentation corrections, and focused shell
improvements are welcome. Other sound-chip families are outside the current
scope.

## Building and testing

The README covers building. Before opening a pull request:

1. `zig fmt --check .`
2. `zig build`
3. `zig build test`

GitHub Actions runs the same shape of checks on Linux, macOS, and Windows.
Add or update tests when you change playback, loading, or plugin contracts.
Include new modules in `src/tests.zig` so the test root analyzes them explicitly.
Tests should cover behavior, malformed input, and ownership. They should not
repeat constants or require a private music collection.

Default optimize mode is safe, including for tests, so safety checks
stay on for untrusted music files. Pass `-Doptimize=debug` only when you need
it. `-Dstrip=true` drops debug information and defaults to false so local
builds keep stack traces. Only release archives set strip.

For a release, keep the package version, dated changelog section, and supported
version policy in sync. A manual run of the release workflow builds all six
targets without publishing. Version-tag runs check the tag against the package
version and publish archives only after tests and every target build succeed.

## Style

Run `zig fmt` before submitting changes. CI checks the result. Prefer clear
names and types to comments. Reserve comments for constraints that the code
cannot express, and put design rationale in `doc/`.

Match the existing module layout and naming. New dependencies need a strong
reason and an update to [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

Every project Zig file starts with this header, including `build.zig`:

```zig
//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
```

The format and theme templates already carry it. Copy them rather than
inventing a shorter banner.

## Licensing

The project is MIT and your contributions are accepted under the same terms.
Do not add music files to the repository. sehnsucht never ships audio. Sample
playlists under `playlists/` are URL lists only. They point at music already
hosted elsewhere. Playback fetches those bytes into memory and does not write
them into the tree.
