//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

const dro_magic = "DBRAWOPL";
pub const visualizer_name = "stream";

const Version = enum {
    v1,
    v2,

    fn label(self: Version) []const u8 {
        return switch (self) {
            .v1 => "DRO v1",
            .v2 => "DRO v2",
        };
    }

    fn formatName(self: Version) []const u8 {
        return switch (self) {
            .v1 => "DRO",
            .v2 => "DRO2",
        };
    }

    /// v1 and v2 swap the meaning of hardware codes 1 and 2.
    fn hardware(self: Version, code: u8) Hardware {
        return switch (self) {
            .v1 => switch (code) {
                1 => .opl3,
                2 => .dual_opl2,
                else => .opl2,
            },
            .v2 => switch (code) {
                1 => .dual_opl2,
                2 => .opl3,
                else => .opl2,
            },
        };
    }
};

const Hardware = enum {
    opl2,
    dual_opl2,
    opl3,

    fn label(self: Hardware) []const u8 {
        return switch (self) {
            .opl2 => "OPL2",
            .dual_opl2 => "Dual OPL2",
            .opl3 => "OPL3",
        };
    }
};

const DroSource = struct {
    data: []const u8,
    pos: usize = 0,
    sample_rate: u32,
    bank: u16 = 0,
    version: Version,
    hardware: Hardware,
    short_delay_code: u8 = 0,
    long_delay_code: u8 = 0,
    codemap: []const u8 = &.{},
    frac: u32 = 0,
    total_ms: u64 = 0,
    title: []const u8,

    fn framesForMs(self: *DroSource, ms: u32) u64 {
        return fmt.rescale(ms, 1000, self.sample_rate, &self.frac);
    }

    pub fn step(self: *DroSource, chip: fmt.Chip) fmt.StepResult {
        return switch (self.version) {
            .v1 => self.stepV1(chip),
            .v2 => self.stepV2(chip),
        };
    }

    fn rewindDone(self: *DroSource) fmt.StepResult {
        self.pos = 0;
        self.bank = 0;
        return .{ .frames = 0, .done = true };
    }

    fn stepV1(self: *DroSource, chip: fmt.Chip) fmt.StepResult {
        if (self.pos >= self.data.len) return self.rewindDone();
        const cmd = self.data[self.pos];
        self.pos += 1;
        switch (cmd) {
            0x00 => {
                if (self.pos >= self.data.len) return self.rewindDone();
                const ms: u32 = @as(u32, self.data[self.pos]) + 1;
                self.pos += 1;
                return .{ .frames = self.framesForMs(ms) };
            },
            0x01 => {
                if (self.pos + 1 >= self.data.len) return self.rewindDone();
                const ms: u32 = @as(u32, fmt.readU16Le(self.data, self.pos)) + 1;
                self.pos += 2;
                return .{ .frames = self.framesForMs(ms) };
            },
            0x02 => {
                self.bank = 0x000;
                return .{ .frames = 0 };
            },
            0x03 => {
                self.bank = 0x100;
                return .{ .frames = 0 };
            },
            0x04 => {
                if (self.pos + 1 >= self.data.len) return self.rewindDone();
                chip.writeReg(self.bank + self.data[self.pos], self.data[self.pos + 1]);
                self.pos += 2;
                return .{ .frames = 0 };
            },
            else => {
                if (self.pos >= self.data.len) return self.rewindDone();
                chip.writeReg(self.bank + cmd, self.data[self.pos]);
                self.pos += 1;
                return .{ .frames = 0 };
            },
        }
    }

    fn stepV2(self: *DroSource, chip: fmt.Chip) fmt.StepResult {
        if (self.pos + 1 >= self.data.len) return self.rewindDone();
        const index = self.data[self.pos];
        const value = self.data[self.pos + 1];
        self.pos += 2;

        if (index == self.short_delay_code) {
            return .{ .frames = self.framesForMs(@as(u32, value) + 1) };
        }
        if (index == self.long_delay_code) {
            return .{ .frames = self.framesForMs((@as(u32, value) + 1) << 8) };
        }

        var idx = index;
        var reg_bank: u16 = 0;
        if (idx & 0x80 != 0) {
            reg_bank = 0x100;
            idx &= 0x7F;
        }
        if (idx >= self.codemap.len) return self.rewindDone();
        chip.writeReg(reg_bank + self.codemap[idx], value);
        return .{ .frames = 0 };
    }

    pub fn info(self: *DroSource) fmt.TrackInfo {
        return .{
            .title = self.title,
            .format_name = self.version.formatName(),
            .opl3 = self.hardware == .opl3,
            .system = self.hardware.label(),
            .loop = true,
            .visualizer = visualizer_name,
        };
    }

    pub fn durationFrames(self: *DroSource) u64 {
        return self.total_ms * self.sample_rate / 1000;
    }

    pub fn deinit(self: *DroSource, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.codemap);
        gpa.free(self.title);
        gpa.destroy(self);
    }
};

fn totalMs(
    stream: []const u8,
    version: Version,
    short_code: u8,
    long_code: u8,
    codemap_len: usize,
) u64 {
    var ms: u64 = 0;
    var pos: usize = 0;
    switch (version) {
        .v1 => while (pos < stream.len) {
            const cmd = stream[pos];
            pos += 1;
            switch (cmd) {
                0x00 => {
                    if (pos >= stream.len) break;
                    ms += @as(u64, stream[pos]) + 1;
                    pos += 1;
                },
                0x01 => {
                    if (pos + 1 >= stream.len) break;
                    ms += @as(u64, fmt.readU16Le(stream, pos)) + 1;
                    pos += 2;
                },
                0x02, 0x03 => {},
                0x04 => pos += 2,
                else => pos += 1,
            }
        },
        .v2 => while (pos + 1 < stream.len) {
            const index = stream[pos];
            const value = stream[pos + 1];
            pos += 2;
            if (index == short_code) {
                ms += @as(u64, value) + 1;
            } else if (index == long_code) {
                ms += (@as(u64, value) + 1) << 8;
            } else if ((index & 0x7F) >= codemap_len) {
                break;
            }
        },
    }
    return ms;
}

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (data.len < 12 or !std.mem.eql(u8, data[0..8], dro_magic)) return null;

    const version_word = fmt.readU32Le(data, 8);
    if (version_word == 0 or version_word == 0x00010000) {
        return try loadV1(gpa, data, ctx.sample_rate);
    }
    if (version_word == 2) {
        return try loadV2(gpa, data, ctx.sample_rate);
    }
    return try loadV1Old(gpa, data, ctx.sample_rate);
}

const SourceOptions = struct {
    version: Version,
    hw_code: u8,
    short_code: u8 = 0,
    long_code: u8 = 0,
    codemap: []const u8 = &.{},
};

fn makeSource(
    gpa: std.mem.Allocator,
    stream: []const u8,
    sample_rate: u32,
    opts: SourceOptions,
) !fmt.MusicSource {
    const copy = try gpa.dupe(u8, stream);
    errdefer gpa.free(copy);
    const hardware = opts.version.hardware(opts.hw_code);
    const title = try std.fmt.allocPrint(gpa, "{s} ({s})", .{ opts.version.label(), hardware.label() });
    errdefer gpa.free(title);
    const src = try gpa.create(DroSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .data = copy,
        .sample_rate = sample_rate,
        .version = opts.version,
        .hardware = hardware,
        .short_delay_code = opts.short_code,
        .long_delay_code = opts.long_code,
        .codemap = opts.codemap,
        .total_ms = totalMs(copy, opts.version, opts.short_code, opts.long_code, opts.codemap.len),
        .title = title,
    };
    return fmt.MusicSource.init(src);
}

fn clampToDeclaredLength(stream: []const u8, length_bytes: u32) []const u8 {
    if (length_bytes == 0 or length_bytes > stream.len) return stream;
    return stream[0..length_bytes];
}

fn loadV1Old(gpa: std.mem.Allocator, data: []const u8, sample_rate: u32) !fmt.MusicSource {
    if (data.len < 17) return error.TruncatedDro;

    const stream = clampToDeclaredLength(data[17..], fmt.readU32Le(data, 12));
    return makeSource(gpa, stream, sample_rate, .{ .version = .v1, .hw_code = data[16] });
}

fn loadV1(gpa: std.mem.Allocator, data: []const u8, sample_rate: u32) !fmt.MusicSource {
    if (data.len < 21) return error.TruncatedDro;

    // The 24-byte header pads the hardware byte to a word. The early 21-byte
    // one starts the command stream there instead.
    const padded_header = data.len >= 24 and (fmt.readU32Le(data, 20) & 0xFFFF_FF00) == 0;
    const header_size: usize = if (padded_header) 24 else 21;

    const stream = clampToDeclaredLength(data[header_size..], fmt.readU32Le(data, 16));
    return makeSource(gpa, stream, sample_rate, .{ .version = .v1, .hw_code = data[20] });
}

fn loadV2(gpa: std.mem.Allocator, data: []const u8, sample_rate: u32) !fmt.MusicSource {
    if (data.len < 26) return error.TruncatedDro;

    const pairs = fmt.readU32Le(data, 12);
    const i_format = data[21];
    const compression = data[22];
    if (i_format != 0 or compression != 0) return error.UnsupportedDro2;

    const codemap_len: usize = data[25];
    if (data.len < 26 + codemap_len) return error.TruncatedDro;

    const codemap = try gpa.dupe(u8, data[26 .. 26 + codemap_len]);
    errdefer gpa.free(codemap);

    const stream_off = 26 + codemap_len;
    // Widen before the multiply: pairs is attacker-controlled and pairs * 2 overflows a 32-bit usize.
    const stream_len: usize = @intCast(@min(@as(u64, data.len - stream_off), @as(u64, pairs) * 2));
    return makeSource(gpa, data[stream_off .. stream_off + stream_len], sample_rate, .{
        .version = .v2,
        .hw_code = data[20],
        .short_code = data[23],
        .long_code = data[24],
        .codemap = codemap,
    });
}

pub const format = fmt.Format{
    .name = "DRO",
    .extensions = &.{".dro"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

fn makeTestDroV1(gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "DBRAWOPL");
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x01, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x03, 0x00, 0x00, 0x00 });
    const len_at = list.items.len;
    try list.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try list.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try list.appendSlice(gpa, &[_]u8{ 0x20, 0x01, 0x00, 0x00, 0xB0, 0x31, 0x00, 0x01 });
    const data_len: u32 = @intCast(list.items.len - 24);
    std.mem.writeInt(u32, list.items[len_at..][0..4], data_len, .little);
    return list.toOwnedSlice(gpa);
}

test "dro v1 register and delay sequence" {
    const gpa = std.testing.allocator;
    const data = try makeTestDroV1(gpa);
    defer gpa.free(data);

    var chip = opal.Opal.init(1000);
    const src_opt = try fmt.load(gpa, "test.dro", data, .{ .sample_rate = 1000, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("stream", src.info().visualizer);

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 100);
    try std.testing.expect(drained.writes >= 2);
    try std.testing.expectEqual(@as(u64, 3), drained.frames);
    try std.testing.expectEqual(@as(?u64, 3), src.durationFrames());
}

test "dro v1 early 21-byte header variant" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "DBRAWOPL");
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x01, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x06, 0x00, 0x00, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try list.append(gpa, 0x00);
    try list.appendSlice(gpa, &[_]u8{ 0x20, 0x01, 0x00, 0x05 });

    var chip = opal.Opal.init(1000);
    const src_opt = try fmt.load(gpa, "early.dro", list.items, .{ .sample_rate = 1000, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 100);
    try std.testing.expectEqual(@as(u64, 6), drained.frames);
}

test "dro oldest header-less v1 variant" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "DBRAWOPL");
    try list.appendSlice(gpa, &[_]u8{ 0x03, 0x00, 0x00, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0x08, 0x00, 0x00, 0x00 });
    try list.append(gpa, 0x00);
    try list.appendSlice(gpa, &[_]u8{ 0x20, 0x01, 0x00, 0x00, 0xB0, 0x31, 0x00, 0x01 });

    var chip = opal.Opal.init(1000);
    const src_opt = try fmt.load(gpa, "old.dro", list.items, .{ .sample_rate = 1000, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("DRO", src.info().format_name);

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 100);
    try std.testing.expect(drained.writes >= 2);
    try std.testing.expectEqual(@as(u64, 3), drained.frames);
}

fn makeTestDroV2(gpa: std.mem.Allocator, pairs_data: []const u8, codemap: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "DBRAWOPL");
    try list.appendSlice(gpa, &[_]u8{ 0x02, 0x00, 0x00, 0x00 });
    var pairs_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pairs_bytes, @intCast(pairs_data.len / 2), .little);
    try list.appendSlice(gpa, &pairs_bytes);
    try list.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try list.append(gpa, 2);
    try list.append(gpa, 0);
    try list.append(gpa, 0);
    try list.append(gpa, 0xFE);
    try list.append(gpa, 0xFF);
    try list.append(gpa, @intCast(codemap.len));
    try list.appendSlice(gpa, codemap);
    try list.appendSlice(gpa, pairs_data);
    return list.toOwnedSlice(gpa);
}

test "dro v2 codemap, bank bit, and delay codes" {
    const gpa = std.testing.allocator;
    const pairs = [_]u8{
        0x00, 0x01,
        0xFE, 0x00,
        0x01, 0x31,
        0x81, 0x55,
        0xFF, 0x00,
    };
    const data = try makeTestDroV2(gpa, &pairs, &.{ 0x20, 0xB0 });
    defer gpa.free(data);

    var chip = opal.Opal.init(1000);
    var src = (try fmt.load(gpa, "t.dro", data, .{ .sample_rate = 1000, .chip = chip_adapter.fromOpal(&chip) })).?;
    defer src.deinit(gpa);

    const inf = src.info();
    try std.testing.expectEqualStrings("DRO2", inf.format_name);
    try std.testing.expectEqualStrings("DRO v2 (OPL3)", inf.title.?);
    try std.testing.expect(inf.opl3);
    try std.testing.expectEqual(@as(?u64, 257), src.durationFrames());

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 100);
    try std.testing.expectEqual(@as(u64, 257), drained.frames);
    try std.testing.expectEqual(@as(usize, 3), drained.writes);
}

test "dro v2 hostile codemap index ends the pass instead of crashing" {
    const gpa = std.testing.allocator;
    const pairs = [_]u8{ 0x05, 0x00, 0x85, 0x00 };
    const data = try makeTestDroV2(gpa, &pairs, &.{0x20});
    defer gpa.free(data);

    var chip = opal.Opal.init(1000);
    var src = (try fmt.load(gpa, "bad.dro", data, .{ .sample_rate = 1000, .chip = chip_adapter.fromOpal(&chip) })).?;
    defer src.deinit(gpa);

    const r = src.step(chip_adapter.fromOpal(&chip));
    try std.testing.expect(r.done);
}

test "dro rejects non-magic" {
    const gpa = std.testing.allocator;
    var chip = opal.Opal.init(44100);
    const r = try fmt.load(gpa, "x.dro", "NOTADROP!!!!", .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(r == null);
}

test "dro ms to frames frac-carry at 44100" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "DBRAWOPL");
    try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x01, 0x00 });
    try list.appendSlice(gpa, &[_]u8{ 0xE8, 0x03, 0x00, 0x00 });
    const len_at = list.items.len;
    try list.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    try list.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    for (0..1000) |_| {
        try list.appendSlice(gpa, &[_]u8{ 0x00, 0x00 });
    }
    const data_len: u32 = @intCast(list.items.len - 24);
    std.mem.writeInt(u32, list.items[len_at..][0..4], data_len, .little);

    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "t.dro", list.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 5000);
    try std.testing.expectEqual(@as(u64, 44100), drained.frames);
}
