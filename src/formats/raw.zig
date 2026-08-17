//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

pub const visualizer_name = "stream";

const magic = "RAWADATA";
const header_bytes = 10;
const pit_hz: u32 = 1_193_180;

const Record = extern struct {
    param: u8,
    command: u8,

    comptime {
        if (@sizeOf(Record) != 2) @compileError("RAW record must be two bytes");
    }
};

const Command = enum(u8) {
    delay = 0,
    control = 2,
    end = 0xff,
    _,
};

const RawSource = struct {
    records: []const Record,
    pos: usize = 0,
    sample_rate: u32,
    speed: u16,
    bank: u16 = 0,
    frac: u32 = 0,
    title: ?[]const u8,
    title_embedded: bool,
    artist: ?[]const u8,

    fn framesForTicks(self: *RawSource, ticks: u64) u64 {
        const speed = @max(@as(u32, 1), self.speed);
        // frames = ticks * sample_rate * speed / pit_hz, with fractional carry
        // via rescale(ticks * speed, pit_hz, sample_rate).
        return fmt.rescale(ticks * speed, pit_hz, self.sample_rate, &self.frac);
    }

    const max_ops_per_step: u32 = 4096;

    pub fn step(self: *RawSource, chip: fmt.Chip) fmt.StepResult {
        var ops: u32 = 0;
        while (self.pos < self.records.len) {
            const rec = self.records[self.pos];
            self.pos += 1;
            ops += 1;

            switch (@as(Command, @enumFromInt(rec.command))) {
                .delay => {
                    const ticks: u64 = if (rec.param == 0) 256 else rec.param;
                    return .{ .frames = self.framesForTicks(ticks) };
                },
                .control => {
                    if (rec.param == 0) {
                        if (self.pos >= self.records.len) break;
                        const next = self.records[self.pos];
                        self.pos += 1;
                        ops += 1;
                        self.speed = @as(u16, next.param) | (@as(u16, next.command) << 8);
                        if (self.speed == 0) self.speed = 0xffff;
                    } else {
                        self.bank = @as(u16, rec.param -% 1) * 0x100;
                    }
                },
                .end => {
                    if (rec.param == 0xff) break;
                    const addr = self.bank + rec.command;
                    chip.writeReg(addr, chip_adapter.withStereoC0(addr, rec.param));
                },
                _ => {
                    const addr = self.bank + rec.command;
                    chip.writeReg(addr, chip_adapter.withStereoC0(addr, rec.param));
                },
            }
            if (ops >= max_ops_per_step) return .{ .frames = 0 };
        }
        self.pos = 0;
        self.bank = 0;
        return .{ .frames = 0, .done = true };
    }

    pub fn info(self: *RawSource) fmt.TrackInfo {
        return .{
            .title = self.title,
            .title_embedded = self.title_embedded,
            .artist = self.artist,
            .format_name = "RAW",
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .visualizer = visualizer_name,
        };
    }

    pub fn deinit(self: *RawSource, gpa: std.mem.Allocator) void {
        gpa.free(self.records);
        if (self.title) |t| gpa.free(t);
        if (self.artist) |a| gpa.free(a);
        gpa.destroy(self);
    }
};

const Parsed = struct {
    clock: u16,
    stream: []const u8,
    title: []const u8 = "",
    artist: []const u8 = "",
};

fn parse(data: []const u8) error{InvalidRaw}!?Parsed {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], magic)) return null;
    if (data.len < header_bytes) return error.InvalidRaw;

    const clock = fmt.readU16Le(data, 8);
    const body = data[header_bytes..];
    if (body.len < 2) return error.InvalidRaw;

    // Optional trailer after FF FF: 1A title\0 [1B author\0] [1C desc\0].
    // The stream ends at the first FF FF pair, and tag bytes after it never play.
    var end = body.len - body.len % 2;
    var title: []const u8 = "";
    var artist: []const u8 = "";

    var i: usize = 0;
    while (i + 1 < end) {
        // The record after a set-speed command is a 16-bit operand, not a
        // command, so a speed of 0xFFFF must not read as the end marker.
        if (body[i + 1] == @intFromEnum(Command.control) and body[i] == 0) {
            i += 4;
            continue;
        }
        if (body[i] == 0xff and body[i + 1] == 0xff) {
            const after = i + 2;
            if (after < body.len and body[after] == 0x1a) {
                const tag = body[after + 1 ..];
                title = readCString(tag, 40);
                var rest = tag[title.len..];
                if (rest.len > 0 and rest[0] == 0) rest = rest[1..];
                if (rest.len > 0 and rest[0] == 0x1b) {
                    rest = rest[1..];
                    artist = readCString(rest, 60);
                } else if (rest.len > 0 and rest[0] >= 0x20) {
                    artist = readCString(rest, 60);
                }
            }
            end = i + 2;
            break;
        }
        i += 2;
    }

    const stream = body[0..end];
    if (stream.len < 2) return error.InvalidRaw;
    return .{
        .clock = if (clock == 0) 0xffff else clock,
        .stream = stream,
        .title = title,
        .artist = artist,
    };
}

fn readCString(data: []const u8, max_len: usize) []const u8 {
    return std.mem.sliceTo(data[0..@min(data.len, max_len)], 0);
}

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const parsed = (try parse(data)) orelse return null;

    const n = parsed.stream.len / 2;
    const records = try gpa.alloc(Record, n);
    errdefer gpa.free(records);
    @memcpy(std.mem.sliceAsBytes(records), parsed.stream[0 .. n * 2]);

    const title = if (parsed.title.len != 0) try gpa.dupe(u8, parsed.title) else null;
    errdefer if (title) |t| gpa.free(t);
    const artist = if (parsed.artist.len != 0) try gpa.dupe(u8, parsed.artist) else null;
    errdefer if (artist) |a| gpa.free(a);

    const src = try gpa.create(RawSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .records = records,
        .sample_rate = ctx.sample_rate,
        .speed = parsed.clock,
        .title = title,
        .title_embedded = title != null,
        .artist = artist,
    };

    ctx.chip.writeReg(0x01, 0x20);
    chip_adapter.enableNew(ctx.chip);
    ctx.chip.flush();

    return fmt.MusicSource.init(src);
}

pub const format = fmt.Format{
    .name = "RAW",
    .extensions = &.{".raw"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

test "raw magic and minimal stream load" {
    const gpa = std.testing.allocator;
    // clock 0xFFFF (~18.2 Hz), one write, one delay of 1, end.
    const data = magic ++ [_]u8{
        0xff, 0xff,
        0x20, 0x01, // write reg 0x01 = 0x20
        0x01, 0x00, // delay 1
        0xff, 0xff, // end
    };
    var chip = opal.Opal.init(44100);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .name = "t.raw",
        .ext = ".raw",
    })).?;
    defer src.deinit(gpa);

    const info = src.info();
    try std.testing.expectEqualStrings("RAW", info.format_name);
    try std.testing.expect(info.title == null);
    // Writes batch until a delay: one step applies the reg write and the delay.
    const delay = src.step(fmt.noop_chip);
    try std.testing.expect(delay.frames > 0);
    try std.testing.expect(!delay.done);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}

test "raw rejects bad magic" {
    const gpa = std.testing.allocator;
    const data = "NOTARAW!" ++ [_]u8{ 0, 0, 0x01, 0x00 };
    try std.testing.expect(try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    }) == null);
}

test "raw truncated after magic is invalid" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidRaw, load(gpa, magic, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    }));
    try std.testing.expectError(error.InvalidRaw, load(gpa, magic ++ [_]u8{ 0xff, 0xff }, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    }));
}

test "raw setspeed and dual-chip bank select" {
    const gpa = std.testing.allocator;
    // clock 1000, then control setspeed to 2000, write, delay 2, end.
    const data = magic ++ [_]u8{
        0xe8, 0x03, // clock 1000
        0x00, 0x02, // setspeed follows
        0xd0, 0x07, // speed 2000
        0x02, 0x02, // select chip 1 (bank 0x100)
        0x55, 0xB0, // write reg 0xB0 = 0x55 on bank 1
        0x02, 0x00, // delay 2
        0xff, 0xff,
    };
    var chip = opal.Opal.init(44100);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .ext = ".raw",
    })).?;
    defer src.deinit(gpa);

    // Drain setspeed + bank + write (zero frames) then delay.
    var saw_delay = false;
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        const r = src.step(fmt.noop_chip);
        if (r.frames > 0) {
            saw_delay = true;
            break;
        }
        if (r.done) break;
    }
    try std.testing.expect(saw_delay);
}

test "raw setspeed operand of ffff does not end the stream" {
    const gpa = std.testing.allocator;
    const data = magic ++ [_]u8{
        0xff, 0xff, // clock
        0x00, 0x02, // setspeed follows
        0xff, 0xff, // speed 0xffff, an operand and not the end marker
        0x20, 0x01, // write reg 0x01 = 0x20
        0x01, 0x00, // delay 1
        0xff, 0xff, // real end of stream
    };
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    })).?;
    defer src.deinit(gpa);

    const state: *RawSource = @ptrCast(@alignCast(src.ptr));
    try std.testing.expectEqual(@as(usize, 5), state.records.len);

    const delay = src.step(fmt.noop_chip);
    try std.testing.expect(delay.frames > 0);
    try std.testing.expect(!delay.done);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}

test "raw tag title is embedded metadata" {
    const gpa = std.testing.allocator;
    const data = magic ++ [_]u8{
        0xff, 0xff,
        0x01, 0x00, // delay 1
        0xff, 0xff, // stream end
        0x1a, // tag marker
    } ++ "My Title" ++ [_]u8{0} ++ [_]u8{0x1b} ++ "Author" ++ [_]u8{0};

    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    })).?;
    defer src.deinit(gpa);
    const info = src.info();
    try std.testing.expectEqualStrings("My Title", info.title.?);
    try std.testing.expect(info.title_embedded);
    try std.testing.expectEqualStrings("Author", info.artist.?);
}

test "raw step yields before millions of zero-delay writes" {
    const gpa = std.testing.allocator;
    const write_count: usize = RawSource.max_ops_per_step + 64;
    var body = try gpa.alloc(u8, header_bytes + write_count * 2 + 4);
    defer gpa.free(body);
    @memcpy(body[0..8], magic);
    body[8] = 0xff;
    body[9] = 0xff;
    var i: usize = 0;
    while (i < write_count) : (i += 1) {
        body[header_bytes + i * 2] = 0x20;
        body[header_bytes + i * 2 + 1] = 0x01;
    }
    const tail = header_bytes + write_count * 2;
    body[tail] = 0x01;
    body[tail + 1] = 0x00;
    body[tail + 2] = 0xff;
    body[tail + 3] = 0xff;

    const src = (try load(gpa, body, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".raw",
    })).?;
    defer src.deinit(gpa);

    const first = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);

    var saw_delay = false;
    var n: u32 = 0;
    while (n < 8) : (n += 1) {
        const r = src.step(fmt.noop_chip);
        if (r.frames > 0) {
            saw_delay = true;
            break;
        }
        try std.testing.expect(!r.done);
    }
    try std.testing.expect(saw_delay);
}
