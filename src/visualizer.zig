//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Bridge = @import("bridge.zig").Bridge;
const pcm_band_count = @import("bridge.zig").pcm_band_count;
const format = @import("format.zig");
const view = @import("view.zig");
const Theme = @import("theme.zig").Theme;

pub const header_frame_h: u16 = 4;

pub const status_frame_h: u16 = 4;

pub const spark_retention: usize = 512;

pub const TrackerFocus = enum { pattern, instrument, order, macros, live, spectrum, riffs };

pub const KeyResult = enum { ignored, handled };

pub const Navigation = struct {
    channel_page: u16 = 0,
    instrument_sel: u16 = 0,
    instrument_sel_user: bool = false,
    order_scroll: ?u16 = null,
    macro_scroll: u16 = 0,
    pattern_scroll: ?u16 = null,
    riff_scroll: u16 = 0,
    live_scroll: u16 = 0,
    sequence_scroll: ?u32 = null,
    sequence_pcs: [view.max_pattern_channels]u32 = @splat(view.sequence_pc_none),
    tracker_focus: TrackerFocus = .pattern,
};

pub const DrawContext = struct {
    win: vaxis.Window,
    theme: Theme,
    bridge: *Bridge,
    track: format.TrackInfo,
    views: view.SourceViews = .{},
    tick_rate_hz: ?u32 = null,
    rate_adjustable: bool = false,
    spec_levels: *const [view.max_opl_voices]f32,
    spec_peaks: *const [view.max_opl_voices]f32,
    spec_peak_glow: *const [view.max_opl_voices]f32,
    voice_count: u8 = 9,
    nav: *Navigation,
    pcm_bands: *const [pcm_band_count]f32,
    pcm_band_peaks: *const [pcm_band_count]f32,
    pcm_band_peak_glow: *const [pcm_band_count]f32,
    pcm_peak: f32,
    vu_l: f32 = 0,
    vu_r: f32 = 0,
    vu_peak_l: f32 = 0,
    vu_peak_r: f32 = 0,
    spark: *const [spark_retention]f32,
    spark_head: usize = 0,
    spark_len: usize = 0,
    arena: std.mem.Allocator,
};

pub const Visualizer = struct {
    name: []const u8,
    draw: *const fn (ctx: *DrawContext) void,
    handleKey: ?*const fn (ctx: *DrawContext, key: u21) KeyResult = null,
    requires: view.ViewCaps,
    optional: view.ViewCaps,

    pub fn init(comptime T: type) Visualizer {
        comptime {
            if (!@hasDecl(T, "name")) @compileError(@typeName(T) ++ " must provide name");
            if (!@hasDecl(T, "draw")) @compileError(@typeName(T) ++ " must provide draw");
            if (!@hasDecl(T, "requires")) @compileError(@typeName(T) ++ " must provide requires");
            if (!@hasDecl(T, "optional")) @compileError(@typeName(T) ++ " must provide optional");
        }
        return .{
            .name = T.name,
            .draw = T.draw,
            .handleKey = if (@hasDecl(T, "handleKey")) T.handleKey else null,
            .requires = T.requires,
            .optional = T.optional,
        };
    }
};

pub const visualizers = @import("registry.zig").visualizers;

pub fn find(name: []const u8) ?*const Visualizer {
    for (&visualizers) |*v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    return null;
}
