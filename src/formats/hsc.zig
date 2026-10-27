//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");

const channels = 9;
pub const format_name = "HSC";
pub const extensions = &.{ ".hsc", ".hsp" };
pub const visualizer_name = "tracker";
pub const view_caps = view.ViewCaps{ .pattern = true, .order = true, .instruments = true };
const rows_per_pattern = 64;
const instrument_count = 128;
const instrument_size = 12;
const order_len = 51;
const max_patterns = 50;
const header_bytes = instrument_count * instrument_size + order_len;
const pattern_bytes = rows_per_pattern * channels * 2;
const min_file_bytes = header_bytes + pattern_bytes;
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
    const slide_up: u8 = 0x10;
    const slide_down: u8 = 0x20;
    const carrier_vol: u8 = 0xa0;
    const modulator_vol: u8 = 0xb0;
    const both_vol: u8 = 0xc0;
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
    gate: bool = false,
    note: u8 = 0xFF,
    vol_car: u8 = 0,
    vol_mod: u8 = 0,
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
    order: [order_len]u8 = @splat(song_end_marker),
    file: []const u8,
    num_patterns: u8,
    channel: [channels]Channel = @splat(.{}),
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
    format_name: []const u8 = "HSC",
    used_instruments: u128 = std.math.maxInt(u128),

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
        chip.writeReg(Reg.fnum_lo + chan, lo +% ins.slide);
        chip.writeReg(Reg.key_block + chan, b0);
        self.channel[chan].gate = b0 & key_on_bit != 0;
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
        self.channel[chan].vol_car = carrier_vol;
        chip.writeReg(Reg.carrier_level + op, carrier_vol | ins.carrierKslBits());
        if (ins.additive()) {
            self.channel[chan].vol_mod = modulator_vol;
            chip.writeReg(Reg.modulator_level + op, modulator_vol | ins.modulatorKslBits());
        } else {
            self.channel[chan].vol_mod = ins.modulatorLevelField();
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
        self.channel[chan].gate = false;
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
            self.channel[chan].note = 0xFF;
            return;
        }
        const n = note -% 1;
        chip.writeReg(Reg.key_block + chan, 0);
        self.channel[chan].freq = noteWord(n);
        self.channel[chan].dirty = true;
        self.channel[chan].note = n;
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
                    const db: u8 = eff_op << 2;
                    self.channel[chan].vol_car = db;
                    chip.writeReg(Reg.carrier_level + op_offset[chan], db);
                },
                EffectHi.modulator_vol => {
                    const db: u8 = eff_op << 2;
                    self.channel[chan].vol_mod = db;
                    chip.writeReg(Reg.modulator_level + op_offset[chan], db);
                },
                EffectHi.both_vol => {
                    const db: u8 = eff_op << 2;
                    self.channel[chan].vol_car = db;
                    chip.writeReg(Reg.carrier_level + op_offset[chan], db);
                    if (ins.additive()) {
                        self.channel[chan].vol_mod = db;
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
    pub fn info(self: *HscSource) fmt.TrackInfo {
        return .{
            .format_name = self.format_name,
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
        };
    }

    pub fn playhead(self: *HscSource) view.Playhead {
        return .{
            .order = self.cur_order,
            .row = self.cur_row,
            .pattern = self.cur_pattern,
            .speed = @truncate(self.speed),
            .last_instrument = self.last_instrument,
            .flags = .{
                .has_order = true,
                .has_row = true,
                .has_pattern = true,
                .has_speed = true,
            },
        };
    }

    pub fn patternView(self: *HscSource) view.PatternView {
        return .{
            .ctx = self,
            .grid = .shared_pattern,
            .occupancy = .packed_event,
            .columns = &fmt.hsc_columns,
            .effect_style = .nibble,
            .cell_template = fmt.hsc_cell_template,
            .channels = channels,
            .rows_per_pattern = rows_per_pattern,
            .num_patterns = self.num_patterns,
            .rate_text = "18.2 Hz",
            .cell = viewCell,
            .effectLexicon = hscLexicon,
        };
    }

    fn orderDisplayLen(self: *const HscSource) u16 {
        for (self.order, 0..) |v, i| {
            if (v == song_end_marker) return @intCast(i);
        }
        return order_len;
    }

    pub fn orderView(self: *HscSource) view.OrderView {
        return .{
            .ctx = self,
            .len = self.orderDisplayLen(),
            .kind = .shared_index,
            .entry = hscOrder,
        };
    }

    pub fn instrumentBank(self: *HscSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = instrument_count,
            .get = hscInstrument,
        };
    }

    fn viewCell(ptr: *anyopaque, pattern: u16, row: u16, chan: u16) view.Cell {
        const self: *HscSource = @ptrCast(@alignCast(ptr));
        if (pattern > 255 or row > 255 or chan > 255) return .{};
        const raw = self.patternCell(@intCast(pattern), @intCast(row), @intCast(chan)) orelse return .{};
        if (raw.isInstrumentSet()) {
            return .{ .instrument = raw.effect & (instrument_count - 1) };
        }
        if (raw.note == 0) {
            if (raw.effect == 0) return .{};
            return .{ .effects = .{ .{ .cmd = raw.effect, .param = 0 }, .{} } };
        }
        if (raw.note == note_off_raw) {
            return .{ .note = .off, .effects = .{ .{ .cmd = raw.effect, .param = 0 }, .{} } };
        }
        const n = raw.note -% 1;
        return .{
            .note = .{ .pitch = .{ .semitone = n % 12, .octave = n / 12 } },
            .effects = .{ .{ .cmd = raw.effect, .param = 0 }, .{} },
        };
    }

    fn hscLexicon(_: *anyopaque, cmd: u8, _: u16) view.EffectDesc {
        if (cmd == 0) return .{};
        if (cmd == 0x01) return .{ .text = "!" };
        return switch (cmd & 0xf0) {
            0x10, 0x20, 0xa0, 0xb0, 0xc0 => .{},
            else => .{ .text = "s" },
        };
    }

    pub fn channelState(self: *HscSource) view.ChannelStateBank {
        var bank = view.ChannelStateBank{ .channels = channels };
        for (0..channels) |i| {
            const ch = self.channel[i];
            bank.slots[i] = .{
                .instrument = if (ch.instrument == 0xFF) view.instrument_none else ch.instrument,
                .note_code = ch.note,
                .keyed = ch.gate,
                .vol_mod = ch.vol_mod,
                .vol_car = ch.vol_car,
            };
        }
        return bank;
    }

    fn hscOrder(ptr: *anyopaque, index: u16) view.OrderEntry {
        const self: *HscSource = @ptrCast(@alignCast(ptr));
        if (index >= order_len) return .{ .kind = .end };
        const entry = self.order[index];
        if (entry == 0xff or entry >= 0xb2) return .{ .kind = .end };
        if (entry & 0x80 != 0) {
            var dest: u16 = entry & 0x7f;
            if (dest >= order_jump_limit) dest = 0;
            return .{ .kind = .jump, .jump_to = dest };
        }
        return .{ .kind = .pattern, .pattern = entry };
    }

    fn instrumentIsUsed(self: *const HscSource, index: u8) bool {
        const bit: u7 = @truncate(index);
        return self.used_instruments & (@as(u128, 1) << bit) != 0;
    }

    fn markUsedInstruments(self: *HscSource) void {
        var bits: u128 = 0;
        for (0..channels) |i| bits |= @as(u128, 1) << @intCast(i);
        const stored_patterns = @min(@divCeil(self.file.len -| header_bytes, pattern_bytes), max_patterns);
        var p: u8 = 0;
        while (p < stored_patterns) : (p += 1) {
            var row: u8 = 0;
            while (row < rows_per_pattern) : (row += 1) {
                var ch: u8 = 0;
                while (ch < channels) : (ch += 1) {
                    const pc = self.patternCell(p, row, ch) orelse continue;
                    if (pc.isInstrumentSet()) {
                        bits |= @as(u128, 1) << @intCast(pc.effect & (instrument_count - 1));
                    }
                }
            }
        }
        self.used_instruments = bits;
    }

    fn hscInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
        if (index > 255) return .{};
        const self: *HscSource = @ptrCast(@alignCast(ptr));
        if (!self.instrumentIsUsed(@intCast(index))) return .{};
        const ins = self.instrument(@intCast(index));
        return .{
            .patch = .{ .opl_2op = .{
                .ops = .{
                    fmt.operatorParams(ins.modulator_char, ins.modulator_level, ins.modulator_ad, ins.modulator_sr, ins.modulator_wave),
                    fmt.operatorParams(ins.carrier_char, ins.carrier_level, ins.carrier_ad, ins.carrier_sr, ins.carrier_wave),
                    .{},
                    .{},
                },
                .op_count = 2,
                .feedback = @truncate((ins.feedback_conn >> 1) & 7),
                .additive = ins.additive(),
                .fine_tune = @intCast(ins.slide),
            } },
        };
    }

    pub fn deinit(self: *HscSource, gpa: std.mem.Allocator) void {
        gpa.free(self.file);
        gpa.destroy(self);
    }
};

const PackedRun = extern struct {
    count: u8,
    value: u8,

    comptime {
        if (@sizeOf(PackedRun) != 2) @compileError("HSP run must be two bytes");
    }
};

fn unpackHsp(gpa: std.mem.Allocator, data: []const u8) error{ OutOfMemory, InvalidHsp }!?[]u8 {
    if (data.len < @sizeOf(u16)) return null;
    const orgsize = fmt.readU16Le(data, 0);
    if (orgsize == 0 or orgsize > max_file_bytes) return null;

    const src = data[@sizeOf(u16)..];
    const out = try gpa.alloc(u8, orgsize);
    errdefer gpa.free(out);

    var j: usize = 0;
    var i: usize = 0;
    while (i + 1 < src.len and j < orgsize) : (i += 2) {
        const run = PackedRun{ .count = src[i], .value = src[i + 1] };
        const n: usize = run.count;
        const room = orgsize - j;
        const take = @min(n, room);
        @memset(out[j..][0..take], run.value);
        j += take;
    }

    if (j == 0) return error.InvalidHsp;
    if (j < orgsize) return try gpa.realloc(out, j);
    return out;
}

fn loadUnpacked(
    gpa: std.mem.Allocator,
    owned: []u8,
    ctx: fmt.LoadContext,
    label: []const u8,
) anyerror!?fmt.MusicSource {
    if (owned.len < min_file_bytes or owned.len > max_file_bytes) {
        gpa.free(owned);
        return null;
    }
    const raw_patterns = (owned.len - header_bytes) / pattern_bytes;
    if (raw_patterns == 0) {
        gpa.free(owned);
        return null;
    }
    const num_patterns: u8 = @intCast(@min(raw_patterns, max_patterns));

    const src = gpa.create(HscSource) catch |err| {
        gpa.free(owned);
        return err;
    };
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .file = owned,
        .num_patterns = num_patterns,
        .format_name = label,
    };

    const instr_bytes = instrument_count * instrument_size;
    @memcpy(std.mem.asBytes(&src.instruments)[0..instr_bytes], owned[0..instr_bytes]);
    for (&src.instruments) |*ins| ins.applyLoadFixups();

    for (0..order_len) |i| {
        var v = owned[instr_bytes + i];
        if (v >= order_end_min) v = song_end_marker;
        src.order[i] = v;
    }

    const chip = ctx.chip;
    chip.writeReg(Reg.waveform_select, 0x20);
    chip.writeReg(Reg.csw_note_sel, 0x40);
    chip.writeReg(Reg.rhythm, 0x00);
    for (0..channels) |i| {
        const ch: u8 = @intCast(i);
        src.setInstrument(chip, ch, ch);
    }
    src.markUsedInstruments();
    chip.flush();

    return fmt.MusicSource.init(src, visualizer_name);
}

fn nameForExt(ext: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(ext, ".hsp")) "HSP" else "HSC";
}

pub fn labelForPath(path: []const u8) []const u8 {
    return nameForExt(fmt.extensionOf(path));
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (std.ascii.eqlIgnoreCase(ctx.ext, ".hsp")) {
        const unpacked = (try unpackHsp(gpa, data)) orelse return null;
        return (try loadUnpacked(gpa, unpacked, ctx, nameForExt(ctx.ext))) orelse error.InvalidHsp;
    }
    if (data.len < min_file_bytes or data.len > max_file_bytes) return null;
    const copy = try gpa.dupe(u8, data);
    return loadUnpacked(gpa, copy, ctx, nameForExt(ctx.ext));
}

pub const format = fmt.Format.init(@This());

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

    const ov = src.views().order.?;
    try std.testing.expectEqual(.pattern, ov.entry(ov.ctx, 0).kind);
    try std.testing.expectEqual(@as(u16, 0), ov.entry(ov.ctx, 0).pattern);
    try std.testing.expectEqual(.end, ov.entry(ov.ctx, 1).kind);
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

    try std.testing.expect(src.views().pattern != null);
    try std.testing.expect(src.playhead() != null);
    try std.testing.expect(src.channelState() != null);
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

    const c0 = HscSource.viewCell(ptr, 0, 0, 0);
    try std.testing.expectEqual(view.Note{ .pitch = .{ .semitone = 3, .octave = 4 } }, c0.note);
    try std.testing.expectEqual(@as(u8, 0x12), c0.effects[0].cmd);

    const c1 = HscSource.viewCell(ptr, 0, 0, 1);
    try std.testing.expect(view.packedEventIsInstrumentSet(c1));
    try std.testing.expectEqual(@as(u16, 5), c1.instrument.?);

    const c2 = HscSource.viewCell(ptr, 0, 0, 2);
    try std.testing.expectEqual(view.Note.off, c2.note);

    const c3 = HscSource.viewCell(ptr, 0, 0, 3);
    try std.testing.expectEqual(view.Note.none, c3.note);
    try std.testing.expectEqual(@as(u8, 0xF3), c3.effects[0].cmd);

    const c4 = HscSource.viewCell(ptr, 0, 0, 4);
    try std.testing.expectEqual(view.Note.none, c4.note);
    try std.testing.expect(c4.instrument == null);
    try std.testing.expectEqual(@as(u8, 0), c4.effects[0].cmd);

    const oob = HscSource.viewCell(ptr, 49, 63, 8);
    try std.testing.expectEqual(view.Note.none, oob.note);
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
    const ins = HscSource.hscInstrument(&src, 7);
    const patch = ins.opl();
    try std.testing.expect(patch.ops[1].tremolo);
    try std.testing.expect(patch.ops[1].vibrato);
    try std.testing.expect(patch.ops[1].sustaining);
    try std.testing.expect(!patch.ops[1].ksr);
    try std.testing.expectEqual(@as(u4, 1), patch.ops[1].mult);
    try std.testing.expectEqual(@as(u2, 2), patch.ops[1].ksl);
    try std.testing.expectEqual(@as(u6, 10), patch.ops[1].level);
    try std.testing.expectEqual(@as(u4, 15), patch.ops[1].attack);
    try std.testing.expectEqual(@as(u4, 2), patch.ops[1].decay);
    try std.testing.expectEqual(@as(u4, 7), patch.ops[1].sustain);
    try std.testing.expectEqual(@as(u4, 9), patch.ops[1].release);
    try std.testing.expectEqual(@as(u3, 2), patch.ops[1].wave);
    try std.testing.expect(!patch.ops[0].tremolo);
    try std.testing.expect(patch.ops[0].ksr);
    try std.testing.expectEqual(@as(u4, 5), patch.ops[0].mult);
    try std.testing.expectEqual(@as(u6, 63), patch.ops[0].level);
    try std.testing.expectEqual(@as(u3, 3), patch.ops[0].wave);
    try std.testing.expectEqual(@as(u3, 5), patch.feedback);
    try std.testing.expect(patch.additive);
}

test "hsc instrument set only in a trailing partial pattern plays and is listed as used" {
    const gpa = std.testing.allocator;
    var data: [header_bytes + pattern_bytes + 600]u8 = @splat(0);
    const order_at = instrument_count * instrument_size;
    data[order_at + 0] = 0;
    data[order_at + 1] = 1;
    data[order_at + 2] = song_end_marker;
    data[header_bytes + pattern_bytes + 0] = 0x80;
    data[header_bytes + pattern_bytes + 1] = 20;

    const src = (try load(gpa, &data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".hsc",
        .name = "t.hsc",
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 1), src.views().pattern.?.num_patterns);

    for (0..130) |_| _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 20), src.channelState().?.slots[0].instrument);

    const bank = src.views().instruments.?;
    try std.testing.expect(bank.get(bank.ctx, 20).patch == .opl_2op);
    try std.testing.expect(bank.get(bank.ctx, 21).patch == .empty);
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
    try std.testing.expectEqualStrings("HSC", src.info().format_name);
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
    try std.testing.expect(src.channelState().?.slots[0].keyed);
    const a0 = rec.a0[0];

    _ = src.step(rec.chip());
    _ = src.step(rec.chip());
    try std.testing.expectEqual(a0, rec.a0[0]);
    try std.testing.expectEqual(@as(u8, 0), rec.b0[0]);
    try std.testing.expect(!src.channelState().?.slots[0].keyed);
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
            return @intCast(src.playhead().?.speed);
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
    try std.testing.expectEqual(@as(u8, 9), src.playhead().?.speed);
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

fn packHsp(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var size: [2]u8 = undefined;
    std.mem.writeInt(u16, &size, @intCast(plain.len), .little);
    try out.appendSlice(gpa, &size);
    var i: usize = 0;
    while (i < plain.len) {
        const v = plain[i];
        var n: u8 = 1;
        while (i + @as(usize, n) < plain.len and plain[i + n] == v and n < 255) n += 1;
        try out.append(gpa, n);
        try out.append(gpa, v);
        i += n;
    }
    return out.toOwnedSlice(gpa);
}

fn loadHsp(gpa: std.mem.Allocator, blob: []const u8) !fmt.MusicSource {
    return (try load(gpa, blob, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".hsp",
        .name = "t.hsp",
    })) orelse error.TestUnexpectedResult;
}

test "hsp pack then unpack restores the bytes" {
    const gpa = std.testing.allocator;
    const plain = [_]u8{ 0, 0, 0, 1, 1, 2, 255, 255, 255 };
    const blob = try packHsp(gpa, &plain);
    defer gpa.free(blob);
    const out = (try unpackHsp(gpa, blob)).?;
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &plain, out);
}

test "hsp loads a packed HSC as HSP" {
    const gpa = std.testing.allocator;
    var plain: [min_file_bytes]u8 = @splat(0);
    const blob = try packHsp(gpa, &plain);
    defer gpa.free(blob);
    const src = try loadHsp(gpa, blob);
    defer src.deinit(gpa);

    const inf = src.info();
    try std.testing.expectEqualStrings("HSP", inf.format_name);
    try std.testing.expect(inf.title == null);
    try std.testing.expectEqualStrings(visualizer_name, inf.visualizer);
    try std.testing.expect(src.views().pattern != null);
    try std.testing.expect(src.playhead() != null);
}

test "hsc playlist labels follow the path extension" {
    try std.testing.expectEqualStrings("HSC", labelForPath("tune.hsc"));
    try std.testing.expectEqualStrings("HSP", labelForPath("tune.hsp"));
    try std.testing.expectEqualStrings("HSP", labelForPath("http://x/SATNIGHT.HSP"));
}
