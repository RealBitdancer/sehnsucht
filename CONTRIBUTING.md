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
the `template.zig` file of each plugin directory. Each template has a test
and is listed in `src/tests.zig` so it cannot rot unused.

| Kind | Start here |
|------|------------|
| Format | [doc/adding-a-format.md](doc/adding-a-format.md), [doc/formats/](doc/formats/), copy `src/formats/template.zig` |
| Visualizer | [doc/plugins.md](doc/plugins.md), copy `src/visualizers/template.zig` |
| Theme | [doc/plugins.md](doc/plugins.md), copy `src/themes/template.zig` |

A format should target OPL register streams (or archives of them). Non-OPL PCM
or other chips need a playback-interface change first, so open an issue before
investing in that. Ship tests or verified sample paths, and document a new
format under `doc/formats/` the same way the existing ones are documented.

### Playback accuracy and robustness

Fixes that make a supported file sound right, or keep a hostile file from
hanging the audio callback or crashing the UI, are always high value. Bring
evidence when you can: a misbehaving file, OPL register traces against a
reference, or a citation of the format layout. Another player's different
behavior is a starting point, not proof by itself.

Malformed input should fail with a clear error, never by corrupting state.

### Everything else

Build fixes, CI fixes, documentation corrections, and focused shell
improvements are welcome. Features that pull sehnsucht toward a general
multi-chip tracker suite will be declined kindly.

## Building and testing

The README covers building. Before opening a pull request:

1. `zig fmt --check .`
2. `zig build`
3. `zig build test`

GitHub Actions runs the same shape of checks on Linux, macOS, and Windows.
Add or update tests when you change playback, loading, or plugin contracts.
Registration alone does not put a module in the suite: list it in
`src/tests.zig` or its tests never run.

Default optimize mode is ReleaseSafe, including for tests, so safety checks
stay on for untrusted music files. Pass `-Doptimize=Debug` only when you need
it. `-Dstrip=true` drops debug information and defaults to false so local
builds keep stack traces. Only release archives set strip.

## Style

`zig fmt` enforces the formatting, so run it and the argument is over (CI
checks it). Comment only what the code cannot say itself. A comment that
narrates the line below it will be asked to leave.

Match the existing module layout and naming. New dependencies need a strong
reason and an update to [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Licensing

The project is MIT and your contributions are accepted under the same terms.
Do not add music files to the repository. Sample playlists under `playlists/`
point at freely available remote OPL files for a reason: the tree carries no
audio redistribution burden.
