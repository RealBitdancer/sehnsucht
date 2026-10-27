//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");

pub const format_name = "MusicV";
pub const extensions = &.{ ".wm", ".m" };
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };

const magic = "OPL3 DATA       ";
const header_bytes: usize = 0x20;
const voice_count: usize = 6;
const inst_bytes: usize = 30;
const inst_regs: usize = 20;
const max_insts: usize = 64;
const default_tick_hz: u32 = 200;
const pit_hz: u32 = 1_193_180;
const tempo_num: u32 = 1_491_475;
const default_pit_div: u32 = pit_hz / default_tick_hz;
const max_ops_per_step: u32 = 4096;
const max_song_ticks: u32 = 2_000_000;
const max_index_events: usize = 65_536;
const f4_cap: u8 = 16;

const vol_tab = [_]u8{
    0x32, 0x2d, 0x29, 0x25, 0x21, 0x1e, 0x1b, 0x18,
    0x15, 0x12, 0x0f, 0x0c, 0x09, 0x06, 0x03, 0x00,
};

const conn_table = [_]u8{ 0x08, 0x0a, 0x09, 0x0d };

const c_xlat_table = [_]u8{
    0x00, 0x50, 0xa0, 0xf0, 0x88, 0x44, 0x3c, 0x8b,
    0x1e, 0xe4, 0x09, 0xba, 0x1e, 0x00, 0xb9, 0x40,
};

const asm_to_nuked = [_]u8{ 0, 1, 2, 9, 10, 11 };
const ch_bank = [_]u8{ 0, 0, 0, 1, 1, 1 };
const ch_slot = [_]u8{ 0, 1, 2, 0, 1, 2 };
const op_base = [_]u8{ 0x20, 0x23, 0x28, 0x2b };
const reg_grp = [_]u16{ 0x20, 0x40, 0x60, 0x80, 0xe0 };

const freq_tab = [_]u16{
    0x0159, 0x016d, 0x0183, 0x019a, 0x01b3, 0x01cc, 0x01e7, 0x0204,
    0x0223, 0x0244, 0x0266, 0x028b, 0x02b2, 0x02da, 0x0307, 0x0333,
    0x0366, 0x0398, 0x03cf, 0x0409, 0x0446, 0x0487, 0x04cc, 0x0516,
    0x0565, 0x05b4, 0x060d, 0x0667, 0x06cb, 0x072f, 0x079e, 0x0812,
    0x088b, 0x090f, 0x0998, 0x0a2b, 0x0ac9, 0x0b68, 0x0c1b, 0x0cce,
    0x0d96, 0x0e5e, 0x0f3c, 0x1024, 0x1116, 0x121e, 0x1330, 0x1457,
    0x1593, 0x16cf, 0x1836, 0x199c, 0x1b2c, 0x1cbd, 0x1e78, 0x2047,
    0x222c, 0x243b, 0x265f, 0x28ae, 0x2b26, 0x2d9e, 0x306b, 0x3338,
    0x3659, 0x397a, 0x3cef, 0x408f, 0x4458, 0x4876, 0x4cbf, 0x515b,
    0x564c, 0x5b3d, 0x60d6, 0x6670, 0x6cb2, 0x72f4, 0x79de, 0x811d,
    0x88b1, 0x90ed, 0x997d, 0xa2b6, 0xac98, 0xb679, 0xc1ac, 0xccdf,
    0xd963, 0xe5e7, 0xf3bd, 0x1e60, 0xeb06, 0xeb00, 0xeb00, 0xeb00,
    0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00,
    0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00,
    0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00,
    0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00, 0xeb00,
};

const ChanFlags = packed struct(u8) {
    sounding: bool = false,
    need_freq: bool = false,
    skip_ties: bool = false,
    skip_setup: bool = false,
    _pad: u3 = 0,
    active: bool = false,
};

const FxFlags = packed struct(u8) {
    slide: bool = false,
    vibrato: bool = false,
    lfo: bool = false,
    held: bool = false,
    _pad: u4 = 0,
};

const Inst = struct {
    id: u8 = 0,
    flags: u8 = 0,
    regs: [inst_regs]u8 = @splat(0),
    vib_rate: u8 = 0,
    vib_speed: u8 = 0,
    vib_amp: u16 = 0,
    vib_delay: u8 = 0,
    lfo_lo: u8 = 0,
    lfo_hi: u8 = 0,
    lfo_amp: u8 = 0,

    fn oplPatch(self: Inst) view.OplPatch {
        const alg: u8 = self.flags & 3;
        const feedback: u3 = @truncate(self.flags >> 2);
        return .{
            .ops = .{
                fmt.operatorParams(self.regs[0], self.regs[1], self.regs[2], self.regs[3], self.regs[4]),
                fmt.operatorParams(self.regs[5], self.regs[6], self.regs[7], self.regs[8], self.regs[9]),
                fmt.operatorParams(self.regs[10], self.regs[11], self.regs[12], self.regs[13], self.regs[14]),
                fmt.operatorParams(self.regs[15], self.regs[16], self.regs[17], self.regs[18], self.regs[19]),
            },
            .op_count = 4,
            .feedback = feedback,
            .feedback2 = feedback,
            .additive = alg != 0,
            .algorithm = alg,
        };
    }
};

const Channel = struct {
    flags: ChanFlags = .{},
    note: u8 = 0,
    shown_note: u8 = 0,
    wait_remain: u8 = 0,
    ties_remain: u8 = 0,
    ties_factor: u8 = 0,
    f4_depth: u8 = 0,
    f4_params: [f4_cap]u8 = @splat(0),
    volume: u8 = 10,
    expression: u8 = 0,
    inst_id: u8 = 0xff,
    inst_slot: u16 = view.sequence_unassigned,
    inst_flags: u8 = 0,
    op_tl: [4]u8 = @splat(0),
    op_waveform: [4]u8 = @splat(0xff),
    pos: usize = 0,
    start: usize = 0,
    end: usize = 0,
    freq_raw: u16 = 0,
    pitch_wheel: i16 = 0,
    b_reg_val: u8 = 0,
    a_reg_val: u8 = 0,
    fx: FxFlags = .{},
    porta_rate: u8 = 0,
    porta_flip: u8 = 0,
    porta_delay: u8 = 0,
    porta_delay_ctr: u8 = 0,
    porta_wait: u8 = 0,
    porta_speed: u8 = 0,
    porta_step: i16 = 0,
    porta_step2: i16 = 0,
    porta_step_saved: i16 = 0,
    porta_target: i16 = 0,
    porta_accum: i16 = 0,
    vibrato_amp: i16 = 0,
    slide_accum: i16 = 0,
    slide_step: i16 = 0,
    slide_target: i16 = 0,
    c_val_saved: u8 = 0,
    c_xlat_index: u8 = 3,
    lfo_lo: u8 = 0,
    lfo_hi: u8 = 0,
    lfo_amp: u8 = 0,
    lfo_sub_step: u8 = 0,
    lfo_delay_ctr: u8 = 0,
    lfo_period_ctr: u8 = 0,
    lfo_step: u8 = 0,
    lfo_accum: u8 = 0,
    lfo_sub_ctr: u8 = 0,
    first_fetch: bool = true,
    looped: bool = false,
};

const Parsed = struct {
    track_off: [voice_count]usize,
    track_len: [voice_count]usize,
    inst_off: usize,
    inst_len: usize,
    used: u32,
};

const IndexSink = struct {
    gpa: std.mem.Allocator,
    events: *std.ArrayList(view.SequenceEvent),
    failed: bool = false,
    tick: u32 = 0,
    track: u16 = 0,
    pos: u32 = 0,

    fn push(self: *IndexSink, kind: view.SequenceEventKind, payload: view.EventPayload) void {
        if (self.events.items.len >= max_index_events) return;
        self.events.append(self.gpa, .{
            .tick = self.tick,
            .instr_index = self.pos,
            .track = self.track,
            .channel = @intCast(self.track),
            .kind = kind,
            .payload = payload,
        }) catch {
            self.failed = true;
        };
    }
};

fn oplReg(asm_ch: usize, op: usize, grp: usize) u16 {
    var r: u16 = op_base[op] - 0x20 + reg_grp[grp];
    r += ch_slot[asm_ch];
    if (ch_bank[asm_ch] != 0) r |= 0x100;
    return r;
}

fn aReg(asm_ch: usize) u16 {
    var r: u16 = 0xa0 + @as(u16, asm_to_nuked[asm_ch] % 9);
    if (ch_bank[asm_ch] != 0) r |= 0x100;
    return r;
}

fn bReg(asm_ch: usize) u16 {
    return aReg(asm_ch) + 0x10;
}

fn takeByte(work: []const u8, pos: *usize, end: usize) u8 {
    if (pos.* >= end) return 0;
    const b = work[pos.*];
    pos.* += 1;
    return b;
}

fn takeWord(work: []const u8, pos: *usize, end: usize) u16 {
    const lo = takeByte(work, pos, end);
    const hi = takeByte(work, pos, end);
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

fn takeI16(work: []const u8, pos: *usize, end: usize) i16 {
    return @bitCast(takeWord(work, pos, end));
}

fn wrapI16(v: i32) i16 {
    return @truncate(v);
}

fn wrapU16FromI32(v: i32) u16 {
    return @bitCast(wrapI16(v));
}

fn attenOf(volume: u8, lfo_accum: u8) u8 {
    const raw: i32 = @as(i32, vol_tab[volume & 0x0f]) - @as(i32, @as(i8, @bitCast(lfo_accum)));
    return @intCast(std.math.clamp(raw, 0, 63));
}

fn clampNote(idx: i32) u8 {
    if (idx < 0) return 0;
    if (idx > 127) return 127;
    return @intCast(idx);
}

fn parse(data: []const u8) error{InvalidWm}!?Parsed {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    if (data.len < header_bytes) return error.InvalidWm;
    if (data.len > 0x10000) return null;

    var raw_track: [voice_count]u16 = undefined;
    for (0..voice_count) |i| {
        raw_track[i] = fmt.readU16Le(data, 0x10 + i * 2);
    }
    const raw_inst = fmt.readU16Le(data, 0x1c);
    var eof: usize = fmt.readU16Le(data, 0x1e);
    if (eof < header_bytes or eof > data.len) eof = data.len;

    var inst_off: usize = raw_inst;
    if (inst_off < header_bytes or inst_off >= data.len) inst_off = 0;

    var track_off: [voice_count]usize = @splat(0);
    var track_len: [voice_count]usize = @splat(0);
    var used: u32 = 0;
    for (0..voice_count) |i| {
        const off: usize = raw_track[i];
        if (off < header_bytes or off >= data.len or off >= eof) continue;
        track_off[i] = off;
        track_len[i] = eof - off;
        used += 1;
    }
    if (used == 0) return error.InvalidWm;

    var inst_len: usize = 0;
    if (inst_off > 0) {
        var inst_end = data.len;
        for (track_off) |off| {
            if (off > inst_off and off < inst_end) inst_end = off;
        }
        if (eof > inst_off and eof < inst_end) inst_end = eof;
        inst_len = inst_end - inst_off;
    }

    return .{
        .track_off = track_off,
        .track_len = track_len,
        .inst_off = inst_off,
        .inst_len = inst_len,
        .used = used,
    };
}

fn parseInstruments(data: []const u8, parsed: Parsed, dest: []Inst) u16 {
    if (parsed.inst_off == 0 or parsed.inst_len < inst_bytes) return 0;
    const n = @min(parsed.inst_len / inst_bytes, dest.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = data[parsed.inst_off + i * inst_bytes ..][0..inst_bytes];
        dest[i] = .{
            .id = e[0x15],
            .flags = e[0x14],
            .regs = e[0..inst_regs].*,
            .vib_rate = e[0x16] & 3,
            .vib_speed = e[0x17],
            .vib_amp = @as(u16, e[0x18]) | (@as(u16, e[0x19]) << 8),
            .vib_delay = e[0x1a],
            .lfo_lo = e[0x1b],
            .lfo_hi = e[0x1c],
            .lfo_amp = e[0x1d],
        };
    }
    return @intCast(n);
}

fn findSlot(insts: []const Inst, id: u8) ?u16 {
    for (insts, 0..) |inst, slot| {
        if (inst.id == id) return @intCast(slot);
    }
    return null;
}

fn jumpRel(ch: *Channel, from: usize, off: i16) bool {
    const tgt: i64 = @as(i64, @intCast(from)) + off;
    if (tgt < 0) return false;
    const ut: usize = @intCast(tgt);
    if (ut < ch.start or ut >= ch.end) return false;
    ch.pos = ut;
    return true;
}

const WmSource = struct {
    file: []const u8,
    work: []u8,
    insts: []Inst,
    parsed: Parsed,
    sample_rate: u32,
    frac: u32 = 0,
    tick: u32 = 0,
    pit_div: u32 = default_pit_div,
    transpose: i8 = 0,
    looping: bool = false,
    need_prologue: bool = false,
    total_ticks: u32 = 0,
    total_frames: u64 = 0,
    mean_tick_rate: u32 = default_tick_hz,
    chan: [voice_count]Channel = @splat(.{}),
    events: []view.SequenceEvent = &.{},

    fn framesFor(self: *WmSource, ticks: u64) u64 {
        return fmt.rescale(ticks * self.pit_div, pit_hz, self.sample_rate, &self.frac);
    }

    fn writePrologue(chip: fmt.Chip) void {
        chip_adapter.enableNew(chip);
        chip.writeReg(0x104, 0x3f);
        chip.writeReg(0x0bd, 0x40);
    }

    fn tickRate(self: *const WmSource) u32 {
        return pit_hz / self.pit_div;
    }

    fn resetChannels(self: *WmSource) void {
        self.chan = @splat(.{});
        for (0..voice_count) |i| {
            var ch = &self.chan[i];
            ch.flags = .{ .active = true };
            ch.wait_remain = 1;
            const off = self.parsed.track_off[i];
            const len = self.parsed.track_len[i];
            if (off != 0 and len != 0) {
                ch.start = off;
                ch.pos = off;
                ch.end = off + len;
            }
        }
        self.transpose = 0;
        self.pit_div = default_pit_div;
        self.tick = 0;
        self.frac = 0;
    }

    fn rewindPlay(self: *WmSource) void {
        @memcpy(self.work, self.file);
        self.resetChannels();
        self.need_prologue = true;
    }

    fn applyChannelC(self: *WmSource, asm_ch: usize, chip: fmt.Chip) void {
        const ch = &self.chan[asm_ch];
        const translated = c_xlat_table[ch.c_xlat_index & 0x0f];
        const cl = (ch.inst_flags >> 1) | translated;
        const c0 = cl;
        const c3 = (cl & 0xfe) | (ch.inst_flags & 1);
        const bank: u16 = if (ch_bank[asm_ch] != 0) 0x100 else 0;
        const slot = ch_slot[asm_ch];
        chip.writeReg(bank | (0xc0 + slot), c0);
        chip.writeReg(bank | (0xc3 + slot), c3);
    }

    fn applyVolume(self: *WmSource, asm_ch: usize, chip: fmt.Chip) void {
        const ch = &self.chan[asm_ch];
        const atten = attenOf(ch.volume, ch.lfo_accum);
        var conn = conn_table[ch.c_val_saved & 3];
        for (0..4) |op| {
            const bit = conn & 1;
            conn >>= 1;
            if (bit == 0) continue;
            const tl = ch.op_tl[op];
            const new_tl: u8 = @intCast(@min(63, @as(u16, tl & 0x3f) + atten));
            chip.writeReg(oplReg(asm_ch, op, 1), (tl & 0xc0) | new_tl);
        }
    }

    fn loadInstrument(self: *WmSource, asm_ch: usize, inst_id: u8, chip: fmt.Chip) void {
        var ch = &self.chan[asm_ch];
        const slot = findSlot(self.insts, inst_id) orelse {
            ch.inst_slot = view.sequence_unassigned;
            return;
        };
        const inst = &self.insts[slot];
        ch.inst_id = inst_id;
        ch.inst_slot = slot;
        ch.inst_flags = inst.flags;
        ch.c_val_saved = inst.flags;
        const conn = conn_table[inst.flags & 3];
        const atten = attenOf(ch.volume, ch.lfo_accum);
        for (0..4) |op| {
            const carrier = (conn >> @intCast(op)) & 1;
            for (0..5) |grp| {
                var val = inst.regs[op * 5 + grp];
                const reg = oplReg(asm_ch, op, grp);
                if (grp == 1 and carrier != 0) {
                    const new_tl: u8 = @intCast(@min(63, @as(u16, val & 0x3f) + atten));
                    val = (val & 0xc0) | new_tl;
                }
                if (grp == 4) {
                    if (val == ch.op_waveform[op]) continue;
                    ch.op_waveform[op] = val;
                }
                chip.writeReg(reg, val);
            }
            ch.op_tl[op] = inst.regs[op * 5 + 1];
        }
        self.applyChannelC(asm_ch, chip);

        if (inst.vib_speed != 0) {
            ch.porta_rate = inst.vib_rate;
            ch.porta_speed = inst.vib_speed;
            ch.vibrato_amp = @bitCast(inst.vib_amp);
            ch.porta_delay = inst.vib_delay;
            self.portaInit(asm_ch);
        } else {
            ch.fx.vibrato = false;
        }

        if (inst.lfo_lo != 0 and inst.lfo_hi != 0) {
            ch.lfo_lo = inst.lfo_lo;
            ch.lfo_hi = inst.lfo_hi;
            ch.lfo_amp = inst.lfo_amp;
            ch.fx.lfo = true;
            ch.lfo_sub_step = 0;
            const lo = ch.lfo_lo;
            const hi = ch.lfo_hi;
            if (hi >= lo) {
                ch.lfo_hi = if (lo > 0) hi / lo else hi;
            } else {
                ch.lfo_sub_step = if (hi > 0) lo / hi else 0;
                ch.lfo_hi = 1;
            }
        } else {
            ch.fx.lfo = false;
        }
    }

    fn channelNoteOff(self: *WmSource, asm_ch: usize, chip: fmt.Chip) void {
        var ch = &self.chan[asm_ch];
        if (!ch.flags.sounding) return;
        ch.flags.sounding = false;
        ch.flags.need_freq = false;
        ch.flags.skip_ties = false;
        chip.writeReg(aReg(asm_ch), ch.a_reg_val);
        chip.writeReg(bReg(asm_ch), ch.b_reg_val);
    }

    fn calcFrequency(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        const idx = clampNote(@as(i32, ch.note) + self.transpose);
        ch.freq_raw = freq_tab[idx];
        ch.flags.need_freq = true;
    }

    fn applyFrequency(self: *WmSource, asm_ch: usize, freq_in: u16, chip: fmt.Chip) void {
        var ch = &self.chan[asm_ch];
        var freq = freq_in;
        var octave: u8 = 0;
        while (freq > 0x3ff) {
            octave += 1;
            freq >>= 1;
        }
        const new_a: u8 = @truncate(freq);
        chip.writeReg(aReg(asm_ch), new_a);
        ch.a_reg_val = new_a;
        var al: u8 = @truncate((freq >> 8) & 3);
        al |= (octave & 7) << 2;
        ch.b_reg_val = al;
        if (ch.flags.sounding) al |= 0x20;
        chip.writeReg(bReg(asm_ch), al);
    }

    fn portaInit(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.porta_speed == 0) return;
        ch.fx.vibrato = true;
        ch.porta_wait = ch.porta_speed;
        ch.porta_flip = 0;
        if (ch.porta_rate == 1) {
            ch.porta_step_saved = ch.vibrato_amp;
        } else {
            const speed: i32 = ch.porta_speed;
            ch.porta_step_saved = wrapI16(@divTrunc(@as(i32, ch.vibrato_amp), speed));
            ch.porta_target = wrapI16(@rem(@as(i32, ch.vibrato_amp), speed));
            if (ch.porta_rate >= 2) ch.vibrato_amp = 0;
        }
    }

    fn portaRestart(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (!ch.fx.vibrato) return;
        ch.porta_flip = 0;
        ch.porta_wait = ch.porta_speed;
        ch.porta_step = ch.porta_step_saved;
        ch.porta_step2 = ch.porta_target;
        ch.porta_delay_ctr = ch.porta_delay;
        ch.porta_accum = ch.vibrato_amp;
    }

    fn portaTick(self: *WmSource, asm_ch: usize) i16 {
        var ch = &self.chan[asm_ch];
        if (ch.porta_delay_ctr > 0) {
            ch.porta_delay_ctr -= 1;
            if (ch.porta_delay_ctr > 0) return 0;
        }
        if (ch.porta_rate == 0) {
            ch.porta_wait -%= 1;
            if (ch.porta_wait != 0) {
                ch.porta_accum -%= ch.porta_step;
                return ch.porta_accum;
            }
            ch.porta_wait = ch.porta_speed;
            ch.porta_accum = ch.vibrato_amp;
            return ch.porta_accum;
        }
        if (ch.porta_rate == 1) {
            ch.porta_wait -%= 1;
            if (ch.porta_wait == 0) {
                ch.porta_wait = ch.porta_speed;
                ch.vibrato_amp = -%ch.vibrato_amp;
            }
            return ch.vibrato_amp;
        }
        ch.porta_wait -%= 1;
        if (ch.porta_wait != 0) {
            ch.porta_accum +%= ch.porta_step;
            return ch.porta_accum;
        }
        ch.porta_wait = ch.porta_speed;
        ch.porta_flip = (ch.porta_flip + 1) & 3;
        if (ch.porta_flip & 1 == 0) {
            const old = ch.porta_accum;
            ch.porta_accum = 0;
            return old;
        }
        ch.porta_accum +%= ch.porta_step +% ch.porta_step2;
        ch.porta_step = -%ch.porta_step;
        ch.porta_step2 = -%ch.porta_step2;
        return ch.porta_accum;
    }

    fn lfoRestart(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (!ch.fx.lfo) return;
        ch.lfo_period_ctr = ch.lfo_lo;
        ch.lfo_delay_ctr = ch.lfo_amp;
        ch.lfo_sub_ctr = ch.lfo_sub_step;
        ch.lfo_step = ch.lfo_hi;
        ch.lfo_accum = 0;
    }

    fn lfoTick(self: *WmSource, asm_ch: usize, chip: fmt.Chip) void {
        var ch = &self.chan[asm_ch];
        if (!ch.fx.lfo) return;
        if (ch.lfo_delay_ctr > 0) {
            ch.lfo_delay_ctr -= 1;
            if (ch.lfo_delay_ctr > 0) return;
        }
        ch.lfo_period_ctr -%= 1;
        if (ch.lfo_period_ctr == 0) {
            ch.lfo_sub_ctr = ch.lfo_sub_step;
            ch.lfo_period_ctr = ch.lfo_lo;
            const lfo_delta: i8 = @bitCast(ch.lfo_step);
            ch.lfo_step = @bitCast(0 -% lfo_delta);
            const acc: i8 = @bitCast(ch.lfo_accum);
            const now: i8 = @bitCast(ch.lfo_step);
            ch.lfo_accum = @bitCast(acc +% now);
            self.applyVolume(asm_ch, chip);
            return;
        }
        if (ch.lfo_sub_ctr > 0) {
            ch.lfo_sub_ctr -= 1;
            if (ch.lfo_sub_ctr > 0) return;
        }
        ch.lfo_sub_ctr = ch.lfo_sub_step;
        const acc: i8 = @bitCast(ch.lfo_accum);
        const now: i8 = @bitCast(ch.lfo_step);
        ch.lfo_accum = @bitCast(acc +% now);
        self.applyVolume(asm_ch, chip);
    }

    fn frequencyUpdate(self: *WmSource, asm_ch: usize, chip: fmt.Chip) void {
        var ch = &self.chan[asm_ch];
        if (!ch.flags.active) return;
        var freq_add: i32 = 0;
        if (ch.flags.need_freq) {
            ch.flags.need_freq = false;
            ch.flags.sounding = true;
            ch.slide_accum = 0;
            self.portaRestart(asm_ch);
            self.lfoRestart(asm_ch);
        } else if (!ch.flags.sounding) {
            return;
        } else {
            if (ch.fx.lfo) self.lfoTick(asm_ch, chip);
            if (ch.fx.vibrato) freq_add += self.portaTick(asm_ch);
            if (ch.fx.slide) {
                if (ch.wait_remain <= 1) {
                    ch.freq_raw = @bitCast(ch.slide_target);
                    ch.fx.slide = false;
                } else {
                    ch.slide_accum +%= ch.slide_step;
                    freq_add += ch.slide_accum;
                }
            }
            if (wrapI16(freq_add) == 0) return;
        }
        freq_add += ch.freq_raw;
        freq_add += ch.pitch_wheel;
        self.applyFrequency(asm_ch, wrapU16FromI32(freq_add), chip);
    }

    fn f4Push(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        const val = takeByte(self.work, &ch.pos, ch.end);
        if (ch.f4_depth < f4_cap) {
            ch.f4_params[ch.f4_depth] = val;
            ch.f4_depth += 1;
        }
    }

    fn f5Skip(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.f4_depth == 0) {
            ch.pos = @min(ch.pos + 2, ch.end);
            return;
        }
        const val = ch.f4_params[ch.f4_depth - 1];
        if (val == 1) {
            const cur = ch.pos;
            const off = takeI16(self.work, &ch.pos, ch.end);
            if (!jumpRel(ch, cur, off)) ch.pos = @min(cur + 2, ch.end);
            ch.f4_depth -= 1;
        } else {
            ch.pos = @min(ch.pos + 2, ch.end);
        }
    }

    fn f6Loop(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.f4_depth == 0) {
            ch.pos = @min(ch.pos + 2, ch.end);
            return;
        }
        const idx = ch.f4_depth - 1;
        ch.f4_params[idx] -%= 1;
        if (ch.f4_params[idx] == 0) {
            ch.pos = @min(ch.pos + 2, ch.end);
            ch.f4_depth -= 1;
        } else {
            const cur = ch.pos;
            const off = takeI16(self.work, &ch.pos, ch.end);
            if (!jumpRel(ch, cur, off)) ch.pos = @min(cur + 2, ch.end);
        }
    }

    fn f7Once(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.f4_depth == 0) {
            ch.pos = @min(ch.pos + 1, ch.end);
            return;
        }
        const val = ch.f4_params[ch.f4_depth - 1];
        if (val -% 1 == 0) {
            const off: i8 = @bitCast(takeByte(self.work, &ch.pos, ch.end));
            _ = jumpRel(ch, ch.pos -| 1, off);
            ch.f4_depth -= 1;
        } else {
            ch.pos = @min(ch.pos + 1, ch.end);
        }
    }

    fn f8Loop(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.f4_depth == 0) {
            ch.pos = @min(ch.pos + 1, ch.end);
            return;
        }
        const idx = ch.f4_depth - 1;
        if (ch.f4_params[idx] > 0) ch.f4_params[idx] -= 1;
        if (ch.f4_params[idx] == 0) {
            ch.pos = @min(ch.pos + 1, ch.end);
            ch.f4_depth -= 1;
        } else {
            const cur = ch.pos;
            const off: i8 = @bitCast(takeByte(self.work, &ch.pos, ch.end));
            if (!jumpRel(ch, cur, off)) ch.pos = @min(cur + 1, ch.end);
        }
    }

    fn f1Jump(self: *WmSource, asm_ch: usize, sink: ?*IndexSink) void {
        var ch = &self.chan[asm_ch];
        const cur = ch.pos;
        const off = takeI16(self.work, &ch.pos, ch.end);
        if (jumpRel(ch, cur, off)) {
            if (ch.pos < cur) {
                ch.looped = true;
                if (sink) |s| s.push(.jump, .{ .jump = @intCast(ch.pos) });
            }
        } else {
            ch.pos = @min(cur + 2, ch.end);
        }
    }

    fn f2Repeat(self: *WmSource, asm_ch: usize) void {
        var ch = &self.chan[asm_ch];
        if (ch.pos >= ch.end) return;
        const count_at = ch.pos;
        const count = takeByte(self.work, &ch.pos, ch.end);
        const off = takeI16(self.work, &ch.pos, ch.end);
        if (count > 0) {
            const new_count = count - 1;
            self.work[count_at] = new_count;
            if (new_count > 0) {
                _ = jumpRel(ch, ch.pos, off);
            }
        }
    }

    fn processChannel(self: *WmSource, asm_ch: usize, chip: fmt.Chip, sink: ?*IndexSink) bool {
        var ch = &self.chan[asm_ch];
        if (!ch.flags.active) return false;

        if (ch.flags.sounding and !ch.flags.skip_ties and ch.wait_remain == ch.ties_remain) {
            self.channelNoteOff(asm_ch, chip);
        }

        if (ch.wait_remain > 0) {
            ch.wait_remain -= 1;
            if (ch.wait_remain > 0) return true;
        }

        if (ch.flags.skip_ties) {
            ch.fx.held = true;
            ch.flags.skip_setup = true;
            ch.flags.skip_ties = false;
        } else {
            ch.flags.skip_setup = false;
            self.channelNoteOff(asm_ch, chip);
            ch.fx.slide = false;
        }
        const first_fetch = ch.first_fetch;
        ch.first_fetch = false;

        var ops: u32 = 0;
        while (ops < max_ops_per_step) : (ops += 1) {
            if (ch.pos >= ch.end) {
                ch.flags.active = false;
                return false;
            }
            if (sink) |s| {
                s.track = @intCast(asm_ch);
                s.pos = @intCast(@min(ch.pos, std.math.maxInt(u32)));
            }
            const cmd = takeByte(self.work, &ch.pos, ch.end);

            if (cmd < 0x80) {
                if (cmd != ch.note) {
                    ch.fx.held = false;
                    ch.flags.skip_setup = false;
                }
                ch.note = cmd;
                ch.shown_note = cmd;
                const dur = takeByte(self.work, &ch.pos, ch.end);
                ch.wait_remain = dur;
                if (!ch.flags.skip_ties) {
                    if (ch.ties_factor == 0) {
                        ch.ties_remain = 1;
                    } else {
                        const ties = @as(i32, dur) - @divTrunc(@as(i32, dur) * ch.ties_factor, 8);
                        ch.ties_remain = @intCast(@max(@as(i32, 1), ties));
                    }
                }
                if (sink) |s| s.push(.duration_note, .{ .note = .{
                    .note = cmd,
                    .velocity = ch.volume,
                    .duration_ticks = dur,
                } });
                if (ch.flags.skip_setup or (first_fetch and dur == 1)) return true;
                self.calcFrequency(asm_ch);
                ch.flags.sounding = true;
                return true;
            }

            if (cmd == 0x80) {
                ch.wait_remain = takeByte(self.work, &ch.pos, ch.end);
                ch.flags.sounding = false;
                ch.flags.need_freq = false;
                ch.flags.skip_ties = false;
                if (sink) |s| s.push(.note_off, .{ .note = .{ .note = ch.note, .velocity = 0, .duration_ticks = ch.wait_remain } });
                return true;
            }

            if (cmd == 0xf0) {
                ch.flags.active = false;
                self.channelNoteOff(asm_ch, chip);
                return false;
            }

            if (cmd <= 0x8f) {
                switch (cmd & 0x0f) {
                    0x01 => {
                        ch.inst_id = takeByte(self.work, &ch.pos, ch.end);
                        self.loadInstrument(asm_ch, ch.inst_id, chip);
                        if (sink) |s| s.push(.program, .{ .program = ch.inst_slot });
                    },
                    0x02 => {},
                    0x03 => ch.flags.skip_ties = true,
                    0x04 => {
                        const v = takeWord(self.work, &ch.pos, ch.end);
                        if (v > 0) self.pit_div = @max(1, tempo_num / v);
                        if (sink) |s| s.push(.tempo, .{ .tempo = self.tickRate() });
                    },
                    0x05 => ch.ties_factor = takeByte(self.work, &ch.pos, ch.end) & 7,
                    0x06 => {},
                    0x07 => {
                        ch.volume = takeByte(self.work, &ch.pos, ch.end) & 0x0f;
                        self.applyVolume(asm_ch, chip);
                    },
                    0x08 => self.transpose = @bitCast(takeByte(self.work, &ch.pos, ch.end)),
                    0x09 => {
                        ch.c_xlat_index = takeByte(self.work, &ch.pos, ch.end);
                        self.applyChannelC(asm_ch, chip);
                    },
                    0x0a => {
                        ch.expression = takeByte(self.work, &ch.pos, ch.end) -% 1;
                        self.applyVolume(asm_ch, chip);
                    },
                    0x0b => ch.pitch_wheel = takeI16(self.work, &ch.pos, ch.end),
                    0x0c => {
                        if (ch.expression < 7) ch.expression += 1;
                        self.applyVolume(asm_ch, chip);
                    },
                    0x0d => {
                        if (ch.expression > 0) ch.expression -= 1;
                        self.applyVolume(asm_ch, chip);
                    },
                    0x0e => {
                        if (ch.volume < 15) ch.volume += 1;
                        self.applyVolume(asm_ch, chip);
                    },
                    0x0f => {
                        if (ch.volume > 0) ch.volume -= 1;
                        self.applyVolume(asm_ch, chip);
                    },
                    else => {},
                }
                continue;
            }

            if (cmd <= 0x9f) {
                switch (cmd) {
                    0x90 => {
                        const target_word = takeWord(self.work, &ch.pos, ch.end);
                        const dur = takeByte(self.work, &ch.pos, ch.end);
                        const note_idx = clampNote(@as(i32, target_word & 0xff) + self.transpose);
                        const target_idx = clampNote(@as(i32, (target_word >> 8) & 0xff) + self.transpose);
                        const freq_note = freq_tab[note_idx];
                        const freq_target = freq_tab[target_idx];
                        ch.wait_remain = dur;
                        ch.ties_remain = 0;
                        ch.freq_raw = freq_note;
                        ch.slide_target = @bitCast(freq_target);
                        const divisor: i32 = if (dur < 1) 1 else dur;
                        ch.slide_step = wrapI16(@divTrunc(@as(i32, freq_target) - @as(i32, freq_note), divisor));
                        ch.slide_accum = 0;
                        ch.fx.slide = true;
                        ch.fx.held = false;
                        ch.flags.sounding = false;
                        ch.flags.need_freq = true;
                        ch.shown_note = clampNote(target_word & 0xff);
                        if (sink) |s| s.push(.duration_note, .{ .note = .{
                            .note = ch.shown_note,
                            .velocity = ch.volume,
                            .duration_ticks = dur,
                        } });
                        return true;
                    },
                    0x91 => {
                        ch.porta_rate = takeByte(self.work, &ch.pos, ch.end);
                        ch.porta_speed = takeByte(self.work, &ch.pos, ch.end);
                        ch.vibrato_amp = takeI16(self.work, &ch.pos, ch.end);
                        self.portaInit(asm_ch);
                    },
                    0x92 => ch.fx.vibrato = true,
                    0x93 => ch.fx.vibrato = false,
                    0x94 => ch.porta_delay = takeByte(self.work, &ch.pos, ch.end),
                    0x95 => _ = takeByte(self.work, &ch.pos, ch.end),
                    else => {},
                }
                continue;
            }

            if (cmd <= 0xef) continue;

            switch (cmd) {
                0xf1 => self.f1Jump(asm_ch, sink),
                0xf2 => self.f2Repeat(asm_ch),
                0xf3 => {
                    _ = takeByte(self.work, &ch.pos, ch.end);
                    _ = takeWord(self.work, &ch.pos, ch.end);
                },
                0xf4 => self.f4Push(asm_ch),
                0xf5 => self.f5Skip(asm_ch),
                0xf6 => self.f6Loop(asm_ch),
                0xf7 => self.f7Once(asm_ch),
                0xf8 => self.f8Loop(asm_ch),
                0xf9 => {
                    const r = takeByte(self.work, &ch.pos, ch.end);
                    const v = takeByte(self.work, &ch.pos, ch.end);
                    chip.writeReg(r, v);
                },
                else => {},
            }
        }
        ch.wait_remain = 1;
        return true;
    }

    fn allLooped(self: *const WmSource) bool {
        for (self.chan) |ch| {
            if (ch.flags.active and !ch.looped) return false;
        }
        return true;
    }

    fn anyActive(self: *const WmSource) bool {
        for (self.chan) |ch| {
            if (ch.flags.active) return true;
        }
        return false;
    }

    fn tickOnce(self: *WmSource, chip: fmt.Chip, sink: ?*IndexSink) struct { working: bool, looped: bool } {
        var working = false;
        for (0..voice_count) |i| {
            if (!self.chan[i].flags.active) continue;
            if (self.processChannel(i, chip, sink)) working = true;
            self.frequencyUpdate(i, chip);
        }
        return .{ .working = working, .looped = self.allLooped() and self.anyActive() };
    }

    pub fn step(self: *WmSource, chip: fmt.Chip) fmt.StepResult {
        if (self.need_prologue) {
            writePrologue(chip);
            for (0..voice_count) |i| chip.writeReg(bReg(i), 0);
            self.need_prologue = false;
        }
        const pit_div = self.pit_div;
        const r = self.tickOnce(chip, null);
        const ended = !r.working or r.looped or self.tick >= max_song_ticks;
        const frames = fmt.rescale(pit_div, pit_hz, self.sample_rate, &self.frac);
        if (ended) {
            self.rewindPlay();
            return .{ .frames = frames, .done = true };
        }
        self.tick +|= 1;
        return .{ .frames = frames };
    }

    pub fn info(self: *WmSource) fmt.TrackInfo {
        return .{
            .format_name = format_name,
            .opl3 = true,
            .system = "OPL3",
            .loop = self.looping,
        };
    }

    pub fn durationFrames(self: *WmSource) u64 {
        return self.total_frames;
    }

    pub fn getTickRate(self: *WmSource) u32 {
        return self.mean_tick_rate;
    }

    pub fn playhead(self: *WmSource) view.Playhead {
        return .{
            .tick = self.tick,
            .tempo = @intCast(@min(self.tickRate(), std.math.maxInt(u16))),
            .flags = .{ .has_tick = true, .has_tempo = true },
        };
    }

    pub fn sequenceState(self: *WmSource) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = voice_count };
        for (0..voice_count) |i| {
            const ch = self.chan[i];
            bank.slots[i] = .{
                .program = ch.inst_slot,
                .note = ch.shown_note,
                .keyed = ch.flags.sounding,
                .bend = @bitCast(ch.pitch_wheel),
                .transpose = self.transpose,
                .opl_voice = asm_to_nuked[i],
                .pc = if (ch.flags.active) @intCast(@min(ch.pos, std.math.maxInt(u32))) else view.sequence_pc_none,
                .duration = ch.wait_remain,
                .stack = ch.f4_depth,
                .fx = .{
                    .slide = ch.fx.slide,
                    .vibrato = ch.fx.vibrato,
                    .modulate = ch.fx.lfo,
                },
            };
        }
        return bank;
    }

    pub fn sequenceView(self: *WmSource) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .event_stream,
            .track_count = voice_count,
            .channel_count = voice_count,
            .tick_rate = self.mean_tick_rate,
            .length_ticks = self.total_ticks,
            .track = wmTrack,
            .eventAt = wmEventAt,
            .eventsInRange = wmEventsInRange,
            .event_count = @intCast(self.events.len),
        };
    }

    pub fn instrumentBank(self: *WmSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = @intCast(self.insts.len),
            .get = wmInstrument,
        };
    }

    pub fn deinit(self: *WmSource, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.insts);
        gpa.free(self.work);
        gpa.free(self.file);
        gpa.destroy(self);
    }
};

fn wmTrack(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self: *WmSource = @ptrCast(@alignCast(ptr));
    if (index >= voice_count) return .{};
    return .{
        .channel = @intCast(index),
        .kind = .melodic,
        .in_use = self.parsed.track_off[index] != 0,
    };
}

fn wmEventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self: *WmSource = @ptrCast(@alignCast(ptr));
    if (index >= self.events.len) return .{};
    return self.events[index];
}

fn wmEventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self: *WmSource = @ptrCast(@alignCast(ptr));
    var written: u16 = 0;
    var total: u32 = 0;
    for (self.events) |ev| {
        if (ev.tick < tick0 or ev.tick >= tick1) continue;
        total += 1;
        if (written < dest.len) {
            dest[written] = ev;
            written += 1;
        }
    }
    return .{ .written = written, .total_in_range = total };
}

fn wmInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self: *WmSource = @ptrCast(@alignCast(ptr));
    if (index >= self.insts.len) return .{};
    return .{ .patch = .{ .opl_4op = self.insts[index].oplPatch() } };
}

fn measure(
    gpa: std.mem.Allocator,
    src: *WmSource,
) !struct { ticks: u32, frames: u64, looping: bool, events: []view.SequenceEvent } {
    var list: std.ArrayList(view.SequenceEvent) = .empty;
    errdefer list.deinit(gpa);
    var sink = IndexSink{ .gpa = gpa, .events = &list };
    var frames: u64 = 0;
    var frac: u32 = 0;
    var looping = false;
    var ticks: u32 = 0;
    while (ticks < max_song_ticks) {
        sink.tick = ticks;
        const pit_div = src.pit_div;
        const r = src.tickOnce(fmt.noop_chip, &sink);
        if (sink.failed) return error.OutOfMemory;
        frames += fmt.rescale(pit_div, pit_hz, src.sample_rate, &frac);
        if (r.looped) looping = true;
        ticks += 1;
        if (!r.working or r.looped) break;
    }
    return .{
        .ticks = ticks,
        .frames = frames,
        .looping = looping,
        .events = try list.toOwnedSlice(gpa),
    };
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const parsed = (try parse(data)) orelse return null;

    const file = try gpa.dupe(u8, data);
    errdefer gpa.free(file);
    const work = try gpa.dupe(u8, data);
    errdefer gpa.free(work);

    var inst_buf: [max_insts]Inst = undefined;
    const ninst = parseInstruments(file, parsed, inst_buf[0..]);
    const insts = try gpa.dupe(Inst, inst_buf[0..ninst]);
    errdefer gpa.free(insts);

    const src = try gpa.create(WmSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .file = file,
        .work = work,
        .insts = insts,
        .parsed = parsed,
        .sample_rate = ctx.sample_rate,
    };
    src.resetChannels();

    const measured = try measure(gpa, src);
    errdefer gpa.free(measured.events);
    src.events = measured.events;
    src.total_ticks = measured.ticks;
    src.total_frames = measured.frames;
    if (measured.frames != 0) {
        const mean = (@as(u64, measured.ticks) * src.sample_rate + measured.frames / 2) / measured.frames;
        src.mean_tick_rate = @intCast(std.math.clamp(mean, 1, std.math.maxInt(u32)));
    }
    src.looping = measured.looping;

    @memcpy(src.work, src.file);
    src.resetChannels();
    WmSource.writePrologue(ctx.chip);
    ctx.chip.flush();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

fn putU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

fn pack(
    gpa: std.mem.Allocator,
    opts: struct {
        tracks: [voice_count][]const u8,
        insts: []const u8 = &.{},
        eof_override: ?u16 = null,
    },
) ![]u8 {
    var body: usize = 0;
    for (opts.tracks) |t| body += t.len;
    body += opts.insts.len;
    const total = header_bytes + body;
    const buf = try gpa.alloc(u8, total);
    @memset(buf, 0);
    @memcpy(buf[0..magic.len], magic);

    var off: u16 = header_bytes;
    for (opts.tracks, 0..) |t, i| {
        if (t.len == 0) {
            putU16(buf, 0x10 + i * 2, 0);
            continue;
        }
        putU16(buf, 0x10 + i * 2, off);
        @memcpy(buf[off..][0..t.len], t);
        off += @intCast(t.len);
    }
    const inst_off: u16 = if (opts.insts.len == 0) 0 else off;
    putU16(buf, 0x1c, inst_off);
    if (opts.insts.len != 0) {
        @memcpy(buf[off..][0..opts.insts.len], opts.insts);
        off += @intCast(opts.insts.len);
    }
    putU16(buf, 0x1e, opts.eof_override orelse off);
    return buf;
}

fn oneInst(id: u8) [inst_bytes]u8 {
    var rec: [inst_bytes]u8 = @splat(0);
    rec[0] = 0x01;
    rec[1] = 0x10;
    rec[5] = 0x01;
    rec[6] = 0x00;
    rec[0x14] = 0x00;
    rec[0x15] = id;
    return rec;
}

fn loadWm(gpa: std.mem.Allocator, data: []const u8) !fmt.MusicSource {
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".wm",
        .name = "tune.wm",
    })).?;
}

const empty_tracks: [voice_count][]const u8 = @splat(&.{});

const TestChip = struct {
    regs: [0x200]u8 = @splat(0),
    key_ons: u32 = 0,

    fn write(ptr: *anyopaque, reg: u16, value: u8) void {
        const self: *TestChip = @ptrCast(@alignCast(ptr));
        if (reg >= self.regs.len) return;
        if (reg == 0xb0 and value & 0x20 != 0 and !self.keyed()) self.key_ons += 1;
        self.regs[reg] = value;
    }

    fn flush(_: *anyopaque) void {}

    fn chip(self: *TestChip) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }

    fn keyed(self: *const TestChip) bool {
        return self.regs[0xb0] & 0x20 != 0;
    }

    fn pitch(self: *const TestChip) u32 {
        const b0 = self.regs[0xb0];
        const fnum = @as(u32, b0 & 3) << 8 | self.regs[0xa0];
        return fnum << @intCast((b0 >> 2) & 7);
    }
};

test "wm loads a one-note file" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x30, 0x04, 0xf0 };
    const inst = oneInst(1);
    const data = try pack(gpa, .{ .tracks = tracks, .insts = &inst });
    defer gpa.free(data);

    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("MusicV", src.info().format_name);
    try std.testing.expectEqualStrings("sequence", src.info().visualizer);
    try std.testing.expect(src.info().opl3);
    try std.testing.expectEqualStrings("OPL3", src.info().system.?);
    try std.testing.expectEqual(@as(u16, 1), src.views().instruments.?.count);
    try std.testing.expect(src.views().sequence.?.event_count >= 1);
    try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
}

test "wm F1 backward jump is a song loop" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x30, 0x02, 0xf1, 0xfd, 0xff, 0xf0 };
    const data = try pack(gpa, .{ .tracks = tracks });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    var saw_done = false;
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        if (src.step(fmt.noop_chip).done) {
            saw_done = true;
            break;
        }
    }
    try std.testing.expect(saw_done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}

test "wm rejects other magics and empty songs" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".wm", .name = "x.wm" };
    try std.testing.expect(try load(gpa, "not music here!!", ctx) == null);
    try std.testing.expect(try load(gpa, "OPL3", ctx) == null);
    try std.testing.expectError(error.InvalidWm, load(gpa, magic ++ @as([16]u8, @splat(0)), ctx));
    try std.testing.expectError(error.InvalidWm, load(gpa, magic ++ @as([4]u8, @splat(0)), ctx));
}

test "wm .m with OPL3 DATA is claimed and ultima-like .m is not" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x30, 0x01, 0xf0 };
    const data = try pack(gpa, .{ .tracks = tracks });
    defer gpa.free(data);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".m",
        .name = "tune.m",
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("MusicV", src.info().format_name);

    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".m", .name = "bootup.m" };
    try std.testing.expect(try load(gpa, &[_]u8{ 0x01, 0x00, 0x02, 0x00, 0x03 }, ctx) == null);
}

test "wm live state shows a 0x90 slide's start note" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x30, 0x04, 0x90, 0x24, 0x28, 0x08, 0xf0 };
    const data = try pack(gpa, .{ .tracks = tracks });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 0x30), src.sequenceState().?.slots[0].note);
    for (0..4) |_| _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 0x24), src.sequenceState().?.slots[0].note);
}

test "wm instrument feedback is the FB field the C registers receive" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x81, 0x01, 0x30, 0x04, 0xf0 };
    var inst = oneInst(1);
    inst[0x14] = 0x1d;
    const data = try pack(gpa, .{ .tracks = tracks, .insts = &inst });
    defer gpa.free(data);
    const Capture = struct {
        c0: u8 = 0,
        c3: u8 = 0,
        fn write(ptr: *anyopaque, reg: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg == 0xc0) self.c0 = value;
            if (reg == 0xc3) self.c3 = value;
        }
        fn flush(_: *anyopaque) void {}
    };
    var capture: Capture = .{};
    const chip: fmt.Chip = .{ .ptr = &capture, .vtable = &.{ .writeReg = Capture.write, .flush = Capture.flush } };
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    _ = src.step(chip);
    const bank = src.views().instruments.?;
    const patch = bank.get(bank.ctx, 0).opl();
    try std.testing.expectEqual(@as(u3, 7), patch.feedback);
    try std.testing.expectEqual(@as(u3, @truncate(capture.c0 >> 1)), patch.feedback);
    try std.testing.expectEqual(@as(u3, @truncate(capture.c3 >> 1)), patch.feedback2);
    try std.testing.expectEqual(@as(u8, 1), patch.algorithm);
}

test "wm instrument load before a repeated pitch still keys the note on" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x81, 0x01, 0x30, 0x04, 0x81, 0x01, 0x30, 0x04, 0xf0 };
    const inst = oneInst(1);
    const data = try pack(gpa, .{ .tracks = tracks, .insts = &inst });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    var test_chip: TestChip = .{};
    while (!src.step(test_chip.chip()).done) {}
    try std.testing.expectEqual(@as(u32, 2), test_chip.key_ons);
}

test "wm one-tick note on a voice's first fetch never keys on" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { track: []const u8, key_ons: u32 }{
        .{ .track = &.{ 0x30, 0x01, 0x34, 0x04, 0xf0 }, .key_ons = 1 },
        .{ .track = &.{ 0x80, 0x01, 0x30, 0x01, 0x34, 0x04, 0xf0 }, .key_ons = 2 },
    };
    for (cases) |case| {
        var tracks = empty_tracks;
        tracks[0] = case.track;
        const data = try pack(gpa, .{ .tracks = tracks });
        defer gpa.free(data);
        const src = try loadWm(gpa, data);
        defer src.deinit(gpa);
        var test_chip: TestChip = .{};
        while (!src.step(test_chip.chip()).done) {}
        try std.testing.expectEqual(case.key_ons, test_chip.key_ons);
    }
}

test "wm slide writes B0 with every step across an F-NUM high-bit boundary" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x90, 0x24, 0x28, 0x08, 0xf0 };
    const data = try pack(gpa, .{ .tracks = tracks });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    var test_chip: TestChip = .{};
    var last: u32 = 0;
    while (!src.step(test_chip.chip()).done) {
        try std.testing.expect(test_chip.pitch() >= last);
        last = test_chip.pitch();
    }
    try std.testing.expectEqual(@as(u8, 0x37), test_chip.regs[0xa0]);
    try std.testing.expectEqual(@as(u8, 0x0b), test_chip.regs[0xb0]);
}

test "wm voice starts at volume 10 and ties factor 0" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x81, 0x01, 0x30, 0x10, 0xf0 };
    const inst = oneInst(1);
    const data = try pack(gpa, .{ .tracks = tracks, .insts = &inst });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    var test_chip: TestChip = .{};
    var keyed_ticks: u32 = 0;
    while (!src.step(test_chip.chip()).done) {
        if (test_chip.keyed()) keyed_ticks += 1;
    }
    try std.testing.expectEqual(vol_tab[10], test_chip.regs[0x4b]);
    try std.testing.expectEqual(@as(u32, 16), keyed_ticks);
}

test "wm 0x84 tempo ticks at the PIT divisor MUSICV_2.COM programs" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0x84, 0x19, 0x00, 0x30, 0x08, 0xf0 };
    const data = try pack(gpa, .{ .tracks = tracks });
    defer gpa.free(data);
    const src = try loadWm(gpa, data);
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 20), src.playhead().?.tempo);
    for (0..7) |_| try std.testing.expectEqual(@as(u64, 2205), src.step(fmt.noop_chip).frames);
}
