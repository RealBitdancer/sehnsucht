//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");

pub const format_name = "BAM";
pub const extensions = &.{".bam"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };

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
    keyed: [max_voices]bool = @splat(false),
    last_freq: [max_voices]u8 = @splat(0),
    events: []view.SequenceEvent = &.{},
    markers: []view.SequenceMarker = &.{},
    label_at: [max_slots]u32 = @splat(0),
    instruments: []Patch,
    programs: [max_voices]u16 = @splat(view.sequence_unassigned),
    used_voices: [max_voices]bool,
    current_event: u32 = 0,
    last_instrument: u16 = 0,

    const max_ops_per_step: u32 = 4096;

    fn rewind(self: *BamSource) void {
        self.pos = 0;
        self.chorus_ret = null;
        self.labels = freshLabels();
        self.last_b0 = @splat(0);
        self.keyed = @splat(false);
        self.last_freq = @splat(0);
        self.programs = @splat(view.sequence_unassigned);
        self.current_event = 0;
    }

    fn keyOn(self: *BamSource, chip: fmt.Chip, voice: u4, index: u8) void {
        if (@as(u8, voice) >= max_voices) return;
        const freq = note_freq[@min(index, note_freq.len - 1)];
        const b0: u8 = @intCast(freq >> 8);
        self.last_b0[voice] = b0;
        self.keyed[voice] = true;
        self.last_freq[voice] = index;
        chip.writeReg(Reg.fnum_lo + voice, @truncate(freq));
        chip.writeReg(Reg.key_block + voice, b0 | Reg.key_on);
    }

    fn keyOff(self: *BamSource, chip: fmt.Chip, voice: u4) void {
        if (@as(u8, voice) >= max_voices) return;
        self.keyed[voice] = false;
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
            self.current_event = self.eventIndex(self.pos);
            self.pos = cur;
            ops += 1;

            switch (ev) {
                .stop => {
                    self.rewind();
                    return .{ .frames = 0, .done = true };
                },
                .start_note => |n| self.keyOn(chip, n.voice, n.freq),
                .stop_note => |voice| self.keyOff(chip, voice),
                .set_instrument => |ins| {
                    ins.patch.apply(chip, ins.voice);
                    if (ins.voice < max_voices) {
                        const program = self.events[self.current_event].payload.program;
                        self.programs[ins.voice] = program;
                        self.last_instrument = program;
                    }
                },
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
        };
    }

    fn eventIndex(self: *const BamSource, pos: usize) u32 {
        var lo: usize = 0;
        var hi = self.events.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.events[mid].instr_index < pos + magic.len) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, self.events.len -| 1));
    }

    pub fn playhead(self: *BamSource) view.Playhead {
        return .{
            .tick = self.current_event,
            .last_instrument = self.last_instrument,
            .flags = .{ .has_tick = true },
        };
    }

    pub fn instrumentBank(self: *BamSource) view.InstrumentBank {
        return .{ .ctx = self, .count = @intCast(self.instruments.len), .get = bamInstrument };
    }

    pub fn sequenceState(self: *BamSource) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = max_voices };
        for (0..max_voices) |i| {
            bank.slots[i] = .{
                .program = self.programs[i],
                .note = self.last_freq[i],
                .keyed = self.keyed[i],
                .opl_voice = @intCast(i),
            };
        }
        return bank;
    }

    pub fn sequenceView(self: *BamSource) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .event_stream,
            .position_unit = .event_index,
            .track_count = max_voices,
            .channel_count = max_voices,
            .tick_rate = tick_hz,
            .length_ticks = if (self.events.len == 0) 0 else self.events[self.events.len - 1].tick,
            .track = bamTrack,
            .eventAt = bamEventAt,
            .labelTable = bamLabelTable,
            .event_count = @intCast(self.events.len),
            .marker_count = @intCast(self.markers.len),
            .markerAt = bamMarkerAt,
        };
    }

    pub fn deinit(self: *BamSource, gpa: std.mem.Allocator) void {
        gpa.free(self.instruments);
        gpa.free(self.events);
        gpa.free(self.markers);
        gpa.free(self.song);
        gpa.destroy(self);
    }
};

fn bamTrack(ptr: *anyopaque, index: u16) view.SequenceTrack {
    const self: *BamSource = @ptrCast(@alignCast(ptr));
    if (index >= max_voices) return .{};
    return .{
        .channel = @intCast(index),
        .in_use = self.used_voices[index],
    };
}

fn bamInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self: *BamSource = @ptrCast(@alignCast(ptr));
    if (index >= self.instruments.len) return .{};
    const p = self.instruments[index];
    return .{ .patch = .{ .opl_2op = .{
        .ops = .{
            fmt.operatorParams(p.mod_char, p.mod_level, p.mod_ad, p.mod_sr, p.mod_wave),
            fmt.operatorParams(p.car_char, p.car_level, p.car_ad, p.car_sr, p.car_wave),
            .{},
            .{},
        },
        .feedback = @truncate(p.feedback >> 1),
        .additive = p.feedback & 1 != 0,
    } } };
}

fn bamEventAt(ptr: *anyopaque, index: u32) view.SequenceEvent {
    const self: *BamSource = @ptrCast(@alignCast(ptr));
    if (index >= self.events.len) return .{};
    return self.events[index];
}

fn bamMarkerAt(ptr: *anyopaque, index: u32) view.SequenceMarker {
    const self: *BamSource = @ptrCast(@alignCast(ptr));
    return if (index < self.markers.len) self.markers[index] else .{};
}

fn bamLabelTable(ptr: *anyopaque, label: u16) u32 {
    const self: *BamSource = @ptrCast(@alignCast(ptr));
    if (label >= max_slots) return std.math.maxInt(u32);
    return self.label_at[label];
}

fn indexBam(gpa: std.mem.Allocator, song: []const u8) !struct {
    events: []view.SequenceEvent,
    markers: []view.SequenceMarker,
    label_at: [max_slots]u32,
    instruments: []Patch,
    used_voices: [max_voices]bool,
} {
    var instruments: std.ArrayList(Patch) = .empty;
    defer instruments.deinit(gpa);
    var patch_ids: std.AutoHashMap([patch_bytes]u8, u16) = .init(gpa);
    defer patch_ids.deinit();
    var used_voices: [max_voices]bool = @splat(false);
    var list: std.ArrayList(view.SequenceEvent) = .empty;
    errdefer list.deinit(gpa);
    var label_at: [max_slots]u32 = @splat(std.math.maxInt(u32));
    label_at[0] = 0;

    var pos: usize = 0;
    var score_tick: u32 = 0;
    while (pos < song.len) {
        const start = pos;
        const ev = (try readEvent(song, &pos)) orelse break;
        const base = view.SequenceEvent{
            .tick = score_tick,
            .instr_index = @intCast(start + magic.len),
        };
        switch (ev) {
            .nop => {},
            .wait => |ticks| {
                try list.append(gpa, .{
                    .tick = base.tick,
                    .instr_index = base.instr_index,
                    .track = view.sequence_unassigned,
                    .kind = .wait,
                    .payload = .{ .wait = ticks },
                });
                score_tick +|= ticks;
            },
            .stop => try list.append(gpa, .{
                .tick = base.tick,
                .instr_index = base.instr_index,
                .track = view.sequence_unassigned,
                .kind = .end,
            }),
            .start_note => |n| try list.append(gpa, .{
                .tick = base.tick,
                .instr_index = base.instr_index,
                .track = n.voice,
                .channel = n.voice,
                .kind = .note_on,
                .payload = .{ .note = .{ .note = n.freq, .velocity = 127 } },
            }),
            .stop_note => |voice| try list.append(gpa, .{
                .tick = base.tick,
                .instr_index = base.instr_index,
                .track = voice,
                .channel = voice,
                .kind = .note_off,
                .payload = .{ .note = .{ .note = 255, .velocity = 0 } },
            }),
            .set_instrument => |ins| {
                const entry = try patch_ids.getOrPut(std.mem.toBytes(ins.patch));
                if (!entry.found_existing) {
                    if (instruments.items.len == std.math.maxInt(u16)) return error.InvalidBam;
                    entry.value_ptr.* = @intCast(instruments.items.len);
                    try instruments.append(gpa, ins.patch);
                }
                try list.append(gpa, .{
                    .tick = base.tick,
                    .instr_index = base.instr_index,
                    .track = ins.voice,
                    .channel = ins.voice,
                    .kind = .program,
                    .payload = .{ .program = entry.value_ptr.* },
                });
            },
            .set_label => |id| {
                label_at[id] = @intCast(list.items.len);
                try list.append(gpa, .{
                    .tick = base.tick,
                    .instr_index = base.instr_index,
                    .track = view.sequence_unassigned,
                    .kind = .label,
                    .payload = .{ .label = id },
                });
            },
            .jump => |j| try list.append(gpa, .{
                .tick = base.tick,
                .instr_index = base.instr_index,
                .track = view.sequence_unassigned,
                .kind = .jump,
                .payload = .{ .branch = .{
                    .target = j.label,
                    .kind = switch (j.how) {
                        .leave => .skip,
                        .song_loop => .loop,
                        .chorus => .call,
                        .times => .jump,
                    },
                    .repeats = if (j.how == .times) j.how.times else 0,
                } },
            }),
            .end_chorus => try list.append(gpa, .{
                .tick = base.tick,
                .instr_index = base.instr_index,
                .track = view.sequence_unassigned,
                .kind = .jump,
                .payload = .{ .branch = .{ .kind = .ret } },
            }),
        }
    }
    var markers: std.ArrayList(view.SequenceMarker) = .empty;
    errdefer markers.deinit(gpa);
    const start_labelled = list.items.len != 0 and list.items[0].kind == .label and list.items[0].payload.label == 0;
    if (!start_labelled) try markers.append(gpa, .{ .event = .{
        .track = view.sequence_unassigned,
        .kind = .label,
        .payload = .{ .label = 0 },
    } });
    for (list.items, 0..) |event, i| {
        if (event.track < max_voices) used_voices[event.track] = true;
        switch (event.kind) {
            .label, .jump, .end => try markers.append(gpa, .{ .position = @intCast(i), .event = event }),
            else => {},
        }
    }
    const patches = try instruments.toOwnedSlice(gpa);
    errdefer gpa.free(patches);
    const marker_slice = try markers.toOwnedSlice(gpa);
    errdefer gpa.free(marker_slice);
    return .{
        .instruments = patches,
        .used_voices = used_voices,
        .events = try list.toOwnedSlice(gpa),
        .markers = marker_slice,
        .label_at = label_at,
    };
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    const body = data[magic.len..];
    const loop = try scan(body);

    const song = try gpa.dupe(u8, body);
    errdefer gpa.free(song);
    const indexed = try indexBam(gpa, song);
    errdefer gpa.free(indexed.events);
    errdefer gpa.free(indexed.markers);
    errdefer gpa.free(indexed.instruments);
    const src = try gpa.create(BamSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .song = song,
        .sample_rate = ctx.sample_rate,
        .loop = loop,
        .events = indexed.events,
        .markers = indexed.markers,
        .instruments = indexed.instruments,
        .used_voices = indexed.used_voices,
        .label_at = indexed.label_at,
    };

    ctx.chip.writeReg(Reg.waveform_select, 0x20);
    ctx.chip.flush();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

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
    try std.testing.expectEqualStrings("sequence", src.info().visualizer);
    const sv = src.views().sequence.?;
    try std.testing.expectEqual(view.SequenceKind.event_stream, sv.kind);
    try std.testing.expect(sv.event_count >= 2);
    try std.testing.expectEqual(view.SequenceEventKind.wait, sv.eventAt.?(sv.ctx, 0).kind);
    try std.testing.expectEqual(view.sequence_unassigned, sv.eventAt.?(sv.ctx, 0).track);
    try std.testing.expectEqual(view.SequenceEventKind.end, sv.eventAt.?(sv.ctx, 1).kind);
    try std.testing.expectEqual(view.sequence_unassigned, sv.eventAt.?(sv.ctx, 1).track);
    const st = src.sequenceState() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, max_voices), st.channels);
    try std.testing.expect(!src.info().loop);
    try std.testing.expectEqual(@as(u64, 44100 / tick_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}

test "BAM instrument events share identical patches and retain live assignments" {
    const a = [_]u8{ 1, 0, 0xf0, 0x77, 0, 1, 0, 0xf0, 0x77, 0, 2 };
    const b = [_]u8{ 2, 0, 0xf0, 0x77, 0, 1, 0, 0xf0, 0x77, 0, 2 };
    const data = magic ++ [_]u8{0x30} ++ a ++ [_]u8{0x31} ++ a ++ [_]u8{0x30} ++ b ++ [_]u8{ wait1, 0 };
    const src = try loadBam(std.testing.allocator, data);
    defer src.deinit(std.testing.allocator);
    const views = src.views();
    try std.testing.expectEqual(@as(u16, 2), views.instruments.?.count);
    const seq = views.sequence.?;
    try std.testing.expectEqual(seq.eventAt.?(seq.ctx, 0).payload.program, seq.eventAt.?(seq.ctx, 1).payload.program);
    _ = src.step(fmt.noop_chip);
    const state = src.sequenceState().?;
    try std.testing.expectEqual(@as(u16, 1), state.slots[0].program);
    try std.testing.expectEqual(@as(u16, 0), state.slots[1].program);
    try std.testing.expectEqual(@as(u16, 1), src.playhead().?.last_instrument);
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

test "bam publishes labels, jumps, returns, and the stop as structure markers" {
    const gpa = std.testing.allocator;
    const data = magic ++ [_]u8{ label1, 0x10, 40, wait1, wait1, jump1, 2, 0x70, wait1, 0x00 };
    const src = try loadBam(gpa, data);
    defer src.deinit(gpa);
    const sv = src.views().sequence.?;
    try std.testing.expectEqual(@as(u32, 5), sv.marker_count);
    const at = sv.markerAt.?;
    try std.testing.expectEqual(@as(u16, 0), at(sv.ctx, 0).event.payload.label);
    try std.testing.expectEqual(@as(u16, 1), at(sv.ctx, 1).event.payload.label);
    try std.testing.expectEqual(@as(u32, 0), at(sv.ctx, 1).position);
    const jump = at(sv.ctx, 2);
    try std.testing.expectEqual(@as(u32, 4), jump.position);
    try std.testing.expectEqual(@as(u16, 2), jump.event.payload.branch.repeats);
    try std.testing.expectEqual(.ret, at(sv.ctx, 3).event.payload.branch.kind);
    try std.testing.expectEqual(view.SequenceEventKind.end, at(sv.ctx, 4).event.kind);
    try std.testing.expectEqual(@as(u32, 7), at(sv.ctx, 4).position);
    try std.testing.expectEqual(view.SequenceEvent{}, at(sv.ctx, 5).event);
}

test "bam marks the implicit start label only when the file does not set it" {
    const gpa = std.testing.allocator;
    const explicit = try loadBam(gpa, magic ++ [_]u8{ label0, wait1, jump0, Jump.song_loop_code, 0x00 });
    defer explicit.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), explicit.views().sequence.?.marker_count);
    const implicit = try loadBam(gpa, magic ++ [_]u8{ wait1, jump0, Jump.song_loop_code, 0x00 });
    defer implicit.deinit(gpa);
    const sv = implicit.views().sequence.?;
    try std.testing.expectEqual(@as(u32, 3), sv.marker_count);
    try std.testing.expectEqual(view.SequenceEventKind.label, sv.markerAt.?(sv.ctx, 0).event.kind);
    try std.testing.expectEqual(.loop, sv.markerAt.?(sv.ctx, 1).event.payload.branch.kind);
}

test "bam events carry score ticks summed from waits" {
    const gpa = std.testing.allocator;
    const src = try loadBam(gpa, magic ++ [_]u8{ 0x10, 40, 130, 0x20, wait1, 0x00 });
    defer src.deinit(gpa);
    const sv = src.views().sequence.?;
    const at = sv.eventAt.?;
    try std.testing.expectEqual(@as(u32, 0), at(sv.ctx, 0).tick);
    try std.testing.expectEqual(@as(u32, 0), at(sv.ctx, 1).tick);
    try std.testing.expectEqual(@as(u32, 3), at(sv.ctx, 2).tick);
    try std.testing.expectEqual(@as(u32, 4), at(sv.ctx, 4).tick);
    try std.testing.expectEqual(@as(u32, 4), sv.length_ticks);
    try std.testing.expect(sv.position_unit == .event_index);
}

test "bam events carry file offsets and the playhead still finds them" {
    const gpa = std.testing.allocator;
    const src = try loadBam(gpa, magic ++ [_]u8{ 0x10, 40, wait1, 0x00 });
    defer src.deinit(gpa);
    const sv = src.views().sequence.?;
    const at = sv.eventAt.?;
    try std.testing.expectEqual(@as(u32, 4), at(sv.ctx, 0).instr_index);
    try std.testing.expectEqual(@as(u32, 6), at(sv.ctx, 1).instr_index);
    try std.testing.expectEqual(@as(u32, 7), at(sv.ctx, 2).instr_index);
    _ = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u32, 1), src.playhead().?.tick);
}
