# Plugin architecture

Formats, visualizers, and themes use the same compile-time plugin model. Each
plugin kind has five parts:

1. A small interface in one root module.
2. One implementation per file in a named subdirectory.
3. An explicit list in `src/registry.zig`.
4. A compiling template. Templates are not registered and do not ship in the
   executable.
5. Registry validation for names and cross-plugin references.

There is no runtime code loading or filesystem discovery. A contributor can see
every enabled plugin in one registry, and a missing interface field fails at
compile time.

| Plugin | Interface | Implementations | Template |
|--------|-----------|-----------------|----------|
| Format | `src/format.zig` | `src/formats/` | `src/formats/template.zig` |
| Visualizer | `src/visualizer.zig` | `src/visualizers/` | `src/visualizers/template.zig` |
| Theme | `src/theme.zig` | `src/themes/` | `src/themes/template.zig` |

The format-specific loading, ownership, and timing contract is in
[Adding a format](adding-a-format.md).

## Adding a visualizer

Copy `src/visualizers/template.zig` to
`src/visualizers/<name>.zig`. A visualizer module exports:

```zig
pub const name = "example";
pub const requires = view.ViewCaps{};
pub const optional = view.ViewCaps{};

pub fn draw(ctx: *viz.DrawContext) void {
    if (ctx.win.width == 0 or ctx.win.height == 0) return;
    paint.printAt(ctx.win, 0, 0, "Example visualizer", ctx.theme.style(.viz_notice));
}

pub const visualizer = viz.Visualizer.init(@This());
```

`Visualizer.init` verifies that the module provides `name`, `draw`, `requires`,
and `optional`. Optional `handleKey` is discovered the same way. The name is a
stable lowercase identifier containing letters, digits, hyphens, or
underscores. Registry checks that each format's `view_caps` satisfies the
named visualizer's `requires`.

`DrawContext.win` is already the interior of the visualizer frame. Do not draw
outside its width or height. The context and all referenced playback data are
borrowed for one draw call. Use `ctx.arena` for temporary frame data. Do not
retain pointers from the context. State that must outlast the frame, such as
a scroll offset, goes in a defaulted field of `viz.Navigation`, which the
shell resets for each song. Measure source text with `paint.textWidth`, not
`Window.gwidth`.

Every visualizer style comes from `ctx.theme`, as `ctx.theme.style(.role)` for
fixed roles. Do not encode RGB, indexed, or default colors in a visualizer, and
do not assemble foreground/background style pairs there. When existing roles do
not cover a new visual element, add a `Theme.Role` tag and its line in
`Theme.style`, then define its colors in every standalone theme.

Add the exported `visualizer` to `registry.visualizers`.
A format can use the visualizer after its
module `visualizer_name` names it. `Format.init` and `MusicSource.init` copy
that one name onto the registered format and the live `TrackInfo`.

The smallest supported window, missing optional track data, and the
minimum dimensions at which the visualizer draws content must remain usable.
Tracker completeness:
every contained and played field the source exposes stays reachable. Size
changes the viewport. Size does not hide a provided region. Below height 20,
or when a taller pane cannot fit its columns beside the full spectrum, those
regions collapse to one-line strips. Sequence completeness is the
channel grid, SPECTRUM, a live MIDI/voice mixer, and CTRL or FLOW when that
format has a conductor or song-level stream. It is not the tracker region set
(order, macros, riffs, backtick focus, operator gauges).

## Adding a theme

Copy `src/themes/template.zig` to `src/themes/<name>.zig`. The template inherits
Midnight Azure and changes only selected roles:

```zig
pub const theme = Theme.derive(base.theme, "Example", "Short description.", .{
    .colors = &.{
        Theme.color(.brand_fg, .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }),
    },
    .typography = &.{
        Theme.text(.emphasis, .{ .italic = true }),
    },
});
```

Color and typography field names are `Colors` / `Typography` field enums, so
a typo fails at compile time. Typography
overrides merge individual attributes, so the example adds italic while
retaining the base theme's bold emphasis. Omitted colors, typography roles,
attributes, and gradients remain inherited. Set `vu_stops` or `peak_stops` in
the override when replacing a whole gradient.

Copy `src/themes/midnight_azure.zig` when creating an independent theme. It
supplies the six declarations required by `Theme.init`: `display_name`,
`description`, `colors`, `typography`, `vu_stops`, and `peak_stops`. Export
the result as `pub const theme = Theme.init(@This());`.

`Theme.init` verifies that all six declarations exist and have the required
types. `Colors` intentionally requires every role. A newly added UI color role
therefore makes every theme update explicitly instead of silently borrowing an
unrelated fallback. Derived themes receive that role from their base.

`Typography` controls normal text, decoration, emphasis, selections, menu
hotkeys, and meters. Each role supports bold, dim, italic, blink, reverse,
invisible, strikethrough, six underline styles, and a separate underline
color. Drawing code obtains complete styles from `Theme`, so text attributes
are not hardcoded in UI or visualizer modules.

Gradient positions must be ordered. The first stop is `0.0` and the final stop
is `1.0`. Display names are user-facing and must be unique without regard to
ASCII case. Descriptions must be non-empty and briefly identify the theme's
appearance.

Add the exported `theme` to `registry.themes` in alphabetical order by display name.
Registered themes appear in that order in the Theme browser. Midnight Azure is
selected explicitly as the default in `theme.zig`, independent of its position.
Shipped themes are Cyberpunk, High Contrast, LCD Ink, Midnight Azure (default),
Neo Tokyo, and Tron Ares.

## Registry checks

`src/registry.zig` verifies:

* Unique format names. Distinct formats may share an extension.
* Registered formats refer to known visualizers.
* Unique, valid visualizer identifiers.
* At least one theme.
* Unique theme display names in alphabetical order and non-empty descriptions.
* Ordered VU and peak gradients with complete endpoints.

Run the full checks after adding any plugin. The registry checks above run as
tests, so include `zig build test`:

```text
zig fmt --check .
zig build
zig build test
```

## Inspection and playback extensions

The shell owns the centered `I` inspector popup in `src/inspector.zig`.
All three visualizers use it. It pages metadata, instruments,
macros, pattern cells, channels, events, orders, branch targets, and chip state
using the existing theme roles.
The normal pane remains the playback view. Wide fields can be panned, and
32-bit event indices keep long streams accessible.

Format plugins can request named resources after content detection, render
PCM alongside OPL, publish polyphonic voices and independent pattern cursors,
and accept explicit branch requests. These are optional source methods and
view fields. Their contracts are in
[Adding a format](adding-a-format.md#named-resources-and-pcm).

For sequences, `position_unit` defaults to `tick`. An indexed command source
such as BAM sets it to `event_index` when `Playhead.tick` is an event index.
A timed command source supplies `eventAt` in stable tick order. This lets the
shared visualizer follow either source without format-name checks.

Tracker and Stream use `DrawContext.voice_count` for physical OPL voices,
independently of pattern channel count. Sequence groups its meters and spectrum
by logical channel, using each active voice's hardware mapping or PCM level.
See [Visualizer architecture](visualizer-architecture.md) for the display and
threading contracts.
