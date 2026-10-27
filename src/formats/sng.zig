//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "SNGPlay";
pub const extensions = &.{".sng"};
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

const magic = "ObsM";
const header_bytes = 12;
const tick_hz: u32 = 70;
const max_ops_per_step: u32 = 4096;

const Record = extern struct {
    val: u8,
    reg: u8,

    comptime {
        if (@sizeOf(Record) != 2) @compileError("SNG record must be two bytes");
    }

    fn isDelay(self: Record) bool {
        return self.reg == 0;
    }

    fn ticks(self: Record, compressed: bool) u64 {
        if (compressed and self.val != 0) return self.val;
        return 1;
    }
};

const Parsed = struct {
    stream: []const u8,
    start: usize,
    loop: usize,
    intro_ticks: u8,
    compressed: bool,
    total_ticks: u64,
    write_count: u32,
    loop_writes: u32,
};

fn countWrites(records: []const Record) u32 {
    var n: u32 = 0;
    for (records) |rec| {
        if (!rec.isDelay()) n += 1;
    }
    return n;
}

fn measurePass(records: []const Record, start: usize, loop: usize, intro_ticks: u8, compressed: bool) error{InvalidSng}!u64 {
    var pos = start;
    var ticks: u64 = intro_ticks;
    var wrapped = false;
    var ops: u32 = 0;
    const cap: u32 = @intCast(records.len * 2 + 2);
    while (ops < cap) : (ops += 1) {
        const rec = records[pos];
        pos += 1;
        if (pos >= records.len) {
            pos = loop;
            wrapped = true;
        }
        if (rec.isDelay()) {
            ticks += rec.ticks(compressed);
            if (wrapped) return ticks;
            continue;
        }
    }
    return error.InvalidSng;
}

fn parse(data: []const u8) error{InvalidSng}!?Parsed {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    if (data.len < header_bytes) return error.InvalidSng;

    const claimed: usize = fmt.readU16Le(data, 4);
    const start_bytes: usize = fmt.readU16Le(data, 6);
    const loop_bytes: usize = fmt.readU16Le(data, 8);
    const intro = data[10];
    const compressed = data[11] != 0;

    const body = data[header_bytes..];
    const take = @min(claimed, body.len) / 2 * 2;
    if (take < @sizeOf(Record)) return error.InvalidSng;

    const records = std.mem.bytesAsSlice(Record, body[0..take]);
    const start = start_bytes / 2;
    const loop = loop_bytes / 2;
    if (start >= records.len or loop >= records.len) return error.InvalidSng;

    const intro_ticks: u8 = if (compressed) intro else 0;
    const total_ticks = try measurePass(records, start, loop, intro_ticks, compressed);
    return .{
        .stream = body[0..take],
        .start = start,
        .loop = loop,
        .intro_ticks = intro_ticks,
        .compressed = compressed,
        .total_ticks = total_ticks,
        .write_count = countWrites(records),
        .loop_writes = countWrites(records[0..loop]),
    };
}

const SngSource = struct {
    records: []const Record,
    pos: usize,
    loop: usize,
    intro_ticks: u8,
    compressed: bool,
    sample_rate: u32,
    frac: u32 = 0,
    total_ticks: u64,
    write_count: u32,
    loop_writes: u32,

    fn framesFor(self: *SngSource, ticks: u64) u64 {
        return fmt.rescale(ticks, tick_hz, self.sample_rate, &self.frac);
    }

    fn advance(self: *SngSource) bool {
        self.pos += 1;
        if (self.pos < self.records.len) return false;
        self.pos = self.loop;
        return true;
    }

    pub fn step(self: *SngSource, chip: fmt.Chip) fmt.StepResult {
        if (self.intro_ticks != 0) {
            const ticks: u64 = self.intro_ticks;
            self.intro_ticks = 0;
            return .{ .frames = self.framesFor(ticks) };
        }

        var ops: u32 = 0;
        var wrapped = false;
        while (ops < max_ops_per_step) : (ops += 1) {
            const rec = self.records[self.pos];
            if (self.advance()) wrapped = true;
            if (rec.isDelay()) {
                return .{
                    .frames = self.framesFor(rec.ticks(self.compressed)),
                    .done = wrapped,
                };
            }
            chip.writeReg(rec.reg, rec.val);
        }
        return .{ .frames = 0, .done = wrapped };
    }

    pub fn info(_: *SngSource) fmt.TrackInfo {
        return .{
            .format_name = format_name,
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
        };
    }

    pub fn durationFrames(self: *SngSource) u64 {
        return self.total_ticks * self.sample_rate / tick_hz;
    }

    pub fn dumpView(self: *SngSource) view.DumpView {
        return .{
            .chip = .opl2,
            .write_count = self.write_count,
            .loop = .{ .unit = .write, .offset = self.loop_writes },
            .header_tick = tick_hz,
        };
    }

    pub fn deinit(self: *SngSource, gpa: std.mem.Allocator) void {
        gpa.free(self.records);
        gpa.destroy(self);
    }
};

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const parsed = (try parse(data)) orelse return null;

    const n = parsed.stream.len / @sizeOf(Record);
    const records = try gpa.alloc(Record, n);
    errdefer gpa.free(records);
    @memcpy(std.mem.sliceAsBytes(records), parsed.stream);

    const src = try gpa.create(SngSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .records = records,
        .pos = parsed.start,
        .loop = parsed.loop,
        .intro_ticks = parsed.intro_ticks,
        .compressed = parsed.compressed,
        .sample_rate = ctx.sample_rate,
        .total_ticks = parsed.total_ticks,
        .write_count = parsed.write_count,
        .loop_writes = parsed.loop_writes,
    };

    ctx.chip.writeReg(0x01, 0x20);
    ctx.chip.flush();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

fn header(length: u16, start: u16, loop: u16, delay: u8, compressed: u8) [header_bytes]u8 {
    var h: [header_bytes]u8 = undefined;
    @memcpy(h[0..4], magic);
    std.mem.writeInt(u16, h[4..6], length, .little);
    std.mem.writeInt(u16, h[6..8], start, .little);
    std.mem.writeInt(u16, h[8..10], loop, .little);
    h[10] = delay;
    h[11] = compressed;
    return h;
}

fn loadSng(gpa: std.mem.Allocator, data: []const u8) !fmt.MusicSource {
    return (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".sng",
        .name = "tune.sng",
    })).?;
}

const tick_frames: u64 = 44100 / tick_hz;

const Capture = struct {
    regs: [16]u16 = @splat(0),
    vals: [16]u8 = @splat(0),
    n: usize = 0,

    fn writeReg(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        if (self.n >= self.regs.len) return;
        self.regs[self.n] = reg;
        self.vals[self.n] = val;
        self.n += 1;
    }

    fn flush(_: *anyopaque) void {}

    const vtable = fmt.Chip.VTable{ .writeReg = writeReg, .flush = flush };

    fn chip(self: *Capture) fmt.Chip {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "sng loads a one-write compressed file" {
    const gpa = std.testing.allocator;
    const data = header(8, 0, 0, 0, 1) ++ [_]u8{
        0x20, 0x01,
        0x02, 0x00,
        0x21, 0x02,
        0x01, 0x00,
    };
    const src = try loadSng(gpa, &data);
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("SNGPlay", src.info().format_name);
    try std.testing.expectEqualStrings("stream", src.info().visualizer);
    try std.testing.expect(src.info().loop);
    try std.testing.expectEqual(@as(u32, 2), src.views().dump.?.write_count);
    try std.testing.expectEqual(tick_hz, src.views().dump.?.header_tick);
    try std.testing.expectEqual(3 * tick_frames, src.durationFrames().?);

    var cap: Capture = .{};
    const first = src.step(cap.chip());
    try std.testing.expectEqual(2 * tick_frames, first.frames);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(@as(usize, 1), cap.n);
    try std.testing.expectEqual(@as(u16, 0x01), cap.regs[0]);
    try std.testing.expectEqual(@as(u8, 0x20), cap.vals[0]);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    try std.testing.expect(!src.step(fmt.noop_chip).done);
}

test "sng start skips records and wrap keeps playing from the loop" {
    const gpa = std.testing.allocator;
    const data = header(12, 4, 4, 0, 0) ++ [_]u8{
        0xaa, 0x20,
        0x01, 0x00,
        0xbb, 0x21,
        0x01, 0x00,
        0xcc, 0x22,
        0x01, 0x00,
    };
    const src = try loadSng(gpa, &data);
    defer src.deinit(gpa);

    var cap: Capture = .{};
    try std.testing.expect(!src.step(cap.chip()).done);
    try std.testing.expectEqual(@as(usize, 1), cap.n);
    try std.testing.expectEqual(@as(u16, 0x21), cap.regs[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), cap.vals[0]);
    try std.testing.expect(src.step(fmt.noop_chip).done);
    cap = .{};
    try std.testing.expect(!src.step(cap.chip()).done);
    try std.testing.expectEqual(@as(u16, 0x21), cap.regs[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), cap.vals[0]);
}

test "sng rejects other sng formats and truncated ObsM" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".sng", .name = "x.sng" };
    try std.testing.expect(try load(gpa, "FMC!", ctx) == null);
    try std.testing.expect(try load(gpa, "nots", ctx) == null);
    try std.testing.expectError(error.InvalidSng, load(gpa, magic, ctx));
    try std.testing.expectError(error.InvalidSng, load(gpa, magic ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, ctx));
    const past_end = header(2, 4, 0, 0, 0) ++ [_]u8{ 0x01, 0x00 };
    try std.testing.expectError(error.InvalidSng, load(gpa, &past_end, ctx));
    const loop_past = header(2, 0, 4, 0, 0) ++ [_]u8{ 0x01, 0x00 };
    try std.testing.expectError(error.InvalidSng, load(gpa, &loop_past, ctx));
    const writes_only = header(4, 0, 0, 0, 0) ++ [_]u8{ 0x20, 0x01, 0x21, 0x02 };
    try std.testing.expectError(error.InvalidSng, load(gpa, &writes_only, ctx));
}

test "sng is claimed by extension" {
    try std.testing.expect(fmt.isPlayablePath("tune.sng"));
    try std.testing.expect(fmt.isPlayablePath("TUNE.SNG"));
}

test "sng loop offset counts the register writes before the loop record" {
    const gpa = std.testing.allocator;
    const data = header(10, 0, 6, 0, 0) ++ [_]u8{
        0x01, 0x00,
        0x20, 0x01,
        0x01, 0x00,
        0x30, 0xa0,
        0x01, 0x00,
    };
    const src = try loadSng(gpa, &data);
    defer src.deinit(gpa);
    const loop = src.views().dump.?.loop.?;
    try std.testing.expectEqual(@as(u32, 1), loop.offset);
    try std.testing.expectEqual(@as(u32, 2), src.views().dump.?.write_count);
}
