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

pub const format_name = "ROL";
pub const extensions = &.{".rol"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const max_events_per_step: u32 = 4096;

const Text = struct {
    bytes: [15 * cp437.max_utf8_per_byte]u8 = undefined,
    len: u8 = 0,

    fn parse(raw: []const u8) Text {
        var text: Text = .{};
        text.len = @intCast(cp437.decode(&text.bytes, binary.text(raw)).len);
        return text;
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Instrument = struct {
    name: [9]u8,
    label: Text,
    patch: view.OplPatch,
};

const Event = struct {
    tick: u32,
    channel: u8 = 0,
    kind: enum { off, instrument, volume, pitch, tempo, note },
    value: f32,
};

const Channel = struct {
    instrument: u16 = 0,
    note: u8 = 0,
    keyed: bool = false,
    volume: u8 = 127,
    bend: f32 = 1,
};

fn recognizes(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0, 0, 4, 0 });
}

pub fn resourceRequests(gpa: std.mem.Allocator, path: []const u8, data: []const u8) ![]fmt.ResourceRequest {
    if (!recognizes(data)) return gpa.alloc(fmt.ResourceRequest, 0);
    const requests = try gpa.alloc(fmt.ResourceRequest, 1);
    errdefer gpa.free(requests);
    requests[0] = try .init(gpa, path, "rol.bank", &.{ "standard.bnk", "STANDARD.BNK" });
    return requests;
}

fn readBank(gpa: std.mem.Allocator, data: []const u8) ![]Instrument {
    if (data.len < 28 or !std.mem.eql(u8, data[2..8], "ADLIB-")) return error.InvalidRolBank;
    const count = fmt.readU16Le(data, 10);
    const names = fmt.readU32Le(data, 12);
    const patches = fmt.readU32Le(data, 16);
    if (names > data.len or @as(usize, count) * 12 > data.len - names or patches > data.len) return error.InvalidRolBank;
    const instruments = try gpa.alloc(Instrument, count);
    errdefer gpa.free(instruments);
    for (instruments, 0..) |*ins, i| {
        const entry = data[names + i * 12 ..][0..12];
        const offset = @as(usize, patches) + @as(usize, fmt.readU16Le(entry, 0)) * 30;
        if (offset > data.len or data.len - offset < 30) return error.InvalidRolBank;
        const p = data[offset..][0..30];
        ins.* = .{ .name = entry[3..12].*, .label = .parse(entry[3..12]), .patch = .{
            .ops = .{ fm.bankOperator(p[2..15], p[28]), fm.bankOperator(p[15..28], p[29]), .{}, .{} },
            .feedback = @truncate(p[4]),
            .additive = p[14] == 0,
            .perc_voice = if (p[0] != 0) p[1] else 0,
        } };
    }
    return instruments;
}

fn findInstrument(instruments: []const Instrument, name: []const u8) !u16 {
    for (instruments, 0..) |*ins, i| {
        if (std.ascii.eqlIgnoreCase(binary.text(&ins.name), name)) return @intCast(i);
    }
    return error.MissingRolInstrument;
}

fn bendValue(value: f32) u16 {
    return @intFromFloat(@min(16383, value * 8192));
}

fn tuneTom(chip: fmt.Chip, note: f64) void {
    fm.pitch(chip, 8, note, false);
    fm.pitch(chip, 7, note + 7, false);
}

fn eventLess(_: void, a: Event, b: Event) bool {
    if (a.tick != b.tick) return a.tick < b.tick;
    return @backingInt(a.kind) < @backingInt(b.kind);
}

const Source = struct {
    instruments: []Instrument,
    events: []Event,
    names: [11]Text,
    channels: [11]Channel = @splat(.{}),
    sample_rate: u32,
    ticks_per_beat: u16,
    base_tempo: f32,
    tempo: f32 = 1,
    tick: u32 = 0,
    length: u32,
    cursor: usize = 0,
    fraction: f64 = 0,
    rhythm: bool,
    rhythm_bits: u8 = 0,
    last_instrument: u16 = 0,
    ended: bool = false,

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.channels = @splat(.{});
        self.tempo = 1;
        self.tick = 0;
        self.cursor = 0;
        self.rhythm_bits = if (self.rhythm) 0x20 else 0;
        chip.writeReg(1, 0x20);
        chip.writeReg(0xbd, self.rhythm_bits);
        for (0..9) |ch| fm.off(chip, @intCast(ch));
        if (self.rhythm) tuneTom(chip, 36);
        self.ended = false;
    }

    fn program(self: *Source, chip: fmt.Chip, channel: u8) void {
        const ch = self.channels[channel];
        const p = self.instruments[ch.instrument].patch;
        if (!self.rhythm or channel <= 6) {
            fm.patch(chip, channel, p, ch.volume);
        } else {
            const offsets = [_]u16{ 20, 18, 21, 17 };
            fm.operator(chip, offsets[channel - 7], p.ops[0], ch.volume);
        }
    }

    fn changePitch(self: *Source, chip: fmt.Chip, channel: u8) void {
        if (self.rhythm and channel > 6) return;
        const ch = self.channels[channel];
        const note = @as(f64, @floatFromInt(ch.note)) + @as(f64, ch.bend) - 1;
        fm.pitch(chip, channel, note, ch.keyed and (!self.rhythm or channel < 6));
    }

    fn key(self: *Source, chip: fmt.Chip, channel: u8, on: bool) void {
        self.channels[channel].keyed = on;
        if (self.rhythm and channel >= 6) {
            const bit: u8 = @as(u8, 0x10) >> @as(u3, @intCast(channel - 6));
            self.rhythm_bits &= ~bit;
            chip.writeReg(0xbd, self.rhythm_bits);
            if (on) self.rhythm_bits |= bit;
            if (on and channel == 8) tuneTom(chip, @floatFromInt(self.channels[8].note));
            self.changePitch(chip, channel);
            chip.writeReg(0xbd, self.rhythm_bits);
        } else self.changePitch(chip, channel);
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        if (self.ended) self.reset(chip);
        var handled: u32 = 0;
        while (self.cursor < self.events.len and self.events[self.cursor].tick <= self.tick) {
            if (handled == max_events_per_step) return .{ .frames = 0 };
            handled += 1;
            const event = self.events[self.cursor];
            self.cursor += 1;
            const ch = &self.channels[event.channel];
            switch (event.kind) {
                .tempo => self.tempo = event.value,
                .instrument => {
                    ch.instrument = @intFromFloat(event.value);
                    self.last_instrument = ch.instrument;
                    self.program(chip, event.channel);
                },
                .volume => {
                    ch.volume = @intFromFloat(@round(event.value * 127));
                    self.program(chip, event.channel);
                },
                .pitch => {
                    ch.bend = event.value;
                    self.changePitch(chip, event.channel);
                },
                .note => {
                    self.key(chip, event.channel, false);
                    ch.note = @intFromFloat(event.value);
                    self.key(chip, event.channel, true);
                },
                .off => self.key(chip, event.channel, false),
            }
        }
        if (self.tick >= self.length) {
            self.ended = true;
            return .{ .frames = 0, .done = true };
        }
        const next = if (self.cursor < self.events.len) @min(self.length, self.events[self.cursor].tick) else self.length;
        const frames = @as(f64, @floatFromInt(next - self.tick)) * @as(f64, @floatFromInt(self.sample_rate)) * 60 / (@as(f64, self.base_tempo) * self.tempo * @as(f64, @floatFromInt(self.ticks_per_beat))) + self.fraction;
        const count: u64 = @intFromFloat(frames);
        self.fraction = frames - @as(f64, @floatFromInt(count));
        self.tick = next;
        return .{ .frames = count };
    }

    pub fn info(_: *Source) fmt.TrackInfo {
        return .{ .format_name = format_name, .system = "OPL2" };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = if (self.cursor != 0) self.events[self.cursor - 1].tick else 0, .tempo = @intFromFloat(@min(65535, self.base_tempo * self.tempo)), .last_instrument = self.last_instrument, .flags = .{ .has_tick = true, .has_tempo = true } };
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = if (self.rhythm) 11 else 9 };
        for (self.channels[0..bank.channels], 0..) |ch, i| {
            bank.slots[i] = .{ .program = ch.instrument, .note = ch.note, .keyed = ch.keyed, .opl_voice = @intCast(if (i < 9) i else @as(usize, if (i == 9) 8 else 7)), .bend = bendValue(ch.bend) };
        }
        return bank;
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        return .{ .ctx = self, .kind = .linear_midi, .track_count = if (self.rhythm) 11 else 9, .channel_count = if (self.rhythm) 11 else 9, .tick_rate = @intFromFloat(self.base_tempo * @as(f32, @floatFromInt(self.ticks_per_beat)) / 60), .length_ticks = self.length, .track = track, .eventsInRange = eventsInRange, .eventAt = eventAt, .event_count = @intCast(self.events.len) };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = @intCast(self.instruments.len), .get = instrument };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.instruments);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}

fn track(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self = source(ptr);
    if (index >= self.names.len) return .{};
    return .{ .name = self.names[index].slice(), .channel = @intCast(index), .kind = if (self.rhythm and index >= 6) .drum else .melodic };
}

fn instrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index >= self.instruments.len) return .{};
    const ins = &self.instruments[index];
    return .{ .name = ins.label.slice(), .patch = .{ .opl_2op = ins.patch } };
}

fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    if (index >= self.events.len) return .{};
    const ev = self.events[index];
    var out = view.SequenceEvent{ .tick = ev.tick, .instr_index = index, .channel = ev.channel, .track = ev.channel };
    switch (ev.kind) {
        .note, .off => {
            out.kind = if (ev.kind == .note) .note_on else .note_off;
            out.payload = .{ .note = .{ .note = @intFromFloat(ev.value), .velocity = if (ev.kind == .note) 127 else 0 } };
        },
        .instrument => {
            out.kind = .program;
            out.payload = .{ .program = @intFromFloat(ev.value) };
        },
        .volume => {
            out.kind = .control;
            out.payload = .{ .control = .{ .cc = 7, .value = @intFromFloat(@round(ev.value * 127)) } };
        },
        .pitch => {
            out.kind = .pitch_bend;
            out.payload = .{ .pitch_bend = bendValue(ev.value) };
        },
        .tempo => {
            out.track = view.sequence_unassigned;
            out.kind = .tempo;
            out.payload = .{ .tempo = @intFromFloat(self.base_tempo * ev.value) };
        },
    }
    return out;
}

fn eventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self = source(ptr);
    var range = view.EventRange{};
    var lo: usize = 0;
    var hi = self.events.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.events[mid].tick < tick0) lo = mid + 1 else hi = mid;
    }
    while (lo < self.events.len and self.events[lo].tick < tick1) : (lo += 1) {
        if (range.written < dest.len) {
            dest[range.written] = eventAt(ptr, @intCast(lo));
            range.written += 1;
        }
        range.total_in_range += 1;
    }
    return range;
}

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) !?fmt.MusicSource {
    if (!recognizes(data)) return null;
    if (data.len < 199) return error.InvalidMusicData;
    const ticks_per_beat = fmt.readU16Le(data, 44);
    if (ticks_per_beat == 0 or data[53] > 1) return error.InvalidMusicData;
    const instruments = try readBank(gpa, ctx.resource("rol.bank") orelse return error.MissingResource);
    errdefer gpa.free(instruments);
    if (instruments.len == 0) return error.InvalidRolBank;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    var reader = binary.Reader{ .data = data, .pos = 197 };
    const tempo = try reader.float();
    if (tempo < 1 or tempo > 1000) return error.InvalidMusicData;
    const tempo_count = try reader.int(u16);
    for (0..tempo_count) |_| {
        const tick = try reader.int(u16);
        const value = try reader.float();
        if (value < 0.01 or value > 10) return error.InvalidMusicData;
        try events.append(gpa, .{ .tick = tick, .kind = .tempo, .value = value });
    }
    var length: u32 = 0;
    var names: [11]Text = undefined;
    for (0..11) |i| {
        const ch: u8 = @intCast(i);
        const used = data[53] == 0 or ch < 9;
        names[i] = .parse(try reader.take(15));
        const ticks = try reader.int(u16);
        if (used) length = @max(length, ticks);
        var tick: u32 = 0;
        while (tick < ticks) {
            const note = try reader.int(u16);
            const duration = try reader.int(u16);
            if (duration == 0 or note > 127) return error.InvalidMusicData;
            if (used) {
                try events.append(gpa, .{ .tick = tick, .channel = ch, .kind = if (note == 0) .off else .note, .value = @floatFromInt(note) });
                try events.append(gpa, .{ .tick = tick + duration, .channel = ch, .kind = .off, .value = @floatFromInt(note) });
            }
            tick += duration;
        }
        _ = try reader.take(15);
        const count = try reader.int(u16);
        for (0..count) |_| {
            const at = try reader.int(u16);
            const name = binary.text(try reader.take(9));
            _ = try reader.take(3);
            if (used) try events.append(gpa, .{ .tick = at, .channel = ch, .kind = .instrument, .value = @floatFromInt(try findInstrument(instruments, name)) });
        }
        for (0..2) |kind| {
            _ = try reader.take(15);
            const n = try reader.int(u16);
            for (0..n) |_| {
                const at = try reader.int(u16);
                const value = try reader.float();
                if (kind != 0 and (value < 0 or value > 2)) return error.InvalidMusicData;
                if (used) try events.append(gpa, .{ .tick = at, .channel = ch, .kind = if (kind == 0) .volume else .pitch, .value = if (kind == 0) std.math.clamp(value, 0, 1) else value });
            }
        }
    }
    if (length == 0) return error.InvalidMusicData;
    std.mem.sort(Event, events.items, {}, eventLess);
    const owned = try events.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    const self = try gpa.create(Source);
    self.* = .{ .instruments = instruments, .events = owned, .names = names, .sample_rate = ctx.sample_rate, .ticks_per_beat = ticks_per_beat, .base_tempo = tempo, .length = length, .rhythm = data[53] == 0 };
    self.reset(ctx.chip);
    return fmt.MusicSource.init(self, visualizer_name);
}

// --- tests -------------------------------------------------------------------

fn testBank(comptime names: []const []const u8) [28 + names.len * 42]u8 {
    var bank: [28 + names.len * 42]u8 = @splat(0);
    const patches = 28 + names.len * 12;
    @memcpy(bank[2..8], "ADLIB-");
    std.mem.writeInt(u16, bank[10..12], names.len, .little);
    std.mem.writeInt(u32, bank[12..16], 28, .little);
    std.mem.writeInt(u32, bank[16..20], patches, .little);
    for (names, 0..) |name, i| {
        std.mem.writeInt(u16, bank[28 + i * 12 ..][0..2], @intCast(i), .little);
        @memcpy(bank[31 + i * 12 ..][0..name.len], name);
        const p = patches + i * 30;
        bank[p + 3] = 1;
        bank[p + 5] = 15;
        bank[p + 16] = 1;
        bank[p + 18] = 15;
    }
    return bank;
}

fn testSong(bytes: []u8, instrument_name: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(bytes);
    var header: [203]u8 = @splat(0);
    header[2] = 4;
    header[44] = 1;
    header[53] = 1;
    std.mem.writeInt(u32, header[197..201], @bitCast(@as(f32, 120)), .little);
    try w.writeAll(&header);
    for (0..11) |ch| {
        try w.splatByteAll(0, 15);
        try w.writeInt(u16, if (ch == 0) 1 else 0, .little);
        if (ch == 0) {
            try w.writeInt(u16, 60, .little);
            try w.writeInt(u16, 1, .little);
        }
        try w.splatByteAll(0, 15);
        try w.writeInt(u16, if (ch == 0) 1 else 0, .little);
        if (ch == 0) {
            try w.writeInt(u16, 0, .little);
            try w.writeAll(instrument_name);
            try w.splatByteAll(0, 12 - instrument_name.len);
        }
        try w.splatByteAll(0, 34);
    }
    return w.buffered();
}

test "ROL resolves a named BNK instrument and plays through note release" {
    const gpa = std.testing.allocator;
    const bank = testBank(&.{"PIANO"});
    var bytes: [2048]u8 = @splat(0);
    const data = try testSong(&bytes, "piano");
    try std.testing.expectError(error.MissingResource, load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip }));
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .resources = &.{.{ .name = "rol.bank", .data = &bank }} })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 22050), src.step(fmt.noop_chip).frames);
    try std.testing.expect(src.sequenceState().?.slots[0].keyed);
    const instruments = src.views().instruments.?;
    try std.testing.expectEqualStrings("PIANO", instruments.get(instruments.ctx, 0).name);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.sequenceState().?.slots[0].keyed);
    try std.testing.expectEqual(@as(u64, 22050), src.step(fmt.noop_chip).frames);
}

test "ROL voice and instrument names are transcoded from CP437" {
    const gpa = std.testing.allocator;
    const bank = testBank(&.{"CLOCH\x90\x00\xdb"});
    var bytes: [2048]u8 = @splat(0);
    const data = try testSong(&bytes, "cloch\x90");
    @memcpy(bytes[203..][0..7], "M\x82lodie");
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .resources = &.{.{ .name = "rol.bank", .data = &bank }} })).?;
    defer src.deinit(gpa);
    const sequence = src.views().sequence.?;
    try std.testing.expectEqualStrings("M\u{e9}lodie", sequence.track(sequence.ctx, 0).name);
    const instruments = src.views().instruments.?;
    try std.testing.expectEqualStrings("CLOCH\u{c9}", instruments.get(instruments.ctx, 0).name);
}

test "ROL neutral pitch publishes the MIDI centre bend" {
    var events = [_]Event{
        .{ .tick = 0, .kind = .pitch, .value = 1 },
        .{ .tick = 0, .kind = .pitch, .value = 2 },
    };
    var self = Source{
        .instruments = &.{},
        .events = &events,
        .names = @splat(.{}),
        .sample_rate = 44100,
        .ticks_per_beat = 4,
        .base_tempo = 120,
        .length = 100,
        .rhythm = false,
    };
    try std.testing.expectEqual(@as(u16, 8192), self.sequenceState().slots[0].bend);
    try std.testing.expectEqual(@as(u16, 8192), eventAt(&self, 0).payload.pitch_bend);
    try std.testing.expectEqual(@as(u16, 16383), eventAt(&self, 1).payload.pitch_bend);
}

const RegRec = struct {
    regs: [256]u8 = @splat(0),
    fn write(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (reg < self.regs.len) self.regs[reg] = val;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
    fn frequency(self: *const @This(), channel: u8) u16 {
        return @as(u16, self.regs[0xb0 + channel] & 0x1f) << 8 | self.regs[0xa0 + channel];
    }
};

test "ROL pitch events bend one semitone each way" {
    var events = [_]Event{
        .{ .tick = 0, .kind = .note, .value = 60 },
        .{ .tick = 4, .kind = .pitch, .value = 0 },
        .{ .tick = 8, .kind = .pitch, .value = 2 },
    };
    var self = Source{
        .instruments = &.{},
        .events = &events,
        .names = @splat(.{}),
        .sample_rate = 44100,
        .ticks_per_beat = 4,
        .base_tempo = 120,
        .length = 100,
        .rhythm = false,
    };
    var rec = RegRec{};
    self.reset(rec.chip());
    _ = self.step(rec.chip());
    try std.testing.expectEqual(fm.frequency(60), rec.frequency(0));
    _ = self.step(rec.chip());
    try std.testing.expectEqual(fm.frequency(59), rec.frequency(0));
    _ = self.step(rec.chip());
    try std.testing.expectEqual(fm.frequency(61), rec.frequency(0));
}

test "ROL rhythm drums keep the driver tom tuning until a tom note retunes them" {
    var events = [_]Event{
        .{ .tick = 0, .channel = 8, .kind = .off, .value = 0 },
        .{ .tick = 0, .channel = 8, .kind = .pitch, .value = 1 },
        .{ .tick = 0, .channel = 7, .kind = .note, .value = 60 },
        .{ .tick = 4, .channel = 8, .kind = .pitch, .value = 2 },
        .{ .tick = 4, .channel = 8, .kind = .note, .value = 48 },
    };
    var self = Source{
        .instruments = &.{},
        .events = &events,
        .names = @splat(.{}),
        .sample_rate = 44100,
        .ticks_per_beat = 4,
        .base_tempo = 120,
        .length = 100,
        .rhythm = true,
    };
    var rec = RegRec{};
    self.reset(rec.chip());
    _ = self.step(rec.chip());
    try std.testing.expectEqual(fm.frequency(36), rec.frequency(8));
    try std.testing.expectEqual(fm.frequency(43), rec.frequency(7));
    _ = self.step(rec.chip());
    try std.testing.expectEqual(fm.frequency(48), rec.frequency(8));
    try std.testing.expectEqual(fm.frequency(55), rec.frequency(7));
}

test "rol same-tick events yield before the callback budget" {
    const gpa = std.testing.allocator;
    const events = try gpa.alloc(Event, max_events_per_step + 2);
    defer gpa.free(events);
    @memset(events, .{ .tick = 0, .kind = .tempo, .value = 1 });
    events[events.len - 1].tick = 10;
    var self = Source{
        .instruments = &.{},
        .events = events,
        .names = @splat(.{}),
        .sample_rate = 44100,
        .ticks_per_beat = 4,
        .base_tempo = 120,
        .length = 100,
        .rhythm = false,
    };
    const first = self.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(max_events_per_step, self.cursor);
}
