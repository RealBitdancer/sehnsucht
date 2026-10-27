//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "JBM";
pub const extensions = &.{".jbm"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };

const id_word: u16 = 2;
const header_bytes = 32;
const voice_count = 11;
const melodic_voices = 9;
const inst_size = 16;
const pit_hz: u32 = 1_193_180;
const max_ops_per_step: u32 = 4096;
const max_note: u8 = 95;
const cmd_instrument: u8 = 0xfd;
const cmd_end: u8 = 0xff;
const note_off_bit: u8 = 0x80;
const tl_xor: u8 = 0x3f;

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };
const perc_op = [_]u8{ 0x14, 0x12, 0x15, 0x11 };
const perc_ch = [_]u8{ 6, 7, 8, 8, 7 };
const perc_on = [_]u8{ 0x10, 0x08, 0x04, 0x02, 0x01 };
const perc_off = [_]u8{ 0xef, 0xf7, 0xfb, 0xfd, 0xfe };

const note_table = [_]u16{
    0x0158, 0x016d, 0x0183, 0x019a, 0x01b2, 0x01cc, 0x01e7, 0x0204,
    0x0223, 0x0244, 0x0266, 0x028b, 0x0558, 0x056d, 0x0583, 0x059a,
    0x05b2, 0x05cc, 0x05e7, 0x0604, 0x0623, 0x0644, 0x0666, 0x068b,
    0x0958, 0x096d, 0x0983, 0x099a, 0x09b2, 0x09cc, 0x09e7, 0x0a04,
    0x0a23, 0x0a44, 0x0a66, 0x0a8b, 0x0d58, 0x0d6d, 0x0d83, 0x0d9a,
    0x0db2, 0x0dcc, 0x0de7, 0x0e04, 0x0e23, 0x0e44, 0x0e66, 0x0e8b,
    0x1158, 0x116d, 0x1183, 0x119a, 0x11b2, 0x11cc, 0x11e7, 0x1204,
    0x1223, 0x1244, 0x1266, 0x128b, 0x1558, 0x156d, 0x1583, 0x159a,
    0x15b2, 0x15cc, 0x15e7, 0x1604, 0x1623, 0x1644, 0x1666, 0x168b,
    0x1958, 0x196d, 0x1983, 0x199a, 0x19b2, 0x19cc, 0x19e7, 0x1a04,
    0x1a23, 0x1a44, 0x1a66, 0x1a8b, 0x1d58, 0x1d6d, 0x1d83, 0x1d9a,
    0x1db2, 0x1dcc, 0x1de7, 0x1e04, 0x1e23, 0x1e44, 0x1e66, 0x1e8b,
};

const Patch = extern struct {
    mod_char: u8 = 0,
    mod_level: u8 = 0,
    mod_ad: u8 = 0,
    mod_sr: u8 = 0,
    car_char: u8 = 0,
    car_level: u8 = 0,
    car_ad: u8 = 0,
    car_sr: u8 = 0,
    extra: u8 = 0,
    pad: [7]u8 = @splat(0),

    comptime {
        if (@sizeOf(Patch) != inst_size) @compileError("JBM instrument must be 16 bytes");
    }

    fn conn(self: Patch) u8 {
        return self.extra & 0x0f;
    }

    fn oplPatch(self: Patch) view.OplPatch {
        const c0 = self.conn();
        return .{
            .ops = .{
                fmt.operatorParams(self.mod_char, self.mod_level ^ tl_xor, self.mod_ad, self.mod_sr, (self.extra >> 4) & 3),
                fmt.operatorParams(self.car_char, self.car_level ^ tl_xor, self.car_ad, self.car_sr, (self.extra >> 6) & 3),
                .{},
                .{},
            },
            .op_count = 2,
            .feedback = @truncate((c0 >> 1) & 7),
            .additive = c0 & 1 != 0,
        };
    }
};

const Voice = struct {
    trkstart: usize = 0,
    trkpos: usize = 0,
    seqpos: usize = 0,
    delay: u32 = 0,
    note: u8 = 0,
    vol: u8 = 0,
    instr: ?u8 = null,
    frq: u16 = 0,
    keyed: bool = false,
    used: bool = false,
    looped: bool = false,
};

const Parsed = struct {
    seqtable: usize,
    instable: usize,
    seqcount: usize,
    inscount: usize,
    divisor: u16,
    rhythm: bool,
    tracks: [voice_count]usize,
    total_ticks: u64,
};

fn take(file: []const u8, pos: *usize, n: usize) error{InvalidJbm}![]const u8 {
    const end = pos.* + n;
    if (end > file.len) return error.InvalidJbm;
    const slice = file[pos.*..end];
    pos.* = end;
    return slice;
}

fn takeByte(file: []const u8, pos: *usize) error{InvalidJbm}!u8 {
    return (try take(file, pos, 1))[0];
}

fn sequenceAt(file: []const u8, seqtable: usize, seqcount: usize, idx: u8) error{InvalidJbm}!usize {
    if (idx >= seqcount) return error.InvalidJbm;
    const off: usize = fmt.readU16Le(file, seqtable + @as(usize, idx) * 2);
    if (off >= file.len) return error.InvalidJbm;
    return off;
}

fn nextSeq(file: []const u8, trkpos: *usize, trkstart: usize) error{InvalidJbm}!struct { seqno: u8, wrapped: bool } {
    trkpos.* += 1;
    if (trkpos.* >= file.len) return error.InvalidJbm;
    const seqno = file[trkpos.*];
    if (seqno == cmd_end) {
        trkpos.* = trkstart;
        return .{ .seqno = file[trkstart], .wrapped = true };
    }
    return .{ .seqno = seqno, .wrapped = false };
}

fn walkVoice(
    file: []const u8,
    seqtable: usize,
    seqcount: usize,
    trkstart: usize,
) error{InvalidJbm}!u64 {
    if (trkstart >= file.len or file[trkstart] == cmd_end) return error.InvalidJbm;
    var trkpos = trkstart;
    var seqpos = try sequenceAt(file, seqtable, seqcount, file[trkstart]);
    var ticks: u64 = 0;
    var notes: u32 = 0;
    var ops: u32 = 0;
    const cap: u32 = @intCast(file.len * 2 + 8);
    while (ops < cap) : (ops += 1) {
        const cmd = try takeByte(file, &seqpos);
        switch (cmd) {
            cmd_instrument => _ = try takeByte(file, &seqpos),
            cmd_end => {
                const step = try nextSeq(file, &trkpos, trkstart);
                if (step.wrapped) {
                    if (notes == 0 or ticks == 0) return error.InvalidJbm;
                    return ticks;
                }
                seqpos = try sequenceAt(file, seqtable, seqcount, step.seqno);
            },
            else => {
                if (cmd & ~note_off_bit > max_note) return error.InvalidJbm;
                const rest = try take(file, &seqpos, 3);
                ticks += @as(u64, fmt.readU16Le(rest, 1)) + 1;
                notes += 1;
            },
        }
    }
    return error.InvalidJbm;
}

fn parse(data: []const u8) error{InvalidJbm}!?Parsed {
    if (data.len < header_bytes) return null;
    if (fmt.readU16Le(data, 0) != id_word) return null;

    const divisor = fmt.readU16Le(data, 2);
    const seqtable: usize = fmt.readU16Le(data, 4);
    const instable: usize = fmt.readU16Le(data, 6);
    const flags = fmt.readU16Le(data, 8);
    if (seqtable < header_bytes or seqtable + 2 > data.len) return error.InvalidJbm;
    if (instable >= data.len or (data.len - instable) / inst_size == 0) return error.InvalidJbm;

    var tracks: [voice_count]usize = @splat(0);
    var min_track: usize = std.math.maxInt(usize);
    var used: u32 = 0;
    for (0..voice_count) |i| {
        const off: usize = fmt.readU16Le(data, 10 + i * 2);
        tracks[i] = off;
        if (off == 0) continue;
        if (off >= data.len) return error.InvalidJbm;
        if (off < min_track) min_track = off;
        used += 1;
    }
    if (used == 0 or min_track < seqtable + 2) return error.InvalidJbm;
    if ((min_track - seqtable) % 2 != 0) return error.InvalidJbm;
    const seqcount = (min_track - seqtable) / 2;
    if (seqcount == 0 or seqcount > 256) return error.InvalidJbm;

    const inscount = @min((data.len - instable) / inst_size, 256);
    var total: u64 = 0;
    for (tracks) |trk| {
        if (trk == 0) continue;
        const ticks = try walkVoice(data, seqtable, seqcount, trk);
        if (ticks > total) total = ticks;
    }
    return .{
        .seqtable = seqtable,
        .instable = instable,
        .seqcount = seqcount,
        .inscount = inscount,
        .divisor = if (divisor == 0) 0xffff else divisor,
        .rhythm = flags & 1 != 0,
        .tracks = tracks,
        .total_ticks = total,
    };
}

const JbmSource = struct {
    file: []const u8,
    seqtable: usize,
    instable: usize,
    seqcount: usize,
    inscount: usize,
    divisor: u16,
    rhythm: bool,
    sample_rate: u32,
    frac: u32 = 0,
    total_ticks: u64,
    bdreg: u8,
    voice: [voice_count]Voice = @splat(.{}),
    events: []view.SequenceEvent = &.{},
    tick: u32 = 0,
    pending_wait: u32 = 0,

    fn seqOff(self: *const JbmSource, idx: u8) error{InvalidJbm}!usize {
        return sequenceAt(self.file, self.seqtable, self.seqcount, idx);
    }

    fn patchAt(self: *const JbmSource, idx: u8) ?Patch {
        if (idx >= self.inscount) return null;
        const off = self.instable + @as(usize, idx) * inst_size;
        if (off + inst_size > self.file.len) return null;
        return std.mem.bytesToValue(Patch, self.file[off..][0..inst_size]);
    }

    fn isPerc(self: *const JbmSource, ch: usize) bool {
        return self.rhythm and ch > 5;
    }

    fn applyPatch(self: *const JbmSource, chip: fmt.Chip, ch: usize, idx: u8) void {
        const patch = self.patchAt(idx) orelse return;
        if (self.rhythm and ch > 6) {
            const op = perc_op[ch - 7];
            chip.writeReg(0x20 + op, patch.mod_char);
            chip.writeReg(0x40 + op, patch.mod_level ^ tl_xor);
            chip.writeReg(0x60 + op, patch.mod_ad);
            chip.writeReg(0x80 + op, patch.mod_sr);
            chip.writeReg(0xc0 + perc_ch[ch - 6], patch.conn());
            return;
        }
        if (ch >= melodic_voices) return;
        const op = op_offset[ch];
        chip.writeReg(0x20 + op, patch.mod_char);
        chip.writeReg(0x40 + op, patch.mod_level ^ tl_xor);
        chip.writeReg(0x60 + op, patch.mod_ad);
        chip.writeReg(0x80 + op, patch.mod_sr);
        chip.writeReg(0x23 + op, patch.car_char);
        chip.writeReg(0x43 + op, patch.car_level ^ tl_xor);
        chip.writeReg(0x63 + op, patch.car_ad);
        chip.writeReg(0x83 + op, patch.car_sr);
        chip.writeReg(0xe0 + op, (patch.extra >> 4) & 3);
        chip.writeReg(0xe3 + op, (patch.extra >> 6) & 3);
        chip.writeReg(0xc0 + @as(u16, @intCast(ch)), patch.conn());
    }

    fn writeGate(self: *JbmSource, chip: fmt.Chip, ch: usize, on: bool) void {
        const v = &self.voice[ch];
        if (self.isPerc(ch)) {
            const p = ch - 6;
            chip.writeReg(0xa0 + perc_ch[p], @truncate(v.frq));
            chip.writeReg(0xb0 + perc_ch[p], @intCast(v.frq >> 8));
            self.bdreg = if (on) self.bdreg | perc_on[p] else self.bdreg & perc_off[p];
            chip.writeReg(0xbd, self.bdreg);
            v.keyed = on;
            return;
        }
        if (ch >= melodic_voices) return;
        chip.writeReg(0xa0 + @as(u16, @intCast(ch)), @truncate(v.frq));
        const b0: u8 = @intCast(v.frq >> 8);
        chip.writeReg(0xb0 + @as(u16, @intCast(ch)), if (on) b0 | 0x20 else b0 & 0x1f);
        v.keyed = on;
    }

    fn writeVol(self: *const JbmSource, chip: fmt.Chip, ch: usize, vol: u8) void {
        const level = vol ^ tl_xor;
        if (self.rhythm and ch > 6) {
            chip.writeReg(0x40 + perc_op[ch - 7], level);
            return;
        }
        if (ch >= melodic_voices) return;
        chip.writeReg(0x43 + op_offset[ch], level);
    }

    fn takeVoiceByte(self: *const JbmSource, pos: *usize) error{InvalidJbm}!u8 {
        return takeByte(self.file, pos);
    }

    fn process(self: *JbmSource, chip: fmt.Chip, ch: usize) error{InvalidJbm}!void {
        var v = &self.voice[ch];
        if (v.keyed) self.writeGate(chip, ch, false);

        var ops: u32 = 0;
        while (v.delay == 0) {
            ops += 1;
            if (ops >= max_ops_per_step) return;
            const cmd = try self.takeVoiceByte(&v.seqpos);
            switch (cmd) {
                cmd_instrument => {
                    v.instr = try self.takeVoiceByte(&v.seqpos);
                    self.applyPatch(chip, ch, v.instr.?);
                },
                cmd_end => {
                    const nxt = try nextSeq(self.file, &v.trkpos, v.trkstart);
                    if (nxt.wrapped) v.looped = true;
                    v.seqpos = try self.seqOff(nxt.seqno);
                    if (nxt.wrapped) return;
                },
                else => {
                    const vol = try self.takeVoiceByte(&v.seqpos);
                    const lo = try self.takeVoiceByte(&v.seqpos);
                    const hi = try self.takeVoiceByte(&v.seqpos);
                    v.note = cmd;
                    v.vol = vol;
                    v.delay = (@as(u32, lo) | (@as(u32, hi) << 8)) + 1;
                    const pitch = cmd & ~note_off_bit;
                    if (pitch <= max_note) v.frq = note_table[pitch];
                    self.writeVol(chip, ch, vol);
                    self.writeGate(chip, ch, cmd & note_off_bit == 0);
                },
            }
        }
    }

    fn allLooped(self: *const JbmSource) bool {
        for (self.voice) |v| {
            if (v.used and !v.looped) return false;
        }
        return true;
    }

    fn minDelay(self: *const JbmSource) u32 {
        var min: u32 = std.math.maxInt(u32);
        for (self.voice) |v| {
            if (v.used and v.delay != 0 and v.delay < min) min = v.delay;
        }
        return min;
    }

    fn subDelay(self: *JbmSource, n: u32) void {
        for (&self.voice) |*v| {
            if (v.used and v.delay >= n) v.delay -= n;
        }
    }

    fn rewind(self: *JbmSource, chip: fmt.Chip) void {
        for (0..voice_count) |ch| {
            if (self.voice[ch].keyed) self.writeGate(chip, ch, false);
            startVoice(self, ch);
        }
        self.tick = 0;
    }

    fn framesFor(self: *JbmSource, ticks: u64) u64 {
        return fmt.rescale(ticks * self.divisor, pit_hz, self.sample_rate, &self.frac);
    }

    pub fn step(self: *JbmSource, chip: fmt.Chip) fmt.StepResult {
        if (self.pending_wait != 0) {
            self.tick +|= self.pending_wait;
            self.pending_wait = 0;
        }

        for (0..2) |_| {
            for (0..voice_count) |ch| {
                if (!self.voice[ch].used or self.voice[ch].delay != 0) continue;
                self.process(chip, ch) catch return .{ .frames = 0, .done = true };
            }
            if (self.allLooped()) {
                self.rewind(chip);
                return .{ .frames = 0, .done = true };
            }
        }
        for (self.voice) |v| if (v.used and v.delay == 0) return .{ .frames = 0 };

        const wait = self.minDelay();
        if (wait == 0 or wait == std.math.maxInt(u32)) {
            return .{ .frames = 0 };
        }
        self.subDelay(wait);
        self.pending_wait = wait;
        return .{ .frames = self.framesFor(wait) };
    }

    pub fn info(_: *JbmSource) fmt.TrackInfo {
        return .{
            .format_name = format_name,
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .archive_track_count = 0,
        };
    }

    pub fn durationFrames(self: *JbmSource) u64 {
        const num = @as(u128, self.total_ticks) * self.divisor * self.sample_rate;
        return @intCast(num / pit_hz);
    }

    pub fn playhead(self: *JbmSource) view.Playhead {
        return .{
            .tick = self.tick,
            .flags = .{ .has_tick = true },
        };
    }

    pub fn sequenceState(self: *JbmSource) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = if (self.rhythm) voice_count else melodic_voices };
        const n = bank.channels;
        for (0..n) |i| {
            const v = self.voice[i];
            bank.slots[i] = .{
                .program = if (v.instr) |instrument| instrument else view.sequence_unassigned,
                .note = v.note & ~note_off_bit,
                .keyed = v.keyed,
                .opl_voice = if (self.isPerc(i)) perc_ch[i - 6] else @intCast(i),
                .pc = @intCast(@min(v.seqpos, std.math.maxInt(u32))),
                .duration = @truncate(@min(v.delay, 255)),
            };
        }
        return bank;
    }

    pub fn sequenceView(self: *JbmSource) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .event_stream,
            .track_count = if (self.rhythm) voice_count else melodic_voices,
            .channel_count = if (self.rhythm) voice_count else melodic_voices,
            .tick_rate = @max(1, pit_hz / @as(u32, self.divisor)),
            .length_ticks = @intCast(@min(self.total_ticks, std.math.maxInt(u32))),
            .track = jbmTrack,
            .eventAt = jbmEventAt,
            .eventsInRange = jbmEventsInRange,
            .event_count = @intCast(self.events.len),
        };
    }

    pub fn instrumentBank(self: *JbmSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = @intCast(self.inscount),
            .get = jbmInstrument,
        };
    }

    pub fn deinit(self: *JbmSource, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.file);
        gpa.destroy(self);
    }
};

fn jbmTrack(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self: *JbmSource = @ptrCast(@alignCast(ptr));
    if (index >= voice_count) return .{};
    const drum = self.rhythm and index > 5;
    return .{
        .channel = @intCast(index),
        .kind = if (drum) .drum else .melodic,
        .in_use = self.voice[index].used,
    };
}

fn jbmEventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self: *JbmSource = @ptrCast(@alignCast(ptr));
    if (index >= self.events.len) return .{};
    return self.events[index];
}

fn jbmEventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self: *JbmSource = @ptrCast(@alignCast(ptr));
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

fn jbmInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self: *JbmSource = @ptrCast(@alignCast(ptr));
    if (index >= self.inscount) return .{};
    const patch = self.patchAt(@intCast(index)) orelse return .{};
    return .{ .patch = .{ .opl_2op = patch.oplPatch() } };
}

fn indexVoice(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(view.SequenceEvent),
    file: []const u8,
    seqtable: usize,
    seqcount: usize,
    trkstart: usize,
    track: u16,
    ticks: u32,
) !void {
    var trkpos = trkstart;
    var seqpos = try sequenceAt(file, seqtable, seqcount, file[trkstart]);
    var tick: u32 = 0;
    var ops: u32 = 0;
    const cap: u32 = @intCast(file.len * 2 + 8);
    while (ops < cap and tick <= ticks) : (ops += 1) {
        const start = seqpos;
        const cmd = try takeByte(file, &seqpos);
        if (tick == ticks and cmd != cmd_end) {
            if (cmd != cmd_instrument) return;
            _ = try takeByte(file, &seqpos);
            continue;
        }
        switch (cmd) {
            cmd_instrument => {
                const ins = try takeByte(file, &seqpos);
                try list.append(gpa, .{
                    .tick = tick,
                    .instr_index = @intCast(start),
                    .track = track,
                    .channel = @intCast(track),
                    .kind = .program,
                    .payload = .{ .program = ins },
                });
            },
            cmd_end => {
                const nxt = try nextSeq(file, &trkpos, trkstart);
                try list.append(gpa, .{
                    .tick = tick,
                    .instr_index = @intCast(start),
                    .track = track,
                    .channel = @intCast(track),
                    .kind = .jump,
                    .payload = .{ .jump = if (nxt.wrapped) cmd_end else nxt.seqno },
                });
                if (nxt.wrapped and tick >= ticks) return;
                seqpos = try sequenceAt(file, seqtable, seqcount, nxt.seqno);
            },
            else => {
                const vol = try takeByte(file, &seqpos);
                const lo = try takeByte(file, &seqpos);
                const hi = try takeByte(file, &seqpos);
                const delay: u32 = @as(u32, lo) | (@as(u32, hi) << 8);
                const pitch = cmd & ~note_off_bit;
                try list.append(gpa, .{
                    .tick = tick,
                    .instr_index = @intCast(start),
                    .track = track,
                    .channel = @intCast(track),
                    .kind = if (cmd & note_off_bit != 0) .note_off else .duration_note,
                    .payload = .{ .note = .{
                        .note = pitch,
                        .velocity = vol,
                        .duration_ticks = delay + 1,
                    } },
                });
                tick +|= delay + 1;
            },
        }
    }
}

fn indexSong(
    gpa: std.mem.Allocator,
    file: []const u8,
    parsed: Parsed,
) ![]view.SequenceEvent {
    var list: std.ArrayList(view.SequenceEvent) = .empty;
    errdefer list.deinit(gpa);
    const ticks: u32 = @intCast(@min(parsed.total_ticks, std.math.maxInt(u32)));
    for (parsed.tracks, 0..) |trk, ch| {
        if (trk == 0) continue;
        try indexVoice(gpa, &list, file, parsed.seqtable, parsed.seqcount, trk, @intCast(ch), ticks);
    }
    const Ranked = struct { ev: view.SequenceEvent, n: u32 };
    const ranked = try gpa.alloc(Ranked, list.items.len);
    defer gpa.free(ranked);
    for (list.items, 0..) |ev, i| ranked[i] = .{ .ev = ev, .n = @intCast(i) };
    std.mem.sort(Ranked, ranked, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            if (a.ev.tick != b.ev.tick) return a.ev.tick < b.ev.tick;
            return a.n < b.n;
        }
    }.less);
    for (ranked, list.items) |item, *slot| slot.* = item.ev;
    return list.toOwnedSlice(gpa);
}

fn startVoice(self: *JbmSource, ch: usize) void {
    var v = &self.voice[ch];
    if (!v.used) return;
    v.trkpos = v.trkstart;
    v.seqpos = sequenceAt(self.file, self.seqtable, self.seqcount, self.file[v.trkpos]) catch 0;
    v.delay = 0;
    v.note = 0;
    v.vol = 0;
    v.instr = null;
    v.frq = 0;
    v.keyed = false;
    v.looped = false;
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const parsed = (try parse(data)) orelse return null;

    const file = try gpa.dupe(u8, data);
    errdefer gpa.free(file);
    const events = try indexSong(gpa, file, parsed);
    errdefer gpa.free(events);
    const src = try gpa.create(JbmSource);
    errdefer gpa.destroy(src);

    const bdreg: u8 = 0xc0 | @as(u8, if (parsed.rhythm) 0x20 else 0);
    src.* = .{
        .file = file,
        .seqtable = parsed.seqtable,
        .instable = parsed.instable,
        .seqcount = parsed.seqcount,
        .inscount = parsed.inscount,
        .divisor = parsed.divisor,
        .rhythm = parsed.rhythm,
        .sample_rate = ctx.sample_rate,
        .total_ticks = parsed.total_ticks,
        .bdreg = bdreg,
        .events = events,
    };
    for (parsed.tracks, 0..) |trk, ch| {
        src.voice[ch].used = trk != 0;
        src.voice[ch].trkstart = trk;
        startVoice(src, ch);
    }

    ctx.chip.writeReg(0x01, 0x20);
    ctx.chip.writeReg(0xbd, bdreg);
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
        divisor: u16 = 17045,
        flags: u16 = 0,
        tracks: [voice_count][]const u8,
        sequences: []const []const u8,
        instruments: u16 = 1,
    },
) ![]u8 {
    var seq_bytes: usize = 0;
    for (opts.sequences) |s| seq_bytes += s.len;
    var trk_bytes: usize = 0;
    for (opts.tracks) |t| trk_bytes += t.len;

    const seqtable: u16 = header_bytes;
    const seq_ptr_bytes: u16 = @intCast(opts.sequences.len * 2);
    const trk_base: u16 = seqtable + seq_ptr_bytes;
    const seq_base: u16 = trk_base + @as(u16, @intCast(trk_bytes));
    const instable: u16 = seq_base + @as(u16, @intCast(seq_bytes));
    const total = @as(usize, instable) + @as(usize, opts.instruments) * inst_size;

    const buf = try gpa.alloc(u8, total);
    @memset(buf, 0);
    putU16(buf, 0, id_word);
    putU16(buf, 2, opts.divisor);
    putU16(buf, 4, seqtable);
    putU16(buf, 6, instable);
    putU16(buf, 8, opts.flags);

    var trk_off = trk_base;
    var track_ptr: [voice_count]u16 = @splat(0);
    for (opts.tracks, 0..) |t, i| {
        if (t.len == 0) continue;
        track_ptr[i] = trk_off;
        @memcpy(buf[trk_off..][0..t.len], t);
        trk_off += @intCast(t.len);
    }
    for (track_ptr, 0..) |p, i| putU16(buf, 10 + i * 2, p);

    var seq_off = seq_base;
    for (opts.sequences, 0..) |s, i| {
        putU16(buf, seqtable + i * 2, seq_off);
        @memcpy(buf[seq_off..][0..s.len], s);
        seq_off += @intCast(s.len);
    }
    return buf;
}

fn loadJbm(gpa: std.mem.Allocator, data: []const u8) !fmt.MusicSource {
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".jbm",
        .name = "tune.jbm",
    })).?;
}

const empty_tracks: [voice_count][]const u8 = @splat(&.{});

test "jbm loads a one-note file" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{&.{ cmd_instrument, 0, 0x20, 0x3f, 0x01, 0x00, cmd_end }},
    });
    defer gpa.free(data);

    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("JBM", src.info().format_name);
    try std.testing.expectEqualStrings("sequence", src.info().visualizer);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(u16, 1), src.views().instruments.?.count);
    try std.testing.expect(src.views().sequence.?.event_count >= 2);
    try std.testing.expectEqual(@as(u64, 2), (try parse(data)).?.total_ticks);
    try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
}

test "jbm track end loops and reports a song boundary" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{&.{
            0x20,    0x3f, 0x01, 0x00,
            0x22,    0x3f, 0x01, 0x00,
            cmd_end,
        }},
    });
    defer gpa.free(data);
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);
    const first = src.step(fmt.noop_chip);
    const second = src.step(fmt.noop_chip);
    const end = src.step(fmt.noop_chip);
    try std.testing.expect(!first.done and !second.done and end.done);
    try std.testing.expectEqual(@as(u64, 0), end.frames);
    try std.testing.expectEqual(src.durationFrames().?, first.frames + second.frames);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}

test "jbm rejects the wrong id and a note past 95" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".jbm", .name = "x.jbm" };
    try std.testing.expect(try load(gpa, &.{ 1, 0, 0, 0 }, ctx) == null);
    try std.testing.expect(try load(gpa, "notjbm", ctx) == null);
    var not_id: [header_bytes]u8 = @splat(0);
    putU16(&not_id, 0, 1);
    try std.testing.expect(try load(gpa, &not_id, ctx) == null);
    var short_ok_id: [header_bytes - 1]u8 = @splat(0);
    putU16(short_ok_id[0..2], 0, id_word);
    try std.testing.expect(try load(gpa, &short_ok_id, ctx) == null);

    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    const bad = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{&.{ 96, 0x3f, 0x01, 0x00, cmd_end }},
    });
    defer gpa.free(bad);
    try std.testing.expectError(error.InvalidJbm, load(gpa, bad, ctx));
}

test "jbm percussion gates preserve the other drums and share physical voices" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[6] = &.{ 0, cmd_end };
    tracks[7] = &.{ 1, cmd_end };
    const data = try pack(gpa, .{
        .flags = 1,
        .tracks = tracks,
        .sequences = &.{
            &.{ 0x20, 0x3f, 0, 0, 0x80, 0x3f, 1, 0, cmd_end },
            &.{ 0x20, 0x3f, 2, 0, cmd_end },
        },
    });
    defer gpa.free(data);
    const Capture = struct {
        rhythm: u8 = 0,
        fn write(ptr: *anyopaque, reg: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg == 0xbd) self.rhythm = value;
        }
        fn flush(_: *anyopaque) void {}
    };
    var capture: Capture = .{};
    const chip: fmt.Chip = .{ .ptr = &capture, .vtable = &.{ .writeReg = Capture.write, .flush = Capture.flush } };
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);
    _ = src.step(chip);
    try std.testing.expectEqual(@as(u8, 0x18), capture.rhythm & 0x1f);
    _ = src.step(chip);
    try std.testing.expectEqual(@as(u8, 0x08), capture.rhythm & 0x1f);
    const state = src.sequenceState().?;
    try std.testing.expectEqual(@as(?u8, 8), state.slots[9].opl_voice);
    try std.testing.expectEqual(@as(?u8, 7), state.slots[10].opl_voice);
}

test "jbm voices without an instrument command publish no program" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{&.{ 0x20, 0x3f, 0x01, 0x00, cmd_end }},
    });
    defer gpa.free(data);
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(view.sequence_unassigned, src.sequenceState().?.slots[0].program);
}

test "jbm song boundary restarts every voice to match the index" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    tracks[1] = &.{ 1, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{
            &.{ 0x20, 0x3f, 0x02, 0x00, cmd_end },
            &.{ 0x24, 0x3f, 0x03, 0x00, cmd_end },
        },
    });
    defer gpa.free(data);
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);

    const sv = src.views().sequence.?;
    var dest: [8]view.SequenceEvent = undefined;
    const replay = sv.eventsInRange.?(sv.ctx, 3, 4, &dest);
    try std.testing.expectEqual(@as(u16, 2), replay.written);
    try std.testing.expectEqual(@as(u16, 0), dest[1].track);
    try std.testing.expectEqual(view.SequenceEventKind.duration_note, dest[1].kind);

    _ = src.step(fmt.noop_chip);
    const fresh = src.sequenceState().?;
    var steps: u32 = 0;
    while (!src.step(fmt.noop_chip).done) : (steps += 1) try std.testing.expect(steps < 16);
    _ = src.step(fmt.noop_chip);
    const again = src.sequenceState().?;
    for (0..2) |ch| try std.testing.expectEqual(fresh.slots[ch], again.slots[ch]);
}

test "jbm index stops at the song end when voice loops differ in length" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    tracks[1] = &.{ 1, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{
            &.{ 0x20, 0x3f, 0x00, 0x00, 0x21, 0x3f, 0x00, 0x00, 0x22, 0x3f, 0x00, 0x00, cmd_end },
            &.{ 0x30, 0x3f, 0x03, 0x00, cmd_end },
        },
    });
    defer gpa.free(data);
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);

    const sv = src.views().sequence.?;
    try std.testing.expectEqual(@as(u32, 4), sv.length_ticks);
    try std.testing.expectEqual(@as(u32, 7), sv.event_count);
    for (0..sv.event_count) |i| {
        const ev = sv.eventAt.?(sv.ctx, @intCast(i));
        try std.testing.expect(ev.tick <= sv.length_ticks);
        try std.testing.expect(ev.tick < sv.length_ticks or ev.kind == .jump);
    }
    const last = sv.eventAt.?(sv.ctx, sv.event_count - 1);
    try std.testing.expectEqual(@as(u16, 1), last.track);
    try std.testing.expectEqual(@as(u32, cmd_end), last.payload.jump);
}

test "jbm index keeps a final-tick wrap that follows an instrument change" {
    const gpa = std.testing.allocator;
    var tracks = empty_tracks;
    tracks[0] = &.{ 0, cmd_end };
    const data = try pack(gpa, .{
        .tracks = tracks,
        .sequences = &.{&.{ 0x30, 0x3f, 0x03, 0x00, cmd_instrument, 0x00, cmd_end }},
    });
    defer gpa.free(data);
    const src = try loadJbm(gpa, data);
    defer src.deinit(gpa);

    const sv = src.views().sequence.?;
    try std.testing.expectEqual(@as(u32, 4), sv.length_ticks);
    try std.testing.expectEqual(@as(u32, 2), sv.event_count);
    const last = sv.eventAt.?(sv.ctx, 1);
    try std.testing.expectEqual(view.SequenceEventKind.jump, last.kind);
    try std.testing.expectEqual(@as(u32, 4), last.tick);
}
