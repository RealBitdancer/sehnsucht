//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Bridge = @import("bridge.zig").Bridge;
const pcm_band_count = @import("bridge.zig").pcm_band_count;
const format = @import("format.zig");
const Theme = @import("theme.zig").Theme;

pub const header_frame_h: u16 = 4;

pub const status_frame_h: u16 = 4;

pub const spark_retention: usize = 512;

pub const DrawContext = struct {
    win: vaxis.Window,
    theme: Theme,
    bridge: *Bridge,
    track: format.TrackInfo,
    view: ?format.TrackerView,
    tick_rate_hz: ?u32 = null,
    rate_adjustable: bool = false,
    spec_levels: *const [9]f32,
    spec_peaks: *const [9]f32,
    spec_peak_glow: *const [9]f32,
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

    pub fn init(comptime T: type) Visualizer {
        comptime {
            if (!@hasDecl(T, "name")) @compileError(@typeName(T) ++ " must provide name");
            if (!@hasDecl(T, "draw")) @compileError(@typeName(T) ++ " must provide draw");
        }
        return .{ .name = T.name, .draw = T.draw };
    }
};

pub const visualizers = @import("registry.zig").visualizers;

pub fn find(name: []const u8) ?*const Visualizer {
    for (&visualizers) |*v| {
        if (std.mem.eql(u8, v.name, name)) return v;
    }
    return null;
}
