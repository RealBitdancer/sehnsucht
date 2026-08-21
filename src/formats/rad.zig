//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
// Reality Adlib Tracker decoder. File layout and playback follow the
// public-domain RAD player by Shayde/Reality (AdPlug rad2).

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

pub const visualizer_name = "tracker";

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
    _,
};

const Instrument = struct {
    algorithm: u8 = 0,
    feedback: u8 = 0,
    volume: u8 = 64,
    ops: [2][5]u8 = @splat(@splat(0)),
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
};

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
    description: ?[]const u8,
    title_embedded: bool,
    channels_state: [channels]Channel = @splat(.{}),
    regs: [256]u8 = @splat(0),
    view_cells: []Cell,
    view_order: []u8,
    num_patterns: u8,
    song_end: bool = false,
    cur_order: u8 = 0,
    cur_row: u8 = 0,
    cur_pattern: u8 = 0,
    last_instrument: u8 = 0,
    owned_lines: []Line,

    fn write(self: *RadSource, chip: fmt.Chip, reg: u16, val: u8) void {
        chip.writeReg(reg, val);
        if (reg < 256) self.regs[@intCast(reg)] = val;
    }

    fn loadInstrument(self: *RadSource, chip: fmt.Chip, ch: u8, inst: *const Instrument) void {
        const alg = inst.algorithm & 1;
        self.channels_state[ch].volume = inst.volume;
        self.write(chip, 0xc0 + ch, 0x30 | (inst.feedback << 1) | alg);
        for (0..2) |op_i| {
            const op = inst.ops[op_i];
            const reg = op_offsets[ch][op_i];
            var vol: u16 = ~op[1] & 0x3f;
            if (op_i == 0 or alg == 1) vol = vol * inst.volume / 64;
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
        const alg = inst.algorithm & 1;
        for (0..2) |op_i| {
            if (op_i == 1 and alg == 0) continue;
            const op = inst.ops[op_i];
            const opvol: u8 = @truncate((@as(u16, (~op[1] & 0x3f)) * vol / 64) ^ 0x3f);
            const reg = 0x40 + op_offsets[ch][op_i];
            self.write(chip, reg, (self.regs[reg] & 0xc0) | (opvol & 0x3f));
        }
    }

    fn playNoteOpl(self: *RadSource, chip: fmt.Chip, ch: u8, octave: u8, note: u8) void {
        var cs = &self.channels_state[ch];
        if (cs.key_off) {
            cs.key_off = false;
            cs.keyed = false;
            self.write(chip, 0xb0 + ch, self.regs[0xb0 + ch] & ~@as(u8, 0x20));
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
        self.write(chip, 0xa0 + ch, @truncate(freq));
        self.write(chip, 0xb0 + ch, @as(u8, @truncate(freq >> 8)) | (octave << 2) | keybit);
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
        const keybit = self.regs[0xb0 + ch] & 0xe0;
        const f: u16 = @intCast(freq);
        self.write(chip, 0xa0 + ch, @truncate(f));
        self.write(chip, 0xb0 + ch, @as(u8, @truncate(f >> 8)) | (@as(u8, @intCast(oct)) << 2) | keybit);
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

    fn playNote(self: *RadSource, chip: fmt.Chip, ch: u8, note: u8, octave: u8, inst: u8, effect: u8, param: u8, retrigger: bool) void {
        var cs = &self.channels_state[ch];
        const fx = &cs.fx;

        var used = inst;
        if (retrigger and used == 0) used = cs.last_used;
        if (used > 0) {
            cs.last_used = used;
            self.last_instrument = used;
        }

        if (effect == @intFromEnum(Effect.tone_slide)) {
            if (note >= 1 and note <= 12) {
                fx.tone_slide_oct = octave;
                fx.tone_slide_freq = note_fnum[note - 1];
            }
            if (param != 0) fx.tone_slide_speed = param;
            self.getSlideDir(ch, fx);
            return;
        }

        if (used > 0 and used <= self.instruments.len) {
            cs.instrument = used;
            self.loadInstrument(chip, ch, &self.instruments[used - 1]);
            cs.key_off = true;
            cs.key_on = true;
        }

        if (note > 0) {
            if (note == 15) {
                cs.key_off = true;
                self.playNoteOpl(chip, ch, 0, 15);
            } else if (note <= 12) {
                self.playNoteOpl(chip, ch, octave, note);
            }
        }

        switch (@as(Effect, @enumFromInt(effect))) {
            .set_vol => self.setVolume(chip, ch, param),
            .set_speed => {
                if (param != 0) {
                    self.speed = param;
                    self.speed_cnt = param;
                }
            },
            .portamento_up => fx.port_slide = @bitCast(param),
            .portamento_down => fx.port_slide = -%@as(i8, @bitCast(param)),
            .vol_slide, .tone_vol_slide => {
                var val: i8 = @bitCast(param);
                if (val >= 50) val = -(val - 50);
                fx.vol_slide = val;
                if (effect == @intFromEnum(Effect.tone_vol_slide)) {
                    if (param != 0) fx.tone_slide_speed = param;
                    self.getSlideDir(ch, fx);
                }
            },
            .jump_to_line => {
                if (param < rows_per_pattern) self.line_jump = param;
            },
            else => {},
        }
    }

    fn continueFx(self: *RadSource, chip: fmt.Chip, ch: u8) void {
        const fx = &self.channels_state[ch].fx;
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
            self.song_end = true;
            return;
        }
        if (self.order_list[self.order_pos] & 0x80 != 0) {
            self.order_pos = self.order_list[self.order_pos] & 0x7f;
            self.song_end = true;
        }
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
                self.playNote(chip, @intCast(ch), cell.note, cell.octave, cell.instrument, cell.effect, cell.param, cell.retrigger);
            }
        }

        self.line += 1;
        if (self.line >= rows_per_pattern or self.line_jump >= 0) {
            self.line = if (self.line_jump >= 0) @intCast(self.line_jump) else 0;
            self.advanceOrder();
        }
    }

    pub fn step(self: *RadSource, chip: fmt.Chip) fmt.StepResult {
        self.playLine(chip);
        for (0..channels) |ch| self.continueFx(chip, @intCast(ch));
        var done = false;
        if (self.song_end) {
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
            .visualizer = visualizer_name,
        };
    }

    pub fn pos(self: *RadSource) fmt.TrackerPos {
        return .{
            .order_pos = self.cur_order,
            .row = self.cur_row,
            .pattern = self.cur_pattern,
            .speed = self.speed,
            .last_instrument = self.last_instrument,
        };
    }

    pub fn trackerView(self: *RadSource) fmt.TrackerView {
        return .{
            .ctx = self,
            .channels = channels,
            .rows_per_pattern = rows_per_pattern,
            .num_patterns = self.num_patterns,
            .order = self.view_order,
            .cell = cellView,
            .instrument = instrumentView,
        };
    }

    fn cellView(ptr: *anyopaque, pattern: u8, row: u8, chan: u8) fmt.TrackerCell {
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (pattern >= self.num_patterns or row >= rows_per_pattern or chan >= channels)
            return .{ .kind = .empty };
        const cell = self.view_cells[
            @as(usize, pattern) * rows_per_pattern * channels +
                @as(usize, row) * channels + chan
        ];
        if (cell.note == 0 and cell.instrument == 0 and cell.effect == 0 and !cell.retrigger)
            return .{ .kind = .empty };
        if (cell.note == 15) return .{ .kind = .note_off, .arg = cell.effect };
        if (cell.note >= 1 and cell.note <= 12) {
            return .{
                .kind = .note,
                .semitone = cell.note - 1,
                .octave = cell.octave,
                .arg = cell.effect,
            };
        }
        if (cell.instrument != 0) return .{ .kind = .set_instrument, .arg = cell.instrument };
        if (cell.effect != 0) return .{ .kind = .effect_only, .arg = cell.effect };
        if (cell.retrigger) return .{ .kind = .set_instrument, .arg = 0 };
        return .{ .kind = .empty };
    }

    fn instrumentView(ptr: *anyopaque, index: u8) fmt.InstrumentInfo {
        const self: *RadSource = @ptrCast(@alignCast(ptr));
        if (index == 0 or index > self.instruments.len) {
            return std.mem.zeroes(fmt.InstrumentInfo);
        }
        const ins = self.instruments[index - 1];
        return .{
            .carrier = fmt.operatorParams(ins.ops[0][0], ins.ops[0][1], ins.ops[0][2], ins.ops[0][3], ins.ops[0][4]),
            .modulator = fmt.operatorParams(ins.ops[1][0], ins.ops[1][1], ins.ops[1][2], ins.ops[1][3], ins.ops[1][4]),
            .feedback = @truncate(ins.feedback & 7),
            .additive = ins.algorithm & 1 != 0,
        };
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
            if (u.ch < channels) line.cells[u.ch] = u.cell;
            if (u.done) break;
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
    order_list: []u8,
    patterns: []Pattern,
    owned_lines: []Line,
    num_patterns: u8,
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
    if (version >= 2 and flags & 0x20 != 0) {
        if (s.len < 2) return error.InvalidRad;
        const bpm = std.mem.readInt(u16, s[0..2], .little);
        s = s[2..];
        tick_num = 5;
        tick_den = @max(@as(u32, 1), @as(u32, bpm) * 2);
    }
    if (flags & 0x40 != 0) {
        tick_num = 5;
        tick_den = 91;
    }

    var description: ?[]const u8 = null;
    errdefer if (description) |d| gpa.free(d);
    if (version >= 2 or flags & 0x80 != 0) {
        const z = std.mem.indexOfScalar(u8, s, 0) orelse return error.InvalidRad;
        // Descriptions are multi-line blobs with 0x01 as the line break.
        // Only the first line is fit for a title bar.
        const line_end = for (s[0..z], 0..) |c, i| {
            if (c < 0x20) break i;
        } else z;
        if (line_end != 0) description = try gpa.dupe(u8, s[0..line_end]);
        s = s[z + 1 ..];
    }

    const max_inst: usize = if (version >= 2) @as(usize, max_instruments) else @as(usize, max_instruments_v1);
    var instruments = try gpa.alloc(Instrument, max_inst);
    errdefer gpa.free(instruments);
    @memset(instruments, .{});
    var highest: u8 = 0;

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
            s = s[namelen..];
            const alg = s[0];
            s = s[1..];
            inst.algorithm = alg & 7;
            if (inst.algorithm < 7) {
                if (s.len < 23) return error.InvalidRad;
                inst.feedback = s[0] & 15;
                inst.volume = s[2];
                s = s[3..];
                for (0..4) |i| {
                    if (i < 2) @memcpy(&inst.ops[i], s[0..5]);
                    s = s[5..];
                }
            } else {
                if (s.len < 6) return error.InvalidRad;
                s = s[6..];
            }
            if (alg & 0x80 != 0) {
                if (s.len < 2) return error.InvalidRad;
                const riff_size = std.mem.readInt(u16, s[0..2], .little);
                s = s[2..];
                if (s.len < riff_size) return error.InvalidRad;
                s = s[riff_size..];
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
    instruments = try gpa.realloc(instruments, @max(@as(usize, 1), highest));

    if (s.len < 1) return error.InvalidRad;
    const order_size = s[0];
    s = s[1..];
    if (order_size == 0 or order_size > max_order or s.len < order_size) return error.InvalidRad;
    const order_list = try gpa.dupe(u8, s[0..order_size]);
    errdefer gpa.free(order_list);
    s = s[order_size..];

    var lines_list: std.ArrayList(Line) = .empty;
    errdefer lines_list.deinit(gpa);

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
            const slice = try appendPatternLines(gpa, &lines_list, s, 2);
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
            if (s.len < 2) break;
            const size = std.mem.readInt(u16, s[0..2], .little);
            s = s[2..];
            if (s.len < size) break;
            s = s[size..];
        }
    } else {
        if (s.len < 64) return error.InvalidRad;
        const offsets = s[0..64];
        for (0..max_patterns_v1) |i| {
            const pos = std.mem.readInt(u16, offsets[i * 2 ..][0..2], .little);
            if (pos == 0 or pos >= data.len) continue;
            const start = lines_list.items.len;
            const slice = try appendPatternLines(gpa, &lines_list, data[pos..], 1);
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

    return .{
        .version = version,
        .speed = speed,
        .tick_num = tick_num,
        .tick_den = tick_den,
        .description = description,
        .instruments = instruments,
        .order_list = order_list,
        .patterns = patterns,
        .owned_lines = owned_lines,
        .num_patterns = num_patterns,
    };
}

fn load(
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
        .description = tune.description,
        .title_embedded = tune.description != null,
        .view_cells = view_cells,
        .view_order = view_order,
        .num_patterns = tune.num_patterns,
        .owned_lines = tune.owned_lines,
    };

    const chip = ctx.chip;
    for (0x20..0xf6) |reg| {
        const val: u8 = if (reg >= 0x60 and reg < 0xa0) 0xff else 0;
        src.write(chip, @intCast(reg), val);
    }
    src.write(chip, 0x01, 0x20);
    src.write(chip, 0x08, 0x00);
    src.write(chip, 0xbd, 0x00);
    if (tune.version >= 2) {
        src.write(chip, 0x104, 0);
        src.write(chip, 0x105, 1);
    }
    chip.flush();

    return fmt.MusicSource.init(src);
}

pub const format = fmt.Format{
    .name = "RAD",
    .extensions = &.{".rad"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

test "rad rejects non-magic" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try load(gpa, "not a rad file!!!!" ++ [_]u8{0} ** 20, .{
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
    try std.testing.expect(src.trackerView() != null);
    const r = src.step(chip_adapter.fromOpal(&chip));
    try std.testing.expect(r.frames > 0);
    const view = src.trackerView().?;
    const c = view.cell(view.ctx, 0, 0, 0);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note, c.kind);
    try std.testing.expectEqual(@as(u8, 0), c.semitone);
    try std.testing.expectEqual(@as(u8, 4), c.octave);
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
    try list.appendSlice(gpa, &([_]u8{0} ** 10)); // unused operator pair
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

test "rad malformed lengths are invalid, not crashes" {
    const gpa = std.testing.allocator;
    // Instrument name length 255 with truncated data.
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    try a.appendSlice(gpa, magic);
    try a.appendSlice(gpa, &[_]u8{ 0x21, 0x02, 0x00, 1, 255 });
    try a.appendSlice(gpa, &([_]u8{0x41} ** 10));
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

    const view = src.trackerView().?;
    const kept = view.cell(view.ctx, 0, 0, 0);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note, kept.kind);
    try std.testing.expectEqual(@as(u8, 0), kept.semitone);
    try std.testing.expectEqual(@as(u8, 4), kept.octave);
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

    const carrier_char_reg = [_]u16{ 0x23, 0x24, 0x25, 0x2b, 0x2c, 0x2d, 0x33, 0x34, 0x35 };

    fn write(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        for (carrier_char_reg, 0..) |r, i| {
            if (reg == r) {
                self.carrier_char[i] = val;
                self.char_writes[i] += 1;
            }
        }
        if (reg >= 0xb0 and reg < 0xb0 + channels) {
            self.b0[reg - 0xb0] = val;
            if (reg == 0xb0 and val & 0x20 == 0) self.keyed_off = true;
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

fn appendRadV2Instrument(list: *std.ArrayList(u8), gpa: std.mem.Allocator, num: u8, carrier_char: u8) !void {
    try list.append(gpa, num);
    try list.appendSlice(gpa, &.{ 0, 0x00, 0x00, 0x00, 64 });
    try list.appendSlice(gpa, &.{ carrier_char, 0x00, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &.{ carrier_char, 0x10, 0xf1, 0x74, 0x00 });
    try list.appendSlice(gpa, &([_]u8{0} ** 10));
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
