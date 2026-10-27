//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "Lucasfilm AD";
pub const extensions = &.{".laa"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const header_len = 6;
const music_start = 0x93;
const callback_hz = 472;
const timer_limit = 256;
const first_wait = 40;
const max_events = 1 << 20;
const max_commands_per_step: u32 = 4096;
const max_wait_callbacks: u64 = callback_hz * 600;
const probe_secs = 30 * 60;

const operator_offsets = [18]u8{ 0, 3, 1, 4, 2, 5, 8, 11, 9, 12, 10, 13, 16, 19, 17, 20, 18, 21 };
const note_frequencies = [12]u16{ 0x200, 0x21e, 0x23f, 0x261, 0x285, 0x2ab, 0x2d4, 0x300, 0x32e, 0x35e, 0x390, 0x3c7 };
const rhythm_bits = [6]u8{ 0x00, 0x10, 0x08, 0x04, 0x02, 0x01 };
const rhythm_operators = [6]u8{ 0x00, 0x00, 0x14, 0x12, 0x15, 0x11 };
const rhythm_channels = [6]u8{ 0, 0, 7, 8, 8, 7 };
const drum_voices = [6]u8{ 0, 6, 7, 8, 8, 7 };

const Kind = enum(u8) { note_on, note_off, tempo, end, other };

const Event = struct {
    tick: u32,
    offset: u32,
    kind: Kind,
    command: u8 = 0,
    note: u8 = 0,
    wait: u16 = 0,
    ticks: u16 = 0,
};

const Voice = struct {
    last_event: u8 = 0,
    frequency: u8 = 0,
    b0: u8 = 0,
    shown: bool = false,
    shown_channel: u8 = 0,
    shown_note: u8 = 0,
};

fn recognizes(data: []const u8) bool {
    return data.len >= header_len + music_start and std.mem.eql(u8, data[4..6], "AD") and data[header_len + 2] == 0x80;
}

fn vlq(music: []const u8, pos: *usize) !u16 {
    if (pos.* >= music.len) return error.InvalidMusicData;
    var value: u16 = music[pos.*];
    pos.* += 1;
    if (value & 0x80 != 0) {
        if (pos.* >= music.len) return error.InvalidMusicData;
        value = ((value - 0x80) << 7) | music[pos.*];
        pos.* += 1;
    }
    return value;
}

fn parse(gpa: std.mem.Allocator, music: []const u8) ![]Event {
    var events: std.ArrayList(Event) = .empty;
    errdefer events.deinit(gpa);
    var pos: usize = music_start;
    var tick: u32 = 0;
    while (true) {
        if (events.items.len >= max_events) return error.InvalidMusicData;
        if (pos >= music.len) {
            try events.append(gpa, .{ .tick = tick, .offset = @intCast(pos), .kind = .end });
            break;
        }
        var ev = Event{ .tick = tick, .offset = @intCast(pos), .kind = .other, .command = music[pos] };
        pos += 1;
        if (ev.command == 0xff) {
            if (pos >= music.len) return error.InvalidMusicData;
            const meta = music[pos];
            pos += 1;
            if (meta == 47) {
                ev.kind = .end;
                try events.append(gpa, ev);
                break;
            } else if (meta == 88) {
                pos += 5;
            } else {
                if (pos + 2 >= music.len) return error.InvalidMusicData;
                if (meta == 81) {
                    const timing = @as(u32, music[pos + 2]) | @as(u32, music[pos + 1]) << 8;
                    ev.kind = .tempo;
                    ev.ticks = if (timing == 0) 0 else @intCast(@min(0xffff, 0x73000 / timing));
                }
                pos += 1 + @as(usize, music[pos]);
            }
        } else {
            if (pos + 2 > music.len) return error.InvalidMusicData;
            ev.kind = if (ev.command >= 0x90) .note_on else .note_off;
            ev.note = music[pos];
            pos += 2;
        }
        if (pos >= music.len) return error.InvalidMusicData;
        if (music[pos] == 0) {
            pos += 1;
        } else {
            const delay = try vlq(music, &pos);
            ev.wait = @max(1, delay >> 1);
            tick +|= ev.wait;
        }
        try events.append(gpa, ev);
    }
    return events.toOwnedSlice(gpa);
}

const Source = struct {
    music: []const u8,
    events: []const Event,
    loop_index: ?u32,
    instrument_offset: [16]u16,
    instrument_count: u8,
    rhythm: bool,
    sample_rate: u32,
    duration: u64 = 0,
    frac: u32 = 0,
    chip: fmt.Chip = fmt.noop_chip,

    cursor: u32 = 0,
    started: bool = false,
    ended: bool = false,
    music_ticks: u32 = 0,
    music_timer: u32 = 0,
    next_event_timer: u32 = first_wait,
    mdvdr: u8 = 0,
    hw_count: u8 = 9,
    hw_allocated: [9]bool = @splat(false),
    voices: [9]Voice = @splat(.{}),
    last_channel: u16 = 0,

    fn write(self: *Source, reg: u8, value: u8) void {
        self.chip.writeReg(reg, value);
    }

    fn setupOperator(self: *Source, operator: u8, bytes: []const u8) void {
        for ([_]u8{ 0x20, 0x40, 0x60, 0x80, 0xe0 }, bytes[0..5]) |base, value| self.write(base + operator, value);
    }

    fn setupChannel(self: *Source, channel: u8, offset: u16) void {
        const ins = self.music[offset..][0..16];
        self.write(0xc0 + channel, ins[2]);
        self.setupOperator(operator_offsets[channel * 2], ins[3..8]);
        self.setupOperator(operator_offsets[channel * 2 + 1], ins[8..13]);
    }

    fn setupFrequency(self: *Source, channel: u8, note: u8) void {
        var frequency: i8 = @bitCast(note);
        frequency -%= 31;
        if (frequency < 0) frequency = 0;
        var octave: u8 = 0;
        while (frequency >= 12) {
            frequency -= 12;
            octave += 1;
        }
        const value = note_frequencies[@intCast(frequency)];
        const b0: u8 = (octave << 2) | @as(u8, @intCast(value >> 8)) | 0x20;
        self.write(0xa0 + channel, @truncate(value));
        self.voices[channel].b0 = b0;
        self.write(0xb0 + channel, b0);
    }

    fn setupRhythm(self: *Source, rhythm: u8, offset: u16) void {
        const ins = self.music[offset..][0..16];
        if (rhythm == 1) {
            self.setupChannel(6, offset);
            self.write(0xa6, ins[0]);
            self.write(0xb6, ins[1] & 0xdf);
        } else if (rhythm < 6) {
            self.setupOperator(rhythm_operators[rhythm], ins[8..13]);
            const channel = rhythm_channels[rhythm];
            self.write(0xa0 + channel, ins[0]);
            self.write(0xb0 + channel, ins[1] & 0xdf);
            self.write(0xc0 + channel, ins[2]);
        } else return;
        self.mdvdr |= rhythm_bits[rhythm];
        self.write(0xbd, self.mdvdr);
    }

    fn allocate(self: *Source) ?u8 {
        var channel: ?u8 = null;
        for (0..self.hw_count) |i| {
            if (!self.hw_allocated[i]) {
                channel = @intCast(i);
                break;
            }
        }
        const c = channel orelse return null;
        self.hw_allocated[c] = true;
        return c;
    }

    fn noteOff(self: *Source, channel: u8) void {
        self.write(0xb0 + channel, self.voices[channel].b0 & 0xdf);
        self.hw_allocated[channel] = false;
        self.voices[channel].last_event = 0;
        self.voices[channel].frequency = 0;
        self.voices[channel].b0 = 0;
    }

    fn instrument(self: *const Source, channel: u8) u16 {
        return if (channel < 16) self.instrument_offset[channel] else 0;
    }

    fn execute(self: *Source, ev: Event) void {
        switch (ev.kind) {
            .note_on => {
                const channel = ev.command - 0x90;
                const offset = self.instrument(channel);
                if (offset == 0) return;
                const rhythm = self.music[offset + 13];
                if (rhythm != 0) {
                    self.setupRhythm(rhythm, offset);
                } else if (self.allocate()) |hw| {
                    self.setupChannel(hw, offset);
                    self.voices[hw] = .{ .last_event = ev.command, .frequency = ev.note, .shown = true, .shown_channel = channel, .shown_note = ev.note };
                    self.setupFrequency(hw, ev.note);
                }
                self.last_channel = channel;
            },
            .note_off => {
                const status = ev.command +% 0x10;
                for (&self.voices, 0..) |v, i| {
                    if (v.last_event != 0 and v.frequency == ev.note and v.last_event == status) {
                        self.noteOff(@intCast(i));
                        return;
                    }
                }
                if (status < 0x90) return;
                const offset = self.instrument(status - 0x90);
                if (offset == 0) return;
                const rhythm = self.music[offset + 13];
                if (rhythm != 0 and rhythm < 6) {
                    self.mdvdr &= ~rhythm_bits[rhythm];
                    self.write(0xbd, self.mdvdr);
                }
            },
            .tempo => if (ev.ticks != 0) {
                self.music_ticks = @min(ev.ticks, timer_limit);
            },
            .end, .other => {},
        }
    }

    fn stop(self: *Source) void {
        for (0..9) |i| {
            if (self.voices[i].last_event != 0) self.noteOff(@intCast(i));
        }
        self.mdvdr = 0;
        self.write(0xbd, 0);
        self.hw_count = 9;
    }

    fn start(self: *Source) void {
        self.mdvdr = if (self.rhythm) 0x20 else 0;
        self.hw_count = if (self.rhythm) 6 else 9;
        for (self.hw_count..9) |i| self.hw_allocated[i] = false;
        self.cursor = 0;
        self.started = false;
        self.ended = false;
        self.music_ticks = self.music[3];
        self.music_timer = 0;
        self.next_event_timer = first_wait;
        self.write(0xbd, self.mdvdr);
    }

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.chip = chip;
        self.write(1, 0);
        self.write(0xbd, 0);
        self.write(8, 0);
        self.write(1, 0x20);
        self.start();
    }

    fn waitCallbacks(self: *Source) u64 {
        var callbacks: u64 = 0;
        while (callbacks < max_wait_callbacks) {
            callbacks += 1;
            self.music_timer += self.music_ticks;
            if (self.music_timer < timer_limit) continue;
            self.music_timer -= timer_limit;
            self.next_event_timer -= 1;
            if (self.next_event_timer == 0) break;
        }
        return callbacks;
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        self.chip = chip;
        if (self.ended) self.start();
        if (self.started) {
            var handled: u32 = 0;
            while (true) : (handled += 1) {
                if (handled == max_commands_per_step) {
                    self.next_event_timer = 1;
                    break;
                }
                const ev = self.events[self.cursor];
                if (ev.kind == .end) {
                    if (self.loop_index) |index| {
                        self.cursor = index;
                    } else {
                        self.stop();
                        self.ended = true;
                    }
                    return .{ .frames = 0, .done = true };
                }
                self.execute(ev);
                self.cursor += 1;
                if (ev.wait != 0) {
                    self.next_event_timer = ev.wait;
                    break;
                }
            }
        }
        self.started = true;
        return .{ .frames = fmt.rescale(self.waitCallbacks(), callback_hz, self.sample_rate, &self.frac) };
    }

    pub fn durationFrames(self: *Source) u64 {
        return self.duration;
    }

    pub fn info(self: *Source) fmt.TrackInfo {
        return .{ .format_name = format_name, .system = "OPL2", .loop = self.loop_index != null };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = if (self.cursor == 0) 0 else self.events[self.cursor - 1].tick, .last_instrument = self.programOf(self.last_channel) orelse 0, .flags = .{ .has_tick = true } };
    }

    fn programOf(self: *const Source, channel: u16) ?u16 {
        if (channel >= 16 or self.instrument_offset[channel] == 0) return null;
        return (self.instrument_offset[channel] - 19) / 16;
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = 16 };
        for (0..16) |ch| bank.slots[ch].program = self.programOf(@intCast(ch)) orelse view.instrument_none;
        for (self.voices, 0..) |v, i| {
            if (!v.shown) continue;
            const keyed = v.last_event != 0;
            bank.voices[bank.voice_count] = .{ .channel = v.shown_channel, .program = self.programOf(v.shown_channel) orelse 0, .note = v.shown_note, .opl_voice = @intCast(i), .keyed = keyed };
            bank.voice_count += 1;
            if (!keyed) continue;
            const slot = &bank.slots[v.shown_channel];
            slot.keyed = true;
            slot.note = v.shown_note;
            slot.opl_voice = @intCast(i);
        }
        if (self.mdvdr & 0x20 != 0) for (1..6) |r| {
            if (self.mdvdr & rhythm_bits[r] == 0) continue;
            bank.voices[bank.voice_count] = .{ .channel = view.sequence_unassigned, .opl_voice = drum_voices[r], .kind = .drum, .keyed = true };
            bank.voice_count += 1;
        };
        return bank;
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .linear_midi,
            .track_count = 16,
            .channel_count = 16,
            .tick_rate = @max(1, callback_hz * @as(u32, self.music[3]) / timer_limit),
            .length_ticks = self.events[self.events.len - 1].tick,
            .track = track,
            .eventsInRange = eventsInRange,
            .eventAt = eventAt,
            .event_count = @intCast(self.events.len),
        };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = self.instrument_count, .get = instrumentInfo };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.music);
        gpa.free(self.events);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}

fn track(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self = source(ptr);
    if (index >= 16) return .{};
    const offset = self.instrument_offset[index];
    const drum = offset != 0 and self.music[offset + 13] != 0;
    return .{ .channel = @intCast(index), .program = self.programOf(index) orelse 0, .kind = if (drum) .drum else .melodic, .in_use = offset != 0 };
}

const names = [8][]const u8{ "Instrument 1", "Instrument 2", "Instrument 3", "Instrument 4", "Instrument 5", "Instrument 6", "Instrument 7", "Instrument 8" };

fn instrumentInfo(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index >= self.instrument_count) return .{};
    const ins = self.music[19 + @as(usize, index) * 16 ..][0..16];
    return .{ .name = names[index], .patch = .{ .opl_2op = .{
        .ops = .{ fmt.operatorParams(ins[3], ins[4], ins[5], ins[6], ins[7]), fmt.operatorParams(ins[8], ins[9], ins[10], ins[11], ins[12]), .{}, .{} },
        .feedback = @truncate(ins[2] >> 1),
        .additive = ins[2] & 1 != 0,
        .perc_voice = ins[13],
    } } };
}

fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    if (index >= self.events.len) return .{};
    const ev = self.events[index];
    var out = view.SequenceEvent{ .tick = ev.tick, .instr_index = index, .channel = ev.command & 0x0f, .track = ev.command & 0x0f };
    switch (ev.kind) {
        .note_on, .note_off => {
            out.kind = if (ev.kind == .note_on) .note_on else .note_off;
            out.payload = .{ .note = .{ .note = ev.note, .velocity = if (ev.kind == .note_on) 127 else 0 } };
        },
        .tempo => {
            out.track = view.sequence_unassigned;
            out.kind = .tempo;
            out.payload = .{ .tempo = ev.ticks };
        },
        .end => {
            out.track = view.sequence_unassigned;
            out.kind = .end;
            if (self.loop_index) |loop| {
                out.kind = .jump;
                out.payload = .{ .jump = self.events[loop].tick };
            }
        },
        .other => {
            out.track = view.sequence_unassigned;
            out.kind = .sysex;
            out.payload = .{ .sysex_ref = ev.command };
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
        if (self.events[mid].tick < tick0) lo = mid + 1 else hi = mid;
    }
    var range = view.EventRange{};
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
    const music = try gpa.dupe(u8, data[header_len..]);
    errdefer gpa.free(music);
    const events = try parse(gpa, music);
    errdefer gpa.free(events);
    var instrument_offset: [16]u16 = @splat(0);
    var rhythm = false;
    const count = @min(music[10], 8);
    for (0..count) |i| {
        const index = @as(i32, music[11 + i]) - 1;
        if (index < 0 or index >= 16) continue;
        const offset: u16 = @intCast(i * 16 + 16 + 3);
        instrument_offset[@intCast(index)] = offset;
        rhythm = rhythm or music[offset + 13] != 0;
    }
    var loop_index: ?u32 = null;
    if (music[4] == 0) {
        const target = music_start + @as(usize, std.mem.readInt(u16, music[5..7], .little));
        loop_index = 0;
        for (events, 0..) |ev, i| if (ev.offset >= target) {
            loop_index = @intCast(i);
            break;
        };
    }
    const self = try gpa.create(Source);
    self.* = .{
        .music = music,
        .events = events,
        .loop_index = loop_index,
        .instrument_offset = instrument_offset,
        .instrument_count = count,
        .rhythm = rhythm,
        .sample_rate = ctx.sample_rate,
    };
    var probe = self.*;
    probe.reset(fmt.noop_chip);
    var frames: u64 = 0;
    while (frames < @as(u64, ctx.sample_rate) * probe_secs) {
        const r = probe.step(fmt.noop_chip);
        frames += r.frames;
        if (r.done) {
            self.duration = frames;
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

fn testSong(buf: []u8, loop: bool, rhythm: u8, commands: []const u8) []const u8 {
    @memset(buf, 0);
    const total = header_len + music_start + commands.len;
    std.mem.writeInt(u32, buf[0..4], @intCast(total), .little);
    @memcpy(buf[4..6], "AD");
    const music = buf[header_len..];
    music[2] = 0x80;
    music[3] = 128;
    music[4] = if (loop) 0 else 1;
    music[10] = 1;
    music[11] = 1;
    const ins = music[19..][0..16];
    ins[0] = 0x56;
    ins[1] = 0x31;
    ins[2] = 0x01;
    ins[3] = 0x21;
    ins[8] = 0x21;
    ins[13] = rhythm;
    @memcpy(music[music_start..][0..commands.len], commands);
    return buf[0..total];
}

test "Lucasfilm AD plays its instruments on the old AdLib timer" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, false, 0, &.{ 0x90, 67, 100, 40, 0x80, 67, 0, 0, 0xff, 47 });
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = callback_hz, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    try std.testing.expect(!src.info().loop);
    try std.testing.expectEqual(@as(?u64, 80 + 40), src.durationFrames());
    try std.testing.expectEqual(@as(u64, 80), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u64, 40), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u8, 0x01), rec.regs[0xc0]);
    try std.testing.expectEqual(@as(u8, 0x2e), rec.regs[0xb0]);
    try std.testing.expectEqual(@as(u8, 0x00), rec.regs[0xa0]);
    try std.testing.expect(src.sequenceState().?.slots[0].keyed);
    const last = src.step(rec.chip());
    try std.testing.expect(last.done);
    try std.testing.expectEqual(@as(u8, 0x0e), rec.regs[0xb0]);
    try std.testing.expect(!src.sequenceState().?.slots[0].keyed);
}

test "Lucasfilm AD loops back to its loop start at the end of track" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, true, 0, &.{ 0x90, 67, 100, 4, 0x80, 67, 0, 4, 0xff, 47 });
    const src = (try load(gpa, data, .{ .sample_rate = callback_hz, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(?u64, 80 + 4 + 4), src.durationFrames());
    _ = src.step(fmt.noop_chip);
    _ = src.step(fmt.noop_chip);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
    const wrap = src.step(fmt.noop_chip);
    try std.testing.expect(wrap.done);
    try std.testing.expectEqual(@as(u64, 0), wrap.frames);
    try std.testing.expectEqual(@as(u32, 0), source(src.ptr).cursor);
    const again = src.step(fmt.noop_chip);
    try std.testing.expect(!again.done);
    try std.testing.expectEqual(@as(u64, 4), again.frames);
    try std.testing.expectEqual(@as(u32, 1), source(src.ptr).cursor);
}

test "Lucasfilm AD drops a note when every channel is busy" {
    const gpa = std.testing.allocator;
    var commands: [44]u8 = undefined;
    for (0..10) |i| commands[i * 4 ..][0..4].* = .{ 0x90, @intCast(50 + i), 100, 0 };
    commands[39] = 4;
    commands[40..44].* = .{ 0xff, 47, 0, 0 };
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, false, 0, commands[0..42]);
    const src = (try load(gpa, data, .{ .sample_rate = callback_hz, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    _ = src.step(fmt.noop_chip);
    const self = source(src.ptr);
    for (self.voices, 0..) |v, i| try std.testing.expectEqual(@as(u8, @intCast(50 + i)), v.frequency);
}

test "Lucasfilm AD keeps one music tick per callback for fast tempos" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, true, 0, &.{ 0xff, 81, 3, 0, 1, 0, 4, 0x90, 60, 100, 4, 0xff, 47 });
    const src = (try load(gpa, data, .{ .sample_rate = callback_hz, .chip = fmt.noop_chip })).?;
    defer src.deinit(gpa);
    for (0..100_000) |_| _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u32, timer_limit), source(src.ptr).music_ticks);
}

test "Lucasfilm AD rhythm instruments set their drum bits" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, false, 2, &.{ 0x90, 60, 100, 4, 0x80, 60, 0, 4, 0xff, 47 });
    var rec: RegRec = .{};
    const src = (try load(gpa, data, .{ .sample_rate = callback_hz, .chip = rec.chip() })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0x20), rec.regs[0xbd]);
    _ = src.step(rec.chip());
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x28), rec.regs[0xbd]);
    try std.testing.expectEqual(@as(u8, 0x56), rec.regs[0xa7]);
    try std.testing.expectEqual(@as(u8, 0x11), rec.regs[0xb7]);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x20), rec.regs[0xbd]);
}

test "Lucasfilm AD declines other files and rejects a truncated stream" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try load(gpa, "ADL \x00\x00\x00\x00", .{ .sample_rate = 1000, .chip = fmt.noop_chip })) == null);
    var buf: [256]u8 = undefined;
    const data = testSong(&buf, false, 0, &.{ 0x90, 67 });
    try std.testing.expectError(error.InvalidMusicData, load(gpa, data, .{ .sample_rate = 1000, .chip = fmt.noop_chip }));
}
