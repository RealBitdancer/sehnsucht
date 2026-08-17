//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

pub const visualizer_name = "stream";

const magic = "CBMF";
const tick_hz: u32 = 25;
const max_voices = 9;
const max_slots = 16;
const patch_bytes = 11;

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };

const Reg = struct {
    const waveform_select: u16 = 0x01;
    const char_base: u16 = 0x20;
    const level_base: u16 = 0x40;
    const ad_base: u16 = 0x60;
    const sr_base: u16 = 0x80;
    const fnum_lo: u16 = 0xa0;
    const key_block: u16 = 0xb0;
    const feedback: u16 = 0xc0;
    const wave_base: u16 = 0xe0;
    const key_on: u8 = 0x20;
};

const op_regs = [_]u16{
    Reg.char_base,
    Reg.char_base + 3,
    Reg.level_base,
    Reg.level_base + 3,
    Reg.ad_base,
    Reg.ad_base + 3,
    Reg.sr_base,
    Reg.sr_base + 3,
    Reg.wave_base,
    Reg.wave_base + 3,
};

const note_freq = [128]u16{
    172,  182,  193,  205,  217,  230,  243,  258,  274,  290,  307,  326,
    345,  365,  387,  410,  435,  460,  489,  517,  547,  580,  614,  651,
    1369, 1389, 1411, 1434, 1459, 1484, 1513, 1541, 1571, 1604, 1638, 1675,
    2393, 2413, 2435, 2458, 2483, 2508, 2537, 2565, 2595, 2628, 2662, 2699,
    3417, 3437, 3459, 3482, 3507, 3532, 3561, 3589, 3619, 3652, 3686, 3723,
    4441, 4461, 4483, 4506, 4531, 4556, 4585, 4613, 4643, 4676, 4710, 4747,
    5465, 5485, 5507, 5530, 5555, 5580, 5609, 5637, 5667, 5700, 5734, 5771,
    6489, 6509, 6531, 6554, 6579, 6604, 6633, 6661, 6691, 6724, 6758, 6795,
    7513, 7533, 7555, 7578, 7603, 7628, 7657, 7685, 7715, 7748, 7782, 7819,
    7858, 7898, 7942, 7988, 8037, 8089, 8143, 8191, 8191, 8191, 8191, 8191,
    8191, 8191, 8191, 8191, 8191, 8191, 8191, 8191,
};

const Patch = extern struct {
    mod_char: u8,
    car_char: u8,
    mod_level: u8,
    car_level: u8,
    mod_ad: u8,
    car_ad: u8,
    mod_sr: u8,
    car_sr: u8,
    mod_wave: u8,
    car_wave: u8,
    feedback: u8,

    comptime {
        if (@sizeOf(Patch) != patch_bytes) @compileError("SBI patch must be 11 bytes");
    }

    fn apply(self: Patch, chip: fmt.Chip, voice: u4) void {
        if (@as(u8, voice) >= max_voices) return;
        const off = op_offset[voice];
        const bytes = std.mem.asBytes(&self);
        for (op_regs, bytes[0..op_regs.len]) |reg, val| {
            chip.writeReg(reg + off, val);
        }
        chip.writeReg(Reg.feedback + voice, self.feedback);
    }
};

const Jump = union(enum) {
    leave,
    song_loop,
    chorus,
    times: u8,

    const song_loop_code: u8 = 254;
    const chorus_code: u8 = 255;

    fn fromByte(code: u8) Jump {
        return switch (code) {
            0 => .leave,
            song_loop_code => .song_loop,
            chorus_code => .chorus,
            else => .{ .times = code },
        };
    }
};

const Event = union(enum) {
    stop,
    start_note: struct { voice: u4, freq: u8 },
    stop_note: u4,
    set_instrument: struct { voice: u4, patch: Patch },
    set_label: u4,
    jump: struct { label: u4, how: Jump },
    end_chorus,
    nop,
    wait: u8,
};

const Label = struct {
    at: ?usize = null,
    left: ?u8 = null,
};

fn take(song: []const u8, pos: *usize, n: usize) error{InvalidBam}![]const u8 {
    const end = pos.* + n;
    if (end > song.len) return error.InvalidBam;
    const slice = song[pos.*..end];
    pos.* = end;
    return slice;
}

fn takeByte(song: []const u8, pos: *usize) error{InvalidBam}!u8 {
    return (try take(song, pos, 1))[0];
}

fn readEvent(song: []const u8, pos: *usize) error{InvalidBam}!?Event {
    if (pos.* >= song.len) return null;
    const op = song[pos.*];
    pos.* += 1;

    if (op >= 0x80) return .{ .wait = op - 127 };
    if (op == 0x7f) return .nop;
    if (op == 0x70) return .end_chorus;
    if (op == 0x00) return .stop;

    const slot: u4 = @truncate(op);
    return switch (op >> 4) {
        0x1 => .{ .start_note = .{ .voice = slot, .freq = try takeByte(song, pos) } },
        0x2 => .{ .stop_note = slot },
        0x3 => blk: {
            const bytes = try take(song, pos, patch_bytes);
            break :blk .{ .set_instrument = .{
                .voice = slot,
                .patch = std.mem.bytesToValue(Patch, bytes[0..patch_bytes]),
            } };
        },
        0x5 => .{ .set_label = slot },
        0x6 => .{ .jump = .{ .label = slot, .how = .fromByte(try takeByte(song, pos)) } },
        else => error.InvalidBam,
    };
}

fn scan(song: []const u8) error{InvalidBam}!bool {
    var pos: usize = 0;
    var loop = false;
    while (try readEvent(song, &pos)) |ev| {
        switch (ev) {
            .jump => |j| if (j.how == .song_loop) {
                loop = true;
            },
            else => {},
        }
    }
    return loop;
}

fn freshLabels() [max_slots]Label {
    var labels: [max_slots]Label = @splat(.{});
    labels[0].at = 0;
    return labels;
}

const BamSource = struct {
    song: []const u8,
    pos: usize = 0,
    sample_rate: u32,
    frac: u32 = 0,
    loop: bool,
    chorus_ret: ?usize = null,
    labels: [max_slots]Label = freshLabels(),
    last_b0: [max_voices]u8 = @splat(0),

    const max_ops_per_step: u32 = 4096;

    fn rewind(self: *BamSource) void {
        self.pos = 0;
        self.chorus_ret = null;
        self.labels = freshLabels();
        self.last_b0 = @splat(0);
    }

    fn keyOn(self: *BamSource, chip: fmt.Chip, voice: u4, index: u8) void {
        if (@as(u8, voice) >= max_voices) return;
        const freq = note_freq[@min(index, note_freq.len - 1)];
        const b0: u8 = @intCast(freq >> 8);
        self.last_b0[voice] = b0;
        chip.writeReg(Reg.fnum_lo + voice, @truncate(freq));
        chip.writeReg(Reg.key_block + voice, b0 | Reg.key_on);
    }

    fn keyOff(self: *BamSource, chip: fmt.Chip, voice: u4) void {
        if (@as(u8, voice) >= max_voices) return;
        chip.writeReg(Reg.key_block + voice, self.last_b0[voice]);
    }

    fn follow(self: *BamSource, id: u4, how: Jump) bool {
        const at = self.labels[id].at orelse return false;
        switch (how) {
            .leave => {},
            .song_loop => {
                self.pos = at;
                self.chorus_ret = null;
                return true;
            },
            .chorus => {
                if (self.chorus_ret == null) {
                    self.chorus_ret = self.pos;
                    self.pos = at;
                }
            },
            .times => |n| {
                const lab = &self.labels[id];
                if (lab.left) |left| {
                    if (left == 0) {
                        lab.left = null;
                    } else {
                        lab.left = left - 1;
                        self.pos = at;
                    }
                } else {
                    lab.left = n - 1;
                    self.pos = at;
                }
            },
        }
        return false;
    }

    pub fn step(self: *BamSource, chip: fmt.Chip) fmt.StepResult {
        var ops: u32 = 0;
        while (self.pos < self.song.len) {
            var cur = self.pos;
            const ev = (readEvent(self.song, &cur) catch break) orelse break;
            self.pos = cur;
            ops += 1;

            switch (ev) {
                .stop => {
                    self.rewind();
                    return .{ .frames = 0, .done = true };
                },
                .start_note => |n| self.keyOn(chip, n.voice, n.freq),
                .stop_note => |voice| self.keyOff(chip, voice),
                .set_instrument => |ins| ins.patch.apply(chip, ins.voice),
                .set_label => |id| self.labels[id].at = self.pos,
                .jump => |j| {
                    if (self.follow(j.label, j.how)) return .{ .frames = 0, .done = true };
                },
                .end_chorus => {
                    if (self.chorus_ret) |ret| {
                        self.pos = ret;
                        self.chorus_ret = null;
                    }
                },
                .nop => {},
                .wait => |ticks| {
                    return .{ .frames = fmt.rescale(ticks, tick_hz, self.sample_rate, &self.frac) };
                },
            }

            if (ops >= max_ops_per_step) return .{ .frames = 0 };
        }
        self.rewind();
        return .{ .frames = 0, .done = true };
    }

    pub fn info(self: *BamSource) fmt.TrackInfo {
        return .{
            .format_name = "BAM",
            .opl3 = false,
            .system = "OPL2",
            .loop = self.loop,
            .visualizer = visualizer_name,
        };
    }

    pub fn deinit(self: *BamSource, gpa: std.mem.Allocator) void {
        gpa.free(self.song);
        gpa.destroy(self);
    }
};

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    const body = data[magic.len..];
    const loop = try scan(body);

    const song = try gpa.dupe(u8, body);
    errdefer gpa.free(song);
    const src = try gpa.create(BamSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .song = song,
        .sample_rate = ctx.sample_rate,
        .loop = loop,
    };

    ctx.chip.writeReg(Reg.waveform_select, 0x20);
    ctx.chip.flush();
    return fmt.MusicSource.init(src);
}

pub const format = fmt.Format{
    .name = "BAM",
    .extensions = &.{".bam"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

const wait1: u8 = 128;
const label0: u8 = 0x50;
const jump0: u8 = 0x60;
const label1: u8 = 0x51;
const jump1: u8 = 0x61;

fn loadBam(gpa: std.mem.Allocator, data: []const u8) !fmt.MusicSource {
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".bam",
    })).?;
}

test "bam loads and waits" {
    const gpa = std.testing.allocator;
    const src = try loadBam(gpa, magic ++ [_]u8{ wait1, 0x00 });
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("BAM", src.info().format_name);
    try std.testing.expect(!src.info().loop);
    try std.testing.expectEqual(@as(u64, 44100 / tick_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}

test "bam rejects bad files" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".bam" };
    try std.testing.expect(try load(gpa, "BAM\x01", ctx) == null);
    try std.testing.expectError(error.InvalidBam, load(gpa, magic ++ [_]u8{jump0}, ctx));
}

test "bam song loop is a boundary" {
    const gpa = std.testing.allocator;
    const src = try loadBam(gpa, magic ++ [_]u8{ label0, wait1, jump0, Jump.song_loop_code, 0x00 });
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}

test "bam chorus returns" {
    const gpa = std.testing.allocator;
    const src = try loadBam(gpa, magic ++ [_]u8{
        label1, wait1, 0x70, jump1, Jump.chorus_code, 129, 0x00,
    });
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 44100 / tick_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u64, 44100 / tick_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u64, 2 * 44100 / tick_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}
