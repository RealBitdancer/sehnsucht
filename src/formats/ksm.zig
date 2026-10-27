//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const fm = @import("../fm.zig");
const binary = @import("../binary.zig");
const cp437 = @import("../cp437.zig");

pub const format_name = "KSM";
pub const extensions = &.{".ksm"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const tick_rate = 240;
const header_len = 82;
const bank_record_len = 33;
const bank_len = 256 * bank_record_len;
const max_notes_per_step: u32 = 4096;

const adlib_freq = [63]u16{
    0,
    2390,
    2411,
    2434,
    2456,
    2480,
    2506,
    2533,
    2562,
    2592,
    2625,
    2659,
    2695,
    3414,
    3435,
    3458,
    3480,
    3504,
    3530,
    3557,
    3586,
    3616,
    3649,
    3683,
    3719,
    4438,
    4459,
    4482,
    4504,
    4528,
    4554,
    4581,
    4610,
    4640,
    4673,
    4707,
    4743,
    5462,
    5483,
    5506,
    5528,
    5552,
    5578,
    5605,
    5634,
    5664,
    5697,
    5731,
    5767,
    6486,
    6507,
    6530,
    6552,
    6576,
    6602,
    6629,
    6658,
    6688,
    6721,
    6755,
    6791,
    7510,
    0,
};

const Drum = struct { mask: u8, channel: u8, octave_down: bool, carrier: bool };

const drums = [5]Drum{
    .{ .mask = 0x10, .channel = 6, .octave_down = true, .carrier = true },
    .{ .mask = 0x08, .channel = 7, .octave_down = true, .carrier = true },
    .{ .mask = 0x04, .channel = 8, .octave_down = false, .carrier = false },
    .{ .mask = 0x02, .channel = 8, .octave_down = false, .carrier = true },
    .{ .mask = 0x01, .channel = 7, .octave_down = true, .carrier = false },
};

const Text = struct {
    bytes: [20 * cp437.max_utf8_per_byte]u8 = undefined,
    len: u8 = 0,

    fn parse(raw: []const u8) Text {
        var t: Text = .{};
        t.len = @intCast(cp437.decode(&t.bytes, binary.text(raw)).len);
        return t;
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Instrument = struct {
    regs: [11]u8,
    name: Text,
};

const Note = struct {
    word: u32,

    fn time(self: Note) u32 {
        return self.word >> 12;
    }

    fn track(self: Note) u4 {
        return @truncate(self.word >> 8);
    }

    fn kind(self: Note) u2 {
        return @truncate(self.word >> 6);
    }

    fn index(self: Note) u6 {
        return @truncate(self.word);
    }

    fn frequency(self: Note) u16 {
        return adlib_freq[@min(self.index(), adlib_freq.len - 1)];
    }

    fn midi(self: Note) u8 {
        return if (self.index() == 0) 0 else @as(u8, self.index()) + 35;
    }
};

fn noteCount(data: []const u8) ?usize {
    if (data.len < header_len) return null;
    const count = fmt.readU16Le(data, 80);
    if (count == 0 or data.len - header_len < @as(usize, count) * 4) return null;
    return count;
}

pub fn resourceRequests(gpa: std.mem.Allocator, path: []const u8, data: []const u8) ![]fmt.ResourceRequest {
    if (noteCount(data) == null) return gpa.alloc(fmt.ResourceRequest, 0);
    const requests = try gpa.alloc(fmt.ResourceRequest, 1);
    errdefer gpa.free(requests);
    requests[0] = try .init(gpa, path, "ksm.insts", &.{ "insts.dat", "INSTS.DAT" });
    return requests;
}

const Source = struct {
    notes: []const u32,
    tracks: [16]Instrument,
    trinst: [16]u8,
    trquant: [16]u8,
    trchan: [16]u8,
    trvol: [16]u8,
    used: [16]bool,
    sample_rate: u32,
    duration: u64 = 0,
    start: i64,
    numchans: u8,
    drumstat: u8 = 0,
    chanfreq: [9]u8 = @splat(0),
    chantrack: [9]u8 = @splat(0),
    chanage: [9]i64 = @splat(0),
    channote: [9]u8 = @splat(0),
    track_note: [16]u8 = @splat(0),
    track_keyed: [16]bool = @splat(false),
    count: i64 = 0,
    countstop: i64 = 0,
    cursor: usize = 0,
    frac: u32 = 0,
    last_track: u16 = 0,

    fn quantize(self: *const Source, word: u32) i64 {
        const note: Note = .{ .word = word };
        const quant = self.trquant[note.track()];
        const quanter: i64 = if (quant == 0) 1 else @max(1, @divTrunc(tick_rate, @as(i64, quant)));
        const t: i64 = note.time();
        return @divTrunc(t + @divTrunc(quanter, 2), quanter) * quanter;
    }

    fn setInstrument(chip: fmt.Chip, channel: u8, regs: [11]u8) void {
        const op = fm.operator_offsets[channel];
        chip.writeReg(0xa0 + @as(u16, channel), 0);
        chip.writeReg(0xb0 + @as(u16, channel), 0);
        chip.writeReg(0xc0 + @as(u16, channel), regs[10]);
        for ([_]u16{ 0x20, 0x40, 0x60, 0x80, 0xe0 }, 0..) |base, i| {
            chip.writeReg(base + op, regs[5 + i]);
            chip.writeReg(base + op + 3, regs[i]);
        }
    }

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.drumstat = if (self.trchan[11] != 0) 0x20 else 0;
        self.numchans = if (self.trchan[11] != 0) 6 else 9;
        chip.writeReg(1, 0x20);
        chip.writeReg(4, 0);
        chip.writeReg(8, 0);
        chip.writeReg(0xbd, self.drumstat);
        if (self.trchan[11] == 1) {
            var regs = self.tracks[11].regs;
            regs[1] = (regs[1] & 0xc0) | (self.trvol[11] ^ 63);
            setInstrument(chip, 6, regs);
            regs = self.tracks[12].regs;
            @memcpy(regs[5..], self.tracks[15].regs[5..]);
            regs[1] = (regs[1] & 0xc0) | (self.trvol[12] ^ 63);
            regs[6] = (regs[6] & 0xc0) | (self.trvol[15] ^ 63);
            setInstrument(chip, 7, regs);
            regs = self.tracks[14].regs;
            @memcpy(regs[5..], self.tracks[13].regs[5..]);
            regs[1] = (regs[1] & 0xc0) | (self.trvol[14] ^ 63);
            regs[6] = (regs[6] & 0xc0) | (self.trvol[13] ^ 63);
            setInstrument(chip, 8, regs);
        }
        self.chantrack = @splat(0);
        self.chanage = @splat(0);
        self.chanfreq = @splat(0);
        self.channote = @splat(0);
        var j: u8 = 0;
        for (self.trchan, 0..) |count, t| {
            var k = count;
            while (j < self.numchans and k > 0) : (k -= 1) {
                self.chantrack[j] = @intCast(t);
                j += 1;
            }
        }
        for (0..self.numchans) |i| {
            const t = self.chantrack[i];
            var regs = self.tracks[t].regs;
            regs[1] = (regs[1] & 0xc0) | @as(u8, @truncate(63 -% self.trvol[t]));
            setInstrument(chip, @intCast(i), regs);
        }
        self.track_note = @splat(0);
        self.track_keyed = @splat(false);
        self.cursor = 0;
        self.count = self.start;
        self.countstop = self.start - 1;
        self.frac = 0;
        self.last_track = 0;
    }

    fn level(self: *const Source, trk: u4, reg: usize, volevel: u8) u8 {
        return (self.tracks[trk].regs[reg] & 0xc0) +% (volevel ^ 63);
    }

    fn play(self: *Source, chip: fmt.Chip, note: Note) void {
        const trk = note.track();
        const freq = note.frequency();
        if (note.kind() == 0) {
            if (self.track_note[trk] == note.midi()) self.track_keyed[trk] = false;
            for (0..self.numchans) |i| {
                if (self.chanfreq[i] != note.index() or self.chantrack[i] != trk) continue;
                chip.writeReg(0xb0 + @as(u16, @intCast(i)), @as(u8, @truncate(freq >> 8)) & 0xdf);
                self.chanfreq[i] = 0;
                self.chanage[i] = 0;
                return;
            }
            return;
        }
        var volevel = self.trvol[trk];
        if (note.kind() == 2) volevel -|= 4;
        if (note.kind() == 3) volevel = @min(63, volevel +| 4);
        if (trk < 11) {
            var oldest: u64 = 0;
            var chosen: ?usize = null;
            for (0..self.numchans) |i| {
                const age: u64 = @bitCast(self.countstop -% self.chanage[i]);
                if (age >= oldest and self.chantrack[i] == trk) {
                    oldest = age;
                    chosen = i;
                }
            }
            const i = chosen orelse return;
            const ch: u16 = @intCast(i);
            chip.writeReg(0xb0 + ch, 0);
            chip.writeReg(0x40 + fm.operator_offsets[i] + 3, self.level(trk, 1, volevel));
            chip.writeReg(0xa0 + ch, @truncate(freq));
            chip.writeReg(0xb0 + ch, @as(u8, @truncate(freq >> 8)) | 0x20);
            self.chanfreq[i] = note.index();
            self.chanage[i] = self.countstop;
            self.channote[i] = note.midi();
        } else if (self.drumstat & 0x20 != 0) {
            const drum = drums[trk - 11];
            const pitch: i32 = @as(i32, freq) - if (drum.octave_down) @as(i32, 2048) else 0;
            const bits: u32 = @bitCast(pitch);
            const ch: u16 = drum.channel;
            chip.writeReg(0xa0 + ch, @truncate(bits));
            chip.writeReg(0xb0 + ch, @as(u8, @truncate(@as(u32, @bitCast(pitch >> 8)))) & 0xdf);
            chip.writeReg(0xbd, self.drumstat & ~drum.mask);
            self.drumstat |= drum.mask;
            if (drum.carrier) {
                chip.writeReg(0x40 + fm.operator_offsets[ch] + 3, self.level(trk, 1, volevel));
            } else {
                chip.writeReg(0x40 + fm.operator_offsets[ch], self.level(trk, 6, volevel));
            }
            chip.writeReg(0xbd, self.drumstat);
        } else return;
        self.track_note[trk] = note.midi();
        self.track_keyed[trk] = true;
        self.last_track = trk;
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        var handled: u32 = 0;
        while (self.count >= self.countstop) {
            if (handled == max_notes_per_step) return .{ .frames = 0 };
            handled += 1;
            self.play(chip, .{ .word = self.notes[self.cursor] });
            self.cursor += 1;
            if (self.cursor == self.notes.len) {
                self.cursor = 0;
                self.count = self.start - 1;
                self.countstop = self.quantize(self.notes[0]);
                const ticks: u64 = @intCast(@max(0, self.countstop - self.count));
                self.count += @intCast(ticks);
                return .{ .frames = fmt.rescale(ticks, tick_rate, self.sample_rate, &self.frac), .done = true };
            }
            self.countstop = self.quantize(self.notes[self.cursor]);
        }
        const ticks: u64 = @intCast(self.countstop - self.count);
        self.count = self.countstop;
        return .{ .frames = fmt.rescale(ticks, tick_rate, self.sample_rate, &self.frac) };
    }

    fn passTicks(self: *const Source) u64 {
        var count = self.start;
        var countstop = self.start - 1;
        var total: u64 = 0;
        var cursor: usize = 0;
        while (true) {
            while (count >= countstop) {
                cursor += 1;
                if (cursor == self.notes.len) {
                    return total + @as(u64, @intCast(@max(0, self.quantize(self.notes[0]) - (self.start - 1))));
                }
                countstop = self.quantize(self.notes[cursor]);
            }
            total += @intCast(countstop - count);
            count = countstop;
        }
    }

    pub fn durationFrames(self: *Source) u64 {
        return self.duration;
    }

    pub fn info(_: *Source) fmt.TrackInfo {
        return .{ .format_name = format_name, .system = "OPL2", .loop = true };
    }

    fn eventTick(self: *const Source, index: usize) u32 {
        return (Note{ .word = self.notes[index] }).time() -| @as(u32, @intCast(self.start));
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = if (self.cursor == 0) 0 else self.eventTick(self.cursor - 1), .tempo = tick_rate, .last_instrument = self.last_track, .flags = .{ .has_tick = true, .has_tempo = true } };
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = 16 };
        for (0..16) |t| {
            bank.slots[t] = .{ .program = @intCast(t), .note = self.track_note[t], .keyed = self.track_keyed[t] };
        }
        for (0..self.numchans) |i| {
            if (self.channote[i] == 0) continue;
            const t = self.chantrack[i];
            const keyed = self.chanfreq[i] != 0;
            bank.voices[bank.voice_count] = .{ .channel = t, .program = t, .note = self.channote[i], .opl_voice = @intCast(i), .keyed = keyed };
            bank.voice_count += 1;
            if (keyed) bank.slots[t].opl_voice = @intCast(i);
        }
        if (self.drumstat & 0x20 != 0) for (drums, 11..) |drum, t| {
            if (self.drumstat & drum.mask == 0) continue;
            bank.voices[bank.voice_count] = .{ .channel = @intCast(t), .program = @intCast(t), .note = self.track_note[t], .opl_voice = drum.channel, .kind = .drum, .keyed = self.track_keyed[t] };
            bank.voice_count += 1;
            bank.slots[t].opl_voice = drum.channel;
        };
        return bank;
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        return .{ .ctx = self, .kind = .linear_midi, .track_count = 16, .channel_count = 16, .tick_rate = tick_rate, .length_ticks = self.eventTick(self.notes.len - 1), .track = track, .eventsInRange = eventsInRange, .eventAt = eventAt, .event_count = @intCast(self.notes.len) };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = 16, .get = instrument };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.notes);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}

fn track(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self = source(ptr);
    if (index >= 16) return .{};
    const drum = index >= 11 and self.trchan[11] != 0;
    return .{ .name = self.tracks[index].name.slice(), .channel = @intCast(index), .program = index, .kind = if (drum) .drum else .melodic, .in_use = self.used[index] };
}

fn instrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index >= 16) return .{};
    const r = self.tracks[index].regs;
    return .{ .name = self.tracks[index].name.slice(), .patch = .{ .opl_2op = .{
        .ops = .{ fmt.operatorParams(r[5], r[6], r[7], r[8], r[9]), fmt.operatorParams(r[0], r[1], r[2], r[3], r[4]), .{}, .{} },
        .feedback = @truncate(r[10] >> 1),
        .additive = r[10] & 1 != 0,
    } } };
}

fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    if (index >= self.notes.len) return .{};
    const note: Note = .{ .word = self.notes[index] };
    const velocity: u8 = switch (note.kind()) {
        0 => 0,
        1 => 100,
        2 => 80,
        3 => 120,
    };
    return .{ .tick = self.eventTick(index), .instr_index = index, .track = note.track(), .channel = note.track(), .kind = if (note.kind() == 0) .note_off else .note_on, .payload = .{ .note = .{ .note = note.midi(), .velocity = velocity } } };
}

fn eventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self = source(ptr);
    var lo: usize = 0;
    var hi = self.notes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.eventTick(mid) < tick0) lo = mid + 1 else hi = mid;
    }
    var range = view.EventRange{};
    while (lo < self.notes.len and self.eventTick(lo) < tick1) : (lo += 1) {
        if (range.written < dest.len) {
            dest[range.written] = eventAt(ptr, @intCast(lo));
            range.written += 1;
        }
        range.total_in_range += 1;
    }
    return range;
}

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) !?fmt.MusicSource {
    const count = noteCount(data) orelse return error.InvalidKsm;
    const bank = ctx.resource("ksm.insts") orelse return error.MissingResource;
    if (bank.len < bank_len) return error.InvalidKsmBank;
    const notes = try gpa.alloc(u32, count);
    errdefer gpa.free(notes);
    var used: [16]bool = @splat(false);
    for (notes, 0..) |*word, i| {
        word.* = fmt.readU32Le(data, header_len + i * 4);
        used[(Note{ .word = word.* }).track()] = true;
    }
    const self = try gpa.create(Source);
    errdefer gpa.destroy(self);
    self.* = .{
        .notes = notes,
        .tracks = undefined,
        .trinst = data[0..16].*,
        .trquant = data[16..32].*,
        .trchan = data[32..48].*,
        .trvol = data[64..80].*,
        .used = used,
        .sample_rate = ctx.sample_rate,
        .start = (Note{ .word = notes[0] }).time(),
        .numchans = 9,
    };
    for (&self.tracks, self.trinst) |*t, index| {
        const record = bank[@as(usize, index) * bank_record_len ..][0..bank_record_len];
        t.* = .{ .regs = record[20..31].*, .name = .parse(record[0..20]) };
    }
    self.duration = self.passTicks() * ctx.sample_rate / tick_rate;
    self.reset(ctx.chip);
    return fmt.MusicSource.init(self, visualizer_name);
}

// --- tests -------------------------------------------------------------------

const RegRec = struct {
    regs: [256]u8 = @splat(0),
    writes: [64]struct { reg: u16, value: u8 } = undefined,
    count: usize = 0,

    fn write(ptr: *anyopaque, reg: u16, value: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (reg < self.regs.len) self.regs[reg] = value;
        if (self.count < self.writes.len) self.writes[self.count] = .{ .reg = reg, .value = value };
        self.count += 1;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

fn testBank() [bank_len]u8 {
    var bank: [bank_len]u8 = @splat(0);
    for (0..256) |i| {
        const record = bank[i * bank_record_len ..][0..bank_record_len];
        record[20 + 1] = 0x80 | 0x10;
        record[20 + 6] = 0x40 | 0x08;
        record[20 + 10] = @intCast(i & 0x0f);
    }
    @memcpy(bank[1 * bank_record_len ..][0..5], "PIANO");
    return bank;
}

fn noteWord(time: u32, trk: u4, kind: u2, index: u6) u32 {
    return time << 12 | @as(u32, trk) << 8 | @as(u32, kind) << 6 | index;
}

fn testSong(buf: []u8, notes: []const u32, drum: bool) []const u8 {
    @memset(buf[0..header_len], 0);
    buf[0] = 1;
    buf[11] = 2;
    buf[15] = 3;
    @memset(buf[16..32], 240);
    buf[32] = 1;
    if (drum) buf[32 + 11] = 1;
    @memset(buf[64..80], 63);
    std.mem.writeInt(u16, buf[80..82], @intCast(notes.len), .little);
    for (notes, 0..) |word, i| std.mem.writeInt(u32, buf[header_len + i * 4 ..][0..4], word, .little);
    return buf[0 .. header_len + notes.len * 4];
}

test "KSM needs its instrument bank and plays notes at 240 Hz" {
    const gpa = std.testing.allocator;
    const bank = testBank();
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, &.{ noteWord(100, 0, 1, 13), noteWord(124, 0, 0, 13), noteWord(148, 0, 1, 25) }, false);
    try std.testing.expectError(error.MissingResource, load(gpa, data, .{ .sample_rate = 48000, .chip = fmt.noop_chip }));
    try std.testing.expectError(error.InvalidKsmBank, load(gpa, data, .{ .sample_rate = 48000, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = bank[0..100] }} }));
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 48000, .chip = rec.chip(), .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 4800), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u8, 0x2d), rec.regs[0xb8]);
    try std.testing.expectEqual(@as(u8, 0x56), rec.regs[0xa8]);
    try std.testing.expectEqual(@as(u8, 0x80), rec.regs[0x55]);
    try std.testing.expect(src.sequenceState().?.slots[0].keyed);
    try std.testing.expectEqual(@as(u64, 4800), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u8, 0x0d), rec.regs[0xb8]);
    try std.testing.expect(!src.sequenceState().?.slots[0].keyed);
    const last = src.step(rec.chip());
    try std.testing.expect(last.done);
    try std.testing.expectEqual(@as(u64, 200), last.frames);
    try std.testing.expectEqual(@as(u8, 0x31), rec.regs[0xb8]);
    try std.testing.expectEqual(@as(?u64, 9800), src.durationFrames());
    const instruments = src.views().instruments.?;
    try std.testing.expectEqualStrings("PIANO", instruments.get(instruments.ctx, 0).name);
}

test "KSM duration matches stepping through one pass" {
    const gpa = std.testing.allocator;
    const bank = testBank();
    var data_buf: [256]u8 = undefined;
    const notes = [_]u32{ noteWord(7, 0, 1, 13), noteWord(19, 0, 0, 13), noteWord(43, 0, 1, 14), noteWord(44, 0, 0, 14), noteWord(90, 0, 1, 15) };
    const data = testSong(&data_buf, &notes, false);
    data_buf[16] = 6;
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    const probe = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer probe.deinit(gpa);
    try std.testing.expectEqual(fmt.measureByStepping(probe, fmt.noop_chip, 44100), src.durationFrames());
}

test "KSM quantizes note times to the track grid" {
    const bank = testBank();
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, &.{ noteWord(100, 0, 1, 13), noteWord(119, 0, 0, 13), noteWord(150, 0, 1, 14) }, false);
    buf[16] = 6;
    const gpa = std.testing.allocator;
    const src = (try load(gpa, data, .{ .sample_rate = 240, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 20), src.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u64, 40), src.step(fmt.noop_chip).frames);
}

test "KSM drum tracks trigger rhythm bits on their fixed channels" {
    const gpa = std.testing.allocator;
    const bank = testBank();
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, &.{ noteWord(10, 11, 1, 13), noteWord(10, 15, 1, 13), noteWord(20, 13, 1, 25) }, true);
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 240, .chip = rec.chip(), .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0x20), rec.regs[0xbd]);
    try std.testing.expectEqual(@as(u8, 0x02), rec.regs[0xc6]);
    try std.testing.expectEqual(@as(u8, 0x03), rec.regs[0xc7]);
    try std.testing.expectEqual(@as(u8, 0x00), rec.regs[0xc8]);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x31), rec.regs[0xbd]);
    try std.testing.expectEqual(@as(u8, 0x56), rec.regs[0xa6]);
    try std.testing.expectEqual(@as(u8, 0x05), rec.regs[0xb6]);
    try std.testing.expectEqual(@as(u8, 0x40), rec.regs[0x51]);
    const state = src.sequenceState().?;
    try std.testing.expectEqual(@as(u16, 2), state.voice_count);
    try std.testing.expectEqual(@as(u8, 6), state.voices[0].opl_voice);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x35), rec.regs[0xbd]);
    try std.testing.expectEqual(@as(u8, 0x11), rec.regs[0xb8] & 0x1f);
}

test "KSM melodic notes take the last of the channels a track left idle longest" {
    const gpa = std.testing.allocator;
    const bank = testBank();
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, &.{ noteWord(10, 0, 1, 13), noteWord(10, 0, 1, 15), noteWord(20, 0, 0, 13), noteWord(30, 0, 1, 17) }, false);
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 240, .chip = rec.chip(), .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x2d), rec.regs[0xb8]);
    try std.testing.expectEqual(@as(u8, 0x2d), rec.regs[0xb7]);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x0d), rec.regs[0xb8]);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x2d), rec.regs[0xb8]);
    try std.testing.expectEqual(@as(u8, 0xb0), rec.regs[0xa8]);
    try std.testing.expectEqual(@as(u8, 0x2d), rec.regs[0xb7]);
}

test "KSM same-time runs yield before the step budget" {
    const gpa = std.testing.allocator;
    const bank = testBank();
    const notes = try gpa.alloc(u32, max_notes_per_step + 2);
    defer gpa.free(notes);
    @memset(notes, noteWord(5, 1, 0, 1));
    notes[notes.len - 1] = noteWord(9, 1, 0, 1);
    const buf = try gpa.alloc(u8, header_len + notes.len * 4);
    defer gpa.free(buf);
    const data = testSong(buf, notes, false);
    const src = (try load(gpa, data, .{ .sample_rate = 240, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = &bank }} })).?;
    defer src.deinit(gpa);
    const first = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(@as(u64, 4), src.step(fmt.noop_chip).frames);
}

test "KSM rejects truncated note lists" {
    const bank = testBank();
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, &.{ noteWord(1, 0, 1, 13), noteWord(2, 0, 0, 13) }, false);
    try std.testing.expectError(error.InvalidKsm, load(std.testing.allocator, data[0 .. data.len - 1], .{ .sample_rate = 240, .chip = fmt.noop_chip, .resources = &.{.{ .name = "ksm.insts", .data = &bank }} }));
}
