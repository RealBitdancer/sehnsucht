//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const binary = @import("../binary.zig");

pub const format_name = "LAA";
pub const extensions = &.{".laa"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const callback_hz = 250;
const callback_us = 1_000_000 / callback_hz;
const ticks_per_beat = 480;
const default_tempo = 500_000;
const timer_increase = 0xd69;
const timer_threshold = 0x411b;
const max_events_per_step: u32 = 4096;
const max_events = 262_144;
const max_segments = 64;
const endless_loop_count = 100;
const probe_secs = 30 * 60;
const probe_steps: u32 = 1 << 22;

const op1 = [9]u8{ 0, 1, 2, 8, 9, 10, 16, 17, 18 };
const op2 = [9]u8{ 3, 4, 5, 11, 12, 13, 19, 20, 21 };

const SetParam = struct { base: u8, shift: u3, mask: u8, inversion: u8 };

const set_params = [15]SetParam{
    .{ .base = 0x40, .shift = 0, .mask = 63, .inversion = 63 },
    .{ .base = 0xe0, .shift = 2, .mask = 0, .inversion = 0 },
    .{ .base = 0x40, .shift = 6, .mask = 192, .inversion = 0 },
    .{ .base = 0x20, .shift = 0, .mask = 15, .inversion = 0 },
    .{ .base = 0x60, .shift = 4, .mask = 240, .inversion = 15 },
    .{ .base = 0x60, .shift = 0, .mask = 15, .inversion = 15 },
    .{ .base = 0x80, .shift = 4, .mask = 240, .inversion = 15 },
    .{ .base = 0x80, .shift = 0, .mask = 15, .inversion = 15 },
    .{ .base = 0xe0, .shift = 0, .mask = 3, .inversion = 0 },
    .{ .base = 0x20, .shift = 7, .mask = 128, .inversion = 0 },
    .{ .base = 0x20, .shift = 6, .mask = 64, .inversion = 0 },
    .{ .base = 0x20, .shift = 5, .mask = 32, .inversion = 0 },
    .{ .base = 0x20, .shift = 4, .mask = 16, .inversion = 0 },
    .{ .base = 0xc0, .shift = 0, .mask = 1, .inversion = 0 },
    .{ .base = 0xc0, .shift = 1, .mask = 14, .inversion = 0 },
};

const param_table = [16]u8{ 29, 28, 27, 0, 3, 4, 7, 8, 13, 16, 17, 20, 21, 30, 31, 0 };
const max_val_table = [16]u16{ 0x2ff, 0x1f, 0x7, 0x3f, 0x0f, 0x0f, 0x0f, 0x3, 0x3f, 0x0f, 0x0f, 0x0f, 0x3, 0x3e, 0x1f, 0 };
const num_steps_table = [32]u16{ 1, 2, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 21, 24, 30, 36, 50, 64, 82, 100, 136, 160, 192, 240, 276, 340, 460, 600, 860, 1200, 1600 };

const note_frequencies = [144]u8{
    90,  91,  92,  92,  93,  94,  94,  95,  96,  96,  97,  98,  98,  99,  100, 101,
    101, 102, 103, 104, 104, 105, 106, 107, 107, 108, 109, 110, 111, 111, 112, 113,
    114, 115, 115, 116, 117, 118, 119, 120, 121, 121, 122, 123, 124, 125, 126, 127,
    128, 129, 130, 131, 132, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142,
    143, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 157, 158, 159, 160,
    161, 162, 163, 165, 166, 167, 168, 169, 171, 172, 173, 174, 176, 177, 178, 180,
    181, 182, 184, 185, 186, 188, 189, 190, 192, 193, 194, 196, 197, 199, 200, 202,
    203, 205, 206, 208, 209, 211, 212, 214, 215, 217, 218, 220, 222, 223, 225, 226,
    228, 230, 231, 233, 235, 236, 238, 240, 242, 243, 245, 247, 249, 251, 252, 254,
};

const volume_table = [64]u8{
    0,  4,  7,  11, 13, 16, 18, 20, 22, 24, 26, 27, 29, 30, 31, 33,
    34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 44, 45, 46, 47, 47,
    48, 49, 49, 50, 51, 51, 52, 53, 53, 54, 54, 55, 55, 56, 56, 57,
    57, 58, 58, 59, 59, 60, 60, 60, 61, 61, 62, 62, 62, 63, 63, 63,
};

/// ScummVM reads past this 64x32 table for some instrument bytes, so indices are clamped.
fn volLookup(a: i32, b: i32) i32 {
    const row = std.math.clamp(a, 0, 63);
    const col = std.math.clamp(b, 0, 31);
    return if (col == 0) 0 else (row * (col + 1)) >> 5;
}

fn lookupVolume(a: i32, b: i32) i32 {
    if (b == 0) return 0;
    if (b == 31) return a;
    if (a < -63 or a > 63) return (b * (a + 1)) >> 5;
    if (b < 0) return if (a < 0) volLookup(-a, -b) else -volLookup(a, -b);
    return if (a < 0) -volLookup(-a, b) else volLookup(a, b);
}

fn transposeClamp(value: i32, low: i32, high: i32) i32 {
    var a = value;
    if (low > a) a += @divTrunc(low - a + 11, 12) * 12;
    if (high < a) a -= @divTrunc(a - high + 11, 12) * 12;
    return a;
}

const Instrument = struct {
    bytes: [30]u8 = @splat(0),
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,

    fn label(self: *const Instrument) []const u8 {
        return self.name[0..self.name_len];
    }
};

const Kind = enum(u8) {
    note_off,
    note_on,
    control,
    program,
    pitch_bend,
    tempo,
    end,
    allocate,
    shutdown,
    song_start,
    part_instrument,
    global_instrument,
    jump,
    hook_transpose,
    hook_onoff,
    hook_volume,
    hook_part_transpose,
    loop,
    clear_loop,
    ignored,
};

const no_instrument: u16 = std.math.maxInt(u16);

const Event = struct {
    tick: u32,
    at: u32 = 0,
    kind: Kind,
    channel: u4 = 0,
    code: u8 = 0,
    args: [10]u8 = @splat(0),

    fn word(self: Event, index: usize) u16 {
        return std.mem.readInt(u16, self.args[index..][0..2], .big);
    }
};

const Track = struct { first: u32, end: u32, offset: u32 };

fn decodeNibbles(dest: []u8, src: []const u8) void {
    for (dest, 0..) |*b, i| {
        const hi: u8 = if (2 * i < src.len) src[2 * i] else 0;
        const lo: u8 = if (2 * i + 1 < src.len) src[2 * i + 1] else 0;
        b.* = (hi << 4) | (lo & 0x0f);
    }
}

const Parser = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    instruments: std.ArrayList(Instrument) = .empty,
    used: [16]bool = @splat(false),

    fn deinit(self: *Parser) void {
        self.events.deinit(self.gpa);
        self.instruments.deinit(self.gpa);
    }

    fn addInstrument(self: *Parser, nibbles: []const u8, comptime kind: []const u8, number: u8) !u16 {
        if (self.instruments.items.len >= no_instrument) return error.InvalidMusicData;
        var ins: Instrument = .{};
        decodeNibbles(&ins.bytes, nibbles);
        ins.name_len = @intCast((std.fmt.bufPrint(&ins.name, kind ++ " {d}", .{number}) catch unreachable).len);
        try self.instruments.append(self.gpa, ins);
        return @intCast(self.instruments.items.len - 1);
    }

    fn sysex(self: *Parser, ev: *Event, raw: []const u8) !void {
        var msg = raw;
        if (msg.len != 0 and msg[msg.len - 1] == 0xf7) msg = msg[0 .. msg.len - 1];
        ev.kind = .ignored;
        if (msg.len < 2 or msg[0] != 0x7d) return;
        const code = msg[1];
        const p = msg[2..];
        ev.code = code;
        switch (code) {
            0 => if (p.len >= 1) {
                ev.kind = .allocate;
                ev.channel = @truncate(p[0]);
                decodeNibbles(ev.args[0..8], p[1..]);
            },
            1 => if (p.len >= 1 and p[0] < 16) {
                ev.kind = .shutdown;
                ev.channel = @intCast(p[0]);
            },
            2 => ev.kind = .song_start,
            16 => if (p.len >= 2) {
                ev.kind = .part_instrument;
                ev.channel = @truncate(p[0]);
                const index = if (p.len == 62 or p.len == 48) try self.addInstrument(p[2..], "Part", ev.channel) else no_instrument;
                std.mem.writeInt(u16, ev.args[0..2], index, .big);
            },
            17 => if (p.len >= 3 and (p.len == 63 or p.len == 49) and p[2] < 32) {
                ev.kind = .global_instrument;
                ev.args[2] = p[2];
                std.mem.writeInt(u16, ev.args[0..2], try self.addInstrument(p[3..], "Global", p[2]), .big);
            },
            48 => if (p.len >= 1) {
                ev.kind = .jump;
                decodeNibbles(ev.args[0..7], p[1..]);
            },
            49 => if (p.len >= 1) {
                ev.kind = .hook_transpose;
                decodeNibbles(ev.args[0..3], p[1..]);
            },
            50, 51, 53 => if (p.len >= 1) {
                ev.kind = switch (code) {
                    50 => .hook_onoff,
                    51 => .hook_volume,
                    else => .hook_part_transpose,
                };
                ev.channel = @truncate(p[0]);
                decodeNibbles(ev.args[0..3], p[1..]);
            },
            80 => if (p.len >= 1) {
                ev.kind = .loop;
                decodeNibbles(ev.args[0..10], p[1..]);
            },
            81 => ev.kind = .clear_loop,
            else => {},
        }
    }

    fn readTrack(self: *Parser, body: []const u8, offset: u32) !Track {
        const first: u32 = @intCast(self.events.items.len);
        var r = binary.Reader{ .data = body };
        var tick: u32 = 0;
        var status: u8 = 0;
        while (r.pos < body.len) {
            tick = std.math.add(u32, tick, try r.vlq()) catch return error.InvalidMusicData;
            var b = try r.byte();
            if (b < 0x80) {
                if (status == 0) return error.InvalidMusicData;
                r.pos -= 1;
                b = status;
            }
            status = b;
            var ev = Event{ .tick = tick, .kind = .ignored, .channel = @truncate(b) };
            switch (b >> 4) {
                8, 9 => {
                    const note = try r.byte();
                    const velocity = try r.byte();
                    ev.kind = if (b >> 4 == 9 and velocity != 0) .note_on else .note_off;
                    ev.args[0] = note;
                    ev.args[1] = velocity;
                    self.used[ev.channel] = true;
                },
                0xa, 0xe => {
                    ev.args[0] = try r.byte();
                    ev.args[1] = try r.byte();
                    if (b >> 4 == 0xe) ev.kind = .pitch_bend;
                },
                0xb => {
                    ev.kind = .control;
                    ev.args[0] = try r.byte();
                    ev.args[1] = try r.byte();
                },
                0xc => {
                    ev.kind = .program;
                    ev.args[0] = try r.byte();
                },
                0xd => _ = try r.byte(),
                else => switch (b) {
                    0xf0 => try self.sysex(&ev, try r.take(try r.vlq())),
                    0xf7 => _ = try r.take(try r.vlq()),
                    0xff => {
                        const kind = try r.byte();
                        const bytes = try r.take(try r.vlq());
                        if (kind == 0x2f) break;
                        if (kind == 0x51 and bytes.len >= 3) {
                            ev.kind = .tempo;
                            @memcpy(ev.args[0..3], bytes[0..3]);
                        }
                    },
                    0xf2 => _ = try r.take(2),
                    0xf3 => _ = try r.take(1),
                    else => {},
                },
            }
            if (ev.kind == .ignored and ev.code == 0) continue;
            if (self.events.items.len >= max_events) return error.InvalidMusicData;
            try self.events.append(self.gpa, ev);
        }
        try self.events.append(self.gpa, .{ .tick = tick, .kind = .end });
        for (self.events.items[first..]) |*ev| ev.at = offset +| ev.tick;
        return .{ .first = first, .end = @intCast(self.events.items.len), .offset = offset };
    }
};

const Effect = struct {
    active: u8 = 0,
    cur_val: i16 = 0,
    count: i16 = 0,
    max_value: u16 = 0,
    start_value: i16 = 0,
    loop: bool = false,
    table_a: [4]u8 = @splat(0),
    table_b: [4]u8 = @splat(0),
    unk3: i8 = 0,
    mod_wheel: i8 = 0,
    mod_wheel_last: i8 = 0,
    speed_lo_max: u16 = 0,
    num_steps: u16 = 0,
    speed_hi: i16 = 0,
    direction: i8 = 0,
    speed_lo: u16 = 0,
    speed_lo_counter: u16 = 0,
    modify_val: i16 = 0,
    param: u8 = 0,
    flag40: bool = false,
    flag10: bool = false,
};

const Voice = struct {
    part: ?u4 = null,
    next: ?u4 = null,
    prev: ?u4 = null,
    wait_for_pedal: bool = false,
    note: u8 = 0,
    two_chan: bool = false,
    vol1: u8 = 0,
    vol2: u8 = 0,
    duration: i16 = 0,
    effects: [2]Effect = @splat(.{}),
    shown: bool = false,
    shown_part: u4 = 0,
    program: u16 = 0,
    velocity: u8 = 0,
};

const Part = struct {
    exists: bool = false,
    on: bool = true,
    pri: i8 = 0,
    vol: u8 = 127,
    transpose: i8 = 0,
    detune: i8 = 0,
    pitchbend: i16 = 0,
    pitchbend_factor: u8 = 2,
    modwheel: u8 = 0,
    pedal: bool = false,
    instrument: ?u16 = null,
    allocated: bool = false,
    voice: ?u4 = null,
    pri_eff: u8 = 0,
    vol_eff: u8 = 0,
    transpose_eff: i8 = 0,
    detune_eff: i16 = 0,
};

const JumpKind = enum { hook, endless_loop, counted_loop };

const Hanging = struct { channel: u4 = 0, note: u8 = 0, time_left: u32 = 0 };
const Segment = struct { track: u16, from: u32, to: u32 };

const Header = struct {
    priority: u8 = 0x80,
    transpose: i8 = 0,
    detune: i8 = 0,
    speed: u8 = 128,
};

const Source = struct {
    events: []const Event,
    tracks: []const Track,
    instruments: []const Instrument,
    used: [16]bool,
    ppqn: u32,
    header: Header,
    static_channels: bool,
    sample_rate: u32,
    duration: u64 = 0,
    looping: bool = true,
    chip: fmt.Chip = fmt.noop_chip,
    frac: u32 = 0,

    track: u16 = 0,
    cursor: u32 = 0,
    play_time: u64 = 0,
    last_event_time: u64 = 0,
    last_event_tick: u32 = 0,
    play_tick: u32 = 0,
    psec_per_tick: u32 = 1,
    end_time: ?u64 = null,
    aborted: bool = false,
    playing: bool = true,
    ended: bool = false,
    pass_done: bool = false,
    active_notes: [128]u16 = @splat(0),
    hanging: [32]Hanging = @splat(.{}),
    hanging_count: u8 = 0,
    loop_counter: u16 = 0,
    loop_endless: bool = false,
    loop_to_beat: u16 = 1,
    loop_to_tick: u16 = 0,
    loop_from_beat: u16 = 1,
    loop_from_tick: u16 = 0,
    segments: [max_segments]Segment = undefined,
    segment_count: u8 = 0,
    segment_from: u32 = 0,

    parts: [16]Part = @splat(.{}),
    globals: [32]?u16 = @splat(null),
    transpose: i8 = 0,

    voices: [9]Voice = @splat(.{}),
    regs: [256]u8 = @splat(0),
    channel_table2: [9]u16 = @splat(0),
    cur_not_table: [9]u16 = @splat(0),
    voice_index: i8 = -1,
    timer_counter: i32 = 0,
    rand_seed: u8 = 1,
    last_instrument: u16 = 0,

    fn timerRate(self: *const Source) u64 {
        return (@as(u64, callback_us) * self.header.speed) >> 7;
    }

    fn write(self: *Source, reg: u8, value: u8) void {
        self.regs[reg] = value;
        self.chip.writeReg(reg, value);
    }

    fn randomNr(self: *Source, a: i32) i32 {
        if (self.rand_seed & 1 != 0) {
            self.rand_seed >>= 1;
            self.rand_seed ^= 0xb8;
        } else self.rand_seed >>= 1;
        return (@as(i32, self.rand_seed) * a) >> 8;
    }

    fn keyOff(self: *Source, ch: u4) void {
        self.write(0xb0 + @as(u8, ch), self.regs[0xb0 + @as(u8, ch)] & ~@as(u8, 0x20));
    }

    fn keyOnOff(self: *Source, ch: u4) void {
        const val = self.regs[0xb0 + @as(u8, ch)];
        self.write(0xb0 + @as(u8, ch), val & ~@as(u8, 0x20));
        self.write(0xb0 + @as(u8, ch), val | 0x20);
    }

    fn playNote(self: *Source, ch: u4, note: i32) void {
        var note2: u8 = @truncate(@as(u32, @bitCast((note >> 7) - 4)));
        if (note2 >= 128) note2 = 0;
        var oct: u8 = note2 / 12;
        oct = if (oct > 7) 7 << 2 else oct << 2;
        var notex: u8 = note2 % 12 + 3;
        var old = self.regs[0xb0 + @as(u8, ch)];
        if (old & 0x20 != 0) {
            old &= ~@as(u8, 0x20);
            if (oct > old) {
                if (notex < 6) {
                    notex += 12;
                    oct -= 4;
                }
            } else if (oct < old) {
                if (notex > 11) {
                    notex -= 12;
                    oct += 4;
                }
            }
        }
        const i = (@as(usize, notex) << 3) + @as(usize, @intCast((note >> 4) & 7));
        self.write(0xa0 + @as(u8, ch), note_frequencies[i]);
        self.write(0xb0 + @as(u8, ch), oct | 0x20);
    }

    fn noteOnEx(self: *Source, ch: u4, note: u8, mod: i32) void {
        const code = (@as(i32, note) << 7) + mod;
        self.cur_not_table[ch] = @truncate(@as(u32, @bitCast(code)));
        self.channel_table2[ch] = 0;
        self.playNote(ch, code);
    }

    fn noteOn(self: *Source, ch: u4, note: u8, mod: i32) void {
        const code = (@as(i32, note) << 7) + mod;
        self.cur_not_table[ch] = @truncate(@as(u32, @bitCast(code)));
        self.playNote(ch, @as(i32, @as(i16, @bitCast(self.channel_table2[ch]))) + code);
    }

    fn setParam(self: *Source, ch: u4, param: u8, value: i32) void {
        var p = param;
        var val = value;
        var reg: u8 = undefined;
        if (p <= 12) {
            reg = op2[ch];
        } else if (p <= 25) {
            p -= 13;
            reg = op1[ch];
        } else if (p <= 27) {
            p -= 13;
            reg = ch;
        } else if (p == 28 or p == 29) {
            val -= if (p == 28) 15 else 383;
            val *= 16;
            self.channel_table2[ch] = @truncate(@as(u32, @bitCast(val)));
            self.playNote(ch, @as(i32, self.cur_not_table[ch]) + val);
            return;
        } else return;
        const sp = set_params[p];
        if (sp.inversion != 0) val = @as(i32, sp.inversion) - val;
        const r = reg + sp.base;
        const shifted: u8 = @truncate(@as(u32, @as(u8, @truncate(@as(u32, @bitCast(val))))) << sp.shift);
        self.write(r, (self.regs[r] & ~sp.mask) | shifted);
    }

    fn regValueParam(self: *const Source, ch: u4, param: u8) i32 {
        var p = param;
        var reg: u8 = undefined;
        if (p <= 12) {
            reg = op2[ch];
        } else if (p <= 25) {
            p -= 13;
            reg = op1[ch];
        } else if (p <= 27) {
            p -= 13;
            reg = ch;
        } else if (p == 28) {
            return 0xf;
        } else if (p == 29) {
            return 0x17f;
        } else return 0;
        const sp = set_params[p];
        var val: u8 = self.regs[reg + sp.base] & sp.mask;
        val >>= sp.shift;
        if (sp.inversion != 0) val = sp.inversion -% val;
        return val;
    }

    fn effectSetup(self: *Source, e: *Effect) void {
        const b: i32 = e.unk3;
        const f: usize = e.active - 1;
        var t = e.table_a[f];
        var steps: i32 = num_steps_table[@intCast(std.math.clamp(volLookup(t & 0x7f, b), 0, 31))];
        if (t & 0x80 != 0) steps = self.randomNr(steps);
        if (steps == 0) steps += 1;
        e.num_steps = @truncate(@as(u32, @bitCast(steps)));
        e.speed_lo_max = e.num_steps;
        var h: i32 = 0;
        if (f != 2) {
            const c: i32 = e.max_value;
            const g: i32 = e.start_value;
            t = e.table_b[f];
            var d = lookupVolume(c, @as(i32, t & 0x7f) - 31);
            if (t & 0x80 != 0) d = self.randomNr(d);
            if (d + g > c) {
                h = c - g;
            } else {
                h = d;
                if (d + g < 0) h = -g;
            }
            h -= e.cur_val;
        }
        e.speed_hi = @truncate(@divTrunc(h, steps));
        if (h < 0) {
            h = -h;
            e.direction = -1;
        } else e.direction = 1;
        e.speed_lo = @truncate(@as(u32, @bitCast(@rem(h, steps))));
        e.speed_lo_counter = 0;
    }

    fn effectTick(self: *Source, e: *Effect) u8 {
        var result: u8 = 0;
        if (e.count != 0) {
            e.count -%= 17;
            if (e.count <= 0) {
                e.active = 0;
                return 0;
            }
        }
        var i: i32 = @as(i32, e.cur_val) + e.speed_hi;
        e.speed_lo_counter +%= e.speed_lo;
        if (e.speed_lo_counter >= e.speed_lo_max) {
            e.speed_lo_counter -%= e.speed_lo_max;
            i += e.direction;
        }
        if (e.cur_val != i or e.mod_wheel != e.mod_wheel_last) {
            e.cur_val = @truncate(i);
            e.mod_wheel_last = e.mod_wheel;
            i = lookupVolume(i, e.mod_wheel_last);
            if (i != e.modify_val) {
                e.modify_val = @truncate(i);
                result = 1;
            }
        }
        e.num_steps -%= 1;
        if (e.num_steps == 0) {
            e.active += 1;
            if (e.active > 4) {
                if (e.loop) {
                    e.active = 1;
                    result |= 2;
                    self.effectSetup(e);
                } else e.active = 0;
            } else self.effectSetup(e);
        }
        return result;
    }

    fn effectInit(self: *Source, vi: u4, which: u1, flags: u8, extra: [8]u8) void {
        const v = &self.voices[vi];
        const e = &v.effects[which];
        e.modify_val = 0;
        e.flag40 = flags & 0x40 != 0;
        e.loop = flags & 0x20 != 0;
        e.flag10 = flags & 0x10 != 0;
        e.param = param_table[flags & 0x0f];
        e.max_value = max_val_table[flags & 0x0f];
        e.unk3 = 31;
        e.mod_wheel = if (e.flag40) @intCast(self.parts[v.part.?].modwheel >> 2) else 31;
        switch (e.param) {
            0 => e.start_value = v.vol2,
            13 => e.start_value = v.vol1,
            30 => {
                e.start_value = 31;
                v.effects[1 - which].mod_wheel = 0;
            },
            31 => {
                e.start_value = 0;
                v.effects[1 - which].unk3 = 0;
            },
            else => e.start_value = @intCast(self.regValueParam(vi, e.param)),
        }
        e.active = 1;
        e.cur_val = 0;
        e.mod_wheel_last = 31;
        e.count = extra[0];
        if (e.count != 0) e.count *= 63;
        e.table_a = .{ extra[1], extra[3], extra[5], extra[6] };
        e.table_b = .{ extra[2], extra[4], 0, extra[7] };
        self.effectSetup(e);
    }

    fn effectStep(self: *Source, vi: u4, which: u1) void {
        const v = &self.voices[vi];
        const e = &v.effects[which];
        const code = self.effectTick(e);
        const vol_eff = self.parts[v.part.?].vol_eff;
        if (code & 1 != 0) switch (e.param) {
            0 => {
                v.vol2 = @truncate(@as(u32, @bitCast(@as(i32, e.start_value) + e.modify_val)));
                self.setParam(vi, 0, volume_table[@intCast(volLookup(v.vol2, vol_eff >> 2))]);
            },
            13 => {
                v.vol1 = @truncate(@as(u32, @bitCast(@as(i32, e.start_value) + e.modify_val)));
                if (v.two_chan) {
                    self.setParam(vi, 13, volume_table[@intCast(volLookup(v.vol1, vol_eff >> 2))]);
                } else self.setParam(vi, 13, v.vol1);
            },
            30 => v.effects[1 - which].mod_wheel = @truncate(e.modify_val),
            31 => v.effects[1 - which].unk3 = @truncate(e.modify_val),
            else => self.setParam(vi, e.param, @as(i32, e.start_value) + e.modify_val),
        };
        if (code & 2 != 0 and e.flag10) self.keyOnOff(vi);
    }

    fn mcOff(self: *Source, vi: u4) void {
        self.keyOff(vi);
        const v = &self.voices[vi];
        const prev = v.prev;
        if (v.next) |n| self.voices[n].prev = prev;
        if (prev) |p| self.voices[p].next = v.next else self.parts[v.part.?].voice = v.next;
        v.part = null;
    }

    fn allocateVoice(self: *Source, priority: u8) ?u4 {
        var best: ?u4 = null;
        var pri = priority;
        for (0..9) |_| {
            self.voice_index += 1;
            if (self.voice_index >= 9) self.voice_index = 0;
            const vi: u4 = @intCast(self.voice_index);
            const v = self.voices[vi];
            const owner = v.part orelse return vi;
            if (v.next == null and self.parts[owner].pri_eff <= pri) {
                pri = self.parts[owner].pri_eff;
                best = vi;
            }
        }
        if (best) |b| self.mcOff(b);
        return best;
    }

    fn keyOn(self: *Source, part: u4, index: u16, note: u8, velocity: u8) void {
        const vi = self.allocateVoice(self.parts[part].pri_eff) orelse return;
        const v = &self.voices[vi];
        v.part = part;
        v.next = self.parts[part].voice;
        self.parts[part].voice = vi;
        v.prev = null;
        if (v.next) |n| self.voices[n].prev = vi;

        const ins = self.instruments[index].bytes;
        const p = self.parts[part];
        v.two_chan = ins[10] & 1 != 0;
        v.note = note;
        v.wait_for_pedal = false;
        v.duration = ins[29];
        if (v.duration != 0) v.duration *= 63;
        var vol1: i32 = @min(0x3f, @as(i32, ins[1] & 0x3f) + volLookup(velocity >> 1, ins[4] >> 2));
        v.vol1 = @intCast(vol1);
        var vol2: i32 = @min(0x3f, @as(i32, ins[6] & 0x3f) + volLookup(velocity >> 1, ins[9] >> 2));
        v.vol2 = @intCast(vol2);
        const c: i32 = p.vol_eff >> 2;
        vol2 = volume_table[@intCast(volLookup(vol2, c))];
        if (v.two_chan) vol1 = volume_table[@intCast(volLookup(vol1, c))];

        const m = op1[vi];
        const k = op2[vi];
        self.write(0x20 + m, ins[0]);
        self.write(0x40 + m, (ins[1] | 0x3f) - @as(u8, @intCast(vol1)));
        self.write(0x60 + m, ~ins[2]);
        self.write(0x80 + m, ~ins[3]);
        self.write(0xe0 + m, ins[4]);
        self.write(0x20 + k, ins[5]);
        self.write(0x40 + k, (ins[6] | 0x3f) - @as(u8, @intCast(vol2)));
        self.write(0x60 + k, ~ins[7]);
        self.write(0x80 + k, ~ins[8]);
        self.write(0xe0 + k, ins[9]);
        self.write(0xc0 + @as(u8, vi), ins[10]);
        self.noteOnEx(vi, note +% @as(u8, @bitCast(p.transpose_eff)), modulation(p));
        if (ins[11] & 0x80 != 0) self.effectInit(vi, 0, ins[11], ins[12..20].*) else v.effects[0].active = 0;
        if (ins[20] & 0x80 != 0) self.effectInit(vi, 1, ins[20], ins[21..29].*) else v.effects[1].active = 0;

        v.shown = true;
        v.shown_part = part;
        v.program = index;
        v.velocity = velocity;
        self.last_instrument = index;
    }

    fn modulation(p: Part) i32 {
        return ((@as(i32, p.pitchbend) * p.pitchbend_factor) >> 6) + p.detune_eff;
    }

    fn renote(self: *Source, part: u4) void {
        const p = self.parts[part];
        var it = p.voice;
        while (it) |vi| : (it = self.voices[vi].next) {
            self.noteOn(vi, self.voices[vi].note +% @as(u8, @bitCast(p.transpose_eff)), modulation(p));
        }
    }

    fn keyOffPart(self: *Source, part: u4, note: u8) void {
        var it = self.parts[part].voice;
        while (it) |vi| {
            it = self.voices[vi].next;
            if (self.voices[vi].note != note) continue;
            if (self.parts[part].pedal) self.voices[vi].wait_for_pedal = true else self.mcOff(vi);
        }
    }

    fn driverVolume(self: *Source, part: u4, value: u8) void {
        self.parts[part].vol_eff = value;
        var it = self.parts[part].voice;
        while (it) |vi| : (it = self.voices[vi].next) {
            const v = self.voices[vi];
            self.setParam(vi, 0, volume_table[@intCast(volLookup(v.vol2, value >> 2))]);
            if (v.two_chan) self.setParam(vi, 13, volume_table[@intCast(volLookup(v.vol1, value >> 2))]);
        }
    }

    fn driverModWheel(self: *Source, part: u4, value: u8) void {
        self.parts[part].modwheel = value;
        var it = self.parts[part].voice;
        while (it) |vi| : (it = self.voices[vi].next) {
            for (&self.voices[vi].effects) |*e| {
                if (e.active != 0 and e.flag40) e.mod_wheel = @intCast(value >> 2);
            }
        }
    }

    fn driverSustain(self: *Source, part: u4, value: bool) void {
        self.parts[part].pedal = value;
        if (value) return;
        var it = self.parts[part].voice;
        while (it) |vi| {
            it = self.voices[vi].next;
            if (self.voices[vi].wait_for_pedal) self.mcOff(vi);
        }
    }

    fn driverAllNotesOff(self: *Source, part: u4) void {
        while (self.parts[part].voice) |vi| self.mcOff(vi);
    }

    fn driverTimer(self: *Source) void {
        self.timer_counter += timer_increase;
        while (self.timer_counter >= timer_threshold) {
            self.timer_counter -= timer_threshold;
            for (0..9) |i| {
                const vi: u4 = @intCast(i);
                if (self.voices[vi].part == null) continue;
                const v = &self.voices[vi];
                if (v.duration != 0) {
                    v.duration -%= 0x11;
                    if (v.duration <= 0) {
                        self.mcOff(vi);
                        return;
                    }
                }
                if (self.voices[vi].effects[0].active != 0) self.effectStep(vi, 0);
                if (self.voices[vi].effects[1].active != 0) self.effectStep(vi, 1);
            }
        }
    }

    fn driverBusy(self: *const Source) bool {
        for (self.voices) |v| {
            if (v.part == null) continue;
            if (v.duration != 0 or v.effects[0].active != 0 or v.effects[1].active != 0) return true;
        }
        return false;
    }

    fn getPart(self: *Source, ch: u4) *Part {
        const p = &self.parts[ch];
        if (!p.exists) p.* = .{
            .exists = true,
            .pri_eff = self.header.priority,
            .vol_eff = 127,
            .transpose_eff = self.transpose,
            .detune_eff = self.header.detune,
        };
        return p;
    }

    fn uninitPart(self: *Source, ch: u4) void {
        if (!self.parts[ch].exists) return;
        self.driverSustain(ch, false);
        self.driverAllNotesOff(ch);
        self.parts[ch].exists = false;
    }

    fn setOnOff(self: *Source, ch: u4, on: bool) void {
        const p = self.getPart(ch);
        if (p.on == on) return;
        p.on = on;
        if (on) return;
        self.driverSustain(ch, false);
        self.driverAllNotesOff(ch);
    }

    fn setVolume(self: *Source, ch: u4, value: u8) void {
        const p = self.getPart(ch);
        p.vol = value;
        self.driverVolume(ch, @truncate(((@as(u32, value) + 1) * 127) >> 7));
    }

    fn setPriority(self: *Source, ch: u4, value: i8) void {
        const p = self.getPart(ch);
        p.pri = value;
        p.pri_eff = @intCast(std.math.clamp(@as(i32, value) + self.header.priority, 0, 255));
    }

    fn setTranspose(self: *Source, ch: u4, value: i8, low: i32, high: i32) void {
        const p = self.getPart(ch);
        p.transpose = value;
        p.transpose_eff = if (value == -128) 0 else @truncate(transposeClamp(@as(i32, value) + self.transpose, low, high));
        self.renote(ch);
    }

    fn setDetune(self: *Source, ch: u4, value: i8) void {
        const p = self.getPart(ch);
        p.detune = value;
        p.detune_eff = @intCast(std.math.clamp(@as(i32, value) + self.header.detune, -128, 127));
        self.renote(ch);
    }

    fn setPitchBend(self: *Source, ch: u4, value: i16) void {
        self.getPart(ch).pitchbend = value;
        self.renote(ch);
    }

    fn setPitchBendFactor(self: *Source, ch: u4, value: u8) void {
        if (value > 12) return;
        self.setPitchBend(ch, 0);
        self.getPart(ch).pitchbend_factor = value;
        self.renote(ch);
    }

    fn globalInstrument(self: *Source, slot: u8) ?u16 {
        if (slot >= 32) return null;
        return self.globals[slot] orelse 0;
    }

    fn control(self: *Source, ch: u4, cc: u8, value: u8) void {
        if (cc == 123) {
            if (self.parts[ch].exists) self.driverAllNotesOff(ch);
            return;
        }
        _ = self.getPart(ch);
        switch (cc) {
            1 => self.driverModWheel(ch, value),
            7 => self.setVolume(ch, value),
            16 => self.setPitchBendFactor(ch, value),
            17 => self.setDetune(ch, @bitCast(value -% 0x40)),
            18 => self.setPriority(ch, @bitCast(value -% 0x40)),
            64 => self.driverSustain(ch, value != 0),
            else => {},
        }
    }

    fn noteOff(self: *Source, ch: u4, note: u8) void {
        if (!self.getPart(ch).on) return;
        self.keyOffPart(ch, note);
    }

    fn setTempo(self: *Source, tempo: u32) void {
        self.psec_per_tick = @max(1, (tempo + (self.ppqn >> 2)) / self.ppqn);
    }

    fn eventTime(self: *const Source, ev: Event) u64 {
        return self.last_event_time + @as(u64, ev.tick -| self.last_event_tick) * self.psec_per_tick;
    }

    fn activeNote(self: *Source, ch: u4, note: u8, active: bool) void {
        if (note >= 128) return;
        const bit = @as(u16, 1) << ch;
        if (active) self.active_notes[note] |= bit else self.active_notes[note] &= ~bit;
        for (&self.hanging) |*h| {
            if (h.channel == ch and h.note == note and h.time_left != 0) {
                h.time_left = 0;
                self.hanging_count -= 1;
                break;
            }
        }
    }

    fn hangNote(self: *Source, ch: u4, note: u8, time: u32) void {
        if (self.hanging_count >= self.hanging.len) return;
        var best: ?*Hanging = null;
        for (&self.hanging) |*h| {
            if (h.channel == ch and h.note == note) {
                best = h;
                if (h.time_left != 0) self.hanging_count -= 1;
                break;
            } else if (best == null and h.time_left == 0) best = h;
        }
        const slot = best orelse return;
        slot.* = .{ .channel = ch, .note = note, .time_left = if (time == 0 or time & 0x8000_0000 != 0) 1 else time };
        self.hanging_count += 1;
    }

    fn hangActiveNotes(self: *Source, from: u32) void {
        var pending = self.active_notes;
        const t = self.tracks[self.track];
        const base = self.events[from].tick;
        var i = from + 1;
        while (anyPending(&pending)) : (i += 1) {
            const ev = if (i < t.end) self.events[i] else Event{ .tick = 0, .kind = .end };
            if (ev.kind == .note_off) {
                const bit = @as(u16, 1) << ev.channel;
                if (ev.args[0] < 128 and pending[ev.args[0]] & bit != 0) {
                    self.hangNote(ev.channel, ev.args[0], (ev.tick -% base) *% self.psec_per_tick);
                    pending[ev.args[0]] &= ~bit;
                }
            } else if (ev.kind == .end) {
                for (pending, 0..) |mask, note| for (0..16) |ch| {
                    if (mask & (@as(u16, 1) << @intCast(ch)) == 0) continue;
                    self.activeNote(@intCast(ch), @intCast(note), false);
                    self.noteOff(@intCast(ch), @intCast(note));
                };
                return;
            }
        }
    }

    fn anyPending(pending: *const [128]u16) bool {
        for (pending) |mask| if (mask != 0) return true;
        return false;
    }

    fn allNotesOff(self: *Source) void {
        for (self.active_notes, 0..) |mask, note| for (0..16) |ch| {
            if (mask & (@as(u16, 1) << @intCast(ch)) != 0) self.noteOff(@intCast(ch), @intCast(note));
        };
        for (&self.hanging) |*h| {
            if (h.time_left == 0) continue;
            self.noteOff(h.channel, h.note);
            h.time_left = 0;
        }
        self.hanging_count = 0;
        for (0..16) |ch| {
            if (self.parts[ch].exists) self.driverAllNotesOff(@intCast(ch));
        }
        self.active_notes = @splat(0);
    }

    fn rewindTrack(self: *Source) void {
        self.cursor = self.tracks[self.track].first;
        self.play_time = 0;
        self.last_event_time = 0;
        self.last_event_tick = 0;
        self.play_tick = 0;
    }

    fn jumpToTick(self: *Source, target: u64) bool {
        const saved = .{ self.cursor, self.play_time, self.last_event_time, self.last_event_tick, self.play_tick };
        const tracking = self.playing;
        self.rewindTrack();
        if (target > 0) while (true) {
            const ev = self.events[self.cursor];
            if (ev.tick >= target) {
                self.play_time += (target - self.last_event_tick) * self.psec_per_tick;
                self.play_tick = @intCast(target);
                break;
            }
            if (ev.kind == .end) {
                self.cursor, self.play_time, self.last_event_time, self.last_event_tick, self.play_tick = saved;
                return false;
            }
            if (ev.kind == .tempo) self.setTempo(std.mem.readInt(u24, ev.args[0..3], .big));
            const time = self.eventTime(ev);
            self.play_time = time;
            self.last_event_time = time;
            self.last_event_tick = ev.tick;
            self.play_tick = ev.tick;
            self.cursor += 1;
        };
        if (!tracking) {
            self.allNotesOff();
        } else {
            const target_pos = .{ self.cursor, self.play_time, self.last_event_time, self.last_event_tick, self.play_tick };
            self.cursor, self.play_time, self.last_event_time, self.last_event_tick, self.play_tick = saved;
            self.hangActiveNotes(saved[0]);
            self.cursor, self.play_time, self.last_event_time, self.last_event_tick, self.play_tick = target_pos;
        }
        self.aborted = true;
        return true;
    }

    fn markJump(self: *Source, from_track: u16, from_tick: u32, to_track: u16, to_tick: u64, kind: JumpKind) void {
        if (self.segment_count < max_segments) {
            self.segments[self.segment_count] = .{ .track = from_track, .from = self.segment_from, .to = from_tick };
            self.segment_count += 1;
        } else self.pass_done = true;
        switch (kind) {
            .endless_loop => self.pass_done = true,
            .counted_loop => {},
            .hook => {
                if (to_track == from_track and to_tick <= from_tick) self.pass_done = true;
                for (self.segments[0..self.segment_count]) |s| {
                    if (s.track == to_track and s.from <= to_tick and to_tick <= s.to) self.pass_done = true;
                }
            },
        }
        if (self.pass_done) self.segment_count = 0;
        self.segment_from = @intCast(@min(to_tick, std.math.maxInt(u32)));
    }

    fn jump(self: *Source, to_track: u16, beat: u16, tick: u16, from_tick: u32, kind: JumpKind) void {
        const old_track = self.track;
        if (to_track < self.tracks.len and to_track != self.track) {
            self.hangActiveNotes(self.cursor);
            self.track = to_track;
            self.rewindTrack();
            self.active_notes = @splat(0);
            self.aborted = true;
        }
        const target: u64 = if (beat == 0) std.math.maxInt(u64) else (@as(u64, beat) - 1) * ticks_per_beat + tick;
        const moved = self.jumpToTick(target);
        if (moved or self.track != old_track) self.markJump(old_track, from_tick, self.track, if (moved) target else 0, kind);
        if (!moved) return;
        for (0..16) |ch| {
            if (self.parts[ch].exists and self.parts[ch].pedal) self.driverSustain(@intCast(ch), false);
        }
    }

    fn endSong(self: *Source) void {
        self.allNotesOff();
        for (0..16) |ch| self.uninitPart(@intCast(ch));
        self.playing = false;
        self.ended = true;
    }

    fn process(self: *Source, ev: Event) void {
        const ch = ev.channel;
        switch (ev.kind) {
            .note_on => {
                const p = self.getPart(ch);
                if (!p.on or (self.static_channels and !p.allocated)) return;
                const index = p.instrument orelse return;
                self.keyOn(ch, index, ev.args[0], ev.args[1]);
            },
            .note_off => self.noteOff(ch, ev.args[0]),
            .control => self.control(ch, ev.args[0], ev.args[1]),
            .program => {
                const p = self.getPart(ch);
                if (self.globalInstrument(ev.args[0])) |index| p.instrument = index;
            },
            .pitch_bend => self.setPitchBend(ch, @as(i16, @intCast((@as(u16, ev.args[1] & 0x7f) << 7) | (ev.args[0] & 0x7f))) - 0x2000),
            .tempo => self.setTempo(std.mem.readInt(u24, ev.args[0..3], .big)),
            .end => self.endSong(),
            .allocate => {
                self.setOnOff(ch, ev.args[0] & 1 != 0);
                self.setPriority(ch, @bitCast(ev.args[1]));
                self.setVolume(ch, ev.args[2]);
                self.setTranspose(ch, @bitCast(ev.args[4]), -12, 12);
                self.setDetune(ch, @bitCast(ev.args[5]));
                self.setPitchBendFactor(ch, ev.args[6]);
                if (self.globalInstrument(ev.args[7])) |index| self.getPart(ch).instrument = index;
                self.getPart(ch).allocated = true;
            },
            .shutdown => {
                _ = self.getPart(ch);
                self.uninitPart(ch);
            },
            .song_start => for (0..16) |i| self.uninitPart(@intCast(i)),
            .part_instrument => {
                const index = ev.word(0);
                self.getPart(ch).instrument = if (index == no_instrument) null else index;
            },
            .global_instrument => self.globals[ev.args[2]] = ev.word(0),
            .jump => if (ev.args[0] == 0) self.jump(ev.word(1), ev.word(3), ev.word(5), ev.tick, .hook),
            .hook_transpose => if (ev.args[0] == 0) {
                var b: i32 = @as(i8, @bitCast(ev.args[2]));
                if (b > 24 or b < -24 or ev.args[1] > 1) return;
                if (ev.args[1] != 0) b = transposeClamp(@as(i32, self.transpose) + b, -7, 7);
                self.transpose = @intCast(b);
                for (0..16) |i| {
                    if (self.parts[i].exists) self.setTranspose(@intCast(i), self.parts[i].transpose, -24, 24);
                }
            },
            .hook_onoff => if (ev.args[0] == 0) self.setOnOff(ch, ev.args[1] != 0),
            .hook_volume => if (ev.args[0] == 0) self.setVolume(ch, ev.args[1]),
            .hook_part_transpose => if (ev.args[0] == 0) {
                var b: i32 = @as(i8, @bitCast(ev.args[2]));
                if (b > 24 or b < -24) return;
                const p = self.getPart(ch);
                if (ev.args[1] != 0) b = transposeClamp(b + p.transpose, -7, 7);
                self.setTranspose(ch, @intCast(b), -24, 24);
            },
            .loop => {
                var to_beat = ev.word(2);
                const from_beat = ev.word(6);
                if (@as(u32, to_beat) + 1 >= from_beat) return;
                if (to_beat == 0) to_beat = 1;
                self.loop_counter = 0;
                self.loop_to_beat = to_beat;
                self.loop_to_tick = ev.word(4);
                self.loop_from_beat = from_beat;
                self.loop_from_tick = ev.word(8);
                self.loop_counter = ev.word(0);
                self.loop_endless = self.loop_counter >= endless_loop_count;
            },
            .clear_loop => self.loop_counter = 0,
            .ignored => {},
        }
    }

    fn callback(self: *Source) bool {
        if (self.end_time == null) {
            if (!self.playing) {
                self.driverTimer();
                return true;
            }
            if (self.loop_counter != 0) {
                const beat = self.play_tick / ticks_per_beat + 1;
                const tick = self.play_tick % ticks_per_beat;
                if (beat > self.loop_from_beat or (beat == self.loop_from_beat and tick >= self.loop_from_tick)) {
                    self.loop_counter -= 1;
                    self.jump(self.track, self.loop_to_beat, self.loop_to_tick, self.play_tick, if (self.loop_endless) .endless_loop else .counted_loop);
                }
            }
            const rate = self.timerRate();
            self.end_time = self.play_time + rate;
            self.aborted = false;
            if (self.hanging_count != 0) for (&self.hanging) |*h| {
                if (h.time_left == 0) continue;
                if (h.time_left <= rate) {
                    h.time_left = 0;
                    self.hanging_count -= 1;
                    self.noteOff(h.channel, h.note);
                } else h.time_left -= @intCast(rate);
            };
        }
        const end_time = self.end_time.?;
        var handled: u32 = 0;
        while (!self.aborted) {
            const ev = self.events[self.cursor];
            const time = self.eventTime(ev);
            if (time > end_time) break;
            if (handled == max_events_per_step) return false;
            handled += 1;
            if (ev.kind == .note_off) self.activeNote(ev.channel, ev.args[0], false);
            if (ev.kind == .note_on) self.activeNote(ev.channel, ev.args[0], true);
            self.process(ev);
            if (!self.playing) {
                self.end_time = null;
                self.driverTimer();
                return true;
            }
            if (self.aborted) break;
            self.play_time = time;
            self.last_event_time = time;
            self.last_event_tick = ev.tick;
            self.play_tick = ev.tick;
            self.cursor += 1;
        }
        if (!self.aborted) {
            self.play_time = end_time;
            self.play_tick = @intCast(@min(std.math.maxInt(u32), (end_time - self.last_event_time) / self.psec_per_tick + self.last_event_tick));
        }
        self.end_time = null;
        self.driverTimer();
        return true;
    }

    fn idleCallbacks(self: *Source) u64 {
        if (!self.playing or self.hanging_count != 0 or self.loop_counter != 0 or self.driverBusy()) return 0;
        const rate = self.timerRate();
        const next = self.eventTime(self.events[self.cursor]);
        if (next <= self.play_time + rate) return 0;
        const idle: u64 = @min((next - self.play_time - 1) / rate, callback_hz * 60);
        self.play_time += idle * rate;
        self.play_tick = @intCast(@min(std.math.maxInt(u32), (self.play_time - self.last_event_time) / self.psec_per_tick + self.last_event_tick));
        self.timer_counter = @intCast((@as(u64, @intCast(self.timer_counter)) + idle * timer_increase) % timer_threshold);
        return idle;
    }

    fn restart(self: *Source) void {
        self.track = 0;
        self.rewindTrack();
        self.setTempo(default_tempo);
        self.end_time = null;
        self.aborted = false;
        self.playing = true;
        self.ended = false;
        self.pass_done = false;
        self.active_notes = @splat(0);
        self.hanging = @splat(.{});
        self.hanging_count = 0;
        self.loop_counter = 0;
        self.segment_count = 0;
        self.segment_from = 0;
        for (0..16) |ch| self.uninitPart(@intCast(ch));
        self.globals = @splat(null);
        self.transpose = self.header.transpose;
        self.rand_seed = 1;
    }

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.chip = chip;
        self.write(8, 0x40);
        self.write(0xbd, 0);
        self.write(1, 0x20);
        self.restart();
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        self.chip = chip;
        if (self.ended) self.restart();
        if (!self.callback()) return .{ .frames = 0 };
        const callbacks: u64 = if (self.pass_done) 1 else 1 + self.idleCallbacks();
        const done = self.pass_done or self.ended;
        self.pass_done = false;
        return .{ .frames = fmt.rescale(callbacks, callback_hz, self.sample_rate, &self.frac), .done = done };
    }

    pub fn durationFrames(self: *Source) u64 {
        return self.duration;
    }

    pub fn info(self: *Source) fmt.TrackInfo {
        return .{ .format_name = format_name, .system = "iMUSE / OPL2", .loop = self.looping };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = self.tracks[self.track].offset +| self.play_tick, .tempo = @intCast(@min(65535, 60_000_000 / (@as(u64, self.psec_per_tick) * self.ppqn))), .last_instrument = self.last_instrument, .flags = .{ .has_tick = true, .has_tempo = true } };
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = 16 };
        for (self.parts, 0..) |p, i| {
            if (!p.exists) continue;
            bank.slots[i] = .{ .program = p.instrument orelse view.instrument_none, .bend = @intCast(@as(i32, p.pitchbend) + 8192), .transpose = p.transpose_eff };
        }
        for (self.voices, 0..) |v, i| {
            if (!v.shown) continue;
            const keyed = v.part != null;
            bank.voices[bank.voice_count] = .{ .channel = v.shown_part, .program = v.program, .note = v.note, .velocity = v.velocity, .opl_voice = @intCast(i), .keyed = keyed };
            bank.voice_count += 1;
            if (!keyed) continue;
            const slot = &bank.slots[v.shown_part];
            slot.keyed = true;
            slot.note = v.note;
            slot.opl_voice = @intCast(i);
        }
        return bank;
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .linear_midi,
            .track_count = 16,
            .channel_count = 16,
            .tick_rate = self.ppqn * 2,
            .length_ticks = self.events[self.events.len - 1].at,
            .track = track,
            .eventLexicon = eventLexicon,
            .eventsInRange = eventsInRange,
            .eventAt = eventAt,
            .event_count = @intCast(self.events.len),
        };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = @intCast(self.instruments.len), .get = instrument };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.tracks);
        gpa.free(self.instruments);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}

fn track(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self = source(ptr);
    if (index >= 16) return .{};
    return .{ .channel = @intCast(index), .in_use = self.used[index] };
}

fn instrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index >= self.instruments.len) return .{};
    const ins = &self.instruments[index];
    const b = ins.bytes;
    return .{ .name = ins.label(), .patch = .{ .opl_2op = .{
        .ops = .{ fmt.operatorParams(b[0], b[1], ~b[2], ~b[3], b[4]), fmt.operatorParams(b[5], b[6], ~b[7], ~b[8], b[9]), .{}, .{} },
        .feedback = @truncate(b[10] >> 1),
        .additive = b[10] & 1 != 0,
    } } };
}

fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    if (index >= self.events.len) return .{};
    const ev = self.events[index];
    var out = view.SequenceEvent{ .tick = ev.at, .instr_index = index, .channel = ev.channel, .track = ev.channel };
    switch (ev.kind) {
        .note_on, .note_off => {
            out.kind = if (ev.kind == .note_on) .note_on else .note_off;
            out.payload = .{ .note = .{ .note = ev.args[0], .velocity = ev.args[1] } };
        },
        .control => {
            out.kind = .control;
            out.payload = .{ .control = .{ .cc = ev.args[0], .value = ev.args[1] } };
        },
        .program => {
            out.kind = .program;
            out.payload = .{ .program = ev.args[0] };
        },
        .part_instrument => {
            out.kind = .program;
            out.payload = .{ .program = ev.word(0) };
        },
        .pitch_bend => {
            out.kind = .pitch_bend;
            out.payload = .{ .pitch_bend = (@as(u16, ev.args[1] & 0x7f) << 7) | (ev.args[0] & 0x7f) };
        },
        .tempo => {
            out.track = view.sequence_unassigned;
            out.kind = .tempo;
            out.payload = .{ .tempo = std.mem.readInt(u24, ev.args[0..3], .big) };
        },
        .end => {
            out.track = view.sequence_unassigned;
            out.kind = .end;
        },
        .jump => {
            out.track = view.sequence_unassigned;
            const to = ev.word(1);
            if (ev.args[0] == 0 and to < self.tracks.len and ev.word(3) != 0) {
                out.kind = .jump;
                out.payload = .{ .jump = self.tracks[to].offset +| ((@as(u32, ev.word(3)) - 1) * ticks_per_beat + ev.word(5)) };
            } else {
                out.kind = .sysex;
                out.payload = .{ .sysex_ref = ev.code };
            }
        },
        else => {
            out.kind = .sysex;
            out.payload = .{ .sysex_ref = ev.code };
            if (ev.kind == .song_start or ev.kind == .global_instrument or ev.kind == .hook_transpose or ev.kind == .loop or ev.kind == .clear_loop) out.track = view.sequence_unassigned;
        },
    }
    return out;
}

fn eventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self = source(ptr);
    var lo: usize = 0;
    var hi = self.events.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.events[mid].at < tick0) lo = mid + 1 else hi = mid;
    }
    var range = view.EventRange{};
    while (lo < self.events.len and self.events[lo].at < tick1) : (lo += 1) {
        if (range.written < dest.len) {
            dest[range.written] = eventAt(ptr, @intCast(lo));
            range.written += 1;
        }
        range.total_in_range += 1;
    }
    return range;
}

fn eventLexicon(_: *anyopaque, ev: view.SequenceEvent) view.EffectDesc {
    return switch (ev.payload) {
        .control => |c| .{ .text = switch (c.cc) {
            1 => "Modulation",
            7 => "Volume",
            10 => "Pan",
            16 => "Pitch bend range",
            17 => "Detune",
            18 => "Priority",
            64 => "Sustain",
            123 => "All notes off",
            else => "",
        } },
        .sysex_ref => |code| .{ .text = switch (code) {
            0 => "Allocate part",
            1 => "Shut down part",
            2 => "Start of song",
            16 => "Part instrument",
            17 => "Global instrument",
            33 => "Parameter adjust",
            48 => "Hook jump",
            49 => "Hook transpose",
            50 => "Hook part on/off",
            51 => "Hook part volume",
            52 => "Hook program",
            53 => "Hook part transpose",
            64 => "Marker",
            80 => "Loop",
            81 => "End loop",
            96 => "Set instrument",
            else => "",
        } },
        else => .{},
    };
}

fn readHeader(mdhd: ?[]const u8) Header {
    const d = mdhd orelse return .{};
    if (d.len < 8) return .{};
    var header = Header{ .speed = if (d[7] != 0) d[7] else 128 };
    if (d[2] | d[3] | d[7] != 0) {
        header.priority = d[2];
        header.transpose = @bitCast(d[5]);
        header.detune = @bitCast(d[6]);
    }
    return header;
}

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) !?fmt.MusicSource {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "ADL ")) return null;
    var parser = Parser{ .gpa = gpa };
    defer parser.deinit();
    try parser.instruments.append(gpa, .{ .name = "Default".* ++ @as([9]u8, @splat(0)), .name_len = 7 });
    var tracks: std.ArrayList(Track) = .empty;
    defer tracks.deinit(gpa);
    var mdhd: ?[]const u8 = null;
    var ppqn: ?u16 = null;
    var offset: u32 = 0;
    var pos: usize = 8;
    while (data.len - pos >= 8) {
        const id = data[pos..][0..4];
        const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        const body = data[pos..][0..@min(len, data.len - pos)];
        pos += body.len;
        if (std.mem.eql(u8, id, "MDhd")) {
            mdhd = body;
        } else if (std.mem.eql(u8, id, "MThd")) {
            if (body.len < 6) return error.InvalidMusicData;
            const division = std.mem.readInt(u16, body[4..6], .big);
            if (division == 0 or division & 0x8000 != 0) return error.InvalidMusicData;
            ppqn = division;
        } else if (std.mem.eql(u8, id, "MTrk")) {
            if (ppqn == null or tracks.items.len >= std.math.maxInt(u16)) return error.InvalidMusicData;
            const t = try parser.readTrack(body, offset);
            try tracks.append(gpa, t);
            offset = parser.events.items[t.end - 1].at +| ticks_per_beat;
        }
    }
    if (tracks.items.len == 0) return error.InvalidMusicData;
    const events = try parser.events.toOwnedSlice(gpa);
    errdefer gpa.free(events);
    const owned_tracks = try tracks.toOwnedSlice(gpa);
    errdefer gpa.free(owned_tracks);
    const instruments = try parser.instruments.toOwnedSlice(gpa);
    errdefer gpa.free(instruments);
    const self = try gpa.create(Source);
    self.* = .{
        .events = events,
        .tracks = owned_tracks,
        .instruments = instruments,
        .used = parser.used,
        .ppqn = ppqn.?,
        .header = readHeader(mdhd),
        .static_channels = for (events) |ev| {
            if (ev.kind == .allocate) break true;
        } else false,
        .sample_rate = ctx.sample_rate,
    };
    var probe = self.*;
    probe.reset(fmt.noop_chip);
    var frames: u64 = 0;
    var steps: u32 = 0;
    while (frames < @as(u64, ctx.sample_rate) * probe_secs and steps < probe_steps) : (steps += 1) {
        const r = probe.step(fmt.noop_chip);
        frames += r.frames;
        if (r.done) {
            self.duration = frames;
            self.looping = !probe.ended;
            break;
        }
    }
    self.reset(ctx.chip);
    return fmt.MusicSource.init(self, visualizer_name);
}

// --- tests -------------------------------------------------------------------

const RegRec = struct {
    regs: [256]u8 = @splat(0),

    fn write(ptr: *anyopaque, reg: u16, value: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (reg < self.regs.len) self.regs[reg] = value;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

const TestSong = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn bytes(self: *TestSong, data: []const u8) void {
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn nibbles(self: *TestSong, data: []const u8) void {
        for (data) |b| self.bytes(&.{ b >> 4, b & 0x0f });
    }

    fn sysex(self: *TestSong, delta: []const u8, code: u8, prefix: []const u8, payload: []const u8) void {
        self.bytes(delta);
        self.bytes(&.{ 0xf0, @intCast(2 + prefix.len + payload.len * 2 + 1), 0x7d, code });
        self.bytes(prefix);
        self.nibbles(payload);
        self.bytes(&.{0xf7});
    }

    fn build(self: *TestSong, track_body: []const u8) []const u8 {
        self.len = 0;
        self.bytes("ADL \x00\x00\x00\x00MDhd\x00\x00\x00\x08\x00\x00\x80\x7f\x00\x00\x00\x80");
        self.bytes("MThd\x00\x00\x00\x06\x00\x02\x00\x01\x01\xe0MTrk");
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(track_body.len), .big);
        self.bytes(&len);
        self.bytes(track_body);
        return self.buf[0..self.len];
    }
};

const test_instrument = [30]u8{ 0x21, 0x10, 0x0f, 0x0f, 0, 0x21, 0x00, 0x0f, 0x0f, 0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

fn testTrack(body: *TestSong, tail: []const u8) []const u8 {
    body.len = 0;
    body.sysex(&.{0}, 0, &.{0}, &.{ 1, 0, 127, 0, 0, 0, 2, 0 });
    body.sysex(&.{0}, 16, &.{ 0, 1 }, &test_instrument);
    body.bytes(&.{ 0, 0x90, 60, 100 });
    body.bytes(tail);
    return body.buf[0..body.len];
}

test "LAA plays an iMUSE part instrument and loops at a hook-0 jump" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    var tail: TestSong = .{};
    tail.bytes(&.{ 0x83, 0x60, 0x80, 60, 0 });
    tail.sysex(&.{ 0x83, 0x60 }, 48, &.{0}, &.{ 0, 0, 0, 0, 1, 0, 100 });
    tail.bytes(&.{ 0, 0xff, 0x2f, 0 });
    const data = song.build(testTrack(&body, tail.buf[0..tail.len]));
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 1000, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(?u64, 1000), src.durationFrames());
    const first = src.step(rec.chip());
    try std.testing.expect(!first.done);
    try std.testing.expect(rec.regs[0xb0] & 0x20 != 0);
    try std.testing.expectEqual(@as(u8, 0x01), rec.regs[0xc0]);
    try std.testing.expect(src.sequenceState().?.slots[0].keyed);
    var frames = first.frames;
    while (true) {
        const r = src.step(rec.chip());
        frames += r.frames;
        if (r.done) break;
    }
    try std.testing.expectEqual(@as(u64, 1000), frames);
    try std.testing.expect(rec.regs[0xb0] & 0x20 == 0);
    const instruments = src.views().instruments.?;
    try std.testing.expectEqualStrings("Part 0", instruments.get(instruments.ctx, 1).name);
}

test "LAA ends at the end of track when no jump loops back" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    const data = song.build(testTrack(&body, &.{ 0x83, 0x60, 0x80, 60, 0, 0, 0xff, 0x2f, 0 }));
    const src = (try load(gpa, data, .{ .sample_rate = 1000, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    try std.testing.expect(!src.info().loop);
    try std.testing.expectEqual(@as(?u64, 500), src.durationFrames());
}

test "LAA notes without a valid instrument stay silent" {
    const gpa = std.testing.allocator;
    var song: TestSong = .{};
    const data = song.build(&.{ 0, 0x90, 60, 100, 0x83, 0x60, 0x80, 60, 0, 0, 0xff, 0x2f, 0 });
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 1000, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    for (0..9) |ch| try std.testing.expect(rec.regs[0xb0 + ch] & 0x20 == 0);
    try std.testing.expectEqual(@as(u16, 0), src.sequenceState().?.voice_count);
}

test "LAA a jump hangs held notes until their release time" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    var tail: TestSong = .{};
    tail.sysex(&.{ 0x81, 0x70 }, 48, &.{0}, &.{ 0, 0, 0, 0, 4, 0, 0 });
    tail.bytes(&.{ 0x83, 0x60, 0x80, 60, 0 });
    tail.bytes(&.{ 0x8d, 0x10, 0xff, 0x2f, 0 });
    const data = song.build(testTrack(&body, tail.buf[0..tail.len]));
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 1000, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    var elapsed: u64 = 0;
    var released_at: ?u64 = null;
    while (elapsed < 2000) {
        const r = src.step(rec.chip());
        if (released_at == null and rec.regs[0xb0] & 0x20 == 0) released_at = elapsed;
        elapsed += r.frames;
        if (r.done) break;
    }
    try std.testing.expect(released_at != null);
    try std.testing.expect(released_at.? >= 740 and released_at.? <= 760);
}

test "LAA instrument effects modulate registers over time" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    var ins = test_instrument;
    ins[11] = 0x80 | 0x20 | 0x04;
    ins[12..20].* = .{ 0, 4, 0x7f, 4, 0x00, 4, 4, 0x7f };
    body.len = 0;
    body.sysex(&.{0}, 0, &.{0}, &.{ 1, 0, 127, 0, 0, 0, 2, 0 });
    body.sysex(&.{0}, 16, &.{ 0, 1 }, &ins);
    body.bytes(&.{ 0, 0x90, 60, 127, 0x8f, 0x00, 0x80, 60, 0, 0, 0xff, 0x2f, 0 });
    const data = song.build(body.buf[0..body.len]);
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 1000, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    var seen: [64]bool = @splat(false);
    for (0..200) |_| {
        _ = src.step(rec.chip());
        seen[rec.regs[0x20 + op2[0]] & 0x0f] = true;
    }
    var distinct: usize = 0;
    for (seen) |s| distinct += @intFromBool(s);
    try std.testing.expect(distinct > 1);
}

fn loopDuration(loop_count: u8) !?u64 {
    var body: TestSong = .{};
    var song: TestSong = .{};
    var tail: TestSong = .{};
    tail.sysex(&.{100}, 80, &.{0}, &.{ 0, loop_count, 0, 1, 0, 200, 0, 3, 0, 0 });
    tail.bytes(&.{ 0x82, 0x7c, 0x80, 60, 0 });
    tail.sysex(&.{ 0x87, 0x40 }, 48, &.{0}, &.{ 0, 0, 0, 0, 1, 0, 0 });
    tail.bytes(&.{ 0x83, 0x60, 0xff, 0x2f, 0 });
    const src = (try load(std.testing.allocator, song.build(testTrack(&body, tail.buf[0..tail.len])), .{ .sample_rate = 1000, .chip = fmt.noop_chip })).?;
    defer src.deinit(std.testing.allocator);
    return src.durationFrames();
}

test "LAA a short counted loop plays out before the song loops, an endless one is the loop" {
    const short = (try loopDuration(1)).?;
    try std.testing.expect(short > 2200 and short < 2350);
    const endless = (try loopDuration(100)).?;
    try std.testing.expect(endless > 950 and endless < 1050);
}

test "LAA a backward hook jump into a skipped bar is the song loop" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    var tail: TestSong = .{};
    tail.sysex(&.{100}, 48, &.{0}, &.{ 0, 0, 0, 0, 3, 0, 0 });
    tail.bytes(&.{ 0x86, 0x5c, 0x80, 60, 0 });
    tail.sysex(&.{ 0x83, 0x60 }, 48, &.{0}, &.{ 0, 0, 0, 0, 1, 0x01, 0x90 });
    tail.bytes(&.{ 0x83, 0x60, 0xff, 0x2f, 0 });
    const src = (try load(gpa, song.build(testTrack(&body, tail.buf[0..tail.len])), .{ .sample_rate = 1000, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    const frames = src.durationFrames().?;
    try std.testing.expect(frames > 580 and frames < 640);
}

test "LAA files that allocate parts sound only on allocated parts" {
    const gpa = std.testing.allocator;
    var body: TestSong = .{};
    var song: TestSong = .{};
    body.sysex(&.{0}, 0, &.{0}, &.{ 1, 0, 127, 0, 0, 0, 2, 0 });
    body.sysex(&.{0}, 16, &.{ 0, 1 }, &test_instrument);
    body.sysex(&.{0}, 16, &.{ 1, 1 }, &test_instrument);
    body.bytes(&.{ 0, 0x91, 64, 100, 0, 0x90, 60, 100, 0x83, 0x60, 0xff, 0x2f, 0 });
    const src = (try load(gpa, song.build(body.buf[0..body.len]), .{ .sample_rate = 1000, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    const state = src.sequenceState().?;
    try std.testing.expectEqual(@as(u16, 1), state.voice_count);
    try std.testing.expectEqual(@as(u16, 0), state.voices[0].channel);

    body.len = 0;
    body.sysex(&.{0}, 16, &.{ 1, 1 }, &test_instrument);
    body.bytes(&.{ 0, 0x91, 64, 100, 0x83, 0x60, 0xff, 0x2f, 0 });
    const dynamic = (try load(gpa, song.build(body.buf[0..body.len]), .{ .sample_rate = 1000, .chip = fmt.noop_chip })).?;
    defer dynamic.deinit(gpa);
    _ = dynamic.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 1), dynamic.sequenceState().?.voice_count);
}

test "LAA declines other files and rejects broken MIDI" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try load(gpa, "MThd\x00\x00\x00\x06", .{ .sample_rate = 1000, .chip = fmt.noop_chip })) == null);
    var song: TestSong = .{};
    try std.testing.expectError(error.InvalidMusicData, load(gpa, song.build(&.{ 0, 0x90, 60 }), .{ .sample_rate = 1000, .chip = fmt.noop_chip }));
}
