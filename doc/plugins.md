# Plugin architecture

Formats, visualizers, and themes use the same compile-time plugin model. Each
plugin kind has five parts:

1. A small interface in one root module.
2. One implementation per file in a named subdirectory.
3. An explicit list in `src/registry.zig`.
4. A compiling template, listed in `src/tests.zig` because it has tests.
   Templates are not registered and do not ship in the executable. The test
   root keeps them compiling so scaffolding cannot rot.
5. Registry validation for names and cross-plugin references, at compile
   time where the values are known statically and in the test suite
   otherwise.

There is no runtime code loading or filesystem discovery. A contributor can see
every enabled plugin in one registry, and a missing interface field fails at
compile time.

| Plugin | Interface | Implementations | Template |
|--------|-----------|-----------------|----------|
| Format | `src/format.zig` | `src/formats/` | `src/formats/template.zig` |
| Visualizer | `src/visualizer.zig` | `src/visualizers/` | `src/visualizers/template.zig` |
| Theme | `src/theme.zig` | `src/themes/` | `src/themes/template.zig` |

The format-specific loading, ownership, timing, and testing contract is in
[Adding a format](adding-a-format.md).

## Adding a visualizer

Copy `src/visualizers/template.zig` to
`src/visualizers/<name>.zig`. A visualizer module exports:

```zig
pub const name = "example";

pub fn draw(ctx: *viz.DrawContext) void {
    // Draw inside ctx.win.
}

pub const visualizer = viz.Visualizer.init(@This());
```

`Visualizer.init` verifies that the module provides `name` and `draw`. The name
is a stable lowercase identifier containing letters, digits, hyphens, or
underscores.

`DrawContext.win` is already the interior of the visualizer frame. Do not draw
outside its width or height. The context and all referenced playback data are
borrowed for one draw call. Use `ctx.arena` for temporary frame data. Do not
retain pointers from the context.

Every visualizer style comes from `ctx.theme`, as `ctx.theme.style(.role)` for
fixed roles. Do not encode RGB, indexed, or default colors in a visualizer, and
do not assemble foreground/background style pairs there. When existing roles do
not cover a new visual element, add a `Theme.Role` tag and its line in
`Theme.style`, then define its colors in every standalone theme.

Add the exported `visualizer` to `registry.visualizers`. If the module
declares tests, list it in `src/tests.zig`. Registration alone does not put
its tests in the suite, and a module missing from that list stops being
tested without failing the build. A format can use the visualizer after its
registered `Format.visualizer` and returned `TrackInfo.visualizer` both name
it.

Test the smallest supported window, missing optional track data, and the
minimum dimensions at which the visualizer draws content.

## Adding a theme

Copy `src/themes/template.zig` to `src/themes/<name>.zig`. The template inherits
Midnight Azure and changes only selected roles:

```zig
pub const theme = Theme.derive(base.theme, "Example", "Short description.", .{
    .colors = &.{
        Theme.color("brand_fg", .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }),
    },
    .typography = &.{
        Theme.text("emphasis", .{ .italic = true }),
    },
});
```

Color and typography role names are checked at compile time. Typography
overrides merge individual attributes, so the example adds italic while
retaining the base theme's bold emphasis. Omitted colors, typography roles,
attributes, and gradients remain inherited. Set `vu_stops` or `peak_stops` in
the override when replacing a whole gradient.

Copy `src/themes/midnight_azure.zig` when creating an independent theme. A
standalone theme module exports:

```zig
pub const display_name = "Example";
pub const description = "Short description shown in the theme browser.";
pub const colors = Colors{ /* every color role */ };
pub const typography = Typography{
    .body = .{},
    .decoration = .{},
    .emphasis = .{ .bold = true },
    .selected = .{ .bold = true },
    .menu_hotkey = .{ .bold = true },
    .menu_hotkey_selected = .{ .bold = true, .underline = .single },
    .menu_hotkey_disabled = .{ .dim = true },
    .meter = .{},
    .meter_peak = .{ .bold = true },
};
pub const vu_stops = [3]VuStop{ /* 0.0 through 1.0 */ };
pub const peak_stops = [3]VuStop{ /* 0.0 through 1.0 */ };

pub const theme = Theme.init(@This());
```

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

Add the exported `theme` to `registry.themes`. If the module declares tests,
list it in `src/tests.zig`. The first registered theme is the default.
Registered themes appear in the Theme browser. Shipped themes are Midnight
Azure (default), LCD Ink, and High Contrast.

## Registry checks

`src/registry.zig` verifies:

* Unique format names and extensions.
* Registered formats refer to known visualizers.
* Unique, valid visualizer identifiers.
* At least one theme.
* Unique theme display names and non-empty descriptions.
* Ordered VU and peak gradients with complete endpoints.

Run the full checks after adding any plugin:

```text
zig fmt --check .
zig build test
zig build
```
