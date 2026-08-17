//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

const channels = 9;
pub const visualizer_name = "tracker";
const rows_per_pattern = 64;
const instrument_count = 128;
const instrument_size = 12;
const order_len = 51;
const order_slots = 128;
const max_patterns = 50;
const order_wrap = 50;
const header_bytes = instrument_count * instrument_size + order_len;
const pattern_bytes = rows_per_pattern * channels * 2;
const max_file_bytes = header_bytes + max_patterns * pattern_bytes + 1;

const tick_num = 5;
const tick_den = 91;

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };
const note_fnum = [_]u16{ 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686 };

const Reg = struct {
    const waveform_select: u16 = 0x01;
    const csw_note_sel: u16 = 0x08;
    const rhythm: u16 = 0xbd;
    const fnum_lo: u16 = 0xa0;
    const key_block: u16 = 0xb0;
    const feedback: u16 = 0xc0;
    const carrier_level: u16 = 0x43;
    const modulator_level: u16 = 0x40;
    const carrier_char: u16 = 0x23;
    const modulator_char: u16 = 0x20;
    const carrier_ad: u16 = 0x63;
    const modulator_ad: u16 = 0x60;
    const carrier_sr: u16 = 0x83;
    const modulator_sr: u16 = 0x80;
    const carrier_wave: u16 = 0xe3;
    const modulator_wave: u16 = 0xe0;
};

const EffectHi = struct {
    const global: u8 = 0x00;
    const slide_up: u8 = 0x10;
    const slide_down: u8 = 0x20;
    const percussion: u8 = 0x50;
    const feedback: u8 = 0x60;
    const carrier_vol: u8 = 0xa0;
    const modulator_vol: u8 = 0xb0;
    const both_vol: u8 = 0xc0;
    const position_jump: u8 = 0xd0;
    const speed: u8 = 0xf0;
};

const level_mask: u8 = 63;
const key_on_bit: u8 = 32;
const song_end_marker: u8 = 0xff;
const order_jump_max: u8 = 0xb1;
const order_end_min: u8 = 0xb2;
const note_off_raw: u8 = 0x7f;

/// Mirrors the 12 bytes an instrument occupies in the file, in order.
const Instrument = extern struct {
    carrier_char: u8 = 0,
    modulator_char: u8 = 0,
    carrier_level: u8 = 0,
    modulator_level: u8 = 0,
    carrier_ad: u8 = 0,
    modulator_ad: u8 = 0,
    carrier_sr: u8 = 0,
    modulator_sr: u8 = 0,
    feedback_conn: u8 = 0,
    carrier_wave: u8 = 0,
    modulator_wave: u8 = 0,
    slide: u8 = 0,

    comptime {
        if (@sizeOf(Instrument) != instrument_size) @compileError("Instrument must match the on-disk layout");
    }

    fn additive(self: Instrument) bool {
        return self.feedback_conn & 1 != 0;
    }
    fn carrierLevelField(self: Instrument) u8 {
        return self.carrier_level & level_mask;
    }
    fn modulatorLevelField(self: Instrument) u8 {
        return self.modulator_level & level_mask;
    }
    fn carrierKslBits(self: Instrument) u8 {
        return self.carrier_level & ~level_mask;
    }
    fn modulatorKslBits(self: Instrument) u8 {
        return self.modulator_level & ~level_mask;
    }

    fn applyLoadFixups(self: *Instrument) void {
        self.carrier_level ^= (self.carrier_level & 0x40) << 1;
        self.modulator_level ^= (self.modulator_level & 0x40) << 1;
        self.slide >>= 4;
    }
};

const Channel = struct {
    instrument: u8 = 0,
    slide: i8 = 0,
    freq: u16 = 0,
};

const PatternCell = struct {
    note: u8,
    effect: u8,

    fn effectHi(self: PatternCell) u8 {
        return self.effect & 0xf0;
    }
    fn effectLo(self: PatternCell) u8 {
        return self.effect & 0x0f;
    }
    fn isInstrumentSet(self: PatternCell) bool {
        return self.note & 128 != 0;
    }
};

const HscSource = struct {
    sample_rate: u32,
    frac: u32 = 0,
    instruments: [instrument_count]Instrument = @splat(.{}),
    order: [order_slots]u8 = @splat(song_end_marker),
    file: []const u8,
    num_patterns: u8,
    channel: [channels]Channel = @splat(.{}),
    key_block: [channels]u8 = @splat(0),
    row: u8 = 0,
    order_pos: u8 = 0,
    pattern_break: bool = false,
    song_end: bool = false,
    rhythm_mode: bool = false,
    bd: u8 = 0,
    fadein: u8 = 0,
    speed: u32 = 2,
    delay: u32 = 1,
    cur_order: u8 = 0,
    cur_row: u8 = 0,
    cur_pattern: u8 = 0,
    last_instrument: u8 = 0,

    fn instrument(self: *const HscSource, index: u8) *const Instrument {
        return &self.instruments[index & (instrument_count - 1)];
    }

    fn patternCell(self: *const HscSource, pattern: u8, row: u8, chan: u8) ?PatternCell {
        const cell_off = @as(usize, pattern) * pattern_bytes +
            (@as(usize, row) * channels + chan) * 2;
        const base = header_bytes + cell_off;
        if (base + 1 >= self.file.len) return null;
        return .{
            .note = self.file[base],
            .effect = self.file[base + 1],
        };
    }

    fn setFreq(self: *HscSource, chip: fmt.Chip, chan: u8, freq: u16) void {
        self.key_block[chan] = (self.key_block[chan] & ~@as(u8, 3)) | @as(u8, @truncate(freq >> 8));
        chip.writeReg(Reg.fnum_lo + chan, @truncate(freq & 0xff));
        chip.writeReg(Reg.key_block + chan, self.key_block[chan]);
    }

    fn setVolume(self: *HscSource, chip: fmt.Chip, chan: u8, carrier_vol: u8, modulator_vol: u8) void {
        const ins = self.instrument(self.channel[chan].instrument);
        const op = op_offset[chan];
        chip.writeReg(Reg.carrier_level + op, carrier_vol | ins.carrierKslBits());
        if (ins.additive()) {
            chip.writeReg(Reg.modulator_level + op, modulator_vol | ins.modulatorKslBits());
        } else {
            chip.writeReg(Reg.modulator_level + op, ins.modulator_level);
        }
    }

    fn setInstrument(self: *HscSource, chip: fmt.Chip, chan: u8, index: u8) void {
        if (index >= instrument_count) return;
        const ins = self.instrument(index);
        const op = op_offset[chan];
        self.channel[chan].instrument = index;
        self.last_instrument = index;
        self.key_block[chan] &= ~@as(u8, key_on_bit);
        chip.writeReg(Reg.key_block + chan, self.key_block[chan]);
        chip.writeReg(Reg.feedback + chan, ins.feedback_conn);
        chip.writeReg(Reg.carrier_char + op, ins.carrier_char);
        chip.writeReg(Reg.modulator_char + op, ins.modulator_char);
        chip.writeReg(Reg.carrier_ad + op, ins.carrier_ad);
        chip.writeReg(Reg.modulator_ad + op, ins.modulator_ad);
        chip.writeReg(Reg.carrier_sr + op, ins.carrier_sr);
        chip.writeReg(Reg.modulator_sr + op, ins.modulator_sr);
        chip.writeReg(Reg.carrier_wave + op, ins.carrier_wave);
        chip.writeReg(Reg.modulator_wave + op, ins.modulator_wave);
        self.setVolume(chip, chan, ins.carrierLevelField(), ins.modulatorLevelField());
    }

    fn playRow(self: *HscSource, chip: fmt.Chip, pattern: u8) void {
        for (0..channels) |chan_usize| {
            const chan: u8 = @intCast(chan_usize);
            const pc = self.patternCell(pattern, self.row, chan) orelse continue;

            if (pc.isInstrumentSet()) {
                self.setInstrument(chip, chan, pc.effect);
                continue;
            }

            const eff_op = pc.effectLo();
            const inst = self.channel[chan].instrument;
            const ins = self.instrument(inst);
            if (pc.note != 0) self.channel[chan].slide = 0;

            switch (pc.effectHi()) {
                EffectHi.global => switch (eff_op) {
                    1 => self.pattern_break = true,
                    3 => self.fadein = 31,
                    5 => self.rhythm_mode = true,
                    6 => self.rhythm_mode = false,
                    else => {},
                },
                EffectHi.slide_up, EffectHi.slide_down => {
                    if (pc.effect & EffectHi.slide_up != 0) {
                        self.channel[chan].freq +%= eff_op;
                        self.channel[chan].slide +%= @intCast(eff_op);
                    } else {
                        self.channel[chan].freq -%= eff_op;
                        self.channel[chan].slide -%= @intCast(eff_op);
                    }
                    if (pc.note == 0) self.setFreq(chip, chan, self.channel[chan].freq);
                },
                EffectHi.percussion => {
                    if (eff_op <= 4) {
                        self.rhythm_mode = true;
                        self.bd = 0x20 | (@as(u8, 1) << @intCast(eff_op));
                    } else if (eff_op <= 7) {
                        self.bd = @as(u8, 1) << @intCast(eff_op);
                        if (eff_op == 5) self.rhythm_mode = true;
                    }
                    chip.writeReg(Reg.rhythm, self.bd);
                },
                EffectHi.feedback => {
                    chip.writeReg(
                        Reg.feedback + chan,
                        (ins.feedback_conn & 1) + (eff_op << 1),
                    );
                },
                EffectHi.carrier_vol => {
                    const vol: u8 = eff_op << 2;
                    chip.writeReg(Reg.carrier_level + op_offset[chan], vol | ins.carrierKslBits());
                },
                EffectHi.modulator_vol => {
                    const vol: u8 = eff_op << 2;
                    chip.writeReg(Reg.modulator_level + op_offset[chan], vol | ins.modulatorKslBits());
                },
                EffectHi.both_vol => {
                    const db: u8 = eff_op << 2;
                    chip.writeReg(Reg.carrier_level + op_offset[chan], db | ins.carrierKslBits());
                    if (ins.additive()) {
                        chip.writeReg(Reg.modulator_level + op_offset[chan], db | ins.modulatorKslBits());
                    }
                },
                EffectHi.position_jump => {
                    self.pattern_break = true;
                    self.order_pos = eff_op;
                    self.song_end = true;
                },
                EffectHi.speed => {
                    self.speed = @as(u32, eff_op) + 1;
                    self.delay = self.speed;
                },
                else => {},
            }

            if (self.fadein != 0) {
                const v: u8 = self.fadein *% 2;
                self.setVolume(chip, chan, v, v);
            }

            if (pc.note == 0) continue;
            const n = pc.note -% 1;

            if (n == note_off_raw - 1 or ((n / 12) & ~@as(u8, 7)) != 0) {
                self.key_block[chan] &= ~@as(u8, key_on_bit);
                chip.writeReg(Reg.key_block + chan, self.key_block[chan]);
                continue;
            }

            const block: u8 = ((n / 12) & 7) << 2;
            const slide_u16: u16 = @bitCast(@as(i16, self.channel[chan].slide));
            const fnum: u16 = note_fnum[n % 12] +% ins.slide +% slide_u16;
            self.channel[chan].freq = fnum;
            self.last_instrument = inst;
            if (!self.rhythm_mode or chan < 6) {
                self.key_block[chan] = block | key_on_bit;
            } else {
                self.key_block[chan] = block;
            }
            chip.writeReg(Reg.key_block + chan, 0);
            self.setFreq(chip, chan, fnum);

            if (self.rhythm_mode) {
                switch (chan) {
                    6 => {
                        chip.writeReg(Reg.rhythm, self.bd & ~@as(u8, 16));
                        self.bd |= 48;
                    },
                    7 => {
                        chip.writeReg(Reg.rhythm, self.bd & ~@as(u8, 1));
                        self.bd |= 33;
                    },
                    8 => {
                        chip.writeReg(Reg.rhythm, self.bd & ~@as(u8, 2));
                        self.bd |= 34;
                    },
                    else => {},
                }
                chip.writeReg(Reg.rhythm, self.bd);
            }
        }
    }

    fn update(self: *HscSource, chip: fmt.Chip) bool {
        self.delay -= 1;
        if (self.delay != 0) return !self.song_end;

        if (self.fadein != 0) self.fadein -= 1;

        var pattern = self.order[self.order_pos];
        if (pattern >= order_end_min) {
            self.song_end = true;
            self.order_pos = 0;
            pattern = self.order[self.order_pos];
        } else if ((pattern & 128) != 0 and pattern <= order_jump_max) {
            self.order_pos = self.order[self.order_pos] & (order_slots - 1);
            self.row = 0;
            pattern = self.order[self.order_pos];
            self.song_end = true;
        }

        self.cur_order = self.order_pos;
        self.cur_row = self.row;
        self.cur_pattern = pattern;

        if (pattern < self.num_patterns) {
            self.playRow(chip, pattern);
        }

        self.delay = self.speed;
        if (self.pattern_break) {
            self.row = 0;
            self.pattern_break = false;
            self.order_pos = (self.order_pos + 1) % order_wrap;
            if (self.order_pos == 0) self.song_end = true;
        } else {
            self.row = (self.row + 1) & (rows_per_pattern - 1);
            if (self.row == 0) {
                self.order_pos = (self.order_pos + 1) % order_wrap;
                if (self.order_pos == 0) self.song_end = true;
            }
        }
        return !self.song_end;
    }

    pub fn step(self: *HscSource, chip: fmt.Chip) fmt.StepResult {
        var done = false;
        if (!self.update(chip)) {
            done = true;
            self.song_end = false;
        }
        const frames = fmt.rescale(tick_num, tick_den, self.sample_rate, &self.frac);
        return .{ .frames = frames, .done = done };
    }

    /// No title: the file carries none and HSC synthesizes none, so the shell
    /// falls back to the file name without its extension.
    pub fn info(_: *HscSource) fmt.TrackInfo {
        return .{
            .format_name = "HSC",
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .visualizer = visualizer_name,
        };
    }

    pub fn pos(self: *HscSource) fmt.TrackerPos {
        return .{
            .order_pos = self.cur_order,
            .row = self.cur_row,
            .pattern = self.cur_pattern,
            .speed = @truncate(self.speed),
            .last_instrument = self.last_instrument,
        };
    }

    pub fn trackerView(self: *HscSource) fmt.TrackerView {
        return .{
            .ctx = self,
            .channels = channels,
            .rows_per_pattern = rows_per_pattern,
            .num_patterns = self.num_patterns,
            .order = self.order[0..order_len],
            .cell = cell,
            .instrument = instrumentView,
        };
    }

    fn cell(ptr: *anyopaque, pattern: u8, row: u8, chan: u8) fmt.TrackerCell {
        const self: *HscSource = @ptrCast(@alignCast(ptr));
        const raw = self.patternCell(pattern, row, chan) orelse return .{ .kind = .empty };
        if (raw.isInstrumentSet()) return .{ .kind = .set_instrument, .arg = raw.effect };
        if (raw.note == 0) {
            if (raw.effect == 0) return .{ .kind = .empty };
            return .{ .kind = .effect_only, .arg = raw.effect };
        }
        const n = raw.note -% 1;
        if (n == note_off_raw - 1 or ((n / 12) & ~@as(u8, 7)) != 0) {
            return .{ .kind = .note_off, .arg = raw.effect };
        }
        return .{
            .kind = .note,
            .semitone = n % 12,
            .octave = (n / 12) & 7,
            .arg = raw.effect,
        };
    }

    fn instrumentView(ptr: *anyopaque, index: u8) fmt.InstrumentInfo {
        const self: *HscSource = @ptrCast(@alignCast(ptr));
        const ins = self.instrument(index);
        return .{
            .modulator = fmt.operatorParams(ins.modulator_char, ins.modulator_level, ins.modulator_ad, ins.modulator_sr, ins.modulator_wave),
            .carrier = fmt.operatorParams(ins.carrier_char, ins.carrier_level, ins.carrier_ad, ins.carrier_sr, ins.carrier_wave),
            .feedback = @truncate((ins.feedback_conn >> 1) & 7),
            .additive = ins.additive(),
        };
    }

    pub fn deinit(self: *HscSource, gpa: std.mem.Allocator) void {
        gpa.free(self.file);
        gpa.destroy(self);
    }
};

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const chip = ctx.chip;
    if (data.len < header_bytes + pattern_bytes or data.len > max_file_bytes) return null;

    const raw_patterns = (data.len - header_bytes) / pattern_bytes;
    if (raw_patterns == 0) return null;
    const num_patterns: u8 = @intCast(@min(raw_patterns, max_patterns));

    const copy = try gpa.dupe(u8, data);
    errdefer gpa.free(copy);

    const src = try gpa.create(HscSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .file = copy,
        .num_patterns = num_patterns,
    };

    const instr_bytes = instrument_count * instrument_size;
    @memcpy(std.mem.asBytes(&src.instruments)[0..instr_bytes], data[0..instr_bytes]);
    for (&src.instruments) |*ins| ins.applyLoadFixups();

    for (0..order_len) |i| {
        var v = data[instr_bytes + i];
        if (v < 0x80 and v >= num_patterns) v = song_end_marker;
        if (v >= order_end_min) v = song_end_marker;
        src.order[i] = v;
    }

    for (&src.channel, 0..) |*ch, i| ch.instrument = @intCast(i);

    chip.writeReg(Reg.waveform_select, 0x20);
    chip.writeReg(Reg.csw_note_sel, 0x80);
    chip.writeReg(Reg.rhythm, 0x00);
    for (0..channels) |i| {
        const ch: u8 = @intCast(i);
        src.setInstrument(chip, ch, ch);
    }
    chip.flush();

    return fmt.MusicSource.init(src);
}

pub const format = fmt.Format{
    .name = "HSC",
    .extensions = &.{".hsc"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

test "hsc 18.2 Hz frac-carry over 10 minutes drifts 0 frames" {
    const sample_rate: u32 = 44100;
    var frac: u32 = 0;
    var total: u64 = 0;
    const ticks: u64 = 10920;
    for (0..ticks) |_| {
        total += fmt.rescale(tick_num, tick_den, sample_rate, &frac);
    }
    const ideal: u64 = @as(u64, sample_rate) * tick_num * ticks / tick_den;
    try std.testing.expectEqual(ideal, total);
}

test "order end markers collapse to 0xff at load" {
    const gpa = std.testing.allocator;
    var data: [header_bytes + pattern_bytes]u8 = @splat(0);
    const instr_bytes = instrument_count * instrument_size;
    data[instr_bytes + 0] = 0;
    data[instr_bytes + 1] = 0xB5;
    data[instr_bytes + 2] = 0x90;

    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "t.hsc", &data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) })).?;
    defer src.deinit(gpa);

    const view = src.trackerView().?;
    try std.testing.expectEqual(@as(u8, 0), view.order[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), view.order[1]);
    try std.testing.expectEqual(@as(u8, 0x90), view.order[2]);
}

test "a measured duration does not cost HSC its own capabilities" {
    const gpa = std.testing.allocator;
    var data: [header_bytes + pattern_bytes]u8 = @splat(0);
    data[instrument_count * instrument_size] = 0;

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "t.hsc", &data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);

    try std.testing.expect(src.vtable.durationFrames == null);
    try std.testing.expect(src.duration_override != null);
    try std.testing.expect(src.durationFrames().? > 0);

    try std.testing.expect(src.trackerView() != null);
    try std.testing.expect(src.pos() != null);
    try std.testing.expect(src.getTickRate() == null);
}

test "tracker cell decode matches playRow's note encoding" {
    var data: [header_bytes + pattern_bytes]u8 = @splat(0);
    data[header_bytes + 0] = 1 + 3 + 12 * 4;
    data[header_bytes + 1] = 0x12;
    data[header_bytes + 2] = 0x80;
    data[header_bytes + 3] = 5;
    data[header_bytes + 4] = 0x7f;
    data[header_bytes + 7] = 0xF3;

    var src = HscSource{
        .sample_rate = 44100,
        .file = &data,
        .num_patterns = 1,
    };
    const ptr: *anyopaque = &src;

    const c0 = HscSource.cell(ptr, 0, 0, 0);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note, c0.kind);
    try std.testing.expectEqual(@as(u8, 3), c0.semitone);
    try std.testing.expectEqual(@as(u8, 4), c0.octave);
    try std.testing.expectEqual(@as(u8, 0x12), c0.arg);

    const c1 = HscSource.cell(ptr, 0, 0, 1);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.set_instrument, c1.kind);
    try std.testing.expectEqual(@as(u8, 5), c1.arg);

    const c2 = HscSource.cell(ptr, 0, 0, 2);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note_off, c2.kind);

    const c3 = HscSource.cell(ptr, 0, 0, 3);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.effect_only, c3.kind);
    try std.testing.expectEqual(@as(u8, 0xF3), c3.arg);

    const c4 = HscSource.cell(ptr, 0, 0, 4);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.empty, c4.kind);

    const oob = HscSource.cell(ptr, 49, 63, 8);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.empty, oob.kind);
}

test "instrument decode splits OPL operator fields" {
    var src = HscSource{
        .sample_rate = 44100,
        .file = &.{},
        .num_patterns = 0,
    };
    src.instruments = @splat(.{});
    src.instruments[7] = .{
        .carrier_char = 0xE1,
        .modulator_char = 0x35,
        .carrier_level = 0x8A,
        .modulator_level = 0x3F,
        .carrier_ad = 0xF2,
        .modulator_ad = 0x41,
        .carrier_sr = 0x79,
        .modulator_sr = 0xC8,
        .feedback_conn = 0x0B,
        .carrier_wave = 0x02,
        .modulator_wave = 0x03,
    };
    const ins = HscSource.instrumentView(&src, 7);
    try std.testing.expect(ins.carrier.tremolo);
    try std.testing.expect(ins.carrier.vibrato);
    try std.testing.expect(ins.carrier.sustaining);
    try std.testing.expect(!ins.carrier.ksr);
    try std.testing.expectEqual(@as(u4, 1), ins.carrier.mult);
    try std.testing.expectEqual(@as(u2, 2), ins.carrier.ksl);
    try std.testing.expectEqual(@as(u6, 10), ins.carrier.level);
    try std.testing.expectEqual(@as(u4, 15), ins.carrier.attack);
    try std.testing.expectEqual(@as(u4, 2), ins.carrier.decay);
    try std.testing.expectEqual(@as(u4, 7), ins.carrier.sustain);
    try std.testing.expectEqual(@as(u4, 9), ins.carrier.release);
    try std.testing.expectEqual(@as(u3, 2), ins.carrier.wave);
    try std.testing.expect(!ins.modulator.tremolo);
    try std.testing.expect(ins.modulator.ksr);
    try std.testing.expectEqual(@as(u4, 5), ins.modulator.mult);
    try std.testing.expectEqual(@as(u6, 63), ins.modulator.level);
    try std.testing.expectEqual(@as(u3, 3), ins.modulator.wave);
    try std.testing.expectEqual(@as(u3, 5), ins.feedback);
    try std.testing.expect(ins.additive);
}

test "hsc reports no title so the shell falls back to the file name" {
    const gpa = std.testing.allocator;
    var data: [header_bytes + pattern_bytes]u8 = @splat(0);
    data[instrument_count * instrument_size] = 0;

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "music/tune.hsc", &data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);
    try std.testing.expect(src.info().title == null);
}

test "hsc instrument-set keys off without zeroing block" {
    const Rec = struct {
        b0: [channels]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg >= Reg.key_block and reg < Reg.key_block + channels) {
                self.b0[reg - Reg.key_block] = val;
            }
        }
        fn flush(_: *anyopaque) void {}
        fn chip(self: *@This()) fmt.Chip {
            return .{
                .ptr = self,
                .vtable = &.{ .writeReg = write, .flush = flush },
            };
        }
    };

    const gpa = std.testing.allocator;
    var data: [header_bytes + pattern_bytes]u8 = @splat(0);
    data[instrument_count * instrument_size] = 0;
    data[header_bytes + 0] = 37;
    data[header_bytes + channels * 2] = 0x80;
    data[header_bytes + channels * 2 + 1] = 1;

    var rec = Rec{};
    const src = (try load(gpa, &data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".hsc",
        .name = "t.hsc",
    })).?;
    defer src.deinit(gpa);

    _ = src.step(rec.chip());
    try std.testing.expect(rec.b0[0] & key_on_bit != 0);

    _ = src.step(rec.chip());
    _ = src.step(rec.chip());
    try std.testing.expect(rec.b0[0] & key_on_bit == 0);
    try std.testing.expect(rec.b0[0] != 0);
}
