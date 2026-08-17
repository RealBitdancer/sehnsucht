//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");

pub const visualizer_name = "tracker";

const voices = 9;
const patch_mask: u8 = 0x3f;
const max_patches = 63;
const max_orders = 255;
const pit_hz = 1_193_182;
const header_len = 17;
const patch_core = 33;
const patch_with_midi = 46;
const patch_without_midi = 40;
const slot_bytes = 3;
const missing_word: u16 = 0x8001;
const steps_per_octave = 12 * 16;

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };

const Reg = struct {
    const waveform_select: u16 = 0x01;
    const csw: u16 = 0x08;
    const char: u16 = 0x20;
    const level: u16 = 0x40;
    const ad: u16 = 0x60;
    const sr: u16 = 0x80;
    const fnum_lo: u16 = 0xa0;
    const key_block: u16 = 0xb0;
    const feedback: u16 = 0xc0;
    const wave: u16 = 0xe0;
    const rhythm: u16 = 0xbd;
    const key_on: u8 = 0x20;
};

const frequency = [_]u16{
    343, 344, 345, 347, 348, 349, 350, 352, 353, 354, 356, 357, 358,
    359, 361, 362, 363, 365, 366, 367, 369, 370, 371, 373, 374, 375,
    377, 378, 379, 381, 382, 384, 385, 386, 388, 389, 391, 392, 393,
    395, 396, 398, 399, 401, 402, 403, 405, 406, 408, 409, 411, 412,
    414, 415, 417, 418, 420, 421, 423, 424, 426, 427, 429, 430, 432,
    434, 435, 437, 438, 440, 442, 443, 445, 446, 448, 450, 451, 453,
    454, 456, 458, 459, 461, 463, 464, 466, 468, 469, 471, 473, 475,
    476, 478, 480, 481, 483, 485, 487, 488, 490, 492, 494, 496, 497,
    499, 501, 503, 505, 506, 508, 510, 512, 514, 516, 518, 519, 521,
    523, 525, 527, 529, 531, 533, 535, 537, 538, 540, 542, 544, 546,
    548, 550, 552, 554, 556, 558, 560, 562, 564, 566, 568, 571, 573,
    575, 577, 579, 581, 583, 585, 587, 589, 591, 594, 596, 598, 600,
    602, 604, 607, 609, 611, 613, 615, 618, 620, 622, 624, 627, 629,
    631, 633, 636, 638, 640, 643, 645, 647, 650, 652, 654, 657, 659,
    662, 664, 666, 669, 671, 674, 676, 678, 681, 683,
};

const vib_wave = [_]u8{
    0,   13,  25,  37,  50,  62,  74,  86,  98,  109, 120, 131, 142, 152, 162,
    171, 180, 189, 197, 205, 212, 219, 225, 231, 236, 240, 244, 247, 250, 252,
    254, 255, 255, 255, 254, 252, 250, 247, 244, 240, 236, 231, 225, 219, 212,
    205, 197, 189, 180, 171, 162, 152, 142, 131, 120, 109, 98,  86,  74,  62,
    50,  37,  25,  13,
};

const trem_wave = [_]u8{
    0,   0,   1,   1,   2,   4,   5,   7,   10,  12,  15,  18,  21,  25,  29,  33,
    37,  42,  47,  52,  57,  62,  67,  73,  79,  85,  90,  97,  103, 109, 115, 121,
    128, 134, 140, 146, 152, 158, 165, 170, 176, 182, 188, 193, 198, 203, 208, 213,
    218, 222, 226, 230, 234, 237, 240, 243, 245, 248, 250, 251, 253, 254, 254, 255,
    255, 255, 254, 254, 253, 251, 250, 248, 245, 243, 240, 237, 234, 230, 226, 222,
    218, 213, 208, 203, 198, 193, 188, 182, 176, 170, 165, 158, 152, 146, 140, 134,
    127, 121, 115, 109, 103, 97,  90,  85,  79,  73,  67,  62,  57,  52,  47,  42,
    37,  33,  29,  25,  21,  18,  15,  12,  10,  7,   5,   4,   2,   1,   1,   0,
};

comptime {
    if (frequency.len != steps_per_octave) @compileError("frequency table must cover 16 steps per octave");
    if (vib_wave.len != 64) @compileError("vibrato table must be 64 entries");
    if (trem_wave.len != 128) @compileError("tremolo table must be 128 entries");
}

const Op = struct {
    misc: u8 = 0,
    vol: u8 = 0,
    ad: u8 = 0,
    sr: u8 = 0,
    wave: u8 = 0,
};

const Patch = struct {
    mod: Op = .{},
    car: Op = .{},
    feedback: u8 = 0,
    key_off: u8 = 0,
    portamento: u8 = 0,
    glide: u8 = 0,
    finetune: u8 = 0,
    vibrato: u8 = 0,
    vib_delay: u8 = 0,
    mod_trem: u8 = 0,
    car_trem: u8 = 0,
    trem_wait: u8 = 0,
    arpeggio: u8 = 0,
    arp: [12]u8 = @splat(0),

    fn read(bytes: []const u8) Patch {
        return .{
            .mod = .{ .misc = bytes[0], .vol = bytes[1], .ad = bytes[2], .sr = bytes[3], .wave = bytes[4] },
            .car = .{ .misc = bytes[5], .vol = bytes[6], .ad = bytes[7], .sr = bytes[8], .wave = bytes[9] },
            .feedback = bytes[10],
            .key_off = bytes[11],
            .portamento = bytes[12],
            .glide = bytes[13],
            .finetune = bytes[14],
            .vibrato = bytes[15],
            .vib_delay = bytes[16],
            .mod_trem = bytes[17],
            .car_trem = bytes[18],
            .trem_wait = bytes[19],
            .arpeggio = bytes[20],
            .arp = bytes[21..33].*,
        };
    }

    fn write(self: Patch, buf: []u8) void {
        const fields = [_]u8{
            self.mod.misc, self.mod.vol,   self.mod.ad,     self.mod.sr,   self.mod.wave,
            self.car.misc, self.car.vol,   self.car.ad,     self.car.sr,   self.car.wave,
            self.feedback, self.key_off,   self.portamento, self.glide,    self.finetune,
            self.vibrato,  self.vib_delay, self.mod_trem,   self.car_trem, self.trem_wait,
            self.arpeggio,
        };
        @memcpy(buf[0..fields.len], &fields);
        @memcpy(buf[21..33], &self.arp);
    }

    fn additive(self: Patch) bool {
        return self.feedback & 1 != 0;
    }

    fn oplLevel(self: Patch, which: enum { mod, car }) u8 {
        const raw = if (which == .mod) self.mod.vol else self.car.vol;
        return raw ^ 0x3f;
    }
};

const Cmd = enum(u8) {
    wait = 0x80,
    midi_prog = 0xf0,
    midi_pan = 0xf1,
    hold_tremolo = 0xf2,
    fade = 0xf3,
    volume = 0xf4,
    finetune = 0xf5,
    glide = 0xf6,
    vibrato = 0xf7,
    clear_portamento = 0xf8,
    jump = 0xf9,
    next_order = 0xfa,
    key_off = 0xfb,
    stop = 0xfc,
    next_vol = 0xfd,
    tempo = 0xfe,
    scale_vol = 0xff,
    _,
};

const Event = union(enum) {
    empty,
    note: struct { degree: u8, patch: u8 },
    wait: u8,
    cmd: struct { id: Cmd, arg: u8 },

    fn decode(word: u16) Event {
        if (word == 0) return .empty;
        const hi: u8 = @truncate(word >> 8);
        const lo: u8 = @truncate(word);
        if (hi < 0x80) return .{ .note = .{ .degree = hi, .patch = lo } };
        if (hi == @intFromEnum(Cmd.wait)) return .{ .wait = lo };
        return .{ .cmd = .{ .id = @enumFromInt(hi), .arg = lo } };
    }

    fn jumpsOrder(self: Event) bool {
        return switch (self) {
            .cmd => |c| c.id == .jump or c.id == .next_order,
            else => false,
        };
    }
};

const Stream = struct {
    pos: u16 = 0,
    wait: u8 = 0,

    fn next(self: *Stream, pool: []const u16, start: u16) Event {
        if (self.wait != 0) {
            self.wait -= 1;
            return .empty;
        }
        const ev = Event.decode(wordAt(pool, start, self.pos));
        self.pos +%= 1;
        if (ev == .wait) self.wait = ev.wait;
        return ev;
    }

    fn reset(self: *Stream) void {
        self.* = .{};
    }
};

fn wordAt(pool: []const u16, start: u16, pos: u16) u16 {
    const idx = @as(usize, start) + pos;
    return if (idx < pool.len) pool[idx] else missing_word;
}

const Slot = struct {
    start: u16,
    transpose: u8,

    fn voiced(self: Slot, degree: u8, patch: u8) Voiced {
        return voiceNote(degree, patch, self.transpose);
    }
};

const Voiced = struct {
    patch: u8,
    pitch: u16,
    semitone: u8,
    octave: u8,
};

fn voiceNote(degree: u8, patch: u8, transpose: u8) Voiced {
    const delta = signExtend7(transpose);
    if (transpose & 0x80 != 0) {
        return .{
            .patch = @intCast((@as(i32, patch) + delta) & patch_mask),
            .pitch = @as(u16, degree) << 4,
            .semitone = degree % 12,
            .octave = degree / 12,
        };
    }
    const stepped: i32 = @as(i32, degree) + delta;
    const oct_i = @divFloor(stepped, 12);
    return .{
        .patch = patch & patch_mask,
        .pitch = wrap16(stepped << 4),
        .semitone = @intCast(@mod(stepped, 12)),
        .octave = if (oct_i < 0) 0 else @intCast(@min(oct_i, 9)),
    };
}

fn signExtend7(t: u8) i8 {
    const mag: u8 = t & 0x7f;
    return @bitCast(if (t & 0x40 != 0) mag | 0x80 else mag);
}

fn wrap16(n: i32) u16 {
    return @truncate(@as(u32, @bitCast(n)));
}

fn asI8(a: u8, b: u8) i8 {
    return @bitCast(a +% b);
}

fn pitchOf(tune: u16) struct { fnum: u16, octave: u16 } {
    return .{
        .fnum = frequency[tune % steps_per_octave],
        .octave = (tune / steps_per_octave) -% 1,
    };
}

fn mixArp(base: u16, arp: u16) u16 {
    if (arp >= 0x800) return base -% (arp ^ 0xff0) -% 16;
    return base +% arp;
}

fn approach(from: u16, to: u16, speed: u8) u16 {
    const gap = if (from > to) from - to else to - from;
    if (gap < speed) return to;
    return if (from > to) from - speed else from + speed;
}

fn scaleStored(level: u8, factor: u8, comptime shift: comptime_int) u8 {
    return (level & 0xc0) | @as(u8, @truncate((@as(u16, level & 0x3f) * factor) >> shift));
}

const Tremolo = struct {
    wait: u8 = 0,
    speed: u8 = 0,
    rate: u8 = 0,
    phase: u8 = 0,
    hold: bool = false,

    fn arm(self: *Tremolo, wait: u8, nibble: u8) void {
        if (self.hold) return;
        self.wait = wait;
        self.speed = nibble >> 4;
        self.rate = nibble & 15;
        self.phase = 0;
    }
};

const Held = struct {
    patch: u8,
    pitch: u16,
    left: u8,
};

const Voice = struct {
    pitch: u16 = 0,
    target: u16 = 0,
    stream: Stream = .{},
    finetune: u8 = 0,
    glide: u8 = 0,
    porta: u8 = 0,
    next_vol: u8 = 0,
    mod_vol: u8 = 0,
    car_vol: u8 = 0,
    vib_wait: u8 = 0,
    vib_speed: u8 = 0,
    vib_depth: u8 = 0,
    vib_phase: u8 = 0,
    key_left: u8 = 0,
    arp_len: u8 = 0,
    arp_speed: u8 = 0,
    arp_pos: u8 = 0,
    arp_tick: u8 = 0,
    arp: [12]u8 = @splat(0),
    mod_trem: Tremolo = .{},
    car_trem: Tremolo = .{},
    held: ?Held = null,

    fn resetCursor(self: *Voice) void {
        self.stream.reset();
    }
};

const Fade = struct {
    rate: u8 = 0,
    volume: u8 = 0,
    ceiling: u8 = 0,

    fn set(self: *Fade, volume: u8) void {
        self.volume = volume;
        self.ceiling = volume;
        self.rate = 0;
    }

    fn tick(self: *Fade) void {
        if (self.rate == 0) return;
        if (self.rate <= 128) {
            if (self.volume > self.rate or self.volume == 0) {
                self.volume -%= self.rate;
            } else {
                self.volume = 1;
                self.rate = 0;
            }
            return;
        }
        const rise: u8 = 0 -% self.rate;
        if (self.volume +% rise <= self.ceiling) {
            self.volume +%= rise;
        } else {
            self.volume = self.ceiling;
            self.rate = 0;
        }
    }
};

const Header = struct {
    speed: u16,
    tempo: u8,
    rows: u8,
    note_delay: [voices]u8,
    rhythm: u8,

    fn parse(data: []const u8) ?Header {
        if (data.len < header_len) return null;
        if (data[0] > 2) return null;
        var delay: [voices]u8 = undefined;
        @memcpy(&delay, data[5..14]);
        return .{
            .speed = fmt.readU16Le(data, 1),
            .tempo = data[3],
            .rows = data[4],
            .note_delay = delay,
            .rhythm = data[14],
        };
    }
};

const Sections = struct {
    patch_stride: usize,
    patch_count: u16,
    order_count: u16,
    slots_at: usize,
    pool_at: usize,
};

fn sectionsFit(data: []const u8, stride: usize) ?Sections {
    if (data.len < header_len) return null;
    const patch_count = fmt.readU16Le(data, 15);
    if (patch_count > max_patches) return null;
    const count_at = header_len + @as(usize, patch_count) * stride;
    if (count_at + 2 > data.len) return null;
    const order_count = fmt.readU16Le(data, count_at);
    if (order_count == 0 or order_count > max_orders) return null;
    const slots_at = count_at + 2;
    const digital_at = slots_at + @as(usize, order_count) * voices * slot_bytes;
    if (digital_at + 2 > data.len) return null;
    return .{
        .patch_stride = stride,
        .patch_count = patch_count,
        .order_count = order_count,
        .slots_at = slots_at,
        .pool_at = digital_at + 2,
    };
}

const Tick = enum { running, looped, stopped };

const LdsSource = struct {
    sample_rate: u32,
    frac: u32 = 0,
    header: Header,
    tempo: u8,
    tempo_left: u8 = 3,
    patches: []Patch,
    slots: []Slot,
    pool: []u16,
    view_order: []u8,
    format_name: []const u8,
    loops: bool,
    active: bool = true,
    looped: bool = false,
    order: u16 = 0,
    row: u8 = 0,
    cur_order: u16 = 0,
    cur_row: u8 = 0,
    jump_to: u16 = 0,
    last_patch: u8 = 0,
    fade: Fade = .{},
    voice: [voices]Voice = @splat(.{}),
    regs: [256]u8 = @splat(0),

    fn put(self: *LdsSource, chip: fmt.Chip, reg: u16, val: u8) void {
        const idx: u8 = @truncate(reg);
        if (self.regs[idx] == val) return;
        self.regs[idx] = val;
        chip.writeReg(reg, val);
    }

    fn putMasked(self: *LdsSource, chip: fmt.Chip, reg: u16, keep: u8, val: u8) void {
        const idx: u8 = @truncate(reg);
        self.put(chip, reg, (self.regs[idx] & keep) | val);
    }

    fn slot(self: *const LdsSource, order: u16, chan: u8) ?Slot {
        if (order >= self.view_order.len) return null;
        return self.slots[@as(usize, order) * voices + chan];
    }

    fn writePitch(self: *LdsSource, chip: fmt.Chip, chan: u8, tune: u16, key_on: bool) void {
        const p = pitchOf(tune);
        self.put(chip, Reg.fnum_lo + chan, @truncate(p.fnum));
        const block: u8 = @truncate((p.octave << 2) +% (p.fnum >> 8));
        if (key_on) {
            self.put(chip, Reg.key_block + chan, block +% Reg.key_on);
        } else {
            self.putMasked(chip, Reg.key_block + chan, Reg.key_on, block & ~Reg.key_on);
        }
    }

    fn writeOp(self: *LdsSource, chip: fmt.Chip, off: u8, op: Op, level: u8) void {
        self.put(chip, Reg.char + off, op.misc);
        self.put(chip, Reg.level + off, level);
        self.put(chip, Reg.ad + off, op.ad);
        self.put(chip, Reg.sr + off, op.sr);
        self.put(chip, Reg.wave + off, op.wave);
    }

    fn writeLevel(self: *LdsSource, chip: fmt.Chip, reg: u16, stored: u8) void {
        const scaled: u8 = if (self.fade.volume != 0)
            @truncate((@as(u16, stored) * self.fade.volume) >> 8)
        else
            stored;
        self.putMasked(chip, reg, 0xc0, scaled ^ 0x3f);
    }

    fn strike(self: *LdsSource, chip: fmt.Chip, patch_i: u8, chan: u8, tune_in: i32) void {
        if (patch_i >= self.patches.len) return;
        const patch = self.patches[patch_i];
        var v = &self.voice[chan];
        self.last_patch = patch_i;

        var tune: i32 = tune_in + asI8(patch.finetune, v.finetune);
        if (patch.arpeggio == 0) {
            const first: u16 = @as(u16, patch.arp[0]) << 4;
            tune = if (first > 0x800)
                tune - (@as(i32, first ^ 0xff0) + 16)
            else
                tune + first;
        }

        if (v.glide != 0) {
            v.target = wrap16(tune);
            v.porta = v.glide;
            v.glide = 0;
            v.finetune = 0;
            return;
        }

        const off = op_offset[chan];
        const use_next = v.next_vol != 0;
        v.mod_vol = if (!use_next or !patch.additive())
            patch.mod.vol
        else
            scaleStored(patch.mod.vol, v.next_vol, 6);
        v.car_vol = if (!use_next)
            patch.car.vol
        else
            scaleStored(patch.car.vol, v.next_vol, 6);

        const mod_level = if (patch.additive() and self.fade.volume != 0)
            scaleStored(v.mod_vol, self.fade.volume, 8)
        else
            v.mod_vol;
        const car_level = if (self.fade.volume != 0)
            scaleStored(v.car_vol, self.fade.volume, 8)
        else
            v.car_vol;
        self.writeOp(chip, off, patch.mod, mod_level ^ 0x3f);
        self.writeOp(chip, off + 3, patch.car, car_level ^ 0x3f);
        self.put(chip, Reg.feedback + chan, patch.feedback);
        self.putMasked(chip, Reg.key_block + chan, ~Reg.key_on, 0);

        const dest = wrap16(tune);
        if (patch.glide != 0) {
            self.writePitch(chip, chan, dest, true);
            v.pitch = dest;
            v.target = wrap16(@as(i32, dest) + asI8(patch.glide, 0));
            v.porta = patch.portamento;
        } else if (patch.portamento != 0 and v.pitch != 0) {
            v.target = dest;
            v.porta = patch.portamento;
            self.putMasked(chip, Reg.key_block + chan, ~Reg.key_on, Reg.key_on);
        } else {
            self.writePitch(chip, chan, dest, true);
            v.pitch = dest;
            v.target = dest;
        }

        if (patch.vibrato == 0) {
            v.vib_wait = 0;
            v.vib_speed = 0;
            v.vib_depth = 0;
        } else {
            v.vib_wait = patch.vib_delay;
            v.vib_speed = (patch.vibrato >> 4) + 2;
            v.vib_depth = (patch.vibrato & 15) + 1;
        }

        v.mod_trem.arm((patch.trem_wait & 0xf0) >> 3, patch.mod_trem);
        v.car_trem.arm((patch.trem_wait & 15) << 1, patch.car_trem);
        v.arp_len = @min(patch.arpeggio & 15, @as(u8, v.arp.len));
        v.arp_speed = patch.arpeggio >> 4;
        v.arp = patch.arp;
        v.key_left = patch.key_off;
        v.next_vol = 0;
        v.glide = 0;
        v.finetune = 0;
        v.vib_phase = 0;
        v.arp_pos = 0;
        v.arp_tick = 0;
    }

    fn releaseHeld(self: *LdsSource, chip: fmt.Chip) void {
        for (&self.voice, 0..) |*v, i| {
            const held = v.held orelse continue;
            if (held.left == 0) continue;
            const left = held.left - 1;
            if (left == 0) {
                v.held = null;
                self.strike(chip, held.patch, @intCast(i), held.pitch);
            } else {
                v.held = .{ .patch = held.patch, .pitch = held.pitch, .left = left };
            }
        }
    }

    fn playNote(self: *LdsSource, chip: fmt.Chip, chan: u8, note: Voiced) void {
        if (self.header.note_delay[chan] == 0) {
            self.strike(chip, note.patch, chan, note.pitch);
            return;
        }
        self.voice[chan].held = .{
            .patch = note.patch,
            .pitch = note.pitch,
            .left = self.header.note_delay[chan],
        };
    }

    fn apply(self: *LdsSource, chip: fmt.Chip, chan: u8, ev: Event) void {
        var v = &self.voice[chan];
        switch (ev) {
            .empty, .wait => {},
            .note => |n| {
                const s = self.slot(self.order, chan) orelse return;
                self.playNote(chip, chan, s.voiced(n.degree, n.patch));
            },
            .cmd => |c| switch (c.id) {
                .scale_vol => {
                    v.car_vol = @truncate((@as(u16, v.car_vol & 0x3f) * c.arg) >> 6);
                    if (self.regs[Reg.feedback + chan] & 1 != 0) {
                        v.mod_vol = @truncate((@as(u16, v.mod_vol & 0x3f) * c.arg) >> 6);
                    }
                },
                .tempo => self.tempo = c.arg & 0x3f,
                .next_vol => v.next_vol = c.arg,
                .stop => self.active = false,
                .key_off => v.key_left = 1,
                .next_order => self.jump_to = (self.order + 1) & max_orders,
                .jump => {
                    self.jump_to = c.arg;
                    if (self.jump_to <= self.order) self.looped = true;
                },
                .clear_portamento => v.pitch = 0,
                .vibrato => {
                    v.vib_wait = 0;
                    v.vib_speed = (c.arg >> 4) + 2;
                    v.vib_depth = (c.arg & 15) + 1;
                },
                .glide => v.glide = c.arg,
                .finetune => v.finetune = c.arg,
                .volume => self.fade.set(c.arg),
                .fade => self.fade.rate = c.arg,
                .hold_tremolo => {
                    v.mod_trem.hold = c.arg & 0xf0 != 0;
                    v.car_trem.hold = c.arg & 0x0f != 0;
                },
                .midi_prog, .midi_pan, .wait => {},
                else => if (@intFromEnum(c.id) < 0xa0) {
                    v.glide = @intFromEnum(c.id) & 0x1f;
                },
            },
        }
    }

    fn arpValue(v: *Voice) u16 {
        if (v.arp_len > v.arp.len) v.arp_len = @intCast(v.arp.len);
        if (v.arp_len == 0) return 0;
        if (v.arp_pos >= v.arp_len) v.arp_pos = 0;
        var interval: u16 = @as(u16, v.arp[v.arp_pos]) << 4;
        if (interval == 0x800) {
            if (v.arp_pos > 0) v.arp[0] = v.arp[v.arp_pos - 1];
            v.arp_len = 1;
            v.arp_pos = 0;
            interval = @as(u16, v.arp[0]) << 4;
        }
        if (v.arp_tick == v.arp_speed) {
            v.arp_pos += 1;
            if (v.arp_pos >= v.arp_len) v.arp_pos = 0;
            v.arp_tick = 0;
        } else {
            v.arp_tick += 1;
        }
        return interval;
    }

    fn applyPitchFx(self: *LdsSource, chip: fmt.Chip, chan: u8, v: *Voice, arp: u16) void {
        if (v.pitch != 0 and v.pitch != v.target) {
            v.pitch = approach(v.pitch, v.target, v.porta);
            self.writePitch(chip, chan, mixArp(v.pitch, arp), false);
            return;
        }
        if (v.vib_wait != 0) {
            v.vib_wait -= 1;
            if (v.arp_len != 0) self.writePitch(chip, chan, mixArp(v.pitch, arp), false);
            return;
        }
        if (v.vib_depth != 0) {
            const swing: u16 = @as(u16, vib_wave[v.vib_phase & 0x3f]) * v.vib_depth;
            const bent = if (v.vib_phase & 0x40 == 0)
                v.pitch +% (swing >> 8)
            else
                v.pitch -% (swing >> 8);
            self.writePitch(chip, chan, mixArp(bent, arp), false);
            v.vib_phase +%= v.vib_speed;
            return;
        }
        if (v.arp_len != 0) self.writePitch(chip, chan, mixArp(v.pitch, arp), false);
    }

    fn tremoloLevel(trem: *Tremolo, stored: u8) union(enum) { hold, live: u8 } {
        if (trem.wait != 0) {
            trem.wait -= 1;
            return .hold;
        }
        const base = stored & 0x3f;
        if (trem.rate == 0) return .{ .live = base };
        const raw: u16 = @as(u16, trem_wave[trem.phase & 0x7f]) * trem.rate;
        trem.phase +%= trem.speed;
        const dip: u8 = @truncate(raw >> 8);
        return .{ .live = if (dip <= base) base - dip else 0 };
    }

    fn applyLevels(self: *LdsSource, chip: fmt.Chip, chan: u8, v: *Voice) void {
        const off = op_offset[chan];
        const additive = self.regs[Reg.feedback + chan] & 1 != 0;

        switch (tremoloLevel(&v.mod_trem, v.mod_vol)) {
            .live => |level| {
                if (self.fade.volume != 0 and additive) {
                    self.writeLevel(chip, Reg.level + off, level);
                } else {
                    self.putMasked(chip, Reg.level + off, 0xc0, level ^ 0x3f);
                }
            },
            .hold => if (self.fade.volume != 0 and additive) {
                self.writeLevel(chip, Reg.level + off, v.mod_vol & 0x3f);
            },
        }

        switch (tremoloLevel(&v.car_trem, v.car_vol)) {
            .live => |level| self.writeLevel(chip, Reg.level + off + 3, level),
            .hold => if (self.fade.volume != 0) {
                self.writeLevel(chip, Reg.level + off + 3, v.car_vol & 0x3f);
            },
        }
    }

    fn applyFx(self: *LdsSource, chip: fmt.Chip) void {
        for (&self.voice, 0..) |*v, i| {
            const chan: u8 = @intCast(i);
            if (v.key_left > 0) {
                if (v.key_left == 1) self.putMasked(chip, Reg.key_block + chan, ~Reg.key_on, 0);
                v.key_left -= 1;
            }
            self.applyPitchFx(chip, chan, v, arpValue(v));
            self.applyLevels(chip, chan, v);
        }
    }

    fn finishRow(self: *LdsSource, jumped: bool) void {
        self.row = 0;
        for (&self.voice) |*v| v.resetCursor();
        self.order = if (jumped) self.jump_to else (self.order + 1) & max_orders;
        if (self.order >= self.view_order.len) self.active = false;
    }

    fn runRow(self: *LdsSource, chip: fmt.Chip) void {
        var jumped = false;
        for (&self.voice, 0..) |*v, i| {
            const chan: u8 = @intCast(i);
            const start = if (self.slot(self.order, chan)) |s| s.start else 0;
            const ev = v.stream.next(self.pool, start);
            if (ev.jumpsOrder()) jumped = true;
            self.apply(chip, chan, ev);
        }
        self.tempo_left = self.tempo;
        self.cur_order = self.order;
        self.cur_row = self.row;
        self.row +%= 1;
        if (jumped) {
            self.finishRow(true);
        } else if (self.row >= self.header.rows) {
            self.finishRow(false);
        }
    }

    fn tick(self: *LdsSource, chip: fmt.Chip) Tick {
        if (!self.active) return .stopped;
        self.fade.tick();
        self.releaseHeld(chip);
        if (self.tempo_left == 0) {
            self.runRow(chip);
        } else {
            self.tempo_left -= 1;
        }
        self.applyFx(chip);
        if (self.looped) {
            self.active = true;
            return .looped;
        }
        if (!self.active) return .stopped;
        return .running;
    }

    fn rewind(self: *LdsSource, chip: fmt.Chip) void {
        self.active = true;
        self.looped = false;
        self.tempo_left = 3;
        self.order = 0;
        self.row = 0;
        self.cur_order = 0;
        self.cur_row = 0;
        self.jump_to = 0;
        self.last_patch = 0;
        self.fade = .{};
        self.voice = @splat(.{});
        self.regs = @splat(0);
        self.tempo = self.header.tempo;

        self.put(chip, Reg.waveform_select, 0x20);
        self.put(chip, Reg.csw, 0);
        self.put(chip, Reg.rhythm, self.header.rhythm);
        for (0..voices) |i| {
            const chan: u8 = @intCast(i);
            const off = op_offset[chan];
            const silent = [_]struct { u16, u8 }{
                .{ Reg.char + off, 0 },
                .{ Reg.char + off + 3, 0 },
                .{ Reg.level + off, 0x3f },
                .{ Reg.level + off + 3, 0x3f },
                .{ Reg.ad + off, 0xff },
                .{ Reg.ad + off + 3, 0xff },
                .{ Reg.sr + off, 0xff },
                .{ Reg.sr + off + 3, 0xff },
                .{ Reg.wave + off, 0 },
                .{ Reg.wave + off + 3, 0 },
                .{ Reg.fnum_lo + chan, 0 },
                .{ Reg.key_block + chan, 0 },
                .{ Reg.feedback + chan, 0 },
            };
            for (silent) |pair| self.put(chip, pair[0], pair[1]);
        }
    }

    pub fn step(self: *LdsSource, chip: fmt.Chip) fmt.StepResult {
        if (!self.active) self.rewind(chip);
        const kind = self.tick(chip);
        const frames = fmt.rescale(self.header.speed, pit_hz, self.sample_rate, &self.frac);
        return switch (kind) {
            .running => .{ .frames = frames },
            .looped => blk: {
                self.looped = false;
                break :blk .{ .frames = frames, .done = true };
            },
            .stopped => blk: {
                self.active = false;
                break :blk .{ .frames = frames, .done = true };
            },
        };
    }

    pub fn info(self: *LdsSource) fmt.TrackInfo {
        return .{
            .format_name = self.format_name,
            .opl3 = false,
            .system = "OPL2",
            .loop = self.loops,
            .visualizer = visualizer_name,
        };
    }

    pub fn pos(self: *LdsSource) fmt.TrackerPos {
        return .{
            .order_pos = @truncate(self.cur_order),
            .row = self.cur_row,
            .pattern = @truncate(self.cur_order),
            .speed = self.tempo,
            .last_instrument = self.last_patch,
        };
    }

    pub fn trackerView(self: *LdsSource) fmt.TrackerView {
        return .{
            .ctx = self,
            .channels = voices,
            .rows_per_pattern = self.header.rows,
            .num_patterns = @intCast(self.view_order.len),
            .order = self.view_order,
            .cell = cellAt,
            .instrument = instrumentAt,
        };
    }

    pub fn deinit(self: *LdsSource, gpa: std.mem.Allocator) void {
        gpa.free(self.patches);
        gpa.free(self.slots);
        gpa.free(self.pool);
        gpa.free(self.view_order);
        gpa.destroy(self);
    }
};

fn cellAt(ptr: *anyopaque, pattern: u8, row: u8, chan: u8) fmt.TrackerCell {
    const self: *LdsSource = @ptrCast(@alignCast(ptr));
    if (pattern >= self.view_order.len or row >= self.header.rows or chan >= voices)
        return .{ .kind = .empty };
    const s = self.slots[@as(usize, pattern) * voices + chan];
    var cur = Stream{};
    var ev: Event = .empty;
    var t: u8 = 0;
    while (t <= row) : (t += 1) ev = cur.next(self.pool, s.start);
    return switch (ev) {
        .empty, .wait => .{ .kind = .empty },
        .note => |n| blk: {
            const voiced = s.voiced(n.degree, n.patch);
            break :blk .{
                .kind = .note,
                .semitone = voiced.semitone,
                .octave = voiced.octave,
                .arg = voiced.patch,
            };
        },
        .cmd => |c| if (c.id == .key_off)
            .{ .kind = .note_off }
        else
            .{ .kind = .effect_only, .arg = @intFromEnum(c.id) },
    };
}

fn instrumentAt(ptr: *anyopaque, index: u8) fmt.InstrumentInfo {
    const self: *LdsSource = @ptrCast(@alignCast(ptr));
    if (index >= self.patches.len) return std.mem.zeroes(fmt.InstrumentInfo);
    const p = self.patches[index];
    return .{
        .modulator = fmt.operatorParams(p.mod.misc, p.oplLevel(.mod), p.mod.ad, p.mod.sr, p.mod.wave),
        .carrier = fmt.operatorParams(p.car.misc, p.oplLevel(.car), p.car.ad, p.car.sr, p.car.wave),
        .feedback = @truncate((p.feedback >> 1) & 7),
        .additive = p.additive(),
    };
}

fn hasJump(pool: []const u16) bool {
    for (pool) |word| {
        switch (Event.decode(word)) {
            .cmd => |c| if (c.id == .jump) return true,
            else => {},
        }
    }
    return false;
}

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const header = Header.parse(data) orelse return null;
    if (header.speed == 0 or header.rows == 0) return error.InvalidLds;

    const prefer_old = std.ascii.eqlIgnoreCase(ctx.ext, ".ld0");
    const first: usize = if (prefer_old) patch_without_midi else patch_with_midi;
    const second: usize = if (prefer_old) patch_with_midi else patch_without_midi;
    const lay = sectionsFit(data, first) orelse
        sectionsFit(data, second) orelse return error.InvalidLds;

    const patches = try gpa.alloc(Patch, lay.patch_count);
    errdefer gpa.free(patches);
    for (patches, 0..) |*p, i| {
        p.* = Patch.read(data[header_len + i * lay.patch_stride ..]);
    }

    const slots = try gpa.alloc(Slot, @as(usize, lay.order_count) * voices);
    errdefer gpa.free(slots);
    var at = lay.slots_at;
    for (slots) |*s| {
        s.* = .{
            .start = fmt.readU16Le(data, at) / 2,
            .transpose = data[at + 2],
        };
        at += slot_bytes;
    }

    const pool = try gpa.alloc(u16, (data.len - lay.pool_at) / 2);
    errdefer gpa.free(pool);
    for (pool, 0..) |*word, i| {
        word.* = fmt.readU16Le(data, lay.pool_at + i * 2);
    }

    const view_order = try gpa.alloc(u8, lay.order_count);
    errdefer gpa.free(view_order);
    for (view_order, 0..) |*id, i| id.* = @intCast(i);

    const src = try gpa.create(LdsSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .header = header,
        .tempo = header.tempo,
        .patches = patches,
        .slots = slots,
        .pool = pool,
        .view_order = view_order,
        .format_name = nameForExt(ctx.ext),
        .loops = hasJump(pool),
    };
    src.rewind(ctx.chip);
    ctx.chip.flush();
    return fmt.MusicSource.init(src);
}

fn nameForExt(ext: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(ext, ".ld0")) "LD0" else "LDS";
}

fn labelForPath(path: []const u8) []const u8 {
    return nameForExt(fmt.extensionOf(path));
}

pub const format = fmt.Format{
    .name = "LDS",
    .extensions = &.{ ".lds", ".ld0" },
    .visualizer = visualizer_name,
    .label_for_path = labelForPath,
    .load = load,
};

// --- tests -------------------------------------------------------------------

fn noteWord(degree: u8, patch: u8) u16 {
    return (@as(u16, degree) << 8) | patch;
}

fn cmdWord(id: Cmd, arg: u8) u16 {
    return (@as(u16, @intFromEnum(id)) << 8) | arg;
}

fn waitWord(extra: u8) u16 {
    return cmdWord(.wait, extra);
}

fn writeU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

const blank_row: [voices]Slot = @splat(.{ .start = 0, .transpose = 0 });

const TestSong = struct {
    midi_patches: bool = true,
    mode: u8 = 0,
    speed: u16 = 17152,
    tempo: u8 = 1,
    rows: u8 = 2,
    note_delay: [voices]u8 = @splat(0),
    rhythm: u8 = 0,
    patches: []const Patch = &.{.{}},
    orders: []const [voices]Slot = &.{blank_row},
    words: []const u16 = &.{ noteWord(0x30, 0), cmdWord(.stop, 0) },
};

fn putSong(buf: []u8, song: TestSong) []const u8 {
    const stride: usize = if (song.midi_patches) patch_with_midi else patch_without_midi;
    buf[0] = song.mode;
    writeU16(buf, 1, song.speed);
    buf[3] = song.tempo;
    buf[4] = song.rows;
    @memcpy(buf[5..14], &song.note_delay);
    buf[14] = song.rhythm;
    writeU16(buf, 15, @intCast(song.patches.len));
    var off: usize = header_len;
    for (song.patches) |p| {
        @memset(buf[off .. off + stride], 0);
        p.write(buf[off..]);
        off += stride;
    }
    writeU16(buf, off, @intCast(song.orders.len));
    off += 2;
    for (song.orders) |row| {
        for (row) |s| {
            writeU16(buf, off, s.start * 2);
            buf[off + 2] = s.transpose;
            off += slot_bytes;
        }
    }
    writeU16(buf, off, 0);
    off += 2;
    for (song.words) |word| {
        writeU16(buf, off, word);
        off += 2;
    }
    return buf[0..off];
}

fn loadSong(gpa: std.mem.Allocator, song: TestSong, ext: []const u8) !fmt.MusicSource {
    var buf: [512]u8 = undefined;
    const data = putSong(&buf, song);
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ext,
        .name = "t.lds",
    })).?;
}

test "lds smallest one-shot song loads and ends" {
    const gpa = std.testing.allocator;
    const src = try loadSong(gpa, .{}, ".lds");
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("LDS", src.info().format_name);
    try std.testing.expect(!src.info().loop);
    const drained = fmt.testDrain(src, fmt.noop_chip, 512);
    try std.testing.expect(drained.done);
    try std.testing.expect(drained.frames > 0);
}

test "lds rejects bad files" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".lds" };
    try std.testing.expect(try load(gpa, &[_]u8{ 3, 0, 0 }, ctx) == null);
    try std.testing.expect(try load(gpa, &[_]u8{ 0, 1, 2 }, ctx) == null);
}

test "lds backward jump is a native loop" {
    const gpa = std.testing.allocator;
    const src = try loadSong(gpa, .{
        .rows = 2,
        .words = &.{ noteWord(0x30, 0), cmdWord(.jump, 0) },
    }, ".lds");
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    const drained = fmt.testDrain(src, fmt.noop_chip, 512);
    try std.testing.expect(drained.done);
}

test "lds old layout loads from .ld0" {
    const gpa = std.testing.allocator;
    const src = try loadSong(gpa, .{ .midi_patches = false }, ".ld0");
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("LD0", src.info().format_name);
    try std.testing.expectEqualStrings("LD0", fmt.displayLabelForPath("GENORI.LD0").?);
}

test "lds tracker cells follow packed waits and notes" {
    const gpa = std.testing.allocator;
    const src = try loadSong(gpa, .{
        .rows = 4,
        .words = &.{ noteWord(0x30, 1), waitWord(1), cmdWord(.key_off, 0) },
    }, ".lds");
    defer src.deinit(gpa);

    const view = src.trackerView().?;
    const note = view.cell(view.ctx, 0, 0, 0);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note, note.kind);
    try std.testing.expectEqual(@as(u8, 0), note.semitone);
    try std.testing.expectEqual(@as(u8, 4), note.octave);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.empty, view.cell(view.ctx, 0, 1, 0).kind);
    try std.testing.expectEqual(fmt.TrackerCell.Kind.note_off, view.cell(view.ctx, 0, 3, 0).kind);
}

test "lds overlong arpeggio drains" {
    const gpa = std.testing.allocator;
    var patch = Patch{};
    patch.arpeggio = 0x0f;
    for (&patch.arp, 0..) |*slot, n| slot.* = @intCast(n + 1);
    const src = try loadSong(gpa, .{
        .patches = &.{patch},
        .words = &.{ noteWord(0x30, 0), cmdWord(.stop, 0) },
    }, ".lds");
    defer src.deinit(gpa);
    const drained = fmt.testDrain(src, fmt.noop_chip, 512);
    try std.testing.expect(drained.done);
}
