//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const format = @import("format.zig");
const theme = @import("theme.zig");
const view = @import("view.zig");
const visualizer = @import("visualizer.zig");

/// Registration order is detection order when formats share a path rule.
/// The modules are listed once and `formats` is built from them, so the
/// checks below cannot fall out of step with what is registered.
const format_modules = .{
    @import("formats/a2m.zig"),
    @import("formats/dro.zig"),
    @import("formats/vgm.zig"),
    @import("formats/raw.zig"),
    @import("formats/bam.zig"),
    @import("formats/rol.zig"),
    @import("formats/sci.zig"),
    @import("formats/xmi.zig"),
    @import("formats/jbm.zig"),
    @import("formats/wm.zig"),
    @import("formats/ksm.zig"),
    @import("formats/laa.zig"),
    @import("formats/lucasfilm.zig"),
    @import("formats/xsm.zig"),
    @import("formats/got.zig"),
    @import("formats/sng.zig"),
    @import("formats/cmf.zig"),
    @import("formats/rad.zig"),
    @import("formats/lds.zig"),
    @import("formats/hsc.zig"),
    @import("formats/imf.zig"),
    @import("formats/adl.zig"),
    @import("formats/audiot.zig"),
};

pub const formats = blk: {
    var list: [format_modules.len]format.Format = undefined;
    for (format_modules, 0..) |mod, i| list[i] = mod.format;
    break :blk list;
};

pub const visualizers = [_]visualizer.Visualizer{
    @import("visualizers/tracker.zig").visualizer,
    @import("visualizers/sequence.zig").visualizer,
    @import("visualizers/stream.zig").visualizer,
};

fn findViz(name: []const u8) ?*const visualizer.Visualizer {
    for (&visualizers) |*v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    return null;
}

comptime {
    for (formats) |f| {
        const v = findViz(f.visualizer) orelse {
            @compileError("unknown visualizer: " ++ f.name);
        };
        if (!view.ViewCaps.subsetOf(v.requires, f.view_caps)) {
            @compileError("view_caps does not satisfy visualizer.requires: " ++ f.name);
        }
    }
}

pub const themes = [_]theme.Theme{
    @import("themes/cyberpunk.zig").theme,
    @import("themes/high_contrast.zig").theme,
    @import("themes/lcd_ink.zig").theme,
    @import("themes/midnight_azure.zig").theme,
    @import("themes/neo_tokyo.zig").theme,
    @import("themes/tron_ares.zig").theme,
};

fn hasVisualizer(name: []const u8) bool {
    for (visualizers) |v| {
        if (std.mem.eql(u8, v.name, name)) return true;
    }
    return false;
}

fn validPluginId(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_') continue;
        return false;
    }
    return true;
}

fn validStops(stops: *const [3]theme.VuStop) bool {
    if (stops[0].pos != 0 or stops[2].pos != 1) return false;
    return stops[0].pos <= stops[1].pos and stops[1].pos <= stops[2].pos;
}

fn vaxisColor(rgb: [3]u8) vaxis.Color {
    return .{ .rgb = rgb };
}

// --- tests -------------------------------------------------------------------

test "format registry has unique names" {
    for (formats, 0..) |f, i| {
        try std.testing.expect(f.name.len != 0);
        try std.testing.expect(hasVisualizer(f.visualizer));
        for (f.extensions) |ext| {
            try std.testing.expect(ext.len > 1 and ext[0] == '.');
        }
        for (formats[0..i]) |prior| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(f.name, prior.name));
        }
    }
}

test "AudioT stem names with another format's extension resolve no companions" {
    const gpa = std.testing.allocator;
    for (formats) |f| {
        for (f.extensions) |ext| {
            for ([_][]const u8{ "AUDIO", "AUDIOT", "AUDIOHED" }) |stem| {
                const path = try std.mem.concat(gpa, u8, &.{ stem, ext });
                defer gpa.free(path);
                const paths = try format.resolveCompanions(gpa, path);
                defer paths.deinit(gpa);
                try std.testing.expect(paths.sibling == null and paths.sibling2 == null);
            }
        }
    }
}

test "visualizer registry has unique names" {
    for (visualizers, 0..) |v, i| {
        try std.testing.expect(validPluginId(v.name));
        for (visualizers[0..i]) |prior| {
            try std.testing.expect(!std.mem.eql(u8, v.name, prior.name));
        }
    }
}

test "theme registry has valid alphabetically ordered themes" {
    try std.testing.expect(themes.len != 0);
    for (themes, 0..) |t, i| {
        try std.testing.expect(t.display_name.len != 0);
        try std.testing.expect(t.description.len != 0);
        try std.testing.expect(validStops(t.vu_stops));
        try std.testing.expect(validStops(t.peak_stops));
        for (themes[0..i]) |prior| {
            try std.testing.expect(std.ascii.orderIgnoreCase(prior.display_name, t.display_name) == .lt);
        }
    }
}

test "registered themes supply complete visualizer styles" {
    for (themes) |t| {
        const pat_bar = t.style(.pat_bar);
        try std.testing.expect(std.meta.eql(t.colors.pat_bar_fg, pat_bar.fg));
        try std.testing.expect(std.meta.eql(t.colors.pat_bar_bg, pat_bar.bg));

        const cursor = t.style(.pat_cursor_fill);
        try std.testing.expect(std.meta.eql(t.colors.pat_cur_fg, cursor.fg));
        try std.testing.expect(std.meta.eql(t.colors.pat_cur_bg, cursor.bg));

        const info_meter = t.infoMeter(0, false);
        try std.testing.expect(std.meta.eql(t.colors.meter_off_fg, info_meter.fg));
        try std.testing.expect(std.meta.eql(t.colors.info_bar_bg, info_meter.bg));

        const meter = t.meterBar(0, false);
        try std.testing.expect(std.meta.eql(vaxisColor(t.vu_stops[0].rgb), meter.fg));
        try std.testing.expect(std.meta.eql(t.colors.bg, meter.bg));
    }
}
