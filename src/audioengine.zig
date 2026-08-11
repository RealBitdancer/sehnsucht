//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const zaudio = @import("zaudio");
const opal = @import("opal");

const Bridge = @import("bridge.zig").Bridge;
const pcm_band_count = @import("bridge.zig").pcm_band_count;
const pcmBandFreq = @import("bridge.zig").pcmBandFreq;
const format = @import("format.zig");
const chip_adapter = @import("chip.zig");

pub const default_rate: u32 = 44100;
pub const period_frames: u32 = 441;
const pcm_window_frames: usize = 512;
const meter_makeup: f32 = 2.0;

pub const AudioEngine = struct {
    device: *zaudio.Device,
    started: bool = false,
    chip: opal.Opal,
    source: ?format.MusicSource = null,
    bridge: *Bridge,
    wait: u64 = 0,
    sample_rate: u32 = default_rate,
    level_period: u32 = 441,
    level_countdown: u32 = 0,
    prev_keyed: [9]bool = @splat(false),
    strike_ttl: [9]u8 = @splat(0),

    pub fn create(gpa: std.mem.Allocator, bridge: *Bridge, requested_rate: u32) !*AudioEngine {
        const self = try gpa.create(AudioEngine);
        errdefer gpa.destroy(self);
        // Both are filled in below: the device needs `self` as its callback
        // context before it exists, and `reset` builds the chip at the rate the
        // device reports.
        self.* = .{ .bridge = bridge, .device = undefined, .chip = undefined };

        var config = zaudio.Device.Config.init(.playback);
        config.playback.format = .signed16;
        config.playback.channels = 2;
        config.sample_rate = requested_rate;
        config.data_callback = dataCallback;
        config.user_data = self;
        config.period_size_in_frames = period_frames;

        self.device = try zaudio.Device.create(null, config);
        const dev_rate = self.device.getSampleRate();
        self.sample_rate = if (dev_rate != 0) dev_rate else requested_rate;
        self.level_period = @max(1, self.sample_rate / 100);
        bridge.sample_rate = self.sample_rate;
        self.reset();
        return self;
    }

    fn reset(self: *AudioEngine) void {
        self.chip = opal.Opal.init(@intCast(self.sample_rate));
        self.source = null;
        self.wait = 0;
        self.level_countdown = 0;
        self.prev_keyed = @splat(false);
        self.strike_ttl = @splat(0);
    }

    pub fn load(
        self: *AudioEngine,
        gpa: std.mem.Allocator,
        path: []const u8,
        raw: []const u8,
        companions: format.Companions,
        tick_rate_hz: u32,
        track_index: u32,
    ) !format.MusicSource {
        self.reset();
        return (try format.load(gpa, path, raw, .{
            .sample_rate = self.sample_rate,
            .chip = chip_adapter.fromOpal(&self.chip),
            .tick_rate_hz = tick_rate_hz,
            .track_index = track_index,
            .sibling = companions.sibling,
            .sibling2 = companions.sibling2,
            .sibling_is_alt = companions.sibling_is_alt,
        })) orelse error.UnplayableFile;
    }

    pub fn destroy(self: *AudioEngine, gpa: std.mem.Allocator) void {
        self.stop();
        self.device.destroy();
        gpa.destroy(self);
    }

    pub fn start(self: *AudioEngine) !void {
        if (self.started) return;
        try self.device.start();
        self.started = true;
    }

    pub fn stop(self: *AudioEngine) void {
        if (self.started) {
            self.device.stop() catch {
                // A lost device fails to stop but its callback is already
                // silent, so tearing down chip and source stays safe. A
                // still-running callback would race that teardown.
                if (self.device.getState() == .started) {
                    @panic("audio device kept running after a failed stop");
                }
            };
            self.started = false;
        }
    }

    pub fn render(self: *AudioEngine, buf: []i16) void {
        const frame_count = buf.len / 2;
        const src = self.source orelse {
            @memset(buf, 0);
            return;
        };
        if (self.bridge.paused.load(.acquire)) {
            @memset(buf, 0);
            return;
        }
        const gain = gainQ8(
            self.bridge.volume.load(.acquire),
            self.bridge.muted.load(.acquire),
        );

        const chip = chip_adapter.fromOpal(&self.chip);
        var offset: usize = 0;
        var remaining: usize = frame_count;
        var zero_frame_steps: u32 = 0;
        while (remaining > 0) {
            if (self.wait == 0) {
                const r = src.step(chip);
                self.wait += r.frames;
                if (r.done) {
                    _ = self.bridge.loop_count.fetchAdd(1, .monotonic);
                    if (self.bridge.halt_at_songend.load(.acquire)) {
                        self.bridge.paused.store(true, .release);
                        @memset(buf[offset * 2 ..], 0);
                        return;
                    }
                }
                if (src.pos()) |p| self.bridge.publishTrackerPos(p);
                if (r.frames == 0) {
                    zero_frame_steps += 1;
                    if (zero_frame_steps > 1024) {
                        self.wait = @intCast(remaining);
                    }
                } else {
                    zero_frame_steps = 0;
                }
                continue;
            }
            const n: usize = @intCast(@min(self.wait, @as(u64, remaining)));
            const slice = buf[offset * 2 .. (offset + n) * 2];
            self.chip.render(slice);
            self.wait -= n;
            offset += n;
            remaining -= n;
            _ = self.bridge.position_frames.fetchAdd(n, .monotonic);
            if (self.level_countdown <= n) {
                self.publishLevels();
                self.publishPcmMeters(slice);
                self.level_countdown = self.level_period;
            } else {
                self.level_countdown -= @intCast(n);
            }
            applyGain(slice, gain);
        }
    }

    fn publishLevels(self: *AudioEngine) void {
        for (&self.bridge.levels, 0..) |*published, ch| {
            const car = &self.chip.op[opal.carrierSlot(ch)];
            var lvl = egLevelByte(car);
            var keyed = car.key != 0;
            const chan = &self.chip.chan[ch];
            if (chan.alg != 0 or chan.chan_type == .drum) {
                const mod = &self.chip.op[opal.modulatorSlot(ch)];
                lvl = @max(lvl, egLevelByte(mod));
                keyed = keyed or mod.key != 0;
            }
            if (keyed and !self.prev_keyed[ch]) self.strike_ttl[ch] = 4;
            self.prev_keyed[ch] = keyed;
            var out: u8 = 0;
            if (keyed) {
                if (self.strike_ttl[ch] > 0) {
                    self.strike_ttl[ch] -= 1;
                    out = lvl;
                } else {
                    out = @intCast((@as(u16, lvl) * 5) / 8);
                }
            } else {
                self.strike_ttl[ch] = 0;
            }
            published.store(out, .release);
        }
    }

    /// Pre-fader: reads chip output before `applyGain`, so volume and mute do not
    /// move the meters. `meter_makeup` holds the old full-volume scale.
    fn publishPcmMeters(self: *AudioEngine, interleaved: []const i16) void {
        const frames = interleaved.len / 2;
        if (frames == 0) return;

        const use_frames = @min(frames, pcm_window_frames);
        const first = frames - use_frames;

        var peak_li: u32 = 0;
        var peak_ri: u32 = 0;
        var sum_l: f32 = 0;
        var sum_r: f32 = 0;
        var mono: [pcm_window_frames]f32 = undefined;
        for (0..use_frames) |i| {
            const l: i32 = interleaved[(first + i) * 2];
            const r: i32 = interleaved[(first + i) * 2 + 1];
            peak_li = @max(peak_li, @abs(l));
            peak_ri = @max(peak_ri, @abs(r));
            const lf: f32 = @floatFromInt(l);
            const rf: f32 = @floatFromInt(r);
            sum_l += lf * lf;
            sum_r += rf * rf;
            mono[i] = (lf + rf) * (0.5 / 32768.0);
        }
        const peak_i = @max(peak_li, peak_ri);
        const peak_n = @min(1.0, meter_makeup * @as(f32, @floatFromInt(peak_i)) / 32768.0);
        self.bridge.pcm_peak.store(meter255(peak_n), .release);

        const inv_nf: f32 = 1.0 / @as(f32, @floatFromInt(use_frames));
        self.bridge.pcm_rms_l.store(meter255(meter_makeup * @sqrt(sum_l * inv_nf) / 32768.0), .release);
        self.bridge.pcm_rms_r.store(meter255(meter_makeup * @sqrt(sum_r * inv_nf) / 32768.0), .release);
        self.bridge.pcm_peak_l.store(meter255(meter_makeup * @as(f32, @floatFromInt(peak_li)) / 32768.0), .release);
        self.bridge.pcm_peak_r.store(meter255(meter_makeup * @as(f32, @floatFromInt(peak_ri)) / 32768.0), .release);

        const sr: f32 = @floatFromInt(self.sample_rate);
        var max_pow: f32 = 1e-12;
        var powers: [pcm_band_count]f32 = undefined;
        for (&powers, 0..) |*power, b| {
            const freq = pcmBandFreq(self.sample_rate, b);
            power.* = goertzelPower(mono[0..use_frames], freq / sr);
            max_pow = @max(max_pow, power.*);
        }
        const inv_max = 1.0 / @sqrt(max_pow);
        for (powers, &self.bridge.pcm_bands) |power, *published| {
            const shape = std.math.clamp(@sqrt(power) * inv_max, 0.0, 1.0);
            const nrm = std.math.clamp(shape * peak_n, 0.0, 1.0);
            const curved = std.math.pow(f32, nrm, 0.55);
            published.store(@intFromFloat(curved * 255.0), .release);
        }
    }
};

fn dataCallback(
    device: *zaudio.Device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    _ = input;
    const engine: *AudioEngine = @ptrCast(@alignCast(device.getUserData().?));
    const out: [*]i16 = @ptrCast(@alignCast(output orelse return));
    engine.render(out[0 .. @as(usize, frame_count) * 2]);
}

fn gainQ8(volume_percent: u8, muted: bool) u32 {
    if (muted) return 0;
    const p: u32 = @min(volume_percent, 100);
    return (p * p * 512) / 10000;
}

fn applyGain(slice: []i16, factor_q8: u32) void {
    if (factor_q8 == 256) return;
    if (factor_q8 == 0) {
        @memset(slice, 0);
        return;
    }
    const f: i32 = @intCast(factor_q8);
    for (slice) |*s| {
        const v = (@as(i32, s.*) * f) >> 8;
        s.* = @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
    }
}

fn meter255(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

fn goertzelPower(samples: []const f32, freq_norm: f32) f32 {
    const w = 2.0 * std.math.pi * std.math.clamp(freq_norm, 0.0001, 0.499);
    const coeff = 2.0 * @cos(w);
    var s0: f32 = 0;
    var s1: f32 = 0;
    var s2: f32 = 0;
    for (samples) |x| {
        s0 = x + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

fn egLevelByte(op: *const opal.Operator) u8 {
    if (op.key == 0) return 0;
    const atten: u32 = @min(op.eg_out, 512);
    return @intCast((512 - atten) * 255 / 512);
}

// --- tests -------------------------------------------------------------------

test "volume mapping is perceptual with 2x makeup at full" {
    try std.testing.expectEqual(@as(u32, 512), gainQ8(100, false));
    try std.testing.expectEqual(@as(u32, 258), gainQ8(71, false));
    try std.testing.expectEqual(@as(u32, 128), gainQ8(50, false));
    try std.testing.expect(gainQ8(5, false) > 0);
    try std.testing.expectEqual(@as(u32, 0), gainQ8(0, false));
    try std.testing.expectEqual(@as(u32, 0), gainQ8(100, true));
    try std.testing.expectEqual(@as(u32, 512), gainQ8(255, false));
}

test "pcm meters read the chip output, not the faded output" {
    var br = Bridge{};
    var engine = AudioEngine{ .bridge = &br, .device = undefined, .chip = undefined };

    var half = [_]i16{16384} ** 8;
    engine.publishPcmMeters(&half);
    try std.testing.expectEqual(@as(u8, 255), br.pcm_peak.load(.acquire));
    try std.testing.expectEqual(@as(u8, 255), br.pcm_peak_l.load(.acquire));

    var quarter = [_]i16{8192} ** 8;
    engine.publishPcmMeters(&quarter);
    try std.testing.expectEqual(@as(u8, 127), br.pcm_peak.load(.acquire));
}

test "applyGain scales, clamps, silences, and passes unity through" {
    var buf = [_]i16{ 1000, -1000, 20000, -20000 };
    applyGain(&buf, 128);
    try std.testing.expectEqualSlices(i16, &.{ 500, -500, 10000, -10000 }, &buf);
    applyGain(&buf, 256);
    try std.testing.expectEqualSlices(i16, &.{ 500, -500, 10000, -10000 }, &buf);
    applyGain(&buf, 512);
    try std.testing.expectEqualSlices(i16, &.{ 1000, -1000, 20000, -20000 }, &buf);

    var loud = [_]i16{ 32767, -32768, 20000 };
    applyGain(&loud, 512);
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32768, 32767 }, &loud);

    applyGain(&buf, 0);
    try std.testing.expectEqualSlices(i16, &.{ 0, 0, 0, 0 }, &buf);
}
