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
const order_slots = 256;
const max_patterns = 50;
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
const order_end_min: u8 = 0xb2;
const order_jump_limit: u8 = 0x31;
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
        if (self.additive()) {
            self.modulator_level ^= (self.modulator_level & 0x40) << 1;
        }
        self.slide >>= 4;
    }
};

const Channel = struct {
    instrument: u8 = 0xFF,
    freq: u16 = 0,
    dirty: bool = false,
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
        return self.note == 0x80;
    }
};

fn noteWord(n: u8) u16 {
    return note_fnum[n % 12] +% (@as(u16, n / 12) << 10) +% 0x2000;
}

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

    fn orderByte(self: *const HscSource, slot: u8) u8 {
        const idx = instrument_count * instrument_size + @as(usize, slot);
        if (idx >= self.file.len) return song_end_marker;
        return self.file[idx];
    }

    fn writeFreq(self: *HscSource, chip: fmt.Chip, chan: u8) void {
        const ins = self.instrument(self.channel[chan].instrument);
        if (ins.slide == 0 and !self.channel[chan].dirty) return;
        self.channel[chan].dirty = false;
        const lo: u8 = @truncate(self.channel[chan].freq);
        const b0: u8 = @truncate(self.channel[chan].freq >> 8);
        self.key_block[chan] = b0;
        chip.writeReg(Reg.fnum_lo + chan, lo +% ins.slide);
        chip.writeReg(Reg.key_block + chan, b0);
    }

    fn slideFreq(self: *HscSource, chan: u8, delta: u8, up: bool) void {
        var lo: u8 = @truncate(self.channel[chan].freq);
        if (up) lo +%= delta else lo -%= delta;
        self.channel[chan].freq = (self.channel[chan].freq & 0xff00) | lo;
        self.channel[chan].dirty = true;
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
        if (self.channel[chan].instrument == index) return;
        const ins = self.instrument(index);
        const op = op_offset[chan];
        self.channel[chan].instrument = index;
        self.last_instrument = index;
        chip.writeReg(Reg.key_block + chan, 0);
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

    fn setSpeed(self: *HscSource, nibble: u8) void {
        self.speed = @as(u32, nibble) + 1;
        self.delay = self.speed;
    }

    fn playNote(self: *HscSource, chip: fmt.Chip, chan: u8, note: u8) void {
        if (note == note_off_raw) {
            self.channel[chan].freq &= ~@as(u16, 0x2000);
            self.channel[chan].dirty = true;
            return;
        }
        const n = note -% 1;
        chip.writeReg(Reg.key_block + chan, 0);
        self.channel[chan].freq = noteWord(n);
        self.channel[chan].dirty = true;
        self.last_instrument = self.channel[chan].instrument;
    }

    fn resolveOrderJump(self: *HscSource) void {
        const v = self.orderByte(self.order_pos);
        if (v & 128 == 0) return;
        var dest: u8 = if (v == song_end_marker) 0 else v -% 128;
        if (dest >= order_jump_limit) dest = 0;
        self.order_pos = dest;
        self.song_end = true;
    }

    fn advanceOrder(self: *HscSource) void {
        const prev = self.order_pos;
        self.order_pos +%= 1;
        self.resolveOrderJump();
        if (prev < order_len and self.order_pos >= order_len) self.song_end = true;
    }

    fn playRow(self: *HscSource, chip: fmt.Chip, pattern: u8) void {
        for (0..channels) |chan_usize| {
            const chan: u8 = @intCast(chan_usize);
            const pc = self.patternCell(pattern, self.row, chan) orelse continue;

            if (pc.isInstrumentSet()) {
                self.setInstrument(chip, chan, pc.effect & (instrument_count - 1));
                continue;
            }

            if (pc.note != 0) self.playNote(chip, chan, pc.note);

            if (pc.effect == 0) continue;
            if (pc.effect == 0x01) {
                self.pattern_break = true;
                continue;
            }

            const eff_op = pc.effectLo();
            const ins = self.instrument(self.channel[chan].instrument);

            switch (pc.effectHi()) {
                EffectHi.slide_up, EffectHi.slide_down => {
                    self.slideFreq(chan, eff_op + 1, pc.effect & EffectHi.slide_up != 0);
                },
                EffectHi.carrier_vol => {
                    chip.writeReg(Reg.carrier_level + op_offset[chan], eff_op << 2);
                },
                EffectHi.modulator_vol => {
                    chip.writeReg(Reg.modulator_level + op_offset[chan], eff_op << 2);
                },
                EffectHi.both_vol => {
                    const db: u8 = eff_op << 2;
                    chip.writeReg(Reg.carrier_level + op_offset[chan], db);
                    if (ins.additive()) {
                        chip.writeReg(Reg.modulator_level + op_offset[chan], db);
                    }
                },
                else => self.setSpeed(eff_op),
            }
        }

        for (0..channels) |chan_usize| {
            self.writeFreq(chip, @intCast(chan_usize));
        }
    }

    fn update(self: *HscSource, chip: fmt.Chip) bool {
        self.delay -= 1;
        if (self.delay != 0) return !self.song_end;

        const pattern = self.orderByte(self.order_pos);
        self.cur_order = self.order_pos;
        self.cur_row = self.row;
        self.cur_pattern = pattern;

        self.playRow(chip, pattern);

        self.delay = self.speed;
        if (self.pattern_break) {
            self.row = 0;
            self.pattern_break = false;
            self.advanceOrder();
        } else {
            self.row +%= 1;
            if (self.row == rows_per_pattern) {
                self.row = 0;
                self.advanceOrder();
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
        if (raw.isInstrumentSet()) {
            return .{ .kind = .set_instrument, .arg = raw.effect & (instrument_count - 1) };
        }
        if (raw.note == 0) {
            if (raw.effect == 0) return .{ .kind = .empty };
            return .{ .kind = .effect_only, .arg = raw.effect };
        }
        if (raw.note == note_off_raw) {
            return .{ .kind = .note_off, .arg = raw.effect };
        }
        const n = raw.note -% 1;
        return .{
            .kind = .note,
            .semitone = n % 12,
            .octave = n / 12,
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
        if (v >= order_end_min) v = song_end_marker;
        src.order[i] = v;
    }

    chip.writeReg(Reg.waveform_select, 0x20);
    chip.writeReg(Reg.csw_note_sel, 0x40);
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
    data[instr_bytes + 3] = 5;

    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "t.hsc", &data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) })).?;
    defer src.deinit(gpa);

    const view = src.trackerView().?;
    try std.testing.expectEqual(@as(u8, 0), view.order[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), view.order[1]);
    try std.testing.expectEqual(@as(u8, 0x90), view.order[2]);
    try std.testing.expectEqual(@as(u8, 5), view.order[3]);
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

test "hsc instrument-set with zero slide leaves the key off" {
    const Rec = struct {
        b0: [channels]u8 = @splat(0),
        a0: [channels]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg >= Reg.key_block and reg < Reg.key_block + channels) {
                self.b0[reg - Reg.key_block] = val;
            }
            if (reg >= Reg.fnum_lo and reg < Reg.fnum_lo + channels) {
                self.a0[reg - Reg.fnum_lo] = val;
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
    const a0 = rec.a0[0];

    _ = src.step(rec.chip());
    _ = src.step(rec.chip());
    try std.testing.expectEqual(a0, rec.a0[0]);
    try std.testing.expectEqual(@as(u8, 0), rec.b0[0]);
}

test "hsc instrument-set with slide rewrites the held pitch" {
    const Rec = struct {
        b0: [channels]u8 = @splat(0),
        a0: [channels]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg >= Reg.key_block and reg < Reg.key_block + channels) {
                self.b0[reg - Reg.key_block] = val;
            }
            if (reg >= Reg.fnum_lo and reg < Reg.fnum_lo + channels) {
                self.a0[reg - Reg.fnum_lo] = val;
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
    data[11] = 0x40;
    data[12 + 11] = 0x40;
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
    try std.testing.expect(rec.b0[0] & key_on_bit != 0);
}

test "hsc same instrument-set does not key off" {
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
    data[header_bytes + channels * 2 + 1] = 0;

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
    try std.testing.expect(rec.b0[0] & key_on_bit != 0);
}

test "hsc note words and 1x slides match the NEO player" {
    const Rec = struct {
        a0: u8 = 0,
        b0: u8 = 0,
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg == Reg.fnum_lo) self.a0 = val;
            if (reg == Reg.key_block) self.b0 = val;
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

    {
        var data: [header_bytes + pattern_bytes]u8 = @splat(0);
        data[instrument_count * instrument_size] = 0;
        data[header_bytes + 0] = 1;
        var rec = Rec{};
        const src = (try load(gpa, &data, .{
            .sample_rate = 44100,
            .chip = rec.chip(),
            .ext = ".hsc",
            .name = "t.hsc",
        })).?;
        defer src.deinit(gpa);
        _ = src.step(rec.chip());
        try std.testing.expectEqual(@as(u8, 0x6B), rec.a0);
        try std.testing.expectEqual(@as(u8, 0x21), rec.b0);
    }

    {
        var data: [header_bytes + pattern_bytes]u8 = @splat(0);
        data[instrument_count * instrument_size] = 0;
        data[header_bytes + 0] = 84;
        var rec = Rec{};
        const src = (try load(gpa, &data, .{
            .sample_rate = 44100,
            .chip = rec.chip(),
            .ext = ".hsc",
            .name = "t.hsc",
        })).?;
        defer src.deinit(gpa);
        _ = src.step(rec.chip());
        try std.testing.expectEqual(@as(u8, 0xAE), rec.a0);
        try std.testing.expectEqual(@as(u8, 0x3A), rec.b0);
    }

    {
        var data: [header_bytes + pattern_bytes]u8 = @splat(0);
        data[instrument_count * instrument_size] = 0;
        data[header_bytes + 0] = 1;
        data[header_bytes + 1] = 0x12;
        var rec = Rec{};
        const src = (try load(gpa, &data, .{
            .sample_rate = 44100,
            .chip = rec.chip(),
            .ext = ".hsc",
            .name = "t.hsc",
        })).?;
        defer src.deinit(gpa);
        _ = src.step(rec.chip());
        try std.testing.expectEqual(@as(u8, 0x6B + 3), rec.a0);
        try std.testing.expectEqual(@as(u8, 0x21), rec.b0);
    }
}

test "hsc init enables NOTE-SEL not CSM" {
    const Rec = struct {
        reg08: u8 = 0,
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg == Reg.csw_note_sel) self.reg08 = val;
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

    var rec = Rec{};
    const src = (try load(gpa, &data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".hsc",
        .name = "t.hsc",
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0x40), rec.reg08);
}

test "hsc 3x sets speed like Fx matching the NEO player fallthrough" {
    const Helper = struct {
        fn speedAfterEffect(effect: u8) !u8 {
            const gpa = std.testing.allocator;
            var data: [header_bytes + pattern_bytes]u8 = @splat(0);
            data[instrument_count * instrument_size] = 0;
            data[header_bytes + 1] = effect;

            var chip = opal.Opal.init(44100);
            const src = (try load(gpa, &data, .{
                .sample_rate = 44100,
                .chip = chip_adapter.fromOpal(&chip),
                .ext = ".hsc",
                .name = "t.hsc",
            })).?;
            defer src.deinit(gpa);
            _ = src.step(chip_adapter.fromOpal(&chip));
            return src.pos().?.speed;
        }
    };
    try std.testing.expectEqual(@as(u8, 3), try Helper.speedAfterEffect(0x32));
    try std.testing.expectEqual(@as(u8, 3), try Helper.speedAfterEffect(0xF2));
    try std.testing.expectEqual(@as(u8, 1), try Helper.speedAfterEffect(0x30));
    try std.testing.expectEqual(@as(u8, 16), try Helper.speedAfterEffect(0x3F));
    try std.testing.expectEqual(@as(u8, 5), try Helper.speedAfterEffect(0x44));
    try std.testing.expectEqual(@as(u8, 2), try Helper.speedAfterEffect(0x81));
    try std.testing.expectEqual(@as(u8, 8), try Helper.speedAfterEffect(0x07));
    try std.testing.expectEqual(@as(u8, 2), try Helper.speedAfterEffect(0x13));
    try std.testing.expectEqual(@as(u8, 2), try Helper.speedAfterEffect(0x01));
    try std.testing.expectEqual(@as(u8, 4), try Helper.speedAfterEffect(0x03));
    try std.testing.expectEqual(@as(u8, 3), try Helper.speedAfterEffect(0x52));
    try std.testing.expectEqual(@as(u8, 9), try Helper.speedAfterEffect(0x68));
    try std.testing.expectEqual(@as(u8, 2), try Helper.speedAfterEffect(0xD1));
}

test "hsc KSL xor is carrier always and modulator only when additive" {
    const Rec = struct {
        lvl: [0x56]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg < self.lvl.len) self.lvl[reg] = val;
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

    {
        var data: [header_bytes + pattern_bytes]u8 = @splat(0);
        data[instrument_count * instrument_size] = 0;
        data[2] = 0x56;
        data[3] = 0xC0;
        data[8] = 0;
        var rec = Rec{};
        const src = (try load(gpa, &data, .{
            .sample_rate = 44100,
            .chip = rec.chip(),
            .ext = ".hsc",
            .name = "t.hsc",
        })).?;
        defer src.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0xD6), rec.lvl[Reg.carrier_level]);
        try std.testing.expectEqual(@as(u8, 0xC0), rec.lvl[Reg.modulator_level]);
    }

    {
        var data: [header_bytes + pattern_bytes]u8 = @splat(0);
        data[instrument_count * instrument_size] = 0;
        data[2] = 0x56;
        data[3] = 0xC0;
        data[8] = 1;
        var rec = Rec{};
        const src = (try load(gpa, &data, .{
            .sample_rate = 44100,
            .chip = rec.chip(),
            .ext = ".hsc",
            .name = "t.hsc",
        })).?;
        defer src.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0xD6), rec.lvl[Reg.carrier_level]);
        try std.testing.expectEqual(@as(u8, 0x40), rec.lvl[Reg.modulator_level]);
    }
}

test "hsc 6x sets speed and leaves feedback alone" {
    const Rec = struct {
        c0: [channels]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg >= Reg.feedback and reg < Reg.feedback + channels) {
                self.c0[reg - Reg.feedback] = val;
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
    data[8] = 0x01;
    data[header_bytes + 1] = 0x68;

    var rec = Rec{};
    const src = (try load(gpa, &data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".hsc",
        .name = "t.hsc",
    })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x01), rec.c0[0]);
    try std.testing.expectEqual(@as(u8, 9), src.pos().?.speed);
}

test "hsc An replaces carrier KSL bits" {
    const Rec = struct {
        lvl: u8 = 0,
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg == Reg.carrier_level) self.lvl = val;
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
    data[2] = 0x50;
    data[header_bytes + 1] = 0xA4;

    var rec = Rec{};
    const src = (try load(gpa, &data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".hsc",
        .name = "t.hsc",
    })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x10), rec.lvl);
}

test "ab render fmtrk2 wav" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().access(io, "tmp/hsc-ab/render.flag", .{}) catch return error.SkipZigTest;

    const path = "tmp/fmtrk2.hsc";
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch return error.SkipZigTest;
    defer gpa.free(data);

    const LogChip = struct {
        opal: *opal.Opal,
        gpa: std.mem.Allocator,
        events: std.ArrayList(u8) = .empty,
        frames: u64 = 0,

        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.opal.writeRegBuffered(reg, val);
            var line_buf: [48]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{d} {x:0>2} {x:0>2}\n", .{ self.frames, reg, val }) catch return;
            self.events.appendSlice(self.gpa, line) catch {};
        }
        fn flush(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.opal.flushWriteBuf();
        }
        const vtable = fmt.Chip.VTable{ .writeReg = write, .flush = flush };
        fn chip(self: *@This()) fmt.Chip {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    const sample_rate: u32 = 44100;
    const seconds: u32 = 45;
    var chip_store = try gpa.create(opal.Opal);
    defer gpa.destroy(chip_store);
    chip_store.* = opal.Opal.init(@intCast(sample_rate));
    var log = LogChip{ .opal = chip_store, .gpa = gpa };
    defer log.events.deinit(gpa);
    const chip = log.chip();

    var src = (try fmt.load(gpa, path, data, .{
        .sample_rate = sample_rate,
        .chip = chip,
        .ext = ".hsc",
        .name = "fmtrk2.hsc",
    })).?;
    defer src.deinit(gpa);

    const frames: usize = @as(usize, sample_rate) * seconds;
    const pcm = try gpa.alloc(i16, frames * 2);
    defer gpa.free(pcm);

    var wait: u64 = 0;
    var written: usize = 0;
    while (written < frames) {
        if (wait == 0) {
            const r = src.step(chip);
            wait = r.frames;
            if (r.frames == 0) break;
        }
        const n: usize = @intCast(@min(wait, frames - written));
        chip_store.render(pcm[written * 2 .. (written + n) * 2]);
        wait -= n;
        written += n;
        log.frames += n;
    }

    var hdr: [44]u8 = undefined;
    const bytes: u32 = @intCast(written * 4);
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + bytes, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], 2, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], sample_rate * 4, .little);
    std.mem.writeInt(u16, hdr[32..34], 4, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], bytes, .little);

    var file = try std.Io.Dir.cwd().createFile(io, "tmp/hsc-ab/fmtrk2-sehnsucht.wav", .{});
    defer file.close(io);
    try file.writePositionalAll(io, &hdr, 0);
    try file.writePositionalAll(io, std.mem.sliceAsBytes(pcm[0 .. written * 2]), hdr.len);

    var opl = try std.Io.Dir.cwd().createFile(io, "tmp/hsc-ab/fmtrk2-sehnsucht.opl.txt", .{});
    defer opl.close(io);
    try opl.writePositionalAll(io, log.events.items, 0);
}
