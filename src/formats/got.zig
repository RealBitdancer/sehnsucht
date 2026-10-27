//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "GOT";
pub const extensions = &.{".got"};
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

const header_bytes = 2;
const min_bytes = 9;
const game_hz: u32 = 120;
const title_hz: u32 = 140;
const max_ops_per_step: u32 = 4096;

const resource_names = [_][]const u8{
    "SONG1",   "SONG2",    "SONG3",  "SONG4",
    "SONG21",  "SONG22",   "SONG23", "SONG24",
    "SONG25",  "SONG31",   "SONG32", "SONG33",
    "SONG34",  "SONG35",   "SONG36", "OPENSONG",
    "WINSONG", "BOSSSONG", "MENU",
};

pub fn matchesPath(path: []const u8) bool {
    const base = fmt.basenameOf(path);
    for (resource_names) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

const Event = struct {
    delay: u16,
    reg: u8,
    val: u8,

    fn isEnd(self: Event) bool {
        return self.reg == 0 and self.val == 0;
    }
};

const Parsed = struct {
    stream: []const u8,
    loop_start: ?usize,
    total_ticks: u64,
    write_count: u32,
};

fn readEvent(stream: []const u8, pos: *usize) error{InvalidGot}!?Event {
    if (pos.* >= stream.len) return null;

    var delay: u16 = stream[pos.*];
    pos.* += 1;
    if (delay & 0x80 != 0) {
        if (pos.* >= stream.len) return error.InvalidGot;
        delay = ((delay & 0x7f) << 8) | stream[pos.*];
        pos.* += 1;
    }
    if (pos.* + 2 > stream.len) return error.InvalidGot;
    const reg = stream[pos.*];
    const val = stream[pos.* + 1];
    pos.* += 2;
    return .{ .delay = delay, .reg = reg, .val = val };
}

fn parse(data: []const u8) error{InvalidGot}!?Parsed {
    if (data.len < min_bytes) return null;
    if (!std.mem.eql(u8, data[data.len - 4 ..], &.{ 0, 0, 0, 0 })) return null;

    const header = fmt.readU16Le(data, 0);
    const stream = data[header_bytes..];

    var loop_start: ?usize = null;
    if (header != 0) {
        const off = (@as(usize, header) - 1) * 2;
        if (off < stream.len) loop_start = off;
    }

    var pos: usize = 0;
    var ticks: u64 = 0;
    var writes: u32 = 0;
    var saw_write = false;
    var loop_hit = loop_start == null;
    while (true) {
        const at = pos;
        const ev = (try readEvent(stream, &pos)) orelse return error.InvalidGot;
        if (loop_start == at) loop_hit = true;
        ticks += ev.delay;
        if (ev.isEnd()) {
            if (!saw_write or ticks == 0) return null;
            if (stream.len - pos > 1) return null;
            return .{
                .stream = stream,
                .loop_start = if (loop_hit and loop_start != at) loop_start else null,
                .total_ticks = ticks,
                .write_count = writes,
            };
        }
        saw_write = true;
        writes += 1;
    }
}

fn titleTickHz(name: []const u8) u32 {
    return if (std.ascii.eqlIgnoreCase(fmt.stemOf(name), "menu")) title_hz else game_hz;
}

const GotSource = struct {
    data: []const u8,
    pos: usize = 0,
    loop_start: ?usize,
    sample_rate: u32,
    tick_hz: u32,
    frac: u32 = 0,
    total_ticks: u64,
    write_count: u32,

    fn rewind(self: *GotSource) void {
        self.pos = self.loop_start orelse 0;
    }

    pub fn step(self: *GotSource, chip: fmt.Chip) fmt.StepResult {
        var ops: u32 = 0;
        while (self.pos < self.data.len) {
            var cur = self.pos;
            const ev = (readEvent(self.data, &cur) catch break) orelse break;
            self.pos = cur;
            ops += 1;

            if (ev.isEnd()) {
                self.rewind();
                if (ev.delay == 0) return .{ .frames = 0, .done = true };
                return .{
                    .frames = fmt.rescale(ev.delay, self.tick_hz, self.sample_rate, &self.frac),
                    .done = true,
                };
            }

            chip.writeReg(ev.reg, ev.val);
            if (ev.delay != 0) {
                return .{ .frames = fmt.rescale(ev.delay, self.tick_hz, self.sample_rate, &self.frac) };
            }
            if (ops >= max_ops_per_step) return .{ .frames = 0 };
        }
        self.rewind();
        return .{ .frames = 0, .done = true };
    }

    pub fn info(self: *GotSource) fmt.TrackInfo {
        return .{
            .format_name = "GOT",
            .opl3 = false,
            .system = "OPL2",
            .loop = self.loop_start != null,
        };
    }

    pub fn durationFrames(self: *GotSource) u64 {
        return self.total_ticks * self.sample_rate / self.tick_hz;
    }

    pub fn dumpView(self: *GotSource) view.DumpView {
        return .{
            .chip = .opl2,
            .write_count = self.write_count,
            .loop = if (self.loop_start) |off| .{ .unit = .byte, .offset = @intCast(off) } else null,
            .header_tick = self.tick_hz,
        };
    }

    pub fn deinit(self: *GotSource, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.destroy(self);
    }
};

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const parsed = (try parse(data)) orelse return null;

    const copy = try gpa.dupe(u8, parsed.stream);
    errdefer gpa.free(copy);
    const src = try gpa.create(GotSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .data = copy,
        .loop_start = parsed.loop_start,
        .sample_rate = ctx.sample_rate,
        .tick_hz = titleTickHz(ctx.name),
        .total_ticks = parsed.total_ticks,
        .write_count = parsed.write_count,
    };

    ctx.chip.writeReg(0x01, 0x20);
    ctx.chip.flush();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

fn loadGot(gpa: std.mem.Allocator, data: []const u8, name: []const u8) !fmt.MusicSource {
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".got",
        .name = name,
    })).?;
}

test "got loads a one-write file" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x01, 0x00 } ++ [_]u8{ 0x01, 0x20, 0x01 } ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const src = try loadGot(gpa, &data, "song1.got");
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("GOT", src.info().format_name);
    try std.testing.expectEqual(@as(u32, 1), src.views().dump.?.write_count);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(u64, 44100 / game_hz), src.durationFrames().?);
    try std.testing.expectEqual(@as(u64, 44100 / game_hz), src.step(fmt.noop_chip).frames);
    try std.testing.expect(src.step(fmt.noop_chip).done);

    const menu = try loadGot(gpa, &data, "MENU.GOT");
    defer menu.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 44100 / title_hz), menu.durationFrames().?);

    const once = [_]u8{ 0x00, 0x00 } ++ [_]u8{ 0x01, 0x20, 0x01 } ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const oneshot = try loadGot(gpa, &once, "oneshot.got");
    defer oneshot.deinit(gpa);
    try std.testing.expect(!oneshot.info().loop);
}

test "got rejects short, save-like, and zero-time files" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".got", .name = "x.got" };
    try std.testing.expect(try load(gpa, &.{ 1, 0, 0, 0, 0 }, ctx) == null);
    var slot: [32]u8 = @splat(0);
    @memcpy(slot[0..4], "THOR");
    try std.testing.expect(try load(gpa, &slot, ctx) == null);
    const no_footer = [_]u8{ 0x01, 0x00, 0x01, 0x20, 0x01, 0x00, 0x00, 0x00, 0x01 };
    try std.testing.expect(try load(gpa, &no_footer, ctx) == null);
    const zero_time = [_]u8{ 0x01, 0x00 } ++ [_]u8{ 0x00, 0x20, 0x01 } ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(try load(gpa, &zero_time, ctx) == null);
}

test "got loop offset restarts after the intro" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x04, 0x00 } ++
        [_]u8{ 0x01, 0x20, 0x01 } ++
        [_]u8{ 0x01, 0x21, 0x02 } ++
        [_]u8{ 0x01, 0x22, 0x03 } ++
        [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const src = try loadGot(gpa, &data, "song.got");
    defer src.deinit(gpa);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(u32, 3), src.views().dump.?.write_count);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}
