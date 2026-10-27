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
const view = @import("view.zig");
const chip_adapter = @import("chip.zig");

pub const default_rate: u32 = 44100;
pub const period_frames: u32 = 441;
const pcm_window_frames: usize = 512;
const meter_makeup: f32 = 2.0;
const max_skip_stall: u32 = 1 << 20;

pub const AudioEngine = struct {
    device: *zaudio.Device,
    started: bool = false,
    chip: opal.Opal,
    second_chip: ?opal.Opal = null,
    source: ?format.MusicSource = null,
    bridge: *Bridge,
    wait: u64 = 0,
    park_after_wait: bool = false,
    sample_rate: u32 = default_rate,
    level_period: u32 = 441,
    level_countdown: u32 = 0,
    prev_keyed: [view.max_opl_voices]bool = @splat(false),
    strike_ttl: [view.max_opl_voices]u8 = @splat(0),

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

    fn resetSynth(self: *AudioEngine) void {
        self.chip = opal.Opal.init(@intCast(self.sample_rate));
        self.second_chip = null;
        self.resetTiming();
    }

    fn resetTiming(self: *AudioEngine) void {
        self.wait = 0;
        self.park_after_wait = false;
        self.level_countdown = 0;
        self.prev_keyed = @splat(false);
        self.strike_ttl = @splat(0);
    }

    fn reset(self: *AudioEngine) void {
        self.resetSynth();
        self.source = null;
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
            .chip = .{ .ptr = self, .vtable = &logging_chip_vtable },
            .tick_rate_hz = tick_rate_hz,
            .track_index = track_index,
            .sibling = companions.sibling,
            .sibling2 = companions.sibling2,
            .sibling_is_alt = companions.sibling_is_alt,
            .resources = companions.resources,
        })) orelse error.UnplayableFile;
    }

    pub fn selectArchiveTrack(self: *AudioEngine, gpa: std.mem.Allocator, index: u32) !bool {
        const src = self.source orelse return false;
        if (src.vtable.selectArchiveTrack == null) return false;
        const previous_chip = self.chip;
        const previous_second = self.second_chip;
        self.chip = opal.Opal.init(@intCast(self.sample_rate));
        self.second_chip = null;
        errdefer self.chip = previous_chip;
        errdefer self.second_chip = previous_second;
        const chip = format.Chip{ .ptr = self, .vtable = &logging_chip_vtable };
        var live = src;
        if (!try live.selectArchiveTrack(gpa, index, chip)) {
            self.chip = previous_chip;
            self.second_chip = previous_second;
            return false;
        }
        chip.flush();
        self.resetTiming();
        live.duration_override = null;
        self.source = live;
        return true;
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
        defer self.publishSource(src);
        const gain = gainQ8(
            self.bridge.volume.load(.acquire),
            self.bridge.muted.load(.acquire),
        );

        const chip = format.Chip{ .ptr = self, .vtable = &logging_chip_vtable };
        const branch_label = self.bridge.branch_request.swap(std.math.maxInt(u32), .acq_rel);
        if (branch_label <= std.math.maxInt(u16) and src.branch(@intCast(branch_label), chip)) {
            self.wait = 0;
            self.park_after_wait = false;
        }
        var offset: usize = 0;
        var remaining: usize = frame_count;
        var zero_frame_steps: u32 = 0;
        while (remaining > 0) {
            if (self.wait == 0) {
                if (self.finishPark(buf, offset)) return;
                const r = src.step(chip);
                self.wait += r.frames;
                if (r.done) {
                    _ = self.bridge.loop_count.fetchAdd(1, .monotonic);
                    if (self.bridge.halt_at_songend.load(.acquire)) {
                        self.park_after_wait = true;
                    } else {
                        self.bridge.position_frames.store(0, .release);
                    }
                }
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
            const n: usize = @intCast(@min(self.wait, @as(u64, @min(remaining, pcm_window_frames))));
            const slice = buf[offset * 2 .. (offset + n) * 2];
            self.chip.render(slice);
            var mixed: [pcm_window_frames * 2]i64 = undefined;
            for (slice, mixed[0..slice.len]) |sample, *sum| sum.* = sample;
            if (self.second_chip) |*second| {
                var samples: [pcm_window_frames * 2]i16 = undefined;
                second.render(samples[0..slice.len]);
                for (mixed[0..slice.len], samples[0..slice.len]) |*sum, sample| sum.* += sample;
            }
            if (src.vtable.renderPcm != null) {
                var pcm: [pcm_window_frames * 2]i32 = undefined;
                src.renderPcm(pcm[0..slice.len]);
                for (mixed[0..slice.len], pcm[0..slice.len]) |*sum, extra| sum.* += extra;
            }
            for (slice, mixed[0..slice.len]) |*sample, sum| sample.* = std.math.lossyCast(i16, sum);
            self.wait -= n;
            offset += n;
            remaining -= n;
            _ = self.bridge.position_frames.fetchAdd(n, .monotonic);
            if (self.level_countdown <= n) {
                self.publishLevels();
                self.publishChip();
                self.publishPcmMeters(slice);
                self.level_countdown = self.level_period;
            } else {
                self.level_countdown -= @intCast(n);
            }
            for (slice, mixed[0..slice.len]) |*sample, sum| sample.* = scaleMixed(sum, gain);
            if (self.finishPark(buf, offset)) return;
        }
    }

    pub fn skip(self: *AudioEngine, frames: u64) void {
        const src = self.source orelse return;
        const chip = format.Chip{ .ptr = self, .vtable = &logging_chip_vtable };
        var left = frames;
        var zero_frame_steps: u32 = 0;
        var pcm: [pcm_window_frames * 2]i32 = undefined;
        while (left > 0) {
            if (self.wait == 0) {
                if (self.park_after_wait) break;
                const r = src.step(chip);
                self.wait = r.frames;
                if (r.done) {
                    _ = self.bridge.loop_count.fetchAdd(1, .monotonic);
                    if (self.bridge.halt_at_songend.load(.acquire)) {
                        self.park_after_wait = true;
                    } else {
                        self.bridge.position_frames.store(0, .release);
                    }
                }
                if (r.frames != 0) {
                    zero_frame_steps = 0;
                } else {
                    zero_frame_steps += 1;
                    if (zero_frame_steps > max_skip_stall) break;
                }
                continue;
            }
            const n: u64 = if (src.vtable.renderPcm != null) pcm: {
                const len: usize = @intCast(@min(self.wait, @as(u64, @min(left, pcm_window_frames))));
                src.renderPcm(pcm[0 .. len * 2]);
                break :pcm len;
            } else @min(self.wait, left);
            self.wait -= n;
            left -= n;
            _ = self.bridge.position_frames.fetchAdd(n, .monotonic);
        }
        chip.flush();
    }

    pub fn publishState(self: *AudioEngine) void {
        const src = self.source orelse return;
        self.publishSource(src);
        self.publishLevels();
        self.publishChip();
    }

    fn publishSource(self: *AudioEngine, src: format.MusicSource) void {
        if (src.playhead()) |p| self.bridge.playhead.write(p);
        self.bridge.channels.write(src.channelState() orelse .{});
        self.bridge.sequence.write(src.sequenceState() orelse .{});
        self.bridge.pattern_cursors.write(src.patternCursors());
        self.bridge.pcm.write(src.pcmState());
    }

    fn finishPark(self: *AudioEngine, buf: []i16, offset: usize) bool {
        if (!self.park_after_wait or self.wait != 0) return false;
        self.park_after_wait = false;
        self.bridge.paused.store(true, .release);
        @memset(buf[offset * 2 ..], 0);
        return true;
    }

    fn publishLevels(self: *AudioEngine) void {
        for (&self.bridge.levels, 0..) |*published, ch| {
            const synth = self.voiceChip(ch) orelse {
                published.store(0, .release);
                continue;
            };
            const local = ch % opal.channel_count;
            const chan = outputChannel(synth, local);
            var lvl: u8 = 0;
            var keyed = false;
            for (chan.out_source) |slot| {
                if (slot == opal.op_none) continue;
                const op = &synth.op[slot];
                lvl = @max(lvl, egLevelByte(op));
                keyed = keyed or op.key != 0;
            }
            if (chan.output_enable & 3 == 0) lvl = 0;
            if (keyed and !self.prev_keyed[ch]) self.strike_ttl[ch] = 4;
            self.prev_keyed[ch] = keyed;
            if (!keyed) self.strike_ttl[ch] = 0;
            const out = if (self.strike_ttl[ch] > 0) lvl else @as(u8, @intCast((@as(u16, lvl) * 5) / 8));
            self.strike_ttl[ch] -|= 1;
            published.store(out, .release);
        }
    }

    fn voiceChip(self: *const AudioEngine, ch: usize) ?*const opal.Opal {
        if (ch < opal.channel_count) return &self.chip;
        return if (self.second_chip) |*second| second else null;
    }

    fn outputChannel(synth: *const opal.Opal, ch: usize) *const opal.Channel {
        const chan = &synth.chan[ch];
        return if (chan.chan_type == .four_op) &synth.chan[chan.pair_index] else chan;
    }

    fn publishChip(self: *AudioEngine) void {
        var snap = view.ChipSnapshot{
            .new_bit = self.chip.new_mode != 0,
            .second_new_bit = if (self.second_chip) |*second| second.new_mode != 0 else false,
        };
        for (0..view.max_opl_voices) |ch| {
            const synth = self.voiceChip(ch) orelse continue;
            const local = ch % opal.channel_count;
            const chan = synth.chan[local];
            const car = &synth.op[opal.carrierSlot(local)];
            var keyed = car.key != 0;
            if (chan.connection != 0 or chan.chan_type != .two_op) {
                const mod = &synth.op[opal.modulatorSlot(local)];
                keyed = keyed or mod.key != 0;
            }
            const output = outputChannel(synth, local);
            const pan: u2 = @truncate(output.output_enable);
            const chan_type: view.OplChanType = switch (chan.chan_type) {
                .four_op => .four_op_hi,
                .four_op2 => .four_op_lo,
                .drum => .drum,
                else => .melody,
            };
            const pitch = if (chan.chan_type == .four_op2) synth.chan[chan.pair_index] else chan;
            snap.voices[ch] = .{
                .keyed = keyed,
                .fnum = @truncate(pitch.f_number),
                .block = @truncate(pitch.block),
                .pan = pan,
                .chan_type = @intCast(@backingInt(chan_type)),
            };
        }
        self.bridge.chip.write(snap);
    }

    /// Pre-fader: reads the mixed chip output before `scaleMixed`, so volume and
    /// mute do not move the meters. `meter_makeup` holds the old full-volume scale.
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

fn scaleMixed(sum: i64, factor_q8: u32) i16 {
    if (factor_q8 == 0) return 0;
    return std.math.lossyCast(i16, (sum * @as(i64, factor_q8)) >> 8);
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
    const atten: u32 = @min(op.eg_out, 512);
    return @intCast((512 - atten) * 255 / 512);
}

fn loggingWriteReg(ptr: *anyopaque, reg: u16, val: u8) void {
    const self: *AudioEngine = @ptrCast(@alignCast(ptr));
    if (reg >= 0x400) return;
    if (reg & 0x200 != 0) {
        if (self.second_chip == null) self.second_chip = opal.Opal.init(@intCast(self.sample_rate));
        self.second_chip.?.writeRegBuffered(reg & 0x1ff, val);
    } else {
        self.chip.writeRegBuffered(reg, val);
    }
    traceReg(ptr, reg, val);
}

fn traceReg(ptr: *anyopaque, reg: u16, val: u8) void {
    const self: *AudioEngine = @ptrCast(@alignCast(ptr));
    const packed_write: u32 = @bitCast(view.RegWrite{ .reg = reg, .val = val });
    const i = self.bridge.write_log_i.load(.monotonic);
    self.bridge.write_log[i % view.write_log_cap].store(packed_write, .release);
    _ = self.bridge.write_log_i.fetchAdd(1, .release);
}

fn loggingFlush(ptr: *anyopaque) void {
    const self: *AudioEngine = @ptrCast(@alignCast(ptr));
    chip_adapter.fromOpal(&self.chip).flush();
    if (self.second_chip) |*second| second.flushWriteBuf();
}

const logging_chip_vtable = format.Chip.VTable{ .writeReg = loggingWriteReg, .flush = loggingFlush, .traceReg = traceReg };

test "dual OPL3 renders independent stereo voices and clears the second chip on reset" {
    const Song = struct {
        started: bool = false,

        pub fn step(self: *@This(), chip: format.Chip) format.StepResult {
            if (!self.started) {
                self.started = true;
                for ([_]u16{ 0, 0x200 }, 0..) |chip_base, index| {
                    chip.writeReg(chip_base | 0x105, 1);
                    const bank: u16 = if (index == 0) 0 else 0x100;
                    const channel: u16 = if (index == 0) 0 else 8;
                    const operator: u16 = if (index == 0) 0 else 18;
                    const base = chip_base | bank;
                    for ([_]u16{ operator, operator + 3 }) |slot| {
                        chip.writeReg(base | (0x20 + slot), 0x21);
                        chip.writeReg(base | (0x40 + slot), 0);
                        chip.writeReg(base | (0x60 + slot), 0xf0);
                        chip.writeReg(base | (0x80 + slot), 0x0f);
                    }
                    chip.writeReg(base | (0xc0 + channel), if (index == 0) 0x11 else 0x21);
                    chip.writeReg(base | (0xa0 + channel), 0x6b);
                    chip.writeReg(base | (0xb0 + channel), if (index == 0) 0x31 else 0x35);
                }
                chip.flush();
            }
            return .{ .frames = 44100 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "VGM" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    var song = Song{};
    var br = Bridge{};
    var engine = AudioEngine{ .device = undefined, .bridge = &br, .chip = opal.Opal.init(44100), .source = format.MusicSource.init(&song, "stream") };
    var samples: [2048]i16 = undefined;
    engine.render(&samples);
    var left: u64 = 0;
    var right: u64 = 0;
    for (0..samples.len / 2) |i| {
        left += @abs(samples[2 * i]);
        right += @abs(samples[2 * i + 1]);
    }
    try std.testing.expect(left > 0 and right > 0);
    const snapshot = br.chip.read();
    try std.testing.expect(snapshot.new_bit and snapshot.second_new_bit);
    try std.testing.expect(snapshot.voices[0].keyed and snapshot.voices[35].keyed);
    try std.testing.expectEqual(@as(u2, 1), snapshot.voices[0].pan);
    try std.testing.expectEqual(@as(u2, 2), snapshot.voices[35].pan);
    try std.testing.expectEqual(@as(u3, 4), snapshot.voices[0].block);
    try std.testing.expectEqual(@as(u3, 5), snapshot.voices[35].block);
    try std.testing.expect(br.levels[35].load(.acquire) > 0);
    engine.reset();
    engine.publishChip();
    engine.publishLevels();
    engine.render(&samples);
    try std.testing.expect(engine.second_chip == null);
    try std.testing.expect(!br.chip.read().voices[35].keyed);
    try std.testing.expectEqual(@as(u8, 0), br.levels[35].load(.acquire));
    for (samples) |sample| try std.testing.expectEqual(@as(i16, 0), sample);
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

    var half: [8]i16 = @splat(16384);
    engine.publishPcmMeters(&half);
    try std.testing.expectEqual(@as(u8, 255), br.pcm_peak.load(.acquire));
    try std.testing.expectEqual(@as(u8, 255), br.pcm_peak_l.load(.acquire));

    var quarter: [8]i16 = @splat(8192);
    engine.publishPcmMeters(&quarter);
    try std.testing.expectEqual(@as(u8, 127), br.pcm_peak.load(.acquire));
}

test "four operator meters follow carriers and output routing in every algorithm" {
    const carriers = [_][4]bool{
        .{ false, false, false, true },
        .{ false, true, false, true },
        .{ true, false, false, true },
        .{ true, false, true, true },
    };
    const slots = [_]usize{ opal.modulatorSlot(0), opal.carrierSlot(0), opal.modulatorSlot(3), opal.carrierSlot(3) };
    for (carriers, 0..) |audible, algorithm| {
        var br = Bridge{};
        var engine = AudioEngine{ .bridge = &br, .device = undefined, .chip = opal.Opal.init(44100) };
        engine.chip.writeReg(0x105, 1);
        engine.chip.writeReg(0x104, 1);
        engine.chip.writeReg(0xc0, @intCast(algorithm >> 1));
        engine.chip.writeReg(0xc3, 0x10 | @as(u8, @intCast(algorithm & 1)));
        engine.chip.writeReg(0xb0, 0x20);
        for (slots, audible) |slot, expected| {
            for (&engine.chip.op) |*op| op.eg_out = 511;
            engine.chip.op[slot].eg_out = 0;
            engine.publishLevels();
            try std.testing.expectEqual(expected, br.levels[0].load(.acquire) > 0);
            try std.testing.expectEqual(br.levels[0].load(.acquire), br.levels[3].load(.acquire));
        }
        engine.publishChip();
        try std.testing.expectEqual(@as(u2, 1), br.chip.read().voices[0].pan);
        try std.testing.expectEqual(@as(u2, 1), br.chip.read().voices[3].pan);
        engine.chip.writeReg(0xc3, @intCast(algorithm & 1));
        engine.publishLevels();
        try std.testing.expectEqual(@as(u8, 0), br.levels[0].load(.acquire));
        try std.testing.expectEqual(@as(u8, 0), br.levels[3].load(.acquire));
        // Clearing NEW keeps the pair and its silent speakers.
        engine.chip.writeReg(0x105, 0);
        for (&engine.chip.op) |*op| op.eg_out = 511;
        engine.chip.op[opal.carrierSlot(3)].eg_out = 0;
        engine.publishLevels();
        try std.testing.expectEqual(@as(u8, 0), br.levels[0].load(.acquire));
        try std.testing.expectEqual(@as(u8, 0), br.levels[3].load(.acquire));
        // A C0 write while NEW is clear turns on both speakers.
        engine.chip.writeReg(0xc3, @intCast(algorithm & 1));
        engine.publishLevels();
        engine.publishChip();
        try std.testing.expect(br.levels[0].load(.acquire) > 0);
        try std.testing.expectEqual(br.levels[0].load(.acquire), br.levels[3].load(.acquire));
        try std.testing.expectEqual(@as(u2, 3), br.chip.read().voices[0].pan);
        try std.testing.expectEqual(@backingInt(view.OplChanType.four_op_hi), br.chip.read().voices[0].chan_type);
    }
}

test "the second half of a four operator voice shows the pair's pitch" {
    var br = Bridge{};
    var engine = AudioEngine{ .bridge = &br, .device = undefined, .chip = opal.Opal.init(44100) };
    engine.chip.writeReg(0xa3, 0x11);
    engine.chip.writeReg(0xb3, 0x05);
    engine.chip.writeReg(0x105, 1);
    engine.chip.writeReg(0x104, 1);
    engine.chip.writeReg(0xa0, 0x6b);
    engine.chip.writeReg(0xb0, 0x31);
    engine.publishChip();
    const voices = br.chip.read().voices;
    try std.testing.expectEqual(voices[0].fnum, voices[3].fnum);
    try std.testing.expectEqual(voices[0].block, voices[3].block);
}

test "scaleMixed scales, clamps, silences, and passes unity through" {
    try std.testing.expectEqual(@as(i16, 500), scaleMixed(1000, 128));
    try std.testing.expectEqual(@as(i16, -10_000), scaleMixed(-20_000, 128));
    try std.testing.expectEqual(@as(i16, 10_000), scaleMixed(10_000, 256));
    try std.testing.expectEqual(@as(i16, 20_000), scaleMixed(10_000, 512));
    try std.testing.expectEqual(@as(i16, 32_767), scaleMixed(20_000, 512));
    try std.testing.expectEqual(@as(i16, -32_768), scaleMixed(-32_768, 512));
    try std.testing.expectEqual(@as(i16, 0), scaleMixed(20_000, 0));
    try std.testing.expectEqual(@as(i16, 20_000), scaleMixed(40_000, 128));
    try std.testing.expectEqual(@as(i16, 32_767), scaleMixed(40_000, 512));
}

test "render resets position_frames on loop but not on halt" {
    const LoopSrc = struct {
        phase: u32 = 0,

        pub fn step(self: *@This(), _: format.Chip) format.StepResult {
            self.phase += 1;
            if (self.phase == 1) return .{ .frames = 5 };
            if (self.phase == 2) return .{ .frames = 0, .done = true };
            return .{ .frames = 5 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test", .system = "OPL2", .visualizer = "stream" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    var br = Bridge{};
    var engine = AudioEngine{
        .bridge = &br,
        .device = undefined,
        .chip = opal.Opal.init(44100),
    };
    var src_state = LoopSrc{};
    engine.source = format.MusicSource.init(&src_state, "stream");
    br.position_frames.store(100, .release);

    const frame_count = 20;
    var buf: [frame_count * 2]i16 = undefined;
    engine.render(&buf);
    try std.testing.expectEqual(@as(u32, 1), br.loop_count.load(.acquire));
    try std.testing.expect(br.position_frames.load(.acquire) < 100);
    try std.testing.expectEqual(@as(u64, 15), br.position_frames.load(.acquire));
    try std.testing.expect(!br.paused.load(.acquire));

    br.halt_at_songend.store(true, .release);
    br.position_frames.store(50, .release);
    src_state.phase = 1;
    engine.wait = 0;
    engine.render(&buf);
    try std.testing.expect(br.paused.load(.acquire));
    try std.testing.expectEqual(@as(u64, 50), br.position_frames.load(.acquire));
}

test "skip advances source, chip, PCM and position without rendering, and stops at a song boundary" {
    const Song = struct {
        steps: u8 = 0,
        pcm_frames: usize = 0,

        pub fn step(self: *@This(), chip: format.Chip) format.StepResult {
            self.steps += 1;
            chip.writeReg(0xa0, self.steps);
            if (self.steps == 6) return .{ .frames = 10, .done = true };
            return .{ .frames = 10 };
        }

        pub fn renderPcm(self: *@This(), stereo: []i32) void {
            self.pcm_frames += stereo.len / 2;
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    var br = Bridge{};
    var engine = AudioEngine{ .bridge = &br, .device = undefined, .chip = opal.Opal.init(44100) };
    var song = Song{};
    engine.source = format.MusicSource.init(&song, "stream");

    engine.skip(25);
    try std.testing.expectEqual(@as(u8, 3), song.steps);
    try std.testing.expectEqual(@as(u64, 5), engine.wait);
    try std.testing.expectEqual(@as(usize, 25), song.pcm_frames);
    try std.testing.expectEqual(@as(u64, 25), br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u16, 3), engine.chip.chan[0].f_number & 0xff);

    br.halt_at_songend.store(true, .release);
    engine.skip(1000);
    try std.testing.expectEqual(@as(u8, 6), song.steps);
    try std.testing.expectEqual(@as(u32, 1), br.loop_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 60), br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), engine.wait);
    try std.testing.expect(engine.park_after_wait);
    engine.skip(10);
    try std.testing.expectEqual(@as(u8, 6), song.steps);
    try std.testing.expectEqual(@as(u64, 60), br.position_frames.load(.acquire));

    var looping_br = Bridge{};
    var looping = AudioEngine{ .bridge = &looping_br, .device = undefined, .chip = opal.Opal.init(44100) };
    var looped = Song{};
    looping.source = format.MusicSource.init(&looped, "stream");
    looping.skip(55);
    try std.testing.expectEqual(@as(u8, 6), looped.steps);
    try std.testing.expectEqual(@as(u32, 1), looping_br.loop_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 5), looping_br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u64, 5), looping.wait);
    try std.testing.expect(!looping.park_after_wait);

    const Silent = struct {
        steps: u8 = 0,

        pub fn step(self: *@This(), _: format.Chip) format.StepResult {
            self.steps += 1;
            return .{ .frames = 1 << 50 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    var silent_br = Bridge{};
    var silent_engine = AudioEngine{ .bridge = &silent_br, .device = undefined, .chip = opal.Opal.init(44100) };
    var silent = Silent{};
    silent_engine.source = format.MusicSource.init(&silent, "stream");
    silent_engine.skip(1 << 49);
    try std.testing.expectEqual(@as(u8, 1), silent.steps);
    try std.testing.expectEqual(@as(u64, 1 << 49), silent_br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1 << 49), silent_engine.wait);
}

test "PCM rendering respects tick boundaries, gain, pause and final frames" {
    const Source = struct {
        ticks: u8 = 0,
        rendered: usize = 0,

        pub fn step(self: *@This(), _: format.Chip) format.StepResult {
            self.ticks += 1;
            return .{ .frames = 3, .done = self.ticks == 2 };
        }

        pub fn renderPcm(self: *@This(), samples: []i32) void {
            for (samples) |*sample| sample.* += @as(i32, self.ticks) * 1000;
            self.rendered += samples.len / 2;
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test" };
        }
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    var state = Source{};
    var br = Bridge{};
    br.volume.store(50, .release);
    br.halt_at_songend.store(true, .release);
    var engine = AudioEngine{ .device = undefined, .bridge = &br, .chip = opal.Opal.init(44100), .source = format.MusicSource.init(&state, "stream") };
    var buf: [8]i16 = undefined;
    engine.render(&buf);
    try std.testing.expectEqualSlices(i16, &.{ 500, 500, 500, 500, 500, 500, 1000, 1000 }, &buf);
    br.paused.store(true, .release);
    engine.render(&buf);
    try std.testing.expectEqualSlices(i16, &@as([8]i16, @splat(0)), &buf);
    try std.testing.expectEqual(@as(usize, 4), state.rendered);
    br.paused.store(false, .release);
    br.muted.store(true, .release);
    engine.render(&buf);
    try std.testing.expectEqualSlices(i16, &@as([8]i16, @splat(0)), &buf);
    try std.testing.expectEqual(@as(usize, 6), state.rendered);
    try std.testing.expectEqual(@as(u8, 2), state.ticks);
    try std.testing.expect(br.paused.load(.acquire));
}

test "selectArchiveTrack retargets when the source can, otherwise leaves the synth" {
    const ArcSrc = struct {
        index: u32 = 0,

        pub fn step(_: *@This(), _: format.Chip) format.StepResult {
            return .{ .frames = 1 };
        }

        pub fn info(self: *@This()) format.TrackInfo {
            return .{
                .format_name = "test",
                .visualizer = "stream",
                .archive_track_count = 3,
                .archive_track_index = self.index,
            };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

        pub fn selectArchiveTrack(self: *@This(), _: std.mem.Allocator, index: u32, _: format.Chip) anyerror!void {
            if (index == 3) return error.OutOfMemory;
            self.index = @min(index, 2);
        }
    };

    const PlainSrc = struct {
        pub fn step(_: *@This(), _: format.Chip) format.StepResult {
            return .{ .frames = 1 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test", .visualizer = "stream" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    var br = Bridge{};
    var engine = AudioEngine{
        .bridge = &br,
        .device = undefined,
        .chip = opal.Opal.init(44100),
        .sample_rate = 44100,
        .wait = 9,
    };
    var arc = ArcSrc{};
    engine.source = format.MusicSource.init(&arc, "stream");
    engine.chip.writeReg(0xb0, 0x31);
    const previous = engine.chip;
    try std.testing.expectError(error.OutOfMemory, engine.selectArchiveTrack(std.testing.allocator, 3));
    try std.testing.expectEqualDeep(previous, engine.chip);
    try std.testing.expectEqual(@as(u64, 9), engine.wait);
    try std.testing.expectEqual(@as(u32, 0), arc.index);
    try std.testing.expect(try engine.selectArchiveTrack(std.testing.allocator, 2));
    try std.testing.expectEqual(@as(u32, 2), engine.source.?.info().archive_track_index);
    try std.testing.expectEqual(@as(u64, 0), engine.wait);

    engine.wait = 7;
    var plain = PlainSrc{};
    engine.source = format.MusicSource.init(&plain, "stream");
    try std.testing.expect(!(try engine.selectArchiveTrack(std.testing.allocator, 1)));
    try std.testing.expectEqual(@as(u64, 7), engine.wait);
}
