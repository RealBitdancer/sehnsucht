//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const format = @import("format.zig");

pub const pcm_band_count: usize = 48;

pub const pcm_band_f_lo: f32 = 60.0;
pub const pcm_band_f_hi_factor: f32 = 0.45;

pub fn pcmBandFreq(sample_rate: u32, band: usize) f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const log_lo = @log(pcm_band_f_lo);
    const log_hi = @log(sr * pcm_band_f_hi_factor);
    const t = @as(f32, @floatFromInt(band)) / @as(f32, @floatFromInt(@max(1, pcm_band_count - 1)));
    return @exp(log_lo + (log_hi - log_lo) * t);
}

pub const Bridge = struct {
    paused: std.atomic.Value(bool) = .init(false),
    quit: std.atomic.Value(bool) = .init(false),
    halt_at_songend: std.atomic.Value(bool) = .init(false),
    volume: std.atomic.Value(u8) = .init(100),
    muted: std.atomic.Value(bool) = .init(false),
    position_frames: std.atomic.Value(u64) = .init(0),
    loop_count: std.atomic.Value(u32) = .init(0),
    tracker_pos: std.atomic.Value(u64) = .init(0),
    levels: [9]std.atomic.Value(u8) = @splat(.init(0)),
    pcm_peak: std.atomic.Value(u8) = .init(0),
    pcm_rms_l: std.atomic.Value(u8) = .init(0),
    pcm_rms_r: std.atomic.Value(u8) = .init(0),
    pcm_peak_l: std.atomic.Value(u8) = .init(0),
    pcm_peak_r: std.atomic.Value(u8) = .init(0),
    pcm_bands: [pcm_band_count]std.atomic.Value(u8) = @splat(.init(0)),
    sample_rate: u32 = 44100,

    pub fn resetTrackState(self: *Bridge) void {
        self.position_frames.store(0, .release);
        self.loop_count.store(0, .release);
        self.tracker_pos.store(0, .release);
        self.pcm_peak.store(0, .release);
        self.pcm_rms_l.store(0, .release);
        self.pcm_rms_r.store(0, .release);
        self.pcm_peak_l.store(0, .release);
        self.pcm_peak_r.store(0, .release);
        for (&self.levels) |*l| l.store(0, .release);
        for (&self.pcm_bands) |*b| b.store(0, .release);
    }

    pub fn readTrackerPos(self: *const Bridge) format.TrackerPos {
        return @bitCast(self.tracker_pos.load(.acquire));
    }

    pub fn publishTrackerPos(self: *Bridge, p: format.TrackerPos) void {
        self.tracker_pos.store(@bitCast(p), .release);
    }
};

// --- tests -------------------------------------------------------------------

test "pcmBandFreq spans the log range endpoints" {
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), pcmBandFreq(44100, 0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 44100.0 * 0.45), pcmBandFreq(44100, pcm_band_count - 1), 1.0);
    const mid_lo = pcmBandFreq(44100, 10);
    const mid_hi = pcmBandFreq(44100, 11);
    try std.testing.expect(mid_hi > mid_lo);
}

test "resetTrackState clears playback state but not session flags" {
    var br = Bridge{};
    br.paused.store(true, .release);
    br.volume.store(40, .release);
    br.muted.store(true, .release);
    br.position_frames.store(123, .release);
    br.loop_count.store(2, .release);
    br.levels[3].store(9, .release);
    br.pcm_bands[0].store(7, .release);
    br.publishTrackerPos(.{ .row = 5 });
    br.resetTrackState();
    try std.testing.expect(br.paused.load(.acquire));
    try std.testing.expectEqual(@as(u8, 40), br.volume.load(.acquire));
    try std.testing.expect(br.muted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), br.loop_count.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), br.levels[3].load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), br.pcm_bands[0].load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), br.readTrackerPos().row);
}

test "TrackerPos round-trips through the packed u64" {
    var br = Bridge{};
    br.publishTrackerPos(.{
        .order_pos = 3,
        .row = 42,
        .pattern = 17,
        .speed = 6,
        .last_instrument = 99,
    });
    const p = br.readTrackerPos();
    try std.testing.expectEqual(@as(u8, 3), p.order_pos);
    try std.testing.expectEqual(@as(u8, 42), p.row);
    try std.testing.expectEqual(@as(u8, 17), p.pattern);
    try std.testing.expectEqual(@as(u8, 6), p.speed);
    try std.testing.expectEqual(@as(u8, 99), p.last_instrument);
}
