//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
// Reality Adlib Tracker decoder. File layout and playback follow the
// public-domain RAD player by Shayde/Reality (AdPlug rad2).

const std = @import("std");
const opal = @import("opal");

const cp437 = @import("../cp437.zig");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");

pub const format_name = "RAD";
pub const extensions = &.{".rad"};
pub const visualizer_name = "tracker";
pub const view_caps = view.ViewCaps{ .pattern = true, .order = true, .instruments = true };

const rad_columns = [_]view.ColumnId{ .note, .instrument, .effect, .extra };
const rad_cell_template = view.CellTemplate{ .width = 12, .note_w = 3, .inst_w = 2, .fx_w = 3, .extra_w = 1 };

const magic = "RAD by REALiTY!!";
const channels = 9;
const rows_per_pattern = 64;
const max_instruments_v1 = 31;
const max_instruments = 127;
const max_patterns_v1 = 32;
const max_patterns = 100;
const max_order = 128;

const note_fnum = [_]u16{ 0x16b, 0x181, 0x198, 0x1b0, 0x1ca, 0x1e5, 0x202, 0x220, 0x241, 0x263, 0x287, 0x2ae };

const op_offsets = [_][2]u8{
    .{ 0x03, 0x00 },
    .{ 0x04, 0x01 },
    .{ 0x05, 0x02 },
    .{ 0x0b, 0x08 },
    .{ 0x0c, 0x09 },
    .{ 0x0d, 0x0a },
    .{ 0x13, 0x10 },
    .{ 0x14, 0x11 },
    .{ 0x15, 0x12 },
};

const primary_channels = [_]u16{ 0, 1, 2, 0x100, 0x101, 0x102, 6, 7, 8 };
const secondary_channels = [_]u16{ 3, 4, 5, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108 };
const carriers = [_][4]bool{
    .{ true, false, false, false },
    .{ true, true, false, false },
    .{ true, false, false, false },
    .{ true, false, false, true },
    .{ true, false, true, false },
    .{ true, false, true, true },
    .{ true, true, true, true },
};

const Effect = enum(u8) {
    none = 0,
    portamento_up = 1,
    portamento_down = 2,
    tone_slide = 3,
    tone_vol_slide = 5,
    vol_slide = 0x0a,
    set_vol = 0x0c,
    jump_to_line = 0x0d,
    set_speed = 0x0f,
    ignore_transpose = 'I' - 55,
    multiplier = 'M' - 55,
    riff = 'R' - 55,
    transpose = 'T' - 55,
    feedback = 'U' - 55,
    operator_volume = 'V' - 55,
    _,
};

const Instrument = struct {
    algorithm: u8 = 0,
    feedback: u8 = 0,
    second_feedback: u8 = 0,
    panning: [2]u2 = .{ 0, 0 },
    detune: u8 = 0,
    riff_speed: u8 = 0,
    riff: []const Line = &.{},
    volume: u8 = 0,
    ops: [4][5]u8 = @splat(@splat(0)),
    midi_program: u8 = 0,
    name_buf: [255 * cp437.max_utf8_per_byte]u8 = @splat(0),
    name_len: u16 = 0,
};

const Effects = struct {
    port_slide: i8 = 0,
    vol_slide: i8 = 0,
    tone_slide_freq: u16 = 0,
    tone_slide_oct: u8 = 0,
    tone_slide_speed: u8 = 0,
    tone_slide_dir: i8 = 0,

    fn reset(self: *Effects) void {
        self.port_slide = 0;
        self.vol_slide = 0;
        self.tone_slide_dir = 0;
    }
};

const Channel = struct {
    instrument: u8 = 0,
    last_used: u8 = 0,
    volume: u8 = 64,
    key_on: bool = false,
    keyed: bool = false,
    key_off: bool = false,
    curr_freq: u16 = 0,
    curr_octave: u8 = 0,
    fx: Effects = .{},
    riff: Riff = .{},
    instrument_riff: Riff = .{},
};

const Riff = struct {
    lines: []const Line = &.{},
    row: u8 = 0,
    speed: u8 = 0,
    remaining: u8 = 0,
    note: u8 = 12,
    octave: u8 = 3,
    last_instrument: u8 = 0,
    fx: Effects = .{},
};

const NoteSource = enum { pattern, riff, instrument_riff };

const Cell = struct {
    note: u8 = 0,
    octave: u8 = 0,
    instrument: u8 = 0,
    effect: u8 = 0,
    param: u8 = 0,
    retrigger: bool = false,
};

const Line = struct {
    row: u8,
    cells: [channels]Cell,
    present: u9 = 0,
};

const Pattern = struct {
    lines: []Line,
};

const RadSource = struct {
    sample_rate: u32,
    frac: u32 = 0,
    tick_num: u32,
    tick_den: u32,
    version: u8,
    speed: u8,
    speed_cnt: u8 = 1,
    order_list: []u8,
    order_pos: u8 = 0,
    line: u8 = 0,
    line_jump: i16 = -1,
    patterns: []Pattern,
    instruments: []Instrument,
    instrument_count: u8,
    description: ?[]const u8,
    title_embedded: bool,
    channels_state: [channels]Channel = @splat(.{}),
    regs: [512]u8 = @splat(0),
    riffs: [90][]const Line = @splat(&.{}),
    entrances: u8 = 0,
    view_cells: []Cell,
    view_order: []u8,
    num_patterns: u8,
    song_end: bool = false,
    visited_orders: std.bit_set.Static(max_order) = .empty,
    cur_order: u8 = 0,
    cur_row: u8 = 0,
    cur_pattern: u8 = 0,
    last_instrument: u8 = 0,
    owned_lines: []Line,
    bpm: ?u16 = null,

    fn write(self: *RadSource, chip: fmt.Chip, reg: u16, val: u8) void {
        chip.writeReg(reg, val);
        self.regs[reg] = val;
    }

    fn channelOffset(self: *const RadSource, ch: u8) u16 {
        return if (self.version >= 2) secondary_channels[ch] else ch;
    }

    fn operatorOffset(self: *const RadSource, ch: u8, op: usize) u16 {
        if (self.version < 2) return op_offsets[ch][op];
        const channel = if (op < 2) secondary_channels[ch] else primary_channels[ch];
        return (channel & 0x100) + ((channel & 15) / 3) * 8 + (channel & 15) % 3 + (if (op % 2 == 0) @as(u16, 3) else 0);
    }

    fn loadInstrument(self: *RadSource, chip: fmt.Chip, ch: u8, inst: *const Instrument) void {
        const alg = inst.algorithm;
        if (alg >= 7) return;
        self.channels_state[ch].volume = inst.volume;
        if (self.version >= 2) {
            if (ch < 6) {
                const mask = @as(u8, 1) << @intCast(ch);
                self.write(chip, 0x104, (self.regs[0x104] & ~mask) | (if (alg == 2 or alg == 3) mask else 0));
            }
            self.write(chip, 0xc0 + primary_channels[ch], (@as(u8, inst.panning[1] ^ 3) << 4) | (inst.second_feedback << 1) | @intFromBool(alg == 3 or alg == 5 or alg == 6));
        }
        self.write(chip, 0xc0 + self.channelOffset(ch), (@as(u8, inst.panning[0] ^ 3) << 4) | (inst.feedback << 1) | @intFromBool(alg == 1 or alg == 6));
        for (0..(if (self.version >= 2) @as(usize, 4) else 2)) |op_i| {
            const op = if (alg < 2 and op_i >= 2) [5]u8{ 0, 0x3f, 0, 0xf0, 0 } else inst.ops[op_i];
            const reg = self.operatorOffset(ch, op_i);
            var vol: u16 = ~op[1] & 0x3f;
            if (carriers[alg][op_i]) vol = vol * inst.volume / 64;
            self.write(chip, 0x20 + reg, op[0]);
            self.write(chip, 0x40 + reg, (op[1] & 0xc0) | @as(u8, @truncate((vol ^ 0x3f) & 0x3f)));
            self.write(chip, 0x60 + reg, op[2]);
            self.write(chip, 0x80 + reg, op[3]);
            self.write(chip, 0xe0 + reg, op[4]);
        }
    }

    fn setVolume(self: *RadSource, chip: fmt.Chip, ch: u8, vol_in: u8) void {
        const vol: u8 = @min(vol_in, 64);
        self.channels_state[ch].volume = vol;
        const inst_i = self.channels_state[ch].instrument;
        if (inst_i == 0 or inst_i > self.instruments.len) return;
        const inst = &self.instruments[inst_i - 1];
        if (inst.algorithm >= 7) return;
        for (0..(if (self.version >= 2) @as(usize, 4) else 2)) |op_i| {
            if (!carriers[inst.algorithm][op_i]) continue;
            const op = inst.ops[op_i];
            const opvol: u8 = @truncate((@as(u16, (~op[1] & 0x3f)) * vol / 64) ^ 0x3f);
            const reg = 0x40 + self.operatorOffset(ch, op_i);
            self.write(chip, reg, (self.regs[reg] & 0xc0) | (opvol & 0x3f));
        }
    }

    fn playNoteOpl(self: *RadSource, chip: fmt.Chip, ch: u8, octave: u8, note: u8) void {
        var cs = &self.channels_state[ch];
        const offset = self.channelOffset(ch);
        if (cs.key_off) {
            cs.key_off = false;
            cs.keyed = false;
            self.write(chip, 0xb0 + offset, self.regs[0xb0 + offset] & ~@as(u8, 0x20));
            if (self.version >= 2) {
                const primary = primary_channels[ch];
                self.write(chip, 0xb0 + primary, self.regs[0xb0 + primary] & ~@as(u8, 0x20));
            }
        }
        if (note == 0 or note > 12) return;
        const freq = note_fnum[note - 1];
        cs.curr_freq = freq;
        cs.curr_octave = octave;
        if (cs.key_on) {
            cs.key_on = false;
            cs.keyed = true;
        }
        const keybit: u8 = if (cs.keyed) 0x20 else 0;
        const inst: Instrument = if (cs.instrument > 0 and cs.instrument <= self.instruments.len) self.instruments[cs.instrument - 1] else .{};
        const upper = freq + (inst.detune + 1) / 2;
        const lower = freq - inst.detune / 2;
        if (self.version >= 2 and inst.algorithm >= 2) self.write(chip, 0xa0 + primary_channels[ch], @truncate(lower));
        self.write(chip, 0xa0 + offset, @truncate(upper));
        if (self.version >= 2) self.write(chip, 0xb0 + primary_channels[ch], if (inst.algorithm >= 2) @as(u8, @truncate(lower >> 8)) | (octave << 2) | keybit else 0);
        self.write(chip, 0xb0 + offset, @as(u8, @truncate(upper >> 8)) | (octave << 2) | keybit);
    }

    fn portamento(self: *RadSource, chip: fmt.Chip, ch: u8, fx: *Effects, amount: i8, toneslide: bool) void {
        var cs = &self.channels_state[ch];
        var freq: i32 = cs.curr_freq;
        var oct: i32 = cs.curr_octave;
        freq += amount;
        if (freq < 0x156) {
            if (oct > 0) {
                oct -= 1;
                freq += 0x2ae - 0x156;
            } else freq = 0x156;
        } else if (freq > 0x2ae) {
            if (oct < 7) {
                oct += 1;
                freq -= 0x2ae - 0x156;
            } else freq = 0x2ae;
        }
        if (toneslide) {
            if (amount >= 0) {
                if (oct > fx.tone_slide_oct or (oct == fx.tone_slide_oct and freq >= fx.tone_slide_freq)) {
                    freq = fx.tone_slide_freq;
                    oct = fx.tone_slide_oct;
                }
            } else if (oct < fx.tone_slide_oct or (oct == fx.tone_slide_oct and freq <= fx.tone_slide_freq)) {
                freq = fx.tone_slide_freq;
                oct = fx.tone_slide_oct;
            }
        }
        cs.curr_freq = @intCast(freq);
        cs.curr_octave = @intCast(oct);
        const inst: Instrument = if (cs.instrument > 0 and cs.instrument <= self.instruments.len) self.instruments[cs.instrument - 1] else .{};
        const offsets = [_]u16{ self.channelOffset(ch), primary_channels[ch] };
        for (offsets[0..(if (self.version >= 2) @as(usize, 2) else 1)], 0..) |offset, i| {
            const f: u16 = @intCast(freq + (if (i == 0) @as(i32, (inst.detune + 1) / 2) else -@as(i32, inst.detune / 2)));
            self.write(chip, 0xa0 + offset, @truncate(f));
            self.write(chip, 0xb0 + offset, @as(u8, @truncate(f >> 8)) | (@as(u8, @intCast(oct)) << 2) | (self.regs[0xb0 + offset] & 0xe0));
        }
    }

    fn getSlideDir(self: *RadSource, ch: u8, fx: *Effects) void {
        var speed: i8 = @bitCast(fx.tone_slide_speed);
        if (speed > 0) {
            const cs = self.channels_state[ch];
            if (cs.curr_octave > fx.tone_slide_oct or
                (cs.curr_octave == fx.tone_slide_oct and cs.curr_freq > fx.tone_slide_freq))
            {
                speed = -speed;
            } else if (cs.curr_octave == fx.tone_slide_oct and cs.curr_freq == fx.tone_slide_freq) {
                speed = 0;
            }
        }
        fx.tone_slide_dir = speed;
    }

    fn playNote(self: *RadSource, chip: fmt.Chip, ch: u8, note: u8, octave: u8, inst: u8, effect: u8, param: u8, retrigger: bool, source: NoteSource, operator: usize) void {
        if (self.entrances >= 8) return;
        self.entrances += 1;
        defer self.entrances -= 1;
        var cs = &self.channels_state[ch];
        const fx, const latch = switch (source) {
            .pattern => .{ &cs.fx, &cs.last_used },
            .riff => .{ &cs.riff.fx, &cs.riff.last_instrument },
            .instrument_riff => .{ &cs.instrument_riff.fx, &cs.instrument_riff.last_instrument },
        };
        var transposing = false;

        var used = inst;
        if (retrigger and used == 0) used = latch.*;
        if (used > 0) {
            latch.* = used;
            self.last_instrument = used;
        }

        if (effect == @backingInt(Effect.tone_slide)) {
            if (note >= 1 and note <= 12) {
                fx.tone_slide_oct = octave;
                fx.tone_slide_freq = note_fnum[note - 1];
            }
            if (param != 0) fx.tone_slide_speed = param;
            self.getSlideDir(ch, fx);
            return;
        }

        if (used > 0 and used <= self.instruments.len) {
            const old = cs.instrument;
            cs.instrument = used;
            const patch = &self.instruments[used - 1];
            if (patch.algorithm == 7) return;
            self.loadInstrument(chip, ch, patch);
            cs.key_off = true;
            cs.key_on = true;
            cs.instrument_riff.fx.reset();
            if (source != .instrument_riff or old != used) {
                cs.instrument_riff.remaining = 0;
                if (patch.riff.len > 0 and patch.riff_speed > 0) {
                    cs.instrument_riff = .{ .lines = patch.riff, .speed = patch.riff_speed, .remaining = 1 };
                    if (note >= 1 and note <= 12) {
                        cs.instrument_riff.note = note;
                        cs.instrument_riff.octave = octave;
                        transposing = true;
                    }
                    self.tickRiff(chip, ch, .instrument_riff);
                }
            }
        }

        if (effect == @backingInt(Effect.riff) or effect == @backingInt(Effect.transpose)) {
            const row = param / 10;
            const column = param % 10;
            cs.riff = .{};
            if (row < 10 and column > 0) {
                const lines = self.riffs[@as(usize, row) * 9 + column - 1];
                if (lines.len > 0) {
                    cs.riff = .{ .lines = lines, .speed = self.speed, .remaining = 1 };
                    if (effect == @backingInt(Effect.transpose) and note >= 1 and note <= 12) {
                        cs.riff.note = note;
                        cs.riff.octave = octave;
                        transposing = true;
                    }
                    self.tickRiff(chip, ch, .riff);
                }
            }
        }

        if (note > 0 and !transposing and (cs.instrument == 0 or self.instruments[cs.instrument - 1].algorithm < 7)) {
            if (note == 15) {
                cs.key_off = true;
                self.playNoteOpl(chip, ch, 0, 15);
            } else if (note <= 12) {
                self.playNoteOpl(chip, ch, octave, note);
            }
        }

        switch (@as(Effect, @fromBackingInt(@intCast(effect)))) {
            .set_vol => self.setVolume(chip, ch, param),
            .set_speed => if (param != 0) {
                switch (source) {
                    .pattern => {
                        self.speed = param;
                        self.speed_cnt = param;
                    },
                    .riff, .instrument_riff => {
                        const riff = if (source == .riff) &cs.riff else &cs.instrument_riff;
                        riff.speed = param;
                        riff.remaining = param;
                    },
                }
            },
            .portamento_up => fx.port_slide = @bitCast(param),
            .portamento_down => fx.port_slide = -%@as(i8, @bitCast(param)),
            .vol_slide, .tone_vol_slide => {
                var val: i8 = @bitCast(param);
                if (val >= 50) val = -(val - 50);
                fx.vol_slide = val;
                if (effect == @backingInt(Effect.tone_vol_slide)) {
                    if (param != 0) fx.tone_slide_speed = param;
                    self.getSlideDir(ch, fx);
                }
            },
            .jump_to_line => {
                if (source == .pattern and param < rows_per_pattern) self.line_jump = param;
            },
            .multiplier, .operator_volume => if (source == .instrument_riff) {
                const reg = self.operatorOffset(ch, operator) + @as(u16, if (effect == @backingInt(Effect.multiplier)) 0x20 else 0x40);
                const mask: u8 = if (effect == @backingInt(Effect.multiplier)) 15 else 63;
                const value = if (effect == @backingInt(Effect.multiplier)) param & mask else (param & mask) ^ mask;
                self.write(chip, reg, (self.regs[reg] & ~mask) | value);
            },
            .feedback => if (source == .instrument_riff and param / 10 < 2) {
                const reg = 0xc0 + (if (param / 10 == 0) secondary_channels[ch] else primary_channels[ch]);
                self.write(chip, reg, (self.regs[reg] & 0x31) | ((param % 10 & 7) << 1));
            },
            else => {},
        }
    }

    fn tickRiff(self: *RadSource, chip: fmt.Chip, ch: u8, source: NoteSource) void {
        const riff = if (source == .riff) &self.channels_state[ch].riff else &self.channels_state[ch].instrument_riff;
        if (riff.remaining == 0) {
            riff.fx.reset();
            return;
        }
        riff.remaining -= 1;
        if (riff.remaining > 0) return;
        riff.remaining = riff.speed;
        const row = riff.row;
        riff.row += 1;
        if (riff.row >= rows_per_pattern) riff.remaining = 0;
        riff.fx.reset();
        const lines = riff.lines;
        for (lines) |line| {
            if (line.row != row) continue;
            for (line.cells, 0..) |original, column| {
                if (line.present & (@as(u9, 1) << @intCast(column)) == 0) continue;
                var cell = original;
                if (cell.note >= 1 and cell.note <= 12 and (source == .riff or cell.effect != @backingInt(Effect.ignore_transpose))) {
                    cell.octave = @intCast(std.math.clamp(@as(i16, cell.octave) + riff.octave - 3, 0, 7));
                    const note = @as(i16, cell.note) + riff.note - 12;
                    if (note < 1) {
                        cell.note = if (cell.octave > 0) @intCast(note + 12) else 1;
                        cell.octave -|= 1;
                    } else cell.note = @intCast(note);
                }
                self.playNote(chip, ch, cell.note, cell.octave, cell.instrument, cell.effect, cell.param, cell.retrigger, source, if (column > 0) (column - 1) & 3 else 0);
            }
            break;
        }
        for (lines) |line| {
            if (line.row != riff.row or line.present == 0) continue;
            const cell = line.cells[@ctz(line.present)];
            if (cell.effect == @backingInt(Effect.jump_to_line) and cell.param < rows_per_pattern) riff.row = cell.param;
            break;
        }
    }

    fn continueFx(self: *RadSource, chip: fmt.Chip, ch: u8, fx: *Effects) void {
        if (fx.port_slide != 0) self.portamento(chip, ch, fx, fx.port_slide, false);
        if (fx.vol_slide != 0) {
            const v: i16 = @as(i16, self.channels_state[ch].volume) - fx.vol_slide;
            self.setVolume(chip, ch, @intCast(std.math.clamp(v, 0, 64)));
        }
        if (fx.tone_slide_dir != 0) self.portamento(chip, ch, fx, fx.tone_slide_dir, true);
    }

    fn currentPatternIndex(self: *const RadSource) u8 {
        if (self.order_pos >= self.order_list.len) return 0;
        return self.order_list[self.order_pos] & 0x7f;
    }

    fn advanceOrder(self: *RadSource) void {
        self.order_pos += 1;
        if (self.order_pos >= self.order_list.len) {
            self.order_pos = 0;
        }
        if (self.order_list[self.order_pos] & 0x80 != 0) {
            self.order_pos = self.order_list[self.order_pos] & 0x7f;
        }
        self.song_end = self.visited_orders.isSet(self.order_pos);
        if (self.song_end) self.visited_orders = .empty;
        self.visited_orders.set(self.order_pos);
    }

    fn findLine(self: *const RadSource, pat: u8, row: u8) ?*const Line {
        if (pat >= self.patterns.len) return null;
        for (self.patterns[pat].lines) |*line| {
            if (line.row == row) return line;
            if (line.row > row) return null;
        }
        return null;
    }

    fn playLine(self: *RadSource, chip: fmt.Chip) void {
        self.speed_cnt -%= 1;
        if (self.speed_cnt != 0) return;
        self.speed_cnt = self.speed;

        for (&self.channels_state) |*cs| cs.fx.reset();
        self.line_jump = -1;

        const pat = self.currentPatternIndex();
        self.cur_order = self.order_pos;
        self.cur_row = self.line;
        self.cur_pattern = pat;

        if (self.findLine(pat, self.line)) |row_line| {
            for (row_line.cells, 0..) |cell, ch| {
                if (cell.note == 0 and cell.instrument == 0 and cell.effect == 0 and !cell.retrigger) continue;
                self.playNote(chip, @intCast(ch), cell.note, cell.octave, cell.instrument, cell.effect, cell.param, cell.retrigger, .pattern, 0);
            }
        }

        self.line += 1;
        if (self.line >= rows_per_pattern or self.line_jump >= 0) {
            self.line = if (self.line_jump >= 0) @intCast(self.line_jump) else 0;
            self.advanceOrder();
        }
    }

    pub fn step(self: *RadSource, chip: fmt.Chip) fmt.StepResult {
        if (self.version >= 2) for (0..channels) |ch| {
            self.tickRiff(chip, @intCast(ch), .instrument_riff);
            self.tickRiff(chip, @intCast(ch), .riff);
        };
        self.playLine(chip);
        for (&self.channels_state, 0..) |*channel, ch| {
            self.continueFx(chip, @intCast(ch), &channel.instrument_riff.fx);
            self.continueFx(chip, @intCast(ch), &channel.riff.fx);
            self.continueFx(chip, @intCast(ch), &channel.fx);
        }
        var done = false;
        if (self.song_end and self.speed_cnt == 1) {
            done = true;
            self.song_end = false;
        }
        return .{
            .frames = fmt.rescale(self.tick_num, self.tick_den, self.sample_rate, &self.frac),
            .done = done,
        };
    }

    pub fn info(self: *RadSource) fmt.TrackInfo {
        return .{
            .title = self.description,
            .title_embedded = self.title_embedded,
            .format_name = "RAD",
            .opl3 = self.version >= 2,
            .system = if (self.version >= 2) "OPL3" else "OPL2",
            .loop = true,
        };
    }

    pub fn playhead(self: *RadSource) view.Playhead {
        var out = view.Playhead{
            .order = self.cur_order,
            .row = self.cur_row,
            .pattern = self.cur_pattern,
            .speed = self.speed,
            .last_instrument = self.last_instrument,
            .flags = .{
                .has_order = true,
                .has_row = true,
                .has_pattern = true,
                .has_speed = true,
            },
        };
        if (self.bpm) |bpm| {
            out.bpm = bpm;
            out.flags.has_bpm = true;
        }
        return out;
    }

    pub fn patternView(self: *RadSource) view.PatternView {
        return .{
            .ctx = self,
            .grid = .shared_pattern,
            .occupancy = .independent,
            .columns = &rad_columns,
            .effect_style = .letter_param,
            .cell_template = rad_cell_template,
            .channels = channels,
            .rows_per_pattern = rows_per_pattern,
            .num_patterns = self.num_patterns,
            .cell = viewCell,
            .effectLexicon = radLexicon,
            .channelInfo = channelInfo,
        };
    }

    fn channelInfo(ptr: *anyopaque, channel: u16) view.ChannelInfo {
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (channel >= channels) return .{};
        const offset = self.channelOffset(@intCast(channel));
        return .{ .opl_voice = @intCast((offset & 15) + (offset >> 8) * 9) };
    }

    pub fn orderView(self: *RadSource) view.OrderView {
        return .{
            .ctx = self,
            .len = @intCast(self.view_order.len),
            .kind = .shared_index,
            .entry = radOrder,
        };
    }

    pub fn instrumentBank(self: *RadSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = @as(u16, self.instrument_count) + 1,
            .get = radInstrument,
        };
    }

    fn viewCell(ptr: *anyopaque, pattern: u16, row: u16, chan: u16) view.Cell {
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (pattern >= self.num_patterns or row >= rows_per_pattern or chan >= channels)
            return .{};
        const cell = self.view_cells[
            @as(usize, pattern) * rows_per_pattern * channels +
                @as(usize, row) * channels + chan
        ];
        var out: view.Cell = .{};
        if (cell.note == 15) {
            out.note = .off;
        } else if (cell.note >= 1 and cell.note <= 12) {
            out.note = .{ .pitch = .{ .semitone = cell.note - 1, .octave = cell.octave } };
        }
        if (cell.instrument != 0) out.instrument = cell.instrument;
        if (cell.effect != 0) out.effects[0] = .{ .cmd = cell.effect, .param = cell.param };
        if (cell.retrigger) out.extra = .retrigger;
        return out;
    }

    fn radOrder(ptr: *anyopaque, index: u16) view.OrderEntry {
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (index >= self.view_order.len) return .{ .kind = .end };
        const entry = self.view_order[index];
        const pat: u16 = entry & 0x7f;
        if (entry & 0x80 != 0) return .{ .kind = .jump, .jump_to = pat };
        return .{ .kind = .pattern, .pattern = pat };
    }

    fn radInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
        if (index == 0 or index > 255) return .{};
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (index == 0 or index > self.instrument_count) return .{};
        const slot = &self.instruments[index - 1];
        const midi = slot.algorithm >= 7;
        const four_op = !midi and slot.algorithm >= 2 and slot.algorithm <= 6;
        const name = if (slot.name_len != 0) slot.name_buf[0..slot.name_len] else "";
        if (midi) {
            return .{
                .name = name,
                .patch = .{ .midi = .{ .program = slot.midi_program } },
            };
        }
        const patch = view.OplPatch{
            .ops = .{
                fmt.operatorParams(slot.ops[0][0], slot.ops[0][1], slot.ops[0][2], slot.ops[0][3], slot.ops[0][4]),
                fmt.operatorParams(slot.ops[1][0], slot.ops[1][1], slot.ops[1][2], slot.ops[1][3], slot.ops[1][4]),
                fmt.operatorParams(slot.ops[2][0], slot.ops[2][1], slot.ops[2][2], slot.ops[2][3], slot.ops[2][4]),
                fmt.operatorParams(slot.ops[3][0], slot.ops[3][1], slot.ops[3][2], slot.ops[3][3], slot.ops[3][4]),
            },
            .op_count = if (four_op) 4 else 2,
            .feedback = @truncate(slot.feedback & 7),
            .feedback2 = @truncate(slot.second_feedback),
            .fine_tune = @intCast(slot.detune),
            .panning = slot.panning[0],
            .additive = std.mem.countScalar(bool, &carriers[slot.algorithm], true) > 1,
            .algorithm = slot.algorithm,
            .carrier_first = true,
        };
        return .{
            .name = name,
            .patch = if (four_op) .{ .opl_4op = patch } else .{ .opl_2op = patch },
        };
    }

    fn radLexicon(_: *anyopaque, cmd: u8, _: u16) view.EffectDesc {
        const letter: ?u8 = switch (cmd) {
            1 => '1',
            2 => '2',
            3 => '3',
            5 => '5',
            0x0a => 'A',
            0x0c => 'C',
            0x0d => 'D',
            0x0f => 'F',
            'I' - 55 => 'I',
            'M' - 55 => 'M',
            'R' - 55 => 'R',
            'T' - 55 => 'T',
            'U' - 55 => 'U',
            'V' - 55 => 'V',
            else => null,
        };
        return .{ .letter = letter };
    }

    pub fn deinit(self: *RadSource, gpa: std.mem.Allocator) void {
        gpa.free(self.view_cells);
        gpa.free(self.view_order);
        gpa.free(self.patterns);
        gpa.free(self.instruments);
        gpa.free(self.owned_lines);
        gpa.free(self.order_list);
        if (self.description) |d| gpa.free(d);
        gpa.destroy(self);
    }
};

const ParseErr = error{ InvalidRad, UnsupportedRadVersion, OutOfMemory };

const UnpackedNote = struct { done: bool, ch: u8, cell: Cell };

fn unpackNoteV1(s: *[]const u8) error{Truncated}!UnpackedNote {
    if (s.*.len < 3) return error.Truncated;
    const chanid = s.*[0];
    const note_b = s.*[1];
    const inst_eff = s.*[2];
    s.* = s.*[3..];
    var cell: Cell = .{
        .note = note_b & 0x0f,
        .octave = (note_b >> 4) & 7,
        .instrument = inst_eff >> 4,
        .effect = inst_eff & 0x0f,
    };
    if (note_b & 0x80 != 0) cell.instrument |= 16;
    if (cell.effect != 0) {
        if (s.*.len < 1) return error.Truncated;
        cell.param = s.*[0];
        s.* = s.*[1..];
    }
    return .{ .done = chanid & 0x80 != 0, .ch = chanid & 0x0f, .cell = cell };
}

fn unpackNoteV2(s: *[]const u8) error{Truncated}!UnpackedNote {
    if (s.*.len < 1) return error.Truncated;
    const chanid = s.*[0];
    s.* = s.*[1..];
    var cell: Cell = .{};
    if (chanid & 0x40 != 0) {
        if (s.*.len < 1) return error.Truncated;
        const n = s.*[0];
        s.* = s.*[1..];
        cell.note = n & 0x0f;
        cell.octave = (n >> 4) & 7;
        if (n & 0x80 != 0) cell.retrigger = true;
    }
    if (chanid & 0x20 != 0) {
        if (s.*.len < 1) return error.Truncated;
        cell.instrument = s.*[0];
        s.* = s.*[1..];
    }
    if (chanid & 0x10 != 0) {
        if (s.*.len < 2) return error.Truncated;
        cell.effect = s.*[0];
        cell.param = s.*[1];
        s.* = s.*[2..];
    }
    return .{ .done = chanid & 0x80 != 0, .ch = chanid & 0x0f, .cell = cell };
}

fn appendPatternLines(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    data: []const u8,
    version: u8,
    single_channel: bool,
) ParseErr![]Line {
    const start = lines.items.len;
    var s = data;

    if (version >= 2) {
        if (s.len < 2) return error.InvalidRad;
        const size: usize = std.mem.readInt(u16, s[0..2], .little);
        if (2 + size > s.len) return error.InvalidRad;
        s = s[2 .. 2 + size];
    }

    while (s.len > 0) {
        const linedef = s[0];
        s = s[1..];
        const row = linedef & 0x7f;
        if (row >= rows_per_pattern) return error.InvalidRad;
        if (lines.items.len - start >= rows_per_pattern) return error.InvalidRad;

        // A file cut short mid-note keeps the cells that did decode. The rest
        // of the tune is intact, so losing the tail beats losing the file.
        var line = Line{ .row = row, .cells = @splat(.{}) };
        var truncated = false;
        while (s.len > 0) {
            const u = (if (version >= 2)
                unpackNoteV2(&s)
            else
                unpackNoteV1(&s)) catch {
                truncated = true;
                break;
            };
            const column = if (single_channel) 0 else u.ch;
            if (column < channels) {
                line.cells[column] = u.cell;
                line.present |= @as(u9, 1) << @intCast(column);
            }
            if (u.done or single_channel) break;
        }
        try lines.append(gpa, line);
        if (truncated or linedef & 0x80 != 0) break;
    }
    return lines.items[start..];
}

const ParsedTune = struct {
    version: u8,
    speed: u8,
    tick_num: u32,
    tick_den: u32,
    description: ?[]const u8,
    instruments: []Instrument,
    instrument_count: u8,
    order_list: []u8,
    patterns: []Pattern,
    owned_lines: []Line,
    riffs: [90][]const Line,
    num_patterns: u8,
    bpm: ?u16 = null,
};

const LineRange = struct {
    start: usize = 0,
    count: usize = 0,

    fn slice(self: LineRange, lines: []const Line) []const Line {
        return lines[self.start..][0..self.count];
    }
};

fn parseTune(gpa: std.mem.Allocator, data: []const u8) ParseErr!ParsedTune {
    if (data.len < 18) return error.InvalidRad;
    if (!std.mem.eql(u8, data[0..16], magic)) return error.InvalidRad;
    const ver_byte = data[16];
    if (ver_byte != 0x10 and ver_byte != 0x21) return error.UnsupportedRadVersion;
    const version: u8 = ver_byte >> 4;

    var s: []const u8 = data[17..];
    if (s.len < 1) return error.InvalidRad;
    const flags = s[0];
    s = s[1..];
    const speed: u8 = @max(@as(u8, 1), flags & 0x1f);

    var tick_num: u32 = 1;
    var tick_den: u32 = 50;
    var bpm: ?u16 = null;
    if (version >= 2 and flags & 0x20 != 0) {
        if (s.len < 2) return error.InvalidRad;
        bpm = std.mem.readInt(u16, s[0..2], .little);
        s = s[2..];
        tick_num = 5;
        tick_den = @max(@as(u32, 1), @as(u32, bpm.?) * 2);
    }
    if (flags & 0x40 != 0) {
        tick_num = 5;
        tick_den = 91;
        bpm = null;
    }

    var description: ?[]const u8 = null;
    errdefer if (description) |d| gpa.free(d);
    if (version >= 2 or flags & 0x80 != 0) {
        const z = std.mem.findScalar(u8, s, 0) orelse return error.InvalidRad;
        // Descriptions are multi-line blobs with 0x01 as the line break.
        // Only the first line is fit for a title bar.
        const line_end = for (s[0..z], 0..) |c, i| {
            if (c < 0x20) break i;
        } else z;
        description = try cp437.decodeOptional(gpa, s[0..line_end]);
        s = s[z + 1 ..];
    }

    const max_inst: usize = if (version >= 2) @as(usize, max_instruments) else @as(usize, max_instruments_v1);
    const instruments = try gpa.alloc(Instrument, max_inst);
    errdefer gpa.free(instruments);
    @memset(instruments, .{});
    var highest: u8 = 0;
    var lines_list: std.ArrayList(Line) = .empty;
    errdefer lines_list.deinit(gpa);
    var instrument_riffs: [max_instruments]LineRange = @splat(.{});
    var riff_ranges: [90]LineRange = @splat(.{});

    while (true) {
        if (s.len < 1) return error.InvalidRad;
        const inst_num = s[0];
        s = s[1..];
        if (inst_num == 0) break;
        if (inst_num > max_inst) return error.InvalidRad;
        highest = @max(highest, inst_num);

        var inst = Instrument{};
        if (version >= 2) {
            if (s.len < 1) return error.InvalidRad;
            const namelen: usize = s[0];
            s = s[1..];
            if (s.len < namelen + 1) return error.InvalidRad;
            inst.name_len = @intCast(cp437.decode(&inst.name_buf, s[0..namelen]).len);
            s = s[namelen..];
            const alg = s[0];
            s = s[1..];
            inst.algorithm = alg & 7;
            inst.panning = .{ @truncate(alg >> 3), @truncate(alg >> 5) };
            if (inst.algorithm < 7) {
                if (s.len < 23) return error.InvalidRad;
                inst.feedback = s[0] & 15;
                inst.second_feedback = s[0] >> 4;
                inst.detune = s[1] >> 4;
                inst.riff_speed = s[1] & 15;
                inst.volume = @min(s[2], 64);
                s = s[3..];
                for (0..4) |i| {
                    @memcpy(&inst.ops[i], s[0..5]);
                    s = s[5..];
                }
            } else {
                if (s.len < 6) return error.InvalidRad;
                inst.midi_program = s[0];
                s = s[6..];
            }
            if (alg & 0x80 != 0) {
                if (s.len < 2) return error.InvalidRad;
                const riff_size = std.mem.readInt(u16, s[0..2], .little);
                const start = lines_list.items.len;
                const riff_lines = try appendPatternLines(gpa, &lines_list, s, 2, false);
                instrument_riffs[inst_num - 1] = .{ .start = start, .count = riff_lines.len };
                s = s[2 + @as(usize, riff_size) ..];
            }
        } else {
            if (s.len < 11) return error.InvalidRad;
            inst.ops[0][0] = s[0];
            inst.ops[1][0] = s[1];
            inst.ops[0][1] = s[2];
            inst.ops[1][1] = s[3];
            inst.ops[0][2] = s[4];
            inst.ops[1][2] = s[5];
            inst.ops[0][3] = s[6];
            inst.ops[1][3] = s[7];
            inst.algorithm = s[8] & 1;
            inst.feedback = (s[8] >> 1) & 7;
            inst.ops[0][4] = s[9];
            inst.ops[1][4] = s[10];
            inst.volume = 64;
            s = s[11..];
        }
        instruments[inst_num - 1] = inst;
    }

    if (s.len < 1) return error.InvalidRad;
    const order_size = s[0];
    s = s[1..];
    if (order_size == 0 or order_size > max_order or s.len < order_size) return error.InvalidRad;
    const order_list = try gpa.dupe(u8, s[0..order_size]);
    errdefer gpa.free(order_list);
    for (order_list) |entry| if (entry & 0x80 != 0 and entry & 0x7f >= order_list.len) return error.InvalidRad;
    s = s[order_size..];

    const max_pat: usize = if (version >= 2) @as(usize, max_patterns) else @as(usize, max_patterns_v1);
    var patterns = try gpa.alloc(Pattern, max_pat);
    errdefer gpa.free(patterns);
    @memset(patterns, .{ .lines = &.{} });
    var num_patterns: u8 = 0;

    // Record (start, count) then rebind after toOwnedSlice.
    var ranges: [max_patterns]struct { start: usize, count: usize } = @splat(.{ .start = 0, .count = 0 });

    if (version >= 2) {
        while (s.len > 0) {
            const pattnum = s[0];
            s = s[1..];
            if (pattnum == 0xff) break;
            if (pattnum >= max_patterns) return error.InvalidRad;
            const start = lines_list.items.len;
            const slice = try appendPatternLines(gpa, &lines_list, s, 2, false);
            if (s.len < 2) return error.InvalidRad;
            const size: usize = std.mem.readInt(u16, s[0..2], .little);
            s = s[2 + size ..];
            ranges[pattnum] = .{ .start = start, .count = slice.len };
            num_patterns = @max(num_patterns, pattnum + 1);
        }
        while (s.len > 0) {
            const riffid = s[0];
            s = s[1..];
            if (riffid == 0xff) break;
            if (riffid >> 4 >= 10 or riffid & 15 == 0 or riffid & 15 > 9 or s.len < 2) return error.InvalidRad;
            const size = std.mem.readInt(u16, s[0..2], .little);
            const start = lines_list.items.len;
            const riff_lines = try appendPatternLines(gpa, &lines_list, s, 2, true);
            riff_ranges[@as(usize, riffid >> 4) * 9 + (riffid & 15) - 1] = .{ .start = start, .count = riff_lines.len };
            s = s[2 + @as(usize, size) ..];
        }
    } else {
        if (s.len < 64) return error.InvalidRad;
        const offsets = s[0..64];
        for (0..max_patterns_v1) |i| {
            const pos = std.mem.readInt(u16, offsets[i * 2 ..][0..2], .little);
            if (pos == 0 or pos >= data.len) continue;
            const start = lines_list.items.len;
            const slice = try appendPatternLines(gpa, &lines_list, data[pos..], 1, false);
            ranges[i] = .{ .start = start, .count = slice.len };
            num_patterns = @max(num_patterns, @as(u8, @intCast(i + 1)));
        }
    }

    const owned_lines = try lines_list.toOwnedSlice(gpa);
    errdefer gpa.free(owned_lines);

    for (0..num_patterns) |i| {
        const r = ranges[i];
        patterns[i] = .{ .lines = owned_lines[r.start .. r.start + r.count] };
    }
    for (instruments, 0..) |*inst, i| inst.riff = instrument_riffs[i].slice(owned_lines);
    var riffs: [90][]const Line = undefined;
    for (&riffs, riff_ranges) |*riff, range| riff.* = range.slice(owned_lines);

    return .{
        .version = version,
        .speed = speed,
        .tick_num = tick_num,
        .tick_den = tick_den,
        .description = description,
        .instruments = instruments,
        .instrument_count = highest,
        .order_list = order_list,
        .patterns = patterns,
        .owned_lines = owned_lines,
        .riffs = riffs,
        .num_patterns = num_patterns,
        .bpm = bpm,
    };
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (data.len < 16 or !std.mem.eql(u8, data[0..16], magic)) return null;

    const tune = parseTune(gpa, data) catch |err| switch (err) {
        error.InvalidRad => return error.InvalidRad,
        error.UnsupportedRadVersion => return error.UnsupportedRadVersion,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer {
        gpa.free(tune.instruments);
        gpa.free(tune.order_list);
        gpa.free(tune.patterns);
        gpa.free(tune.owned_lines);
        if (tune.description) |d| gpa.free(d);
    }

    const view_cells = try gpa.alloc(Cell, @as(usize, tune.num_patterns) * rows_per_pattern * channels);
    errdefer gpa.free(view_cells);
    @memset(view_cells, .{});
    for (0..tune.num_patterns) |pi| {
        for (tune.patterns[pi].lines) |line| {
            for (line.cells, 0..) |cell, ch| {
                view_cells[pi * rows_per_pattern * channels + @as(usize, line.row) * channels + ch] = cell;
            }
        }
    }
    const view_order = try gpa.dupe(u8, tune.order_list);
    errdefer gpa.free(view_order);

    const src = try gpa.create(RadSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .tick_num = tune.tick_num,
        .tick_den = tune.tick_den,
        .version = tune.version,
        .speed = tune.speed,
        .order_list = tune.order_list,
        .patterns = tune.patterns,
        .instruments = tune.instruments,
        .instrument_count = tune.instrument_count,
        .description = tune.description,
        .title_embedded = tune.description != null,
        .view_cells = view_cells,
        .view_order = view_order,
        .num_patterns = tune.num_patterns,
        .owned_lines = tune.owned_lines,
        .riffs = tune.riffs,
        .bpm = tune.bpm,
    };
    if (src.order_list[0] & 0x80 != 0) src.order_pos = src.order_list[0] & 0x7f;
    src.visited_orders.set(src.order_pos);

    const chip = ctx.chip;
    for (0x20..0xf6) |reg| {
        const val: u8 = if (reg >= 0x60 and reg < 0xa0) 0xff else 0;
        src.write(chip, @intCast(reg), val);
        if (tune.version >= 2) src.write(chip, @intCast(reg + 0x100), val);
    }
    src.write(chip, 0x01, 0x20);
    src.write(chip, 0x08, 0x00);
    src.write(chip, 0xbd, 0x00);
    if (tune.version >= 2) {
        src.write(chip, 0x104, 0);
        src.write(chip, 0x105, 1);
    }
    chip.flush();

    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

test "rad rejects non-magic" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try load(gpa, "not a rad file!!!!" ++ @as([20]u8, @splat(0)), .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    }) == null);
}

test "rad v1 minimal pattern plays" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.append(gpa, 0x10);
    try list.append(gpa, 0x02);
    try list.append(gpa, 1);
    try list.appendSlice(gpa, &[_]u8{ 0x01, 0x11, 0x4f, 0x00, 0xf1, 0xf2, 0x53, 0x74, 0x00, 0x00, 0x00 });
    try list.append(gpa, 0);
    try list.append(gpa, 1);
    try list.append(gpa, 0);
    const pat_pos: u16 = @intCast(list.items.len + 64);
    for (0..32) |i| {
        const v: u16 = if (i == 0) pat_pos else 0;
        try list.append(gpa, @truncate(v));
        try list.append(gpa, @truncate(v >> 8));
    }
    try list.append(gpa, 0x80);
    try list.append(gpa, 0x80);
    try list.append(gpa, 0x41);
    try list.append(gpa, 0x10);

    var chip = opal.Opal.init(44100);
    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .ext = ".rad",
        .name = "t.rad",
    })).?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("RAD", src.info().format_name);
    try std.testing.expect(src.views().pattern != null);
    const r = src.step(chip_adapter.fromOpal(&chip));
    try std.testing.expect(r.frames > 0);
    const pv = src.views().pattern.?;
    const cell = pv.cell(pv.ctx, 0, 0, 0);
    try std.testing.expect(cell.note == .pitch);
    try std.testing.expectEqual(@as(?u16, 1), cell.instrument);
}

test "rad v2 pattern reports opl3 and is audible" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x02, 0x00 }); // v2.1, speed 2, empty description
    try list.appendSlice(gpa, &[_]u8{ 1, 0, 0x00 }); // instrument 1: no name, algorithm 0
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 64 }); // feedback, detune, volume
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x00, 0xf1, 0x74, 0x00 }); // carrier
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x10, 0xf1, 0x74, 0x00 }); // modulator
    try list.appendSlice(gpa, &@as([10]u8, @splat(0))); // unused operator pair
    try list.append(gpa, 0); // end of instruments
    try list.appendSlice(gpa, &[_]u8{ 1, 0x00 }); // order list: pattern 0
    // pattern 0: last line at row 0, last channel 0, note C-4 with instrument 1
    try list.appendSlice(gpa, &[_]u8{ 0x00, 4, 0, 0x80, 0xe0, 0x41, 0x01 });
    try list.appendSlice(gpa, &[_]u8{ 0xff, 0xff }); // end of patterns, end of riffs

    var chip = opal.Opal.init(44100);
    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .ext = ".rad",
        .name = "t2.rad",
    })).?;
    defer src.deinit(gpa);

    try std.testing.expect(src.info().opl3);
    var peak: u32 = 0;
    var steps: u32 = 0;
    while (steps < 50) : (steps += 1) {
        const r = src.step(chip_adapter.fromOpal(&chip));
        chip.flushWriteBuf();
        var n: u64 = 0;
        while (n < r.frames) : (n += 1) {
            const s = chip.sample();
            peak = @max(peak, @abs(@as(i32, s.left)));
            peak = @max(peak, @abs(@as(i32, s.right)));
        }
        if (r.done) break;
    }
    try std.testing.expect(peak > 0);
}

test "rad v2 description and instrument names are transcoded from CP437" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x02 });
    try list.appendSlice(gpa, "D\x82mo \xCD\x01second line\x00");
    try list.appendSlice(gpa, &[_]u8{ 1, 4, 'B', 0x84, 's', 's', 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 64 });
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x00, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x21, 0x10, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &@as([10]u8, @splat(0)));
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &[_]u8{ 1, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x00, 4, 0, 0x80, 0xe0, 0x41, 0x01 });
    try list.appendSlice(gpa, &[_]u8{ 0xff, 0xff });

    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
        .name = "cp437.rad",
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("Démo ═", src.info().title.?);
    const bank = src.views().instruments.?;
    try std.testing.expectEqualStrings("Bäss", bank.get(bank.ctx, 1).name);
}

test "rad malformed lengths are invalid, not crashes" {
    const gpa = std.testing.allocator;
    // Instrument name length 255 with truncated data.
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    try a.appendSlice(gpa, magic);
    try a.appendSlice(gpa, &[_]u8{ 0x21, 0x02, 0x00, 1, 255 });
    try a.appendSlice(gpa, &@as([10]u8, @splat(0x41)));
    try std.testing.expectError(error.InvalidRad, load(gpa, a.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    }));

    // Pattern size word 0xFFFF.
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, magic);
    try b.appendSlice(gpa, &[_]u8{ 0x21, 0x02, 0x00, 0, 1, 0x00 });
    try b.appendSlice(gpa, &[_]u8{ 0x00, 0xff, 0xff, 0x80, 0x00 });
    try std.testing.expectError(error.InvalidRad, load(gpa, b.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    }));
}

test "rad pattern cut short mid-note keeps the cells that decoded" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.append(gpa, 0x10);
    try list.append(gpa, 0x02);
    try list.append(gpa, 1);
    try list.appendSlice(gpa, &[_]u8{ 0x01, 0x11, 0x4f, 0x00, 0xf1, 0xf2, 0x53, 0x74, 0x00, 0x00, 0x00 });
    try list.append(gpa, 0);
    try list.append(gpa, 1);
    try list.append(gpa, 0);
    const pat_pos: u16 = @intCast(list.items.len + 64);
    for (0..32) |i| {
        const v: u16 = if (i == 0) pat_pos else 0;
        try list.append(gpa, @truncate(v));
        try list.append(gpa, @truncate(v >> 8));
    }
    // Row 0: channel 0 note C-4 instrument 1, then channel 1 claims an effect
    // but the parameter byte is missing, exactly how the damaged archive files
    // end.
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x41, 0x10, 0x01, 0x41, 0x1a });

    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    })).?;
    defer src.deinit(gpa);

    const pv = src.views().pattern.?;
    const kept = pv.cell(pv.ctx, 0, 0, 0);
    try std.testing.expect(kept.note == .pitch);
    try std.testing.expectEqual(@as(u8, 0), kept.note.pitch.semitone);
    try std.testing.expectEqual(@as(u8, 4), kept.note.pitch.octave);
    try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
}

test "rad pattern with more lines than rows is invalid" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.append(gpa, 0x10);
    try list.append(gpa, 0x02);
    try list.append(gpa, 0);
    try list.append(gpa, 1);
    try list.append(gpa, 0);
    const pat_pos: u16 = @intCast(list.items.len + 64);
    for (0..32) |i| {
        const v: u16 = if (i == 0) pat_pos else 0;
        try list.append(gpa, @truncate(v));
        try list.append(gpa, @truncate(v >> 8));
    }
    for (0..65) |i| {
        const row: u8 = @intCast(@min(i, 63));
        try list.appendSlice(gpa, &[_]u8{ row, 0x80, 0x00, 0x00 });
    }
    try std.testing.expectError(error.InvalidRad, load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    }));
}

const RadRec = struct {
    carrier_char: [channels]u8 = @splat(0),
    char_writes: [channels]u32 = @splat(0),
    b0: [channels]u8 = @splat(0),
    keyed_off: bool = false,

    const carrier_char_reg = [_]u16{ 0x2b, 0x2c, 0x2d, 0x12b, 0x12c, 0x12d, 0x133, 0x134, 0x135 };

    fn write(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        for (carrier_char_reg, 0..) |r, i| {
            if (reg == r) {
                self.carrier_char[i] = val;
                self.char_writes[i] += 1;
            }
        }
        for (secondary_channels, 0..) |offset, i| if (reg == 0xb0 + offset) {
            self.b0[i] = val;
            if (i == 0 and val & 0x20 == 0) self.keyed_off = true;
        };
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{
            .ptr = self,
            .vtable = &.{ .writeReg = write, .flush = flush },
        };
    }
};

fn appendRadV2Instrument(list: *std.ArrayList(u8), gpa: std.mem.Allocator, num: u8, carrier_char: u8) !void {
    try list.append(gpa, num);
    try list.appendSlice(gpa, &.{ 0, 0x00, 0x00, 0x00, 64 });
    try list.appendSlice(gpa, &.{ carrier_char, 0x00, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &.{ carrier_char, 0x10, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &@as([10]u8, @splat(0)));
}

fn appendRadV2Pattern(list: *std.ArrayList(u8), gpa: std.mem.Allocator, num: u8, payload: []const u8) !void {
    try list.append(gpa, num);
    const size: u16 = @intCast(payload.len);
    try list.append(gpa, @truncate(size));
    try list.append(gpa, @truncate(size >> 8));
    try list.appendSlice(gpa, payload);
}

test "rad v2 retrigger uses each channel's last instrument" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x01, 0x00 });
    try appendRadV2Instrument(&list, gpa, 1, 0x21);
    try appendRadV2Instrument(&list, gpa, 2, 0x22);
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{
        0x00, 0x60, 0x41, 1, 0xe1, 0x41, 2,
        0x81, 0xc0, 0xc2,
    });
    try list.appendSlice(gpa, &.{ 0xff, 0xff });

    var rec = RadRec{};
    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".rad",
        .name = "retrigger.rad",
    })).?;
    defer src.deinit(gpa);

    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x21), rec.carrier_char[0]);
    try std.testing.expectEqual(@as(u8, 0x22), rec.carrier_char[1]);

    rec.char_writes = @splat(0);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x21), rec.carrier_char[0]);
    try std.testing.expectEqual(@as(u8, 0x22), rec.carrier_char[1]);
    try std.testing.expect(rec.char_writes[0] > 0);
}

test "rad v2 note without instrument does not bounce key-on" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x01, 0x00 });
    try appendRadV2Instrument(&list, gpa, 1, 0x21);
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{
        0x00, 0xe0, 0x41, 1,
        0x81, 0xc0, 0x42,
    });
    try list.appendSlice(gpa, &.{ 0xff, 0xff });

    var rec = RadRec{};
    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".rad",
        .name = "legato.rad",
    })).?;
    defer src.deinit(gpa);

    _ = src.step(rec.chip());
    try std.testing.expect(rec.b0[0] & 0x20 != 0);
    rec.keyed_off = false;
    rec.char_writes = @splat(0);
    _ = src.step(rec.chip());
    try std.testing.expect(rec.b0[0] & 0x20 != 0);
    try std.testing.expect(!rec.keyed_off);
    try std.testing.expectEqual(@as(u32, 0), rec.char_writes[0]);
}

test "rad v2 note naming an instrument past the highest defined one loads a blank patch" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x01, 0x00 });
    try appendRadV2Instrument(&list, gpa, 1, 0x21);
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{
        0x00, 0xe0, 0x41, 1,
        0x81, 0xe0, 0x45, 2,
    });
    try list.appendSlice(gpa, &.{ 0xff, 0xff });

    var rec = RadRec{};
    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".rad",
        .name = "blank.rad",
    })).?;
    defer src.deinit(gpa);

    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x21), rec.carrier_char[0]);
    rec.keyed_off = false;
    rec.char_writes = @splat(0);
    _ = src.step(rec.chip());
    try std.testing.expect(rec.char_writes[0] > 0);
    try std.testing.expectEqual(@as(u8, 0), rec.carrier_char[0]);
    try std.testing.expect(rec.keyed_off);

    const bank = src.views().instruments.?;
    try std.testing.expectEqual(@as(u16, 2), bank.count);
    try std.testing.expect(bank.get(bank.ctx, 2).patch == .empty);
}

test "rad hostile effect params play without crashing" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.append(gpa, 0x10);
    try list.append(gpa, 0x02);
    try list.append(gpa, 1);
    try list.appendSlice(gpa, &[_]u8{ 0x01, 0x11, 0x4f, 0x00, 0xf1, 0xf2, 0x53, 0x74, 0x00, 0x00, 0x00 });
    try list.append(gpa, 0);
    try list.append(gpa, 1);
    try list.append(gpa, 0);
    const pat_pos: u16 = @intCast(list.items.len + 64);
    for (0..32) |i| {
        const v: u16 = if (i == 0) pat_pos else 0;
        try list.append(gpa, @truncate(v));
        try list.append(gpa, @truncate(v >> 8));
    }
    // Row 0: ch0 portamento down with param 0x80, ch1 volume slide with param 200.
    try list.appendSlice(gpa, &[_]u8{ 0x80, 0x00, 0x41, 0x12, 0x80, 0x81, 0x41, 0x1a, 200 });

    const src = (try load(gpa, list.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".rad",
    })).?;
    defer src.deinit(gpa);
    for (0..4) |_| {
        try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
    }
}

test "rad instrument riffs transpose, loop, and retain four-operator routing" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, magic ++ "\x21\x02\x00");
    const instrument_start = bytes.items.len;
    try appendRadV2Instrument(&bytes, gpa, 1, 0x21);
    bytes.items[instrument_start + 2] = 0xca;
    bytes.items[instrument_start + 3] = 0x32;
    bytes.items[instrument_start + 4] = 0x51;
    const riff = [_]u8{ 0, 0x40, 0x3c, 0x91, 'M' - 55, 5, 0x81, 0x90, 13, 0 };
    try bytes.appendSlice(gpa, &.{ riff.len, 0 });
    try bytes.appendSlice(gpa, &riff);
    try bytes.appendSlice(gpa, &.{ 0, 1, 0 });
    try appendRadV2Pattern(&bytes, gpa, 0, &.{ 0x80, 0xe0, 0x41, 1 });
    try bytes.appendSlice(gpa, &.{ 0xff, 0xff });
    const src = (try load(gpa, bytes.items, .{ .sample_rate = 48000, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    const state: *RadSource = @ptrCast(@alignCast(src.ptr));
    for (0..4) |_| {
        _ = src.step(fmt.noop_chip);
        try std.testing.expectEqual(@as(u8, 1), state.regs[0x104]);
        try std.testing.expectEqual(@as(u8, 0x16), state.regs[0xc0]);
        try std.testing.expectEqual(@as(u8, 0x24), state.regs[0xc3]);
        try std.testing.expectEqual(@as(u8, 0x69), state.regs[0xa0]);
        try std.testing.expectEqual(@as(u8, 0x6e), state.regs[0xa3]);
        try std.testing.expectEqual(@as(u8, 0x25), state.regs[0x2b]);
        try std.testing.expectEqual(@as(u8, 0), state.channels_state[0].instrument_riff.row);
    }
}

test "rad channel riffs have independent speed and transposition" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, magic ++ "\x21\x04\x00");
    try appendRadV2Instrument(&bytes, gpa, 1, 0x21);
    try bytes.appendSlice(gpa, &.{ 0, 1, 0 });
    try appendRadV2Pattern(&bytes, gpa, 0, &.{ 0x80, 0xf0, 0x41, 1, 'T' - 55, 11 });
    try bytes.append(gpa, 0xff);
    try appendRadV2Pattern(&bytes, gpa, 0x11, &.{ 0, 0x50, 0x3c, 15, 1, 0x81, 0x40, 0x4c });
    try bytes.append(gpa, 0xff);
    const src = (try load(gpa, bytes.items, .{ .sample_rate = 48000, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    const state: *RadSource = @ptrCast(@alignCast(src.ptr));
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 4), state.channels_state[0].curr_octave);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 5), state.channels_state[0].curr_octave);
    try std.testing.expectEqual(@as(u8, 4), state.speed);
    try std.testing.expectEqual(@as(u8, 0), state.cur_row);
}

test "rad v2 riffs keep their own last-instrument latch" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x01, 0x00 });
    try appendRadV2Instrument(&list, gpa, 1, 0x21);
    try appendRadV2Instrument(&list, gpa, 2, 0x22);
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{
        0x00, 0xf0, 0x41, 1, 'R' - 55, 1,
        0x82, 0xc0, 0xc3,
    });
    try list.append(gpa, 0xff);
    try appendRadV2Pattern(&list, gpa, 0x01, &.{ 0x80, 0x60, 0x45, 2 });
    try list.append(gpa, 0xff);

    var rec = RadRec{};
    const src = (try load(gpa, list.items, .{ .sample_rate = 44100, .chip = rec.chip(), .ext = ".rad" })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x22), rec.carrier_char[0]);
    _ = src.step(rec.chip());
    rec.char_writes = @splat(0);
    _ = src.step(rec.chip());
    try std.testing.expect(rec.char_writes[0] > 0);
    try std.testing.expectEqual(@as(u8, 0x21), rec.carrier_char[0]);
}

test "rad instruments read additive when their algorithm has more than one carrier" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x01, 0x00 });
    for (0..carriers.len) |alg| {
        const instrument_start = list.items.len;
        try appendRadV2Instrument(&list, gpa, @intCast(alg + 1), 0x21);
        list.items[instrument_start + 2] = @intCast(alg);
    }
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{ 0x80, 0xe0, 0x41, 1 });
    try list.appendSlice(gpa, &.{ 0xff, 0xff });
    const src = (try load(gpa, list.items, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".rad" })).?;
    defer src.deinit(gpa);

    const bank = src.views().instruments.?;
    const expected = [_]bool{ false, true, false, true, true, true, true };
    for (expected, 1..) |additive, index| {
        const ins = bank.get(bank.ctx, @intCast(index));
        try std.testing.expectEqual(@as(u8, @intCast(index - 1)), ins.opl().algorithm);
        try std.testing.expectEqual(additive, ins.opl().additive);
    }
}

test "rad slow timer hides the BPM it overrides" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, magic);
    try list.appendSlice(gpa, &.{ 0x21, 0x66, 0x7d, 0x00, 0x00 });
    try appendRadV2Instrument(&list, gpa, 1, 0x21);
    try list.append(gpa, 0);
    try list.appendSlice(gpa, &.{ 1, 0x00 });
    try appendRadV2Pattern(&list, gpa, 0, &.{ 0x80, 0xe0, 0x41, 1 });
    try list.appendSlice(gpa, &.{ 0xff, 0xff });
    const src = (try load(gpa, list.items, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".rad" })).?;
    defer src.deinit(gpa);
    try std.testing.expect(!src.playhead().?.flags.has_bpm);
}
