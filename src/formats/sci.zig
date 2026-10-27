//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const fm = @import("../fm.zig");
const midi = @import("../midi_opl.zig");
const pcm = @import("../pcm.zig");
const binary = @import("../binary.zig");

pub const format_name = "SCI";
pub const extensions = &.{ ".sci", ".snd" };
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const max_events_per_step: u32 = 4096;

fn recognizes(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0x84 and data[1] == 0;
}

pub fn resourceRequests(gpa: std.mem.Allocator, path: []const u8, data: []const u8) ![]fmt.ResourceRequest {
    if (!recognizes(data)) return gpa.alloc(fmt.ResourceRequest, 0);
    if (data.len >= 35 and data[2] == 2) {
        const uses_fm = for (0..15) |channel| {
            if (data[4 + channel * 2] & 4 != 0) break true;
        } else false;
        if (!uses_fm) return gpa.alloc(fmt.ResourceRequest, 0);
    }
    const name = fmt.stemOf(fmt.basenameOf(path));
    const separator = @min(std.mem.findScalar(u8, name, ' ') orelse name.len, std.mem.find(u8, name, "%20") orelse name.len);
    const prefix = name[0..separator];
    const named = try gpa.print("{s}patch.003", .{prefix});
    defer gpa.free(named);
    const requests = try gpa.alloc(fmt.ResourceRequest, 1);
    errdefer gpa.free(requests);
    requests[0] = try .init(gpa, path, "sci.patch", &.{ "patch.003", "PATCH.003", "3.pat", "3.PAT", named });
    return requests;
}

fn readPatches(gpa: std.mem.Allocator, bytes: []const u8) ![]view.OplPatch {
    const data = if (bytes.len >= 2 and bytes[0] == 0x89 and bytes[1] == 0) bytes[2..] else bytes;
    const count: usize = if (data.len == 48 * 28) 48 else if (data.len == 96 * 28 + 2 and std.mem.eql(u8, data[48 * 28 ..][0..2], &.{ 0xab, 0xcd })) 96 else return error.InvalidSciPatch;
    const patches = try gpa.alloc(view.OplPatch, count);
    for (patches, 0..) |*patch, i| {
        const p = data[i * 28 + @as(usize, if (i >= 48) 2 else 0) ..][0..28];
        patch.* = .{ .ops = .{ fm.bankOperator(p[0..13], p[26]), fm.bankOperator(p[13..26], p[27]), .{}, .{} }, .feedback = @truncate(p[2]), .additive = p[12] == 0 };
    }
    return patches;
}

const Source = struct {
    patches: []view.OplPatch,
    events: []view.SequenceEvent,
    initial: [16]midi.Channel,
    driver: midi.Driver,
    samples: []i16,
    sample_hz: u32,
    sample_voice: pcm.Voice = .{},
    sample_level: u8 = 0,
    sample_rate: u32,
    cursor: usize = 0,
    tick: u32 = 0,
    played_tick: u32 = 0,
    fraction: u32 = 0,
    loop_index: ?usize = null,
    last_instrument: u16 = 0,
    ended: bool = false,

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.driver.channels = self.initial;
        self.driver.reset(chip);
        self.cursor = 0;
        self.tick = 0;
        self.played_tick = 0;
        self.fraction = 0;
        self.ended = false;
        self.sample_level = 0;
        if (self.samples.len != 0) self.sample_voice.start(.{ .data = self.samples }, self.sample_hz, self.sample_rate);
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        if (self.ended) {
            if (self.loop_index) |index| {
                self.cursor = index;
                self.tick = self.events[index].tick;
                self.ended = false;
            } else self.reset(chip);
        }
        self.played_tick = self.tick;
        var handled: u32 = 0;
        while (self.cursor < self.events.len and self.events[self.cursor].tick <= self.tick) {
            if (handled == max_events_per_step) return .{ .frames = 0 };
            handled += 1;
            const ev = self.events[self.cursor];
            self.cursor += 1;
            const ch = ev.channel;
            switch (ev.kind) {
                .note_on => if (self.driver.noteOn(chip, ch, ev.payload.note.note, ev.payload.note.velocity, null)) {
                    self.last_instrument = self.driver.channels[ch].program;
                },
                .note_off => self.driver.noteOff(chip, ch, ev.payload.note.note),
                .program => self.driver.channels[ch].program = ev.payload.program,
                .pitch_bend => self.driver.bend(chip, ch, ev.payload.pitch_bend),
                .control => {
                    const c = ev.payload.control;
                    if (c.cc == 75) self.driver.setPolyphony(chip, ch, @intCast(@min(c.value, 9))) else if (c.cc == 78) self.driver.channels[ch].velocity_enabled = c.value != 0 else self.driver.control(chip, ch, c.cc, @intCast(c.value));
                },
                .end => {
                    self.ended = true;
                    const remaining = if (self.sample_voice.active) (@as(u64, self.samples.len) << 32) -| self.sample_voice.position else 0;
                    const frames = if (remaining == 0) 0 else std.math.divCeil(u64, remaining, self.sample_voice.increment) catch 0;
                    return .{ .frames = frames, .done = true };
                },
                else => {},
            }
        }
        if (self.cursor == self.events.len) {
            self.ended = true;
            return .{ .frames = 0, .done = true };
        }
        const next = self.events[self.cursor].tick;
        const frames = fmt.rescale(next - self.tick, 60, self.sample_rate, &self.fraction);
        self.tick = next;
        return .{ .frames = frames };
    }

    pub fn durationFrames(self: *Source) u64 {
        const sequence_frames = @as(u64, self.events[self.events.len - 1].tick) * self.sample_rate / 60;
        const sample_frames = if (self.sample_hz == 0) 0 else @as(u64, self.samples.len) * self.sample_rate / self.sample_hz;
        return @max(sequence_frames, sample_frames);
    }

    pub fn renderPcm(self: *Source, stereo: []i32) void {
        self.sample_voice.mix(stereo);
        var peak: u32 = 0;
        for (stereo) |sample| peak = @max(peak, @abs(sample));
        self.sample_level = @intCast(@min(255, @as(u64, peak) * 255 / 16384));
    }

    pub fn info(self: *Source) fmt.TrackInfo {
        return .{ .format_name = "SCI0", .system = "OPL2", .loop = self.loop_index != null };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = self.played_tick, .last_instrument = self.last_instrument, .flags = .{ .has_tick = true } };
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        var state = self.driver.state();
        if (self.samples.len != 0) {
            state.channels = 17;
            state.slots[16] = .{ .program = @intCast(self.patches.len), .keyed = self.sample_voice.active };
            if (self.sample_voice.active or self.sample_level != 0) {
                state.voices[state.voice_count] = .{ .channel = 16, .kind = .pcm, .program = @intCast(self.patches.len), .velocity = 127, .keyed = self.sample_voice.active, .level = self.sample_level };
                state.voice_count += 1;
            }
        }
        return state;
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        const channels: u16 = if (self.samples.len == 0) 16 else 17;
        return .{ .ctx = self, .kind = .linear_midi, .track_count = channels, .channel_count = channels, .tick_rate = 60, .length_ticks = self.events[self.events.len - 1].tick, .track = track, .eventsInRange = eventsInRange, .eventAt = eventAt, .event_count = @intCast(self.events.len) };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = @intCast(self.patches.len + @intFromBool(self.samples.len != 0)), .get = instrument };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.patches);
        gpa.free(self.samples);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}

fn track(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self = source(ptr);
    if (index == 16 and self.samples.len != 0) return .{ .name = "PCM", .channel = 16, .program = @intCast(self.patches.len), .kind = .pcm };
    if (index >= 16) return .{};
    return .{ .channel = @intCast(index), .kind = if (index == 15) .control else .melodic, .in_use = self.initial[index].enabled };
}

fn instrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index < self.patches.len) return .{ .patch = .{ .opl_2op = self.patches[index] } };
    if (index == self.patches.len and self.samples.len != 0) return .{ .name = "Digital sample", .patch = .{ .sample = .{ .bytes = @intCast(self.samples.len), .c2spd = self.sample_hz, .default_volume = 64 } } };
    return .{};
}

fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    return if (index < self.events.len) self.events[index] else .{};
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
            dest[range.written] = self.events[lo];
            range.written += 1;
        }
        range.total_in_range += 1;
    }
    return range;
}

fn parameter(reader: *binary.Reader) !u8 {
    const value = try reader.byte();
    if (value >= 128) return error.InvalidMusicData;
    return value;
}

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) !?fmt.MusicSource {
    if (!recognizes(data)) return null;
    if (data.len < 35) return error.InvalidMusicData;
    if (data[2] != 0 and data[2] != 2) return error.UnsupportedSciVersion;
    var initial: [16]midi.Channel = @splat(.{});
    var uses_fm = false;
    for (&initial, 0..) |*ch, i| {
        ch.enabled = i != 15 and data[4 + i * 2] & 4 != 0;
        uses_fm = uses_fm or ch.enabled;
        ch.polyphony = @min(data[3 + i * 2] & 0xf, 9);
        ch.velocity_enabled = false;
    }
    const patches = if (ctx.resource("sci.patch")) |bank| try readPatches(gpa, bank) else if (uses_fm or data[2] == 0) return error.MissingResource else try gpa.alloc(view.OplPatch, 0);
    errdefer gpa.free(patches);
    var reader = binary.Reader{ .data = data, .pos = 35 };
    var events: std.ArrayList(view.SequenceEvent) = .empty;
    defer events.deinit(gpa);
    var running: u8 = 0;
    var tick: u32 = 0;
    var loop_index: ?usize = null;
    var ended = false;
    while (reader.pos < data.len) {
        const offset = reader.pos;
        var delay = try reader.byte();
        while (delay == 0xf8) {
            tick = try std.math.add(u32, tick, 240);
            delay = try reader.byte();
        }
        var status: u8 = 0xfc;
        if (delay != 0xfc) {
            tick = try std.math.add(u32, tick, delay);
            status = try reader.byte();
            if (status < 0x80) {
                if (running == 0) return error.InvalidMusicData;
                reader.pos -= 1;
                status = running;
            }
        }
        if (status < 0xf0) running = status;
        var event = view.SequenceEvent{ .tick = tick, .instr_index = @intCast(offset), .channel = status & 15, .track = status & 15 };
        if (status == 0xfc) {
            event.kind = .end;
            event.track = view.sequence_unassigned;
            ended = true;
        } else if (status == 0xf0) {
            while (try reader.byte() != 0xf7) {}
            event.kind = .sysex;
            event.track = view.sequence_unassigned;
            event.payload = .{ .sysex_ref = @intCast(@min(events.items.len, 65535)) };
        } else switch (status >> 4) {
            8, 9 => {
                const note = try parameter(&reader);
                const velocity = try parameter(&reader);
                event.kind = if (status >> 4 == 8 or velocity == 0) .note_off else .note_on;
                event.payload = .{ .note = .{ .note = note, .velocity = velocity } };
            },
            0xa => {
                _ = try parameter(&reader);
                event.kind = .aftertouch;
                event.payload = .{ .aftertouch = try parameter(&reader) };
            },
            0xb => {
                event.kind = .control;
                event.payload = .{ .control = .{ .cc = try parameter(&reader), .value = try parameter(&reader) } };
            },
            0xc => {
                const program = try parameter(&reader);
                if (event.channel == 15) {
                    event.track = view.sequence_unassigned;
                    event.kind = .label;
                    event.payload = .{ .label = program };
                    if (program == 127) loop_index = events.items.len;
                } else {
                    if (initial[event.channel].enabled and program >= patches.len) return error.InvalidSciPatch;
                    event.kind = .program;
                    event.payload = .{ .program = program };
                }
            },
            0xd => {
                event.kind = .aftertouch;
                event.payload = .{ .aftertouch = try parameter(&reader) };
            },
            0xe => {
                const low = try parameter(&reader);
                const high = try parameter(&reader);
                event.kind = .pitch_bend;
                event.payload = .{ .pitch_bend = low | @as(u16, high) << 7 };
            },
            else => return error.InvalidMusicData,
        }
        if (events.items.len >= 262144) return error.InvalidMusicData;
        try events.append(gpa, event);
        if (ended) break;
    }
    if (!ended) return error.InvalidMusicData;
    var sample_hz: u32 = 0;
    var samples: []i16 = &.{};
    if (data[2] == 2) {
        const sample_offset = std.mem.readInt(u16, data[33..35], .big);
        if (sample_offset != 0) {
            const start = @as(usize, sample_offset) + 3;
            if (start < reader.pos or start > data.len) return error.InvalidMusicData;
            reader.pos = start;
        }
        if (sample_offset == 0 and reader.pos < data.len and data[reader.pos] == 0xfc) reader.pos += 1;
        const header = try reader.take(44);
        sample_hz = fmt.readU16Le(header, 14);
        const length = fmt.readU16Le(header, 32);
        if (sample_hz == 0) return error.InvalidMusicData;
        const bytes = try reader.take(length);
        samples = try gpa.alloc(i16, length);
        for (samples, bytes) |*sample, value| sample.* = (@as(i16, value) - 128) * 256;
    }
    errdefer gpa.free(samples);
    const owned = try events.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    const self = try gpa.create(Source);
    self.* = .{ .patches = patches, .events = owned, .initial = initial, .driver = .{ .patches = patches }, .samples = samples, .sample_hz = sample_hz, .sample_rate = ctx.sample_rate, .loop_index = loop_index };
    self.reset(ctx.chip);
    return fmt.MusicSource.init(self, visualizer_name);
}

// --- tests -------------------------------------------------------------------

test "SCI0 plays chords and preserves its explicit loop point" {
    const gpa = std.testing.allocator;
    var header: [35]u8 = @splat(0);
    header[0] = 0x84;
    header[3] = 3;
    header[4] = 4;
    const data = header ++ [_]u8{ 0, 0xcf, 127, 0, 0x90, 60, 100, 0, 64, 100, 60, 0x80, 60, 0, 0, 64, 0, 0, 0xfc };
    const bank: [48 * 28]u8 = @splat(0);
    const src = (try load(gpa, &data, .{ .chip = fmt.noop_chip, .sample_rate = 44100, .resources = &.{.{ .name = "sci.patch", .data = &bank }} })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 44100), src.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u16, 2), src.sequenceState().?.voice_count);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    for (src.sequenceState().?.voices[0..2]) |voice| try std.testing.expect(!voice.keyed);
    try std.testing.expectEqual(@as(u64, 44100), src.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u16, 2), src.sequenceState().?.voice_count);
    for (src.sequenceState().?.voices[0..2]) |voice| try std.testing.expect(voice.keyed);
}

test "SCI0 playhead names the patch of the last AdLib note, not an MT-32 program" {
    const gpa = std.testing.allocator;
    var header: [35]u8 = @splat(0);
    header[0] = 0x84;
    header[3] = 3;
    header[4] = 4;
    header[5] = 3;
    header[6] = 1;
    const data = header ++ [_]u8{ 0, 0xc0, 5, 0, 0x90, 60, 100, 0, 0xc1, 0x50, 0, 0x91, 62, 100, 60, 0x80, 60, 0, 0, 0xfc };
    const bank: [48 * 28]u8 = @splat(0);
    const src = (try load(gpa, &data, .{ .chip = fmt.noop_chip, .sample_rate = 44100, .resources = &.{.{ .name = "sci.patch", .data = &bank }} })).?;
    defer src.deinit(gpa);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 1), src.sequenceState().?.voice_count);
    try std.testing.expectEqual(@as(u16, 5), src.playhead().?.last_instrument);
}

test "SCI digital sample renders its complete tail after the MIDI end marker" {
    var data: [35 + 2 + 44 + 4]u8 = @splat(0);
    data[0] = 0x84;
    data[2] = 2;
    data[36] = 0xfc;
    std.mem.writeInt(u16, data[51..53], 22050, .little);
    std.mem.writeInt(u16, data[69..71], 4, .little);
    @memcpy(data[81..85], &[_]u8{ 128, 255, 128, 0 });
    const src = (try load(std.testing.allocator, &data, .{ .sample_rate = 44100, .chip = fmt.noop_chip })).?;
    defer src.deinit(std.testing.allocator);
    const sequence = src.views().sequence.?;
    try std.testing.expectEqual(@as(u16, 17), sequence.track_count);
    try std.testing.expectEqual(.control, sequence.track(sequence.ctx, 15).kind);
    try std.testing.expectEqual(.pcm, sequence.track(sequence.ctx, 16).kind);
    try std.testing.expectEqual(@as(u16, 16), src.sequenceState().?.voices[0].channel);
    try std.testing.expectEqual(@as(?u64, 8), src.durationFrames());
    const step = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 8), step.frames);
    try std.testing.expect(step.done);
    var out: [16]i32 = undefined;
    src.renderPcm(&out);
    try std.testing.expectEqual(@as(i32, 0), out[0]);
    try std.testing.expect(out[4] > 16000);
    try std.testing.expect(out[12] < -16000);
    const state = src.sequenceState().?;
    try std.testing.expectEqual(@as(u8, 255), state.voices[0].level);
    try std.testing.expect(!state.voices[0].keyed);
    src.renderPcm(&out);
    try std.testing.expectEqual(@as(u16, 0), src.sequenceState().?.voice_count);
}

test "sci same-tick events yield before the callback budget" {
    const gpa = std.testing.allocator;
    const events = try gpa.alloc(view.SequenceEvent, max_events_per_step + 2);
    defer gpa.free(events);
    @memset(events, .{ .tick = 0, .kind = .program, .payload = .{ .program = 1 } });
    events[events.len - 1].tick = 60;
    var patches = [_]view.OplPatch{.{}};
    var self = Source{
        .patches = &patches,
        .events = events,
        .initial = @splat(.{}),
        .driver = .{ .patches = &patches },
        .samples = &.{},
        .sample_hz = 0,
        .sample_rate = 44100,
    };
    const first = self.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(max_events_per_step, self.cursor);
}
