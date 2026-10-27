//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

comptime {
    _ = @import("audioengine.zig");
    _ = @import("bridge.zig");
    _ = @import("browse.zig");
    _ = @import("chip.zig");
    _ = @import("cli.zig");
    _ = @import("cp437.zig");
    _ = @import("format.zig");
    _ = @import("inflate.zig");
    _ = @import("inspector.zig");
    _ = @import("midi_opl.zig");
    _ = @import("loader.zig");
    _ = @import("paint.zig");
    _ = @import("pcm.zig");
    _ = @import("player.zig");
    _ = @import("playlist.zig");
    _ = @import("registry.zig");
    _ = @import("remote.zig");
    _ = @import("theme.zig");
    _ = @import("theme_browser.zig");
    _ = @import("ui.zig");
    _ = @import("view.zig");
    _ = @import("y8950.zig");

    _ = @import("formats/a2m.zig");
    _ = @import("formats/adl.zig");
    _ = @import("formats/audiot.zig");
    _ = @import("formats/bam.zig");
    _ = @import("formats/rol.zig");
    _ = @import("formats/sci.zig");
    _ = @import("formats/xmi.zig");
    _ = @import("formats/cmf.zig");
    _ = @import("formats/dro.zig");
    _ = @import("formats/hsc.zig");
    _ = @import("formats/imf.zig");
    _ = @import("formats/lds.zig");
    _ = @import("formats/rad.zig");
    _ = @import("formats/raw.zig");
    _ = @import("formats/template.zig").format;
    _ = @import("formats/vgm.zig");
    _ = @import("formats/xsm.zig");
    _ = @import("formats/got.zig");
    _ = @import("formats/sng.zig");
    _ = @import("formats/jbm.zig");
    _ = @import("formats/wm.zig");
    _ = @import("formats/ksm.zig");
    _ = @import("formats/laa.zig");
    _ = @import("formats/lucasfilm.zig");

    _ = @import("themes/template.zig");

    _ = @import("visualizers/common.zig");
    _ = @import("visualizers/sequence.zig");
    _ = @import("visualizers/stream.zig");
    _ = @import("visualizers/template.zig").visualizer;
    _ = @import("visualizers/tracker.zig");
}
