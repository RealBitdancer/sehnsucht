//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
// Every module is listed explicitly. `_ = @import("main.zig")` analyzes only
// main's own declarations, never its imports, so a module missing here does not
// fail the build, it just stops being tested.

comptime {
    _ = @import("audioengine.zig");
    _ = @import("bridge.zig");
    _ = @import("browse.zig");
    _ = @import("chip.zig");
    _ = @import("cli.zig");
    _ = @import("diag.zig");
    _ = @import("format.zig");
    _ = @import("loader.zig");
    _ = @import("loaderr.zig");
    _ = @import("main.zig");
    _ = @import("paint.zig");
    _ = @import("player.zig");
    _ = @import("playlist.zig");
    _ = @import("registry.zig");
    _ = @import("remote.zig");
    _ = @import("theme.zig");
    _ = @import("theme_browser.zig");
    _ = @import("ui.zig");
    _ = @import("visualizer.zig");

    _ = @import("formats/audiot.zig");
    _ = @import("formats/cmf.zig");
    _ = @import("formats/dro.zig");
    _ = @import("formats/hsc.zig");
    _ = @import("formats/imf.zig");
    _ = @import("formats/rad.zig");
    _ = @import("formats/raw.zig");
    _ = @import("formats/template.zig");
    _ = @import("formats/vgm.zig");

    _ = @import("themes/high_contrast.zig");
    _ = @import("themes/midnight_azure.zig");
    _ = @import("themes/template.zig");

    _ = @import("visualizers/common.zig");
    _ = @import("visualizers/stream.zig");
    _ = @import("visualizers/template.zig");
    _ = @import("visualizers/tracker.zig");
}
