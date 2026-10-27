//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const midi = @import("../midi_opl.zig");
const binary = @import("../binary.zig");

pub const format_name = "XMI";
pub const extensions = &.{".xmi"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };
pub const format = fmt.Format.init(@This());

const max_events_per_step: u32 = 4096;
const velocity_graph = [16]u8{ 82, 85, 88, 91, 94, 97, 100, 103, 106, 109, 112, 115, 118, 121, 124, 127 };

const Timbre = struct { program: u8, bank: u8, transpose: i8, name: [48]u8 = @splat(0) };
const Branch = struct { label: u16, event: u32 };
const Sequence = struct { events: []view.SequenceEvent, branches: []Branch, duration: u64 = 0 };
const Loop = struct { event: usize, tick: u32, remaining: u8 };

fn recognizes(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "FORM") and (std.mem.eql(u8, data[8..12], "XDIR") or std.mem.eql(u8, data[8..12], "XMID"));
}

pub fn resourceRequests(gpa: std.mem.Allocator, path: []const u8, data: []const u8) ![]fmt.ResourceRequest {
    if (!recognizes(data)) return gpa.alloc(fmt.ResourceRequest, 0);
    const named = try gpa.print("{s}.ad", .{fmt.stemOf(fmt.basenameOf(path))});
    defer gpa.free(named);
    const requests = try gpa.alloc(fmt.ResourceRequest, 1);
    errdefer gpa.free(requests);
    const opl3_named = try gpa.print("{s}.opl", .{fmt.stemOf(fmt.basenameOf(path))});
    defer gpa.free(opl3_named);
    requests[0] = try .init(gpa, path, "xmi.timbres", &.{ opl3_named, named, "standard.opl", "STANDARD.OPL", "standard.ad", "STANDARD.AD", "standard.gtl", "STANDARD.GTL", "sample.opl", "SAMPLE.OPL", "sample.ad", "SAMPLE.AD" });
    return requests;
}

fn parameter(reader: *binary.Reader) !u8 {
    const value = try reader.byte();
    if (value >= 128) return error.InvalidMusicData;
    return value;
}

fn readEvents(gpa: std.mem.Allocator, data: []const u8) ![]view.SequenceEvent {
    var list: std.ArrayList(view.SequenceEvent) = .empty;
    defer list.deinit(gpa);
    var reader = binary.Reader{ .data = data };
    var tick: u32 = 0;
    var depth: u8 = 0;
    while (reader.pos < data.len) {
        var status = try reader.byte();
        while (status < 128) {
            tick = try std.math.add(u32, tick, status);
            status = try reader.byte();
        }
        var ev = view.SequenceEvent{ .tick = tick, .instr_index = @intCast(reader.pos - 1), .channel = status & 15, .track = status & 15 };
        switch (status >> 4) {
            8, 9 => {
                const note = try parameter(&reader);
                const velocity = try parameter(&reader);
                const duration: ?u32 = if (status >> 4 == 9) try reader.vlq() else null;
                ev.kind = if (status >> 4 == 8 or velocity == 0) .note_off else .duration_note;
                ev.payload = .{ .note = .{ .note = note, .velocity = velocity, .duration_ticks = duration } };
            },
            0xa => {
                _ = try parameter(&reader);
                ev.kind = .aftertouch;
                ev.payload = .{ .aftertouch = try parameter(&reader) };
            },
            0xb => {
                const cc = try parameter(&reader);
                const value = try parameter(&reader);
                if (cc == 116) {
                    depth += 1;
                    if (depth > 4) return error.InvalidXmiLoop;
                } else if (cc == 117) {
                    if (depth == 0) return error.InvalidXmiLoop;
                    depth -= 1;
                }
                ev.kind = .control;
                ev.payload = .{ .control = .{ .cc = cc, .value = value } };
            },
            0xc => {
                ev.kind = .program;
                ev.payload = .{ .program = try parameter(&reader) };
            },
            0xd => {
                ev.kind = .aftertouch;
                ev.payload = .{ .aftertouch = try parameter(&reader) };
            },
            0xe => {
                const low = try parameter(&reader);
                ev.kind = .pitch_bend;
                ev.payload = .{ .pitch_bend = low | @as(u16, try parameter(&reader)) << 7 };
            },
            0xf => {
                ev.track = view.sequence_unassigned;
                const kind = if (status == 0xff) try reader.byte() else if (status == 0xf0 or status == 0xf7) @as(u8, 0) else return error.InvalidMusicData;
                const bytes = try reader.take(try reader.vlq());
                if (kind == 0x2f) {
                    if (bytes.len != 0 or depth != 0) return error.InvalidMusicData;
                    ev.kind = .end;
                } else if (kind == 0x51) {
                    if (bytes.len != 3) return error.InvalidMusicData;
                    ev.kind = .tempo;
                    ev.payload = .{ .tempo = @as(u32, bytes[0]) << 16 | @as(u32, bytes[1]) << 8 | bytes[2] };
                } else {
                    ev.kind = .sysex;
                    ev.payload = .{ .sysex_ref = kind };
                }
            },
            else => unreachable,
        }
        if (list.items.len >= 262144) return error.InvalidMusicData;
        try list.append(gpa, ev);
        if (ev.kind == .end) return list.toOwnedSlice(gpa);
    }
    return error.InvalidMusicData;
}

const Chunk = struct { id: []const u8, data: []const u8 };

fn chunk(reader: *binary.Reader) !Chunk {
    const header = try reader.take(8);
    const length = std.mem.readInt(u32, header[4..8], .big);
    const data = try reader.take(length);
    if (length & 1 != 0) _ = try reader.take(1);
    return .{ .id = header[0..4], .data = data };
}

fn findTimbre(timbres: []const Timbre, program: u8, bank: u8) !u16 {
    for (timbres, 0..) |timbre, i| if (timbre.program == program and timbre.bank == bank) return @intCast(i);
    return error.MissingXmiTimbre;
}

fn readSequence(gpa: std.mem.Allocator, data: []const u8, timbres: []const Timbre) !Sequence {
    var reader = binary.Reader{ .data = data };
    var event_data: ?[]const u8 = null;
    var branch_data: []const u8 = &.{};
    while (reader.pos < data.len) {
        const item = try chunk(&reader);
        if (std.mem.eql(u8, item.id, "EVNT")) {
            if (event_data != null) return error.InvalidMusicData;
            event_data = item.data;
        } else if (std.mem.eql(u8, item.id, "RBRN")) {
            branch_data = item.data;
        } else if (std.mem.eql(u8, item.id, "TIMB")) {
            var r = binary.Reader{ .data = item.data };
            const count = try r.int(u16);
            for (0..count) |_| _ = try findTimbre(timbres, try r.byte(), try r.byte());
        }
    }
    const events = try readEvents(gpa, event_data orelse return error.InvalidMusicData);
    errdefer gpa.free(events);
    var programs: [16]u16 = @splat(findTimbre(timbres, 0, 0) catch view.instrument_none);
    var banks: [16]u8 = @splat(0);
    for (events) |*ev| switch (ev.kind) {
        .program => {
            ev.payload.program = if (ev.channel == 9) view.instrument_none else findTimbre(timbres, @intCast(ev.payload.program), banks[ev.channel]) catch view.instrument_none;
            programs[ev.channel] = ev.payload.program;
        },
        .control => if (ev.payload.control.cc == 114) {
            banks[ev.channel] = @intCast(ev.payload.control.value);
        },
        .duration_note => {
            const timbre = if (ev.channel == 9) try findTimbre(timbres, ev.payload.note.note, 127) else programs[ev.channel];
            if (timbre == view.instrument_none) return error.MissingXmiTimbre;
        },
        else => {},
    };
    var branches: std.ArrayList(Branch) = .empty;
    defer branches.deinit(gpa);
    if (branch_data.len != 0) {
        var r = binary.Reader{ .data = branch_data };
        const count = try r.int(u16);
        for (0..count) |_| {
            const label = try r.int(u16);
            const offset = try r.int(u32);
            var found = false;
            for (events, 0..) |ev, i| {
                if (ev.instr_index != offset) continue;
                for (branches.items) |b| if (b.label == label) return error.InvalidMusicData;
                try branches.append(gpa, .{ .label = label, .event = @intCast(i) });
                found = true;
                break;
            }
            if (!found) return error.InvalidXmiBranch;
        }
    }
    return .{ .events = events, .branches = try branches.toOwnedSlice(gpa) };
}

fn readForms(gpa: std.mem.Allocator, data: []const u8, timbres: []const Timbre, sequences: *std.ArrayList(Sequence), depth: u8) !void {
    if (depth > 4) return error.InvalidMusicData;
    var reader = binary.Reader{ .data = data };
    while (reader.pos < data.len) {
        const item = try chunk(&reader);
        if (std.mem.eql(u8, item.id, "FORM") or std.mem.eql(u8, item.id, "CAT ")) {
            if (item.data.len < 4) return error.InvalidMusicData;
            const form_type = item.data[0..4];
            if (std.mem.eql(u8, item.id, "FORM") and std.mem.eql(u8, form_type, "XMID")) {
                if (sequences.items.len >= 256) return error.InvalidMusicData;
                const seq = try readSequence(gpa, item.data[4..], timbres);
                errdefer {
                    gpa.free(seq.events);
                    gpa.free(seq.branches);
                }
                try sequences.append(gpa, seq);
            } else if (std.mem.eql(u8, item.id, "CAT ") or std.mem.eql(u8, form_type, "XDIR")) {
                try readForms(gpa, item.data[4..], timbres, sequences, depth + 1);
            }
        }
    }
}

const Source = struct {
    patches: []view.OplPatch,
    timbres: []Timbre,
    sequences: []Sequence,
    selected: u32 = 0,
    driver: midi.Driver,
    loops: [4]Loop = undefined,
    loop_depth: u8 = 0,
    cursor: usize = 0,
    tick: u32 = 0,
    elapsed: u32 = 0,
    fraction: u32 = 0,
    sample_rate: u32,
    last_instrument: u16 = 0,
    ended: bool = false,

    fn reset(self: *Source, chip: fmt.Chip) void {
        self.driver.channels = @splat(.{ .program = findTimbre(self.timbres, 0, 0) catch view.instrument_none });
        self.driver.reset(chip);
        self.last_instrument = 0;
        self.cursor = 0;
        self.tick = 0;
        self.elapsed = 0;
        self.fraction = 0;
        self.loop_depth = 0;
        self.ended = false;
    }

    pub fn selectArchiveTrack(self: *Source, _: std.mem.Allocator, index: u32, chip: fmt.Chip) !void {
        self.selected = @min(index, @as(u32, @intCast(self.sequences.len - 1)));
        self.reset(chip);
    }

    pub fn branch(self: *Source, label: u16, chip: fmt.Chip) bool {
        const seq = self.sequences[self.selected];
        for (seq.branches) |b| if (b.label == label) {
            self.driver.reset(chip);
            self.cursor = b.event;
            self.tick = seq.events[b.event].tick;
            self.elapsed = 0;
            self.loop_depth = 0;
            self.ended = false;
            return true;
        };
        return false;
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        if (self.ended) self.reset(chip);
        self.driver.advance(chip, self.elapsed);
        self.elapsed = 0;
        const seq = self.sequences[self.selected];
        var commands: u32 = 0;
        while (self.cursor < seq.events.len and commands < max_events_per_step) : (commands += 1) {
            const ev = seq.events[self.cursor];
            var delay = ev.tick -| self.tick;
            if (ev.kind == .end) delay = @max(delay, self.driver.nextRelease() orelse 0);
            if (delay > 0) {
                delay = @min(delay, self.driver.nextRelease() orelse delay);
                self.elapsed = delay;
                self.tick +|= delay;
                return .{ .frames = fmt.rescale(delay, 120, self.sample_rate, &self.fraction) };
            }
            self.cursor += 1;
            const ch = ev.channel;
            switch (ev.kind) {
                .duration_note => {
                    const note = ev.payload.note;
                    if (ch == 9) self.driver.channels[ch].program = findTimbre(self.timbres, note.note, 127) catch continue;
                    const index = self.driver.channels[ch].program;
                    if (index >= self.timbres.len) continue;
                    const trans = self.timbres[index].transpose;
                    const pitch: u8 = @intCast(std.math.clamp(if (ch == 9) @as(i16, @as(u8, @bitCast(trans))) else @as(i16, note.note) + trans, 0, 127));
                    if (self.driver.noteOnTuned(chip, ch, note.note, pitch, velocity_graph[note.velocity >> 3], note.duration_ticks)) self.last_instrument = index;
                },
                .note_off => self.driver.noteOff(chip, ch, ev.payload.note.note),
                .program => if (ch != 9) {
                    self.driver.channels[ch].program = ev.payload.program;
                },
                .pitch_bend => self.driver.bend(chip, ch, ev.payload.pitch_bend),
                .control => {
                    const c = ev.payload.control;
                    switch (c.cc) {
                        112 => self.driver.channels[ch].protected = c.value >= 64,
                        116 => {
                            if (self.loop_depth >= self.loops.len) {
                                self.ended = true;
                                return .{ .frames = 0, .done = true };
                            }
                            self.loops[self.loop_depth] = .{ .event = self.cursor, .tick = self.tick, .remaining = @intCast(c.value) };
                            self.loop_depth += 1;
                        },
                        117 => {
                            if (self.loop_depth == 0) continue;
                            const loop = &self.loops[self.loop_depth - 1];
                            if (c.value < 64 or loop.remaining == 1) self.loop_depth -= 1 else {
                                if (loop.remaining != 0) loop.remaining -= 1;
                                self.cursor = loop.event;
                                self.tick = loop.tick;
                                if (loop.remaining == 0) return .{ .frames = 0, .done = true };
                            }
                        },
                        110, 111, 113, 114, 115, 118, 119, 120 => {},
                        else => self.driver.control(chip, ch, c.cc, @intCast(c.value)),
                    }
                },
                .end => {
                    self.ended = true;
                    return .{ .frames = 0, .done = true };
                },
                else => {},
            }
        }
        if (commands == max_events_per_step and self.cursor < seq.events.len) return .{ .frames = 0 };
        self.ended = true;
        return .{ .frames = 0, .done = true };
    }

    pub fn durationFrames(self: *Source) u64 {
        return self.sequences[self.selected].duration;
    }

    pub fn info(self: *Source) fmt.TrackInfo {
        return .{ .format_name = format_name, .system = if (self.driver.opl3) "AIL / OPL3" else "AIL / OPL2", .opl3 = self.driver.opl3, .archive_track_count = @intCast(self.sequences.len), .archive_track_index = self.selected };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return .{ .tick = self.tick -| self.elapsed, .last_instrument = self.last_instrument, .flags = .{ .has_tick = true } };
    }

    pub fn sequenceState(self: *Source) view.SequenceStateBank {
        return self.driver.state();
    }

    pub fn sequenceView(self: *Source) view.SequenceView {
        const seq = self.sequences[self.selected];
        return .{ .ctx = self, .kind = .linear_midi, .track_count = 16, .channel_count = 16, .tick_rate = 120, .length_ticks = seq.events[seq.events.len - 1].tick, .track = track, .eventLexicon = eventLexicon, .eventAt = eventAt, .eventsInRange = eventsInRange, .event_count = @intCast(seq.events.len), .branch_count = @intCast(seq.branches.len), .branchAt = branchAt };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = @intCast(self.patches.len), .get = instrument };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        for (self.sequences) |seq| {
            gpa.free(seq.events);
            gpa.free(seq.branches);
        }
        gpa.free(self.sequences);
        gpa.free(self.patches);
        gpa.free(self.timbres);
        gpa.destroy(self);
    }
};

fn source(ptr: *anyopaque) *Source {
    return @ptrCast(@alignCast(ptr));
}
fn track(_: *anyopaque, index: u16) view.SequenceTrack {
    return .{ .channel = @intCast(index), .kind = if (index == 9) .drum else .melodic };
}
fn instrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self = source(ptr);
    if (index >= self.patches.len) return .{};
    const patch = self.patches[index];
    return .{ .name = binary.text(&self.timbres[index].name), .patch = if (patch.op_count == 4) .{ .opl_4op = patch } else .{ .opl_2op = patch } };
}
fn eventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self = source(ptr);
    const events = self.sequences[self.selected].events;
    return if (index < events.len) events[index] else .{};
}
fn branchAt(ptr: *anyopaque, index: u16) view.SequenceBranch {
    const self = source(ptr);
    const seq = self.sequences[self.selected];
    if (index >= seq.branches.len) return .{};
    const b = seq.branches[index];
    return .{ .label = b.label, .tick = seq.events[b.event].tick };
}
fn eventsInRange(ptr: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
    const self = source(ptr);
    const events = self.sequences[self.selected].events;
    var lo: usize = 0;
    var hi = events.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (events[mid].tick < tick0) lo = mid + 1 else hi = mid;
    }
    var range = view.EventRange{};
    while (lo < events.len and events[lo].tick < tick1) : (lo += 1) {
        if (range.written < dest.len) {
            dest[range.written] = events[lo];
            range.written += 1;
        }
        range.total_in_range += 1;
    }
    return range;
}

fn eventLexicon(_: *anyopaque, ev: view.SequenceEvent) view.EffectDesc {
    if (ev.payload != .control) return .{};
    return .{ .text = switch (ev.payload.control.cc) {
        7 => "Volume",
        10 => "Pan",
        11 => "Expression",
        64 => "Sustain",
        110 => "Channel lock",
        111 => "Channel protection",
        112 => "Voice protection",
        113 => "Timbre protection",
        114 => "Timbre bank",
        115 => "Indirect prefix",
        116 => "Loop count (0 repeats forever)",
        117 => "Loop next / break",
        118 => "Reset beat",
        119 => "Game callback",
        120 => "Branch label",
        else => "",
    } };
}

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) !?fmt.MusicSource {
    if (!recognizes(data)) return null;
    const bank = ctx.resource("xmi.timbres") orelse return error.MissingXmiBank;
    var timbres: std.ArrayList(Timbre) = .empty;
    defer timbres.deinit(gpa);
    var patches: std.ArrayList(view.OplPatch) = .empty;
    defer patches.deinit(gpa);
    var r = binary.Reader{ .data = bank };
    var opl3 = false;
    while (true) {
        const program = try r.byte();
        if (program == 255) break;
        const bank_id = try r.byte();
        const offset = try r.int(u32);
        if (program >= 128 or bank_id >= 128 or offset > bank.len or bank.len - offset < 14 or timbres.items.len >= 16384) return error.InvalidXmiBank;
        const p = bank[offset..];
        const size = fmt.readU16Le(p, 0);
        if (size != 14 and size != 25) return error.UnsupportedXmiTimbre;
        if (size > p.len) return error.InvalidXmiBank;
        const four_op = size == 25;
        opl3 = opl3 or four_op;
        try timbres.append(gpa, .{ .program = program, .bank = bank_id, .transpose = @bitCast(p[2]) });
        try patches.append(gpa, .{
            .ops = .{ fmt.operatorParams(p[3], p[4], p[5], p[6], p[7]), fmt.operatorParams(p[9], p[10], p[11], p[12], p[13]), if (four_op) fmt.operatorParams(p[14], p[15], p[16], p[17], p[18]) else .{}, if (four_op) fmt.operatorParams(p[20], p[21], p[22], p[23], p[24]) else .{} },
            .op_count = if (four_op) 4 else 2,
            .feedback = @truncate(p[8] >> 1),
            .feedback2 = if (four_op) @truncate(p[19] >> 1) else 0,
            .additive = p[8] & 1 != 0,
            .algorithm = if (four_op) ((p[8] & 1) << 1) | (p[19] & 1) else p[8] & 1,
        });
    }
    if (timbres.items.len == 0) return error.InvalidXmiBank;
    for (timbres.items) |*timbre| {
        _ = try std.mem.print(&timbre.name, "Bank {d}, program {d}, {s} {d}", .{ timbre.bank, timbre.program, if (timbre.bank == 127) "pitch" else "transpose", timbre.transpose });
    }
    var sequences: std.ArrayList(Sequence) = .empty;
    defer sequences.deinit(gpa);
    errdefer for (sequences.items) |seq| {
        gpa.free(seq.events);
        gpa.free(seq.branches);
    };
    try readForms(gpa, data, timbres.items, &sequences, 0);
    if (sequences.items.len == 0) return error.InvalidTrackIndex;
    const owned_timbres = try timbres.toOwnedSlice(gpa);
    errdefer gpa.free(owned_timbres);
    const owned_patches = try patches.toOwnedSlice(gpa);
    errdefer gpa.free(owned_patches);
    const self = try gpa.create(Source);
    errdefer gpa.destroy(self);
    const selected = @min(ctx.track_index, @as(u32, @intCast(sequences.items.len - 1)));
    self.* = .{ .timbres = owned_timbres, .patches = owned_patches, .sequences = try sequences.toOwnedSlice(gpa), .driver = .{ .patches = owned_patches, .opl3 = opl3 }, .sample_rate = ctx.sample_rate, .selected = selected };
    for (self.sequences, 0..) |*seq, i| {
        var probe = self.*;
        probe.selected = @intCast(i);
        probe.reset(fmt.noop_chip);
        seq.duration = fmt.measureByStepping(fmt.MusicSource.init(&probe, visualizer_name), fmt.noop_chip, ctx.sample_rate) orelse 0;
    }
    self.reset(ctx.chip);
    return fmt.MusicSource.init(self, visualizer_name);
}

// --- tests -------------------------------------------------------------------

test "XMI note releases run during waits and finite loops" {
    const gpa = std.testing.allocator;
    const events = try readEvents(gpa, &.{ 0xb0, 116, 2, 0x90, 60, 100, 30, 60, 0xb0, 117, 127, 0xff, 0x2f, 0 });
    defer gpa.free(events);
    var sequences = [_]Sequence{.{ .events = events, .branches = &.{} }};
    var patches = [_]view.OplPatch{.{}};
    var timbres = [_]Timbre{.{ .program = 0, .bank = 0, .transpose = 0 }};
    var self = Source{ .patches = &patches, .timbres = &timbres, .sequences = &sequences, .driver = .{ .patches = &patches }, .sample_rate = 48000 };
    self.reset(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 12000), self.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u16, 1), self.sequenceState().voice_count);
    try std.testing.expectEqual(@as(u64, 12000), self.step(fmt.noop_chip).frames);
    try std.testing.expect(!self.sequenceState().voices[0].keyed);
    try std.testing.expectEqual(@as(u64, 12000), self.step(fmt.noop_chip).frames);
    try std.testing.expectEqual(@as(u16, 1), self.sequenceState().voice_count);
    try std.testing.expect(self.sequenceState().voices[0].keyed);
    try std.testing.expectEqual(@as(u64, 12000), self.step(fmt.noop_chip).frames);
    try std.testing.expect(self.step(fmt.noop_chip).done);
}

const test_song = "FORM\x00\x00\x00\x2cXMIDRBRN\x00\x00\x00\x08\x01\x00\x03\x00\x05\x00\x00\x00EVNT\x00\x00\x00\x10" ++
    [_]u8{ 0x90, 60, 100, 120, 60, 0xb0, 120, 3, 0x90, 67, 90, 30, 60, 0xff, 0x2f, 0 };
const test_bank = [_]u8{ 0, 0, 12, 0, 0, 0, 255, 255, 0, 0, 0, 0, 14, 0, 0, 0x21, 0x4f, 0xf1, 0x53, 0, 6, 0x21, 0, 0xf1, 0x53, 0 };

test "XMI loads OPL3 timbres and publishes all four operators" {
    var bank = test_bank ++ [_]u8{ 0x22, 0x10, 0xf2, 0x54, 1, 7, 0x23, 0, 0xf3, 0x55, 2 };
    bank[12] = 25;
    var opal = @import("opal").Opal.init(48000);
    const chip = @import("../chip.zig").fromOpal(&opal);
    const src = (try load(std.testing.allocator, test_song, .{ .sample_rate = 48000, .chip = chip, .resources = &.{.{ .name = "xmi.timbres", .data = &bank }} })).?;
    defer src.deinit(std.testing.allocator);
    try std.testing.expect(src.info().opl3);
    const instruments = src.views().instruments.?;
    const patch = instruments.get(instruments.ctx, 0).patch.opl_4op;
    try std.testing.expectEqual(@as(u8, 1), patch.algorithm);
    try std.testing.expectEqual(@as(u3, 3), patch.feedback2);
    try std.testing.expectEqual(@as(u4, 3), patch.ops[3].mult);
    const step = src.step(chip);
    try std.testing.expectEqual(@as(u16, 1), src.sequenceState().?.voice_count);
    opal.flushWriteBuf();
    var left_peak: u16 = 0;
    var right_peak: u16 = 0;
    for (0..step.frames) |_| {
        const sample = opal.sample();
        left_peak = @max(left_peak, @abs(sample.left));
        right_peak = @max(right_peak, @abs(sample.right));
    }
    try std.testing.expect(left_peak > 0 and right_peak > 0);
    try std.testing.expectError(error.InvalidXmiBank, load(std.testing.allocator, test_song, .{ .sample_rate = 48000, .chip = fmt.noop_chip, .resources = &.{.{ .name = "xmi.timbres", .data = bank[0 .. bank.len - 1] }} }));
}

test "XMI directory container loads its sequences" {
    const gpa = std.testing.allocator;
    const cat_payload = 4 + test_song.len;
    const cat_chunk = 8 + cat_payload;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "FORM");
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(4 + cat_chunk), .big);
    try file.appendSlice(gpa, &len);
    try file.appendSlice(gpa, "XDIRCAT ");
    std.mem.writeInt(u32, &len, @intCast(cat_payload), .big);
    try file.appendSlice(gpa, &len);
    try file.appendSlice(gpa, "XMID");
    try file.appendSlice(gpa, test_song);
    const src = (try load(gpa, file.items, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .resources = &.{.{ .name = "xmi.timbres", .data = &test_bank }},
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), src.info().archive_track_count);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}

test "XMI same-tick run yields without ending the sequence" {
    const gpa = std.testing.allocator;
    const events = try gpa.alloc(view.SequenceEvent, max_events_per_step + 1);
    defer gpa.free(events);
    @memset(events, .{ .tick = 0, .kind = .program, .payload = .{ .program = 1 } });
    events[events.len - 1] = .{ .tick = 10, .kind = .end };
    var sequences = [_]Sequence{.{ .events = events, .branches = &.{} }};
    var patches = [_]view.OplPatch{.{}};
    var timbres = [_]Timbre{.{ .program = 0, .bank = 0, .transpose = 0 }};
    var self = Source{
        .patches = &patches,
        .timbres = &timbres,
        .sequences = &sequences,
        .driver = .{ .patches = &patches },
        .sample_rate = 44100,
    };
    const first = self.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(max_events_per_step, self.cursor);
}

test "XMI rejects incomplete events, unmatched loops and invalid branch offsets" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidMusicData, readEvents(gpa, &.{ 0x90, 60, 100, 0x81 }));
    try std.testing.expectError(error.InvalidXmiLoop, readEvents(gpa, &.{ 0xb0, 117, 127, 0xff, 0x2f, 0 }));
    var bad = test_song.*;
    bad[24] = 255;
    try std.testing.expectError(error.InvalidXmiBranch, load(gpa, &bad, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .resources = &.{.{ .name = "xmi.timbres", .data = &test_bank }} }));
}

test "XMI program events name timbre-table indices like voices and the bank" {
    const gpa = std.testing.allocator;
    var timbres = [_]Timbre{ .{ .program = 0x10, .bank = 0, .transpose = 0 }, .{ .program = 0x30, .bank = 0, .transpose = 0 } };
    const evnt = [_]u8{ 0xc0, 0x30, 0x90, 0x3c, 0x64, 0x78, 0x78, 0xc9, 0x10, 0xff, 0x2f, 0x00 };
    const form = "EVNT" ++ [_]u8{ 0, 0, 0, evnt.len } ++ evnt;
    const seq = try readSequence(gpa, form, &timbres);
    defer {
        gpa.free(seq.events);
        gpa.free(seq.branches);
    }
    try std.testing.expectEqual(view.SequenceEventKind.program, seq.events[0].kind);
    try std.testing.expectEqual(@as(u16, 1), seq.events[0].payload.program);
    try std.testing.expectEqual(view.SequenceEventKind.program, seq.events[2].kind);
    try std.testing.expectEqual(view.instrument_none, seq.events[2].payload.program);

    var sequences = [_]Sequence{seq};
    var patches = [_]view.OplPatch{ .{}, .{} };
    var self = Source{ .patches = &patches, .timbres = &timbres, .sequences = &sequences, .driver = .{ .patches = &patches }, .sample_rate = 44100 };
    self.reset(fmt.noop_chip);
    _ = self.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 1), self.driver.channels[0].program);
}

test "XMI bank select applies to later program changes, not to the selected timbre" {
    const gpa = std.testing.allocator;
    var timbres = [_]Timbre{ .{ .program = 5, .bank = 0, .transpose = 0 }, .{ .program = 5, .bank = 1, .transpose = 0 } };
    const evnt = [_]u8{ 0xc0, 0x05, 0xb0, 0x72, 0x01, 0x90, 0x3c, 0x64, 0x10, 0x10, 0xff, 0x2f, 0x00 };
    const form = "EVNT" ++ [_]u8{ 0, 0, 0, evnt.len } ++ evnt ++ [_]u8{0};
    const first = try readSequence(gpa, form, timbres[0..1]);
    gpa.free(first.events);
    gpa.free(first.branches);

    const seq = try readSequence(gpa, form, &timbres);
    defer {
        gpa.free(seq.events);
        gpa.free(seq.branches);
    }
    try std.testing.expectEqual(@as(u16, 0), seq.events[0].payload.program);
    var sequences = [_]Sequence{seq};
    var patches = [_]view.OplPatch{ .{}, .{} };
    var self = Source{ .patches = &patches, .timbres = &timbres, .sequences = &sequences, .driver = .{ .patches = &patches }, .sample_rate = 44100 };
    self.reset(fmt.noop_chip);
    _ = self.step(fmt.noop_chip);
    const state = self.sequenceState();
    try std.testing.expectEqual(@as(u16, 1), state.voice_count);
    try std.testing.expectEqual(@as(u16, 0), state.voices[0].program);
    try std.testing.expectEqual(@as(u16, 0), state.slots[0].program);
}

test "XMI playhead names the timbre of the last note that sounded" {
    const gpa = std.testing.allocator;
    var timbres = [_]Timbre{ .{ .program = 0x10, .bank = 0, .transpose = 0 }, .{ .program = 0x30, .bank = 0, .transpose = 0 } };
    const evnt = [_]u8{ 0xc0, 0x30, 0x90, 0x3c, 0x64, 0x78, 0x78, 0xff, 0x2f, 0x00 };
    const form = "EVNT" ++ [_]u8{ 0, 0, 0, evnt.len } ++ evnt;
    const seq = try readSequence(gpa, form, &timbres);
    defer {
        gpa.free(seq.events);
        gpa.free(seq.branches);
    }
    var sequences = [_]Sequence{seq};
    var patches = [_]view.OplPatch{ .{}, .{} };
    var self = Source{ .patches = &patches, .timbres = &timbres, .sequences = &sequences, .driver = .{ .patches = &patches }, .sample_rate = 44100 };
    self.reset(fmt.noop_chip);
    _ = self.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 1), self.playhead().last_instrument);
    self.reset(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 0), self.playhead().last_instrument);
}

test "XMI note velocity follows the AIL velocity table" {
    const Levels = struct {
        regs: [256]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg < 256) self.regs[reg] = value;
        }
        fn flush(_: *anyopaque) void {}
    };
    var levels: Levels = .{};
    const chip: fmt.Chip = .{ .ptr = &levels, .vtable = &.{ .writeReg = Levels.write, .flush = Levels.flush } };
    const gpa = std.testing.allocator;
    const events = try readEvents(gpa, &.{ 0x90, 60, 40, 30, 0x91, 67, 1, 30, 0xff, 0x2f, 0 });
    defer gpa.free(events);
    var sequences = [_]Sequence{.{ .events = events, .branches = &.{} }};
    var patches = [_]view.OplPatch{.{}};
    var timbres = [_]Timbre{.{ .program = 0, .bank = 0, .transpose = 0 }};
    var self = Source{ .patches = &patches, .timbres = &timbres, .sequences = &sequences, .driver = .{ .patches = &patches }, .sample_rate = 48000 };
    self.reset(chip);
    _ = self.step(chip);
    try std.testing.expectEqual(@as(u8, 15), levels.regs[0x43]);
    try std.testing.expectEqual(@as(u8, 22), levels.regs[0x44]);
    try std.testing.expectEqual(@as(u8, 97), self.sequenceState().voices[0].velocity);
}
