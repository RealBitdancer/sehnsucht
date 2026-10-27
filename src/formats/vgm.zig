//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const opal = @import("opal");

const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");
const inflate = @import("../inflate.zig");
const adpcm_chip = @import("../y8950.zig");

const vgm_rate: u32 = 44100;
const magic = "Vgm ";
const gd3_magic = "Gd3 ";
const min_header_bytes: usize = 0x40;
const port0: u16 = 0x000;
const port1: u16 = 0x100;
pub const format_name = "VGM";
pub const extensions = &.{ ".vgm", ".vgz" };
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

const readU16Le = fmt.readU16Le;
const readU32Le = fmt.readU32Le;

const Cmd = struct {
    const end: u8 = 0x66;
    const data_block: u8 = 0x67;
    const pcm_ram: u8 = 0x68;
    const wait_n: u8 = 0x61;
    const wait_735: u8 = 0x62;
    const wait_882: u8 = 0x63;
    const ym3812: u8 = 0x5a;
    const ym3526: u8 = 0x5b;
    const y8950: u8 = 0x5c;
    const ymf262_p0: u8 = 0x5e;
    const ymf262_p1: u8 = 0x5f;
    const dual_ym3812: u8 = 0xaa;
    const dual_ym3526: u8 = 0xab;
    const dual_y8950: u8 = 0xac;
    const ymf262_p0_alt: u8 = 0xae;
    const ymf262_p1_alt: u8 = 0xaf;
};

const Hdr = struct {
    const eof_rel: usize = 0x04;
    const version: usize = 0x08;
    const gd3_rel: usize = 0x14;
    const total_samples: usize = 0x18;
    const loop_rel: usize = 0x1c;
    const data_rel: usize = 0x34;
    const ym2612: usize = 0x2c;
    const ym3812: usize = 0x50;
    const ym3526: usize = 0x54;
    const y8950: usize = 0x58;
    const ymf262: usize = 0x5c;
};

const Gd3 = struct {
    const fields: usize = 11;
};

fn writeOpl(chip: fmt.Chip, port: u16, reg: u8, val: u8, native_opl3: bool) void {
    const addr = port | @as(u16, reg);
    if (native_opl3) chip.writeReg(addr, val) else chip_adapter.writeOpl2(chip, addr, val);
}

const VgmSource = struct {
    data: []const u8,
    cursor: usize,
    data_end: usize,
    loop_offset: ?usize,
    sample_rate: u32,
    version: u32,
    frac: u32 = 0,
    total_samples: u32 = 0,
    write_count: u32 = 0,
    opl3: bool,
    clock_ym3812: u32 = 0,
    clock_ym3526: u32 = 0,
    clock_y8950: u32 = 0,
    clock_ymf262: u32 = 0,
    dual_opl2: bool = false,
    dual_opl3: bool = false,
    y8950_port: u16 = port0,
    adpcm: [2]?adpcm_chip.Adpcm = @splat(null),
    waited_since_loop: bool = true,
    finished: bool = false,
    gd3_storage: []u8 = &.{},
    title: ?[]const u8 = null,
    game: ?[]const u8 = null,
    system: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    format_name: []const u8 = "VGM",

    const max_ops_per_step: u32 = 4096;

    fn waitFrames(self: *VgmSource, samples_44100: u32) u64 {
        const frames = fmt.rescale(samples_44100, vgm_rate, self.sample_rate, &self.frac);
        if (frames > 0) self.waited_since_loop = true;
        return frames;
    }

    fn need(self: *const VgmSource, nbytes: usize) bool {
        return self.cursor + nbytes <= self.data_end;
    }

    pub fn step(self: *VgmSource, chip: fmt.Chip) fmt.StepResult {
        if (self.finished) {
            return .{ .frames = @max(1, self.sample_rate / 10), .done = false };
        }

        const d = self.data;
        var ops: u32 = 0;
        while (self.cursor < self.data_end) {
            if (ops >= max_ops_per_step) return .{ .frames = 0 };
            ops += 1;
            const c = d[self.cursor];
            switch (c) {
                Cmd.end => {
                    if (self.loop_offset) |lo| {
                        if (self.waited_since_loop) {
                            self.cursor = lo;
                            self.waited_since_loop = false;
                            return .{ .frames = 0, .done = true };
                        }
                    }
                    self.finished = true;
                    return .{ .frames = 0, .done = true };
                },
                Cmd.data_block => {
                    if (!self.need(7)) break;
                    const size = readU32Le(d, self.cursor + 3) & 0x7fff_ffff;
                    const next = @as(u64, self.cursor) + 7 + size;
                    if (next > self.data_end) break;
                    if (d[self.cursor + 2] == 0x88 and size >= 8) {
                        const index: usize = readU32Le(d, self.cursor + 3) >> 31;
                        if (self.adpcm[index]) |*voice| {
                            const address = readU32Le(d, self.cursor + 11);
                            const payload = d[self.cursor + 15 .. @intCast(next)];
                            if (address > voice.memory.len or payload.len > voice.memory.len - address) break;
                            @memcpy(voice.memory[address..][0..payload.len], payload);
                        }
                    }
                    self.cursor = @intCast(next);
                },
                Cmd.pcm_ram => {
                    if (!self.need(12)) break;
                    self.cursor += 12;
                },
                Cmd.wait_n => {
                    if (!self.need(3)) break;
                    const w = readU16Le(d, self.cursor + 1);
                    self.cursor += 3;
                    return .{ .frames = self.waitFrames(w) };
                },
                Cmd.wait_735 => {
                    self.cursor += 1;
                    return .{ .frames = self.waitFrames(735) };
                },
                Cmd.wait_882 => {
                    self.cursor += 1;
                    return .{ .frames = self.waitFrames(882) };
                },
                0x70...0x7f => {
                    const w: u32 = (c & 0x0f) + 1;
                    self.cursor += 1;
                    return .{ .frames = self.waitFrames(w) };
                },
                0x80...0x8f => {
                    const w: u32 = c & 0x0f;
                    self.cursor += 1;
                    if (w > 0) return .{ .frames = self.waitFrames(w) };
                },
                Cmd.y8950, Cmd.dual_y8950 => {
                    if (!self.need(3)) break;
                    const index: usize = @intFromBool(c == Cmd.dual_y8950);
                    const port = if (index == 0) self.y8950_port else port1;
                    const reg = d[self.cursor + 1];
                    const value = d[self.cursor + 2];
                    if (self.adpcm[index]) |*voice| voice.write(reg, value);
                    if (reg == 8 or reg < 7 or reg >= 0x20) {
                        writeOpl(chip, port, reg, if (reg == 8) value & 0xc0 else value, false);
                    } else {
                        chip.traceReg(port | reg, value);
                    }
                    self.cursor += 3;
                },
                Cmd.ymf262_p0_alt, Cmd.ymf262_p1_alt => {
                    if (!self.need(3)) break;
                    if (self.dual_opl3)
                        writeOpl(chip, 0x200 | (if (c == Cmd.ymf262_p1_alt) port1 else port0), d[self.cursor + 1], d[self.cursor + 2], true);
                    self.cursor += 3;
                },
                Cmd.ym3812, Cmd.ym3526, Cmd.ymf262_p0 => {
                    if (!self.need(3)) break;
                    writeOpl(chip, port0, d[self.cursor + 1], d[self.cursor + 2], c == Cmd.ymf262_p0);
                    self.cursor += 3;
                },
                Cmd.ymf262_p1, Cmd.dual_ym3812, Cmd.dual_ym3526 => {
                    if (!self.need(3)) break;
                    writeOpl(chip, port1, d[self.cursor + 1], d[self.cursor + 2], c == Cmd.ymf262_p1);
                    self.cursor += 3;
                },
                else => {
                    const skip = commandLength(c, self.version) orelse break;
                    if (!self.need(skip)) break;
                    self.cursor += skip;
                },
            }
        }
        self.finished = true;
        return .{ .frames = 0, .done = true };
    }

    pub fn info(self: *VgmSource) fmt.TrackInfo {
        return .{
            .title = self.title,
            .title_embedded = self.title != null,
            .artist = self.artist,
            .game = self.game,
            .system = self.system,
            .format_name = self.format_name,
            .opl3 = self.opl3,
            .loop = self.loop_offset != null,
        };
    }

    pub fn durationFrames(self: *VgmSource) u64 {
        return @as(u64, self.total_samples) * self.sample_rate / vgm_rate;
    }

    pub fn dumpView(self: *VgmSource) view.DumpView {
        const chip: view.ChipKind = if (self.dual_opl3)
            .dual_opl3
        else if (self.clock_ymf262 != 0)
            .opl3
        else if (self.dual_opl2)
            .dual_opl2
        else
            .opl2;
        return .{
            .chip = chip,
            .write_count = self.write_count,
            .loop = if (self.loop_offset) |off| .{ .unit = .byte, .offset = @intCast(off) } else null,
            .clock_ym3812 = self.clock_ym3812 & 0x3fff_ffff,
            .clock_ym3526 = self.clock_ym3526 & 0x3fff_ffff,
            .clock_y8950 = self.clock_y8950 & 0x3fff_ffff,
            .clock_ymf262 = self.clock_ymf262 & 0x3fff_ffff,
            .adpcm_voices = if (self.adpcm[1] != null) 2 else @intFromBool(self.adpcm[0] != null),
        };
    }

    pub fn deinit(self: *VgmSource, gpa: std.mem.Allocator) void {
        for (self.adpcm) |voice| if (voice) |v| gpa.free(v.memory);
        gpa.free(self.data);
        gpa.free(self.gd3_storage);
        gpa.destroy(self);
    }

    pub fn renderPcm(self: *VgmSource, stereo: []i32) void {
        for (&self.adpcm) |*slot| {
            const voice = if (slot.*) |*v| v else continue;
            var peak: u32 = 0;
            var frame: usize = 0;
            while (frame + 1 < stereo.len) : (frame += 2) {
                const sample = voice.sample();
                peak = @max(peak, @abs(sample));
                stereo[frame] += sample;
                stereo[frame + 1] += sample;
            }
            voice.level = @intCast(@min(255, peak * 255 / 4096));
        }
    }

    pub fn pcmState(self: *VgmSource) view.PcmState {
        var state = view.PcmState{};
        for (self.adpcm, &state.voices) |voice, *snap| if (voice) |v| {
            snap.* = v.state();
        };
        return state;
    }
};

fn dataOffset(d: []const u8) ?usize {
    if (d.len < min_header_bytes or !std.mem.eql(u8, d[0..4], magic)) return null;
    const ver = readU32Le(d, Hdr.version);
    const rel = readU32Le(d, Hdr.data_rel);
    if (ver < 0x150 or rel == 0) return min_header_bytes;
    const off, const ov = @addWithOverflow(@as(usize, Hdr.data_rel), @as(usize, rel));
    if (ov != 0 or off < min_header_bytes or off > d.len) return null;
    return off;
}

fn clockRaw(d: []const u8, data_off: usize, field: usize) u32 {
    if (field + 4 > data_off or d.len < field + 4) return 0;
    return readU32Le(d, field);
}

fn clockAt(d: []const u8, data_off: usize, field: usize) u32 {
    return clockRaw(d, data_off, field) & 0x3fff_ffff;
}

fn dualOpl2Clock(d: []const u8, data_off: usize) bool {
    const bit: u32 = 0x4000_0000;
    return clockRaw(d, data_off, Hdr.ym3812) & bit != 0 or
        clockRaw(d, data_off, Hdr.ym3526) & bit != 0 or
        clockRaw(d, data_off, Hdr.y8950) & bit != 0;
}

fn commandLength(command: u8, version: u32) ?usize {
    return switch (command) {
        0x30...0x3f, 0x4f, 0x50, 0x94 => 2,
        0x40...0x4e => if (version >= 0x160) 3 else 2,
        0x51...0x5f, 0x61, 0xa0...0xbf => 3,
        0x62, 0x63, 0x66, 0x70...0x8f => 1,
        0xc0...0xdf => 4,
        0x68 => 12,
        0x90, 0x91, 0x95, 0xe0...0xff => 5,
        0x92 => 6,
        0x93 => 11,
        else => null,
    };
}

fn countOplWrites(stream: []const u8, version: u32, dual_opl3: bool) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < stream.len) {
        const cmd = stream[i];
        if (cmd == Cmd.end) break;
        const length = if (cmd == Cmd.data_block) blk: {
            if (stream.len - i < 7) break;
            const size = readU32Le(stream, i + 3) & 0x7fff_ffff;
            break :blk @as(u64, 7) + size;
        } else commandLength(cmd, version) orelse break;
        if (length > stream.len - i) break;
        switch (cmd) {
            0x5a, 0x5b, 0x5c, 0x5e, 0x5f, 0xaa, 0xab, 0xac => n += 1,
            0xae, 0xaf => n += @intFromBool(dual_opl3),
            else => {},
        }
        i += @intCast(length);
    }
    return n;
}

fn oplPresence(d: []const u8, data_off: usize) struct { any: bool, opl3: bool } {
    const opl2 = clockAt(d, data_off, Hdr.ym3812);
    const oplm = clockAt(d, data_off, Hdr.ym3526);
    const y8950 = clockAt(d, data_off, Hdr.y8950);
    const opl3 = clockAt(d, data_off, Hdr.ymf262);
    return .{
        .any = opl2 != 0 or oplm != 0 or y8950 != 0 or opl3 != 0,
        .opl3 = opl3 != 0,
    };
}

// Hand-rolled UTF-16: GD3 tags are untrusted and need lenient skip-on-invalid decoding, not std.unicode errors.
fn readUtf16LeZ(gpa: std.mem.Allocator, out: *std.ArrayList(u8), d: []const u8, p: *usize) !void {
    while (p.* + 1 < d.len) {
        const code = readU16Le(d, p.*);
        p.* += 2;
        if (code == 0) break;
        var buf: [4]u8 = undefined;
        const cp: u21 = if (code >= 0xD800 and code <= 0xDBFF) blk: {
            if (p.* + 1 >= d.len) break :blk @as(u21, code);
            const low = readU16Le(d, p.*);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                p.* += 2;
                const hi: u21 = code - 0xD800;
                const lo: u21 = low - 0xDC00;
                break :blk 0x10000 + (hi << 10) + lo;
            }
            break :blk @as(u21, code);
        } else @as(u21, code);
        const enc = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..enc]);
    }
}

fn parseGd3(gpa: std.mem.Allocator, d: []const u8, src: *VgmSource) !void {
    if (d.len < Hdr.gd3_rel + 4) return;
    const rel = readU32Le(d, Hdr.gd3_rel);
    if (rel == 0) return;
    const off_wide = @as(u64, Hdr.gd3_rel) + rel;
    if (off_wide + 12 > d.len) return;
    const off: usize = @intCast(off_wide);
    if (!std.mem.eql(u8, d[off .. off + 4], gd3_magic)) return;
    const gd3_len = readU32Le(d, off + 8);
    const body_off = off + 12;
    if (@as(u64, body_off) + gd3_len > d.len) return;

    var storage: std.ArrayList(u8) = .empty;
    errdefer storage.deinit(gpa);
    var p: usize = body_off;
    const end = body_off + gd3_len;
    for (0..Gd3.fields) |_| {
        if (p >= end) break;
        try readUtf16LeZ(gpa, &storage, d[0..end], &p);
        try storage.append(gpa, 0);
    }
    src.gd3_storage = try storage.toOwnedSlice(gpa);

    var it = std.mem.splitScalar(u8, src.gd3_storage, 0);
    inline for (.{ "title", "game", "system", "artist" }) |field| {
        const english = it.next() orelse return;
        const japanese = it.next() orelse "";
        const text = if (english.len != 0) english else japanese;
        if (text.len != 0) @field(src, field) = text;
    }
}

fn inflateIfGzip(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len < 2 or raw[0] != 0x1f or raw[1] != 0x8b) {
        return gpa.dupe(u8, raw);
    }
    return inflate.decode(gpa, raw, .gzip, fmt.max_input_bytes) catch |err| switch (err) {
        error.ReadFailed => error.GzipFailed,
        else => |e| e,
    };
}

fn enableOpl3(chip: fmt.Chip) void {
    writeOpl(chip, port1, 0x05, 0x01, true);
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const inflated = try inflateIfGzip(gpa, data);
    errdefer gpa.free(inflated);

    if (inflated.len < min_header_bytes or !std.mem.eql(u8, inflated[0..4], magic)) {
        return error.NotVgm;
    }

    const off = dataOffset(inflated) orelse return error.InvalidVgmOffset;
    const version = readU32Le(inflated, Hdr.version);

    const chips = oplPresence(inflated, off);
    if (!chips.any) return error.NonOplVgm;

    var data_end = inflated.len;
    const eof_rel = readU32Le(inflated, Hdr.eof_rel);
    if (eof_rel != 0) {
        const eo, const ov = @addWithOverflow(@as(usize, Hdr.eof_rel), @as(usize, eof_rel));
        if (ov == 0 and eo <= inflated.len and eo > off) data_end = eo;
    }

    var loop_off: ?usize = null;
    const loop_rel = readU32Le(inflated, Hdr.loop_rel);
    if (loop_rel != 0) {
        const lo, const ov = @addWithOverflow(@as(usize, Hdr.loop_rel), @as(usize, loop_rel));
        if (ov == 0 and lo >= off and lo < data_end) loop_off = lo;
    }

    const y8950_shares_bank = clockAt(inflated, off, Hdr.y8950) != 0 and
        (clockAt(inflated, off, Hdr.ym3812) != 0 or clockAt(inflated, off, Hdr.ym3526) != 0);
    const src = try gpa.create(VgmSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .data = inflated,
        .cursor = off,
        .data_end = data_end,
        .loop_offset = loop_off,
        .sample_rate = ctx.sample_rate,
        .version = version,
        .total_samples = readU32Le(inflated, Hdr.total_samples),
        .write_count = countOplWrites(inflated[off..data_end], version, clockRaw(inflated, off, Hdr.ymf262) & 0x4000_0000 != 0),
        .opl3 = chips.opl3,
        .clock_ym3812 = clockAt(inflated, off, Hdr.ym3812),
        .clock_ym3526 = clockAt(inflated, off, Hdr.ym3526),
        .clock_y8950 = clockAt(inflated, off, Hdr.y8950),
        .clock_ymf262 = clockAt(inflated, off, Hdr.ymf262),
        .dual_opl2 = dualOpl2Clock(inflated, off) or y8950_shares_bank,
        .y8950_port = if (y8950_shares_bank) port1 else port0,
        .dual_opl3 = chips.opl3 and clockRaw(inflated, off, Hdr.ymf262) & 0x4000_0000 != 0,
        .format_name = nameForExt(ctx.ext),
    };

    errdefer for (src.adpcm) |voice| if (voice) |v| gpa.free(v.memory);
    try prepareAdpcm(gpa, src, clockRaw(inflated, off, Hdr.y8950) & 0x4000_0000 != 0);

    try parseGd3(gpa, inflated, src);

    if (!chips.opl3) enableOpl3(ctx.chip);
    ctx.chip.flush();

    return fmt.MusicSource.init(src, visualizer_name);
}

fn prepareAdpcm(gpa: std.mem.Allocator, src: *VgmSource, dual: bool) !void {
    if (src.clock_y8950 == 0) return;
    if (src.clock_y8950 > 64_000_000 or src.sample_rate == 0) return error.InvalidVgmClock;
    var cursor = src.cursor;
    while (cursor < src.data_end) {
        const command = src.data[cursor];
        if (command == Cmd.end) break;
        if (command != Cmd.data_block) {
            const length = commandLength(command, src.version) orelse break;
            if (length > src.data_end - cursor) break;
            cursor += length;
            continue;
        }
        if (src.data_end - cursor < 7 or src.data[cursor + 1] != 0x66) return error.InvalidVgmDataBlock;
        const size = readU32Le(src.data, cursor + 3) & 0x7fff_ffff;
        if (size > src.data_end - cursor - 7) return error.InvalidVgmDataBlock;
        if (src.data[cursor + 2] == 0x88) {
            if (size < 8) return error.InvalidVgmDataBlock;
            const total = readU32Le(src.data, cursor + 7);
            const address = readU32Le(src.data, cursor + 11);
            if (total > adpcm_chip.memory_size or address > total or size - 8 > total - address) return error.InvalidVgmDataBlock;
        }
        cursor += 7 + size;
    }
    for (src.adpcm[0..if (dual) @as(usize, 2) else 1]) |*slot| {
        const memory = try gpa.alloc(u8, adpcm_chip.memory_size);
        @memset(memory, 0xff);
        slot.* = .{ .memory = memory, .clock = src.clock_y8950, .sample_rate = src.sample_rate };
    }
}

fn nameForExt(ext: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(ext, ".vgz")) "VGZ" else "VGM";
}

pub fn labelForPath(path: []const u8) []const u8 {
    return nameForExt(fmt.extensionOf(path));
}

pub const format = fmt.Format.init(@This());

test "vgm loads both ADPCM memories and reports live sample state" {
    const gpa = std.testing.allocator;
    const data = try makeMinimalVgm(gpa, false);
    defer gpa.free(data);
    std.mem.writeInt(u32, data[Hdr.ym3812..][0..4], 0, .little);
    std.mem.writeInt(u32, data[Hdr.y8950..][0..4], 3579545 | 0x4000_0000, .little);
    const commands = [_]u8{
        0x67, 0x66, 0x88, 12,   0,    0,    0,    4,    0,    0,    0, 0,    0,    0,    0,    0x77, 0x18, 0xf0, 0x62,
        0x67, 0x66, 0x88, 12,   0,    0,    0x80, 4,    0,    0,    0, 0,    0,    0,    0,    0x88, 0x76, 0x12, 0xa0,
        0x5c, 0x10, 0xff, 0x5c, 0x11, 0x70, 0x5c, 0x12, 0xff, 0x5c, 7, 0xb0, 0xac, 0x10, 0xff, 0xac, 0x11, 0x50, 0xac,
        0x12, 0x80, 0xac, 7,    0xb0, 0x61, 0x44, 0xac, 0x66,
    };
    @memcpy(data[0x80..][0..commands.len], &commands);
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".vgm" })).?;
    defer src.deinit(gpa);
    @memset(data, 0);
    try std.testing.expectEqual(@as(u2, 2), src.views().dump.?.adpcm_voices);
    var wait: u64 = 0;
    for (0..20) |_| {
        const result = src.step(fmt.noop_chip);
        wait = result.frames;
        if (wait != 0) break;
    }
    try std.testing.expectEqual(@as(u64, 44100), wait);
    const state: *VgmSource = @ptrCast(@alignCast(src.ptr));
    try std.testing.expectEqualSlices(u8, &.{ 0x77, 0x18, 0xf0, 0x62 }, state.adpcm[0].?.memory[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x76, 0x12, 0xa0 }, state.adpcm[1].?.memory[0..4]);
    var pcm: [128]i32 = undefined;
    src.renderPcm(&pcm);
    var peak: u32 = 0;
    for (pcm) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0);
    const snapshot = src.pcmState();
    try std.testing.expect(snapshot.voices[0].playing and snapshot.voices[1].playing);
    try std.testing.expect(snapshot.voices[0].rate > snapshot.voices[1].rate);
    try std.testing.expectEqual(@as(u8, 128), snapshot.voices[1].volume);
}

test "vgm rejects truncated and out of range ADPCM memory blocks" {
    const gpa = std.testing.allocator;
    const data = try makeMinimalVgm(gpa, false);
    defer gpa.free(data);
    std.mem.writeInt(u32, data[Hdr.y8950..][0..4], 3579545, .little);
    @memcpy(data[0x80..][0..7], &[_]u8{ 0x67, 0x66, 0x88, 12, 0, 0, 0 });
    std.mem.writeInt(u32, data[0x87..][0..4], 4, .little);
    std.mem.writeInt(u32, data[0x8b..][0..4], 3, .little);
    try std.testing.expectError(error.InvalidVgmDataBlock, load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip }));
    std.mem.writeInt(u32, data[0x83..][0..4], 0x7fffffff, .little);
    try std.testing.expectError(error.InvalidVgmDataBlock, load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip }));
}

// --- tests -------------------------------------------------------------------

fn makeMinimalVgm(gpa: std.mem.Allocator, with_opl3: bool) ![]u8 {
    var d: std.ArrayList(u8) = .empty;
    errdefer d.deinit(gpa);
    try d.appendNTimes(gpa, 0, 0x100);
    @memcpy(d.items[0..4], magic);
    const eof: u32 = @intCast(0x100 - 4);
    d.items[Hdr.eof_rel] = @truncate(eof);
    d.items[Hdr.eof_rel + 1] = @truncate(eof >> 8);
    d.items[Hdr.version] = 0x51;
    d.items[Hdr.version + 1] = 0x01;
    d.items[Hdr.data_rel] = 0x4C;
    if (with_opl3) {
        const clk: u32 = 14318180;
        std.mem.writeInt(u32, d.items[Hdr.ymf262..][0..4], clk, .little);
    } else {
        const clk: u32 = 3579545;
        std.mem.writeInt(u32, d.items[Hdr.ym3812..][0..4], clk, .little);
    }
    d.items[0x80] = Cmd.ym3812;
    d.items[0x81] = 0xB0;
    d.items[0x82] = 0x31;
    d.items[0x83] = Cmd.wait_735;
    d.items[0x84] = Cmd.end;
    std.mem.writeInt(u32, d.items[Hdr.total_samples..][0..4], 735, .little);
    return d.toOwnedSlice(gpa);
}

fn appendUtf16Z(gpa: std.mem.Allocator, d: *std.ArrayList(u8), codes: []const u16) !void {
    for (codes) |c| {
        try d.append(gpa, @truncate(c));
        try d.append(gpa, @truncate(c >> 8));
    }
    try d.appendSlice(gpa, &.{ 0, 0 });
}

fn appendGd3Header(gpa: std.mem.Allocator, d: *std.ArrayList(u8), declared_len: ?u32) !usize {
    const off = d.items.len;
    std.mem.writeInt(u32, d.items[Hdr.gd3_rel..][0..4], @intCast(off - Hdr.gd3_rel), .little);
    try d.appendSlice(gpa, gd3_magic);
    try d.appendSlice(gpa, &.{ 0, 1, 0, 0 });
    const len_pos = d.items.len;
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, declared_len orelse 0, .little);
    try d.appendSlice(gpa, &len_bytes);
    return len_pos;
}

fn loadGd3WithAllocator(gpa: std.mem.Allocator, data: []const u8) !void {
    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "t.vgm", data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);
}

test "vgm gd3 tags decode including surrogate pairs" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    const base = try makeMinimalVgm(gpa, false);
    defer gpa.free(base);
    try d.appendSlice(gpa, base);

    const len_pos = try appendGd3Header(gpa, &d, null);
    const body_start = d.items.len;
    try appendUtf16Z(gpa, &d, &.{ 'S', 'o', 'n', 'g', ' ', 0xD834, 0xDD1E });
    try appendUtf16Z(gpa, &d, &.{0x66f2});
    try appendUtf16Z(gpa, &d, &.{ 'G', 'a', 'm', 'e' });
    try appendUtf16Z(gpa, &d, &.{});
    try appendUtf16Z(gpa, &d, &.{ 'S', 'y', 's' });
    try appendUtf16Z(gpa, &d, &.{});
    try appendUtf16Z(gpa, &d, &.{});
    try appendUtf16Z(gpa, &d, &.{ 0x4f5c, 0x66f2 });
    for (0..3) |_| try appendUtf16Z(gpa, &d, &.{});
    const body_len: u32 = @intCast(d.items.len - body_start);
    std.mem.writeInt(u32, d.items[len_pos..][0..4], body_len, .little);

    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "t.vgm", d.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) })).?;
    defer src.deinit(gpa);
    const inf = src.info();
    try std.testing.expectEqualStrings("Song \xF0\x9D\x84\x9E", inf.title.?);
    try std.testing.expect(inf.title_embedded);
    try std.testing.expectEqualStrings("Game", inf.game.?);
    try std.testing.expectEqualStrings("Sys", inf.system.?);
    try std.testing.expectEqualStrings("作曲", inf.artist.?);
}

test "vgm gd3 propagates allocation failure" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    const base = try makeMinimalVgm(gpa, false);
    defer gpa.free(base);
    try d.appendSlice(gpa, base);

    const len_pos = try appendGd3Header(gpa, &d, null);
    const body_start = d.items.len;
    try appendUtf16Z(gpa, &d, &.{ 'T', 'i', 't', 'l', 'e' });
    const body_len: u32 = @intCast(d.items.len - body_start);
    std.mem.writeInt(u32, d.items[len_pos..][0..4], body_len, .little);

    try std.testing.checkAllAllocationFailures(
        gpa,
        loadGd3WithAllocator,
        .{d.items},
    );
}

test "vgm gd3 hostile lengths are tolerated" {
    const gpa = std.testing.allocator;
    const base = try makeMinimalVgm(gpa, false);
    defer gpa.free(base);

    {
        var d: std.ArrayList(u8) = .empty;
        defer d.deinit(gpa);
        try d.appendSlice(gpa, base);
        _ = try appendGd3Header(gpa, &d, 0xFFFF_FFFF);
        try appendUtf16Z(gpa, &d, &.{ 'A', 'B' });

        var chip = opal.Opal.init(44100);
        var src = (try fmt.load(gpa, "t.vgm", d.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) })).?;
        defer src.deinit(gpa);
        try std.testing.expect(src.info().title == null);
    }

    {
        var d: std.ArrayList(u8) = .empty;
        defer d.deinit(gpa);
        try d.appendSlice(gpa, base);
        const len_pos = try appendGd3Header(gpa, &d, null);
        try d.appendSlice(gpa, &.{ 'A', 0, 'B', 0 });
        std.mem.writeInt(u32, d.items[len_pos..][0..4], 4, .little);

        var chip = opal.Opal.init(44100);
        var src = (try fmt.load(gpa, "t.vgm", d.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) })).?;
        defer src.deinit(gpa);
        try std.testing.expectEqualStrings("AB", src.info().title.?);
    }
}

test "vgm header and wait math" {
    const gpa = std.testing.allocator;
    const data = try makeMinimalVgm(gpa, false);
    defer gpa.free(data);

    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "t.vgm", data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("stream", src.info().visualizer);
    try std.testing.expect(src.views().pattern == null);
    try std.testing.expectEqual(@as(?u64, 735), src.durationFrames());

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 20);
    try std.testing.expectEqual(@as(u64, 735), drained.frames);
}

test "vgm zero-wait run yields before the next delay" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    const base = try makeMinimalVgm(gpa, false);
    defer gpa.free(base);
    try d.appendSlice(gpa, base);
    const start = 0x80;
    const extra = VgmSource.max_ops_per_step + 8;
    try d.resize(gpa, start + extra + 2);
    @memset(d.items[start .. start + extra], 0x80);
    d.items[start + extra] = Cmd.wait_735;
    d.items[start + extra + 1] = Cmd.end;
    std.mem.writeInt(u32, d.items[Hdr.eof_rel..][0..4], @intCast(d.items.len - 4), .little);

    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "t.vgm", d.items, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);

    const first = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);
    const second = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 735), second.frames);
}

const RecChip = struct {
    regs: [0x400]u8 = @splat(0),

    fn writeReg(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *RecChip = @ptrCast(@alignCast(ptr));
        if (reg < self.regs.len) self.regs[reg] = val;
    }
    fn flush(_: *anyopaque) void {}
    const vtable = fmt.Chip.VTable{ .writeReg = writeReg, .flush = flush };
    fn chip(self: *RecChip) fmt.Chip {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "vgm routes both ports of the second OPL3 without overwriting the first" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try d.appendNTimes(gpa, 0, 0x100);
    @memcpy(d.items[0..4], magic);
    d.items[Hdr.version] = 0x51;
    d.items[Hdr.version + 1] = 0x01;
    d.items[Hdr.data_rel] = 0x4C;
    std.mem.writeInt(u32, d.items[Hdr.ymf262..][0..4], 14318180 | 0x4000_0000, .little);
    d.items[0x80] = Cmd.ymf262_p0;
    d.items[0x81] = 0x20;
    d.items[0x82] = 0x11;
    d.items[0x83] = Cmd.ymf262_p0_alt;
    d.items[0x84] = 0x20;
    d.items[0x85] = 0x99;
    d.items[0x86] = Cmd.ymf262_p1_alt;
    d.items[0x87] = 0x20;
    d.items[0x88] = 0x77;
    d.items[0x89] = Cmd.wait_735;
    d.items[0x8a] = Cmd.end;

    var rec = RecChip{};
    var src = (try fmt.load(gpa, "dual.vgm", d.items, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
    })).?;
    defer src.deinit(gpa);

    var safety: usize = 0;
    while (safety < 20) : (safety += 1) {
        if (src.step(rec.chip()).done) break;
    }
    try std.testing.expectEqual(@as(u8, 0x11), rec.regs[0x020]);
    try std.testing.expectEqual(@as(u8, 0), rec.regs[0x120]);
    try std.testing.expectEqual(@as(u8, 0x99), rec.regs[0x220]);
    try std.testing.expectEqual(@as(u8, 0x77), rec.regs[0x320]);
    try std.testing.expectEqual(view.ChipKind.dual_opl3, src.views().dump.?.chip);
    try std.testing.expectEqual(@as(u8, 36), view.visibleVoiceCount(src.views().dump, true, null));
    try std.testing.expectEqual(@as(u32, 3), src.views().dump.?.write_count);
}

test "vgm preserves OPL3 panning and counts only decoded register writes" {
    const gpa = std.testing.allocator;
    const data = try makeMinimalVgm(gpa, true);
    defer gpa.free(data);
    const commands = [_]u8{
        0x5f, 0x05, 0x01,
        0x93, 0x5e, 0xc0,
        0x77, 0,    0,
        0,    0,    0,
        0,    0,    0x67,
        0x66, 0,    3,
        0,    0,    0x80,
        0x5e, 0xc0, 0x77,
        0x5e, 0xc0, 0x10,
        0x5f, 0xc0, 0x20,
        0x5e, 0xc1, 0x00,
        0x5a, 0xc2, 0x01,
        0xae, 0xc0, 0x77,
        0x62, 0x66,
    };
    @memcpy(data[0x80..][0..commands.len], &commands);
    var rec: RecChip = .{};
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = rec.chip(), .ext = ".vgm" })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), rec.regs[0x105]);
    try std.testing.expectEqual(@as(u32, 5), src.views().dump.?.write_count);
    const drained = fmt.testDrain(src, rec.chip(), 100);
    try std.testing.expectEqual(@as(u64, 735), drained.frames);
    try std.testing.expectEqual(@as(u8, 0x10), rec.regs[0xc0]);
    try std.testing.expectEqual(@as(u8, 0x20), rec.regs[0x1c0]);
    try std.testing.expectEqual(@as(u8, 0x00), rec.regs[0xc1]);
    try std.testing.expectEqual(@as(u8, 0x31), rec.regs[0xc2]);
    try std.testing.expectEqual(@as(u8, 1), rec.regs[0x105]);
    try std.testing.expectEqual(@as(u32, 5), src.views().dump.?.write_count);
}

test "vgm non-opl rejected" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try d.appendNTimes(gpa, 0, 0x100);
    @memcpy(d.items[0..4], magic);
    d.items[Hdr.version] = 0x51;
    d.items[Hdr.version + 1] = 0x01;
    d.items[Hdr.data_rel] = 0x4C;
    d.items[Hdr.ym2612] = 0x01;
    d.items[0x80] = Cmd.end;

    var chip = opal.Opal.init(44100);
    const result = fmt.load(gpa, "x.vgm", d.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expectError(error.NonOplVgm, result);
}

test "vgm clocks are not read from command data" {
    const gpa = std.testing.allocator;
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(gpa);
    try d.appendNTimes(gpa, 0, 0x60);
    @memcpy(d.items[0..4], magic);
    d.items[Hdr.version] = 0x10;
    d.items[Hdr.version + 1] = 0x01;
    d.items[0x40] = Cmd.end;
    d.items[Hdr.ym3812] = 0xff;

    var chip = opal.Opal.init(44100);
    const result = fmt.load(gpa, "old.vgm", d.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expectError(error.NonOplVgm, result);
}

test "vgm wait scale to different rate" {
    const gpa = std.testing.allocator;
    const data = try makeMinimalVgm(gpa, false);
    defer gpa.free(data);
    var chip = opal.Opal.init(22050);
    const src_opt = try fmt.load(gpa, "t.vgm", data, .{ .sample_rate = 22050, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("VGM", src.info().format_name);
    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 20);
    try std.testing.expect(drained.frames == 367 or drained.frames == 368);
}

test "vgz gzip round-trip plays" {
    const gpa = std.testing.allocator;
    const plain = try makeMinimalVgm(gpa, false);
    defer gpa.free(plain);

    var aw = try Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer aw.deinit();
    var cbuf: [flate.max_window_len]u8 = undefined;
    var cw = try flate.Compress.init(&aw.writer, &cbuf, .gzip, .default);
    try cw.writer.writeAll(plain);
    try cw.finish();
    const gz = try aw.toOwnedSlice();
    defer gpa.free(gz);
    try std.testing.expect(gz.len >= 2 and gz[0] == 0x1f and gz[1] == 0x8b);

    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "t.vgz", gz, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("VGZ", src.info().format_name);
    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 20);
    try std.testing.expectEqual(@as(u64, 735), drained.frames);
}

test "vgm path labels follow the extension" {
    try std.testing.expectEqualStrings("VGM", labelForPath("t.vgm"));
    try std.testing.expectEqualStrings("VGZ", labelForPath("t.vgz"));
    try std.testing.expectEqualStrings("VGZ", fmt.displayLabelForPath("https://x/tune.VGZ").?);
}

fn oplVgm(gpa: std.mem.Allocator, clocks: []const [2]u32, commands: []const u8) ![]u8 {
    var d: std.ArrayList(u8) = .empty;
    errdefer d.deinit(gpa);
    try d.appendNTimes(gpa, 0, 0x80);
    @memcpy(d.items[0..4], magic);
    d.items[Hdr.version] = 0x51;
    d.items[Hdr.version + 1] = 0x01;
    d.items[Hdr.data_rel] = 0x4C;
    for (clocks) |clock| std.mem.writeInt(u32, d.items[clock[0]..][0..4], clock[1], .little);
    try d.appendSlice(gpa, commands);
    try d.append(gpa, Cmd.end);
    std.mem.writeInt(u32, d.items[Hdr.eof_rel..][0..4], @intCast(d.items.len - 4), .little);
    return d.toOwnedSlice(gpa);
}

test "vgm gives a Y8950 beside a YM3526 its own bank" {
    const gpa = std.testing.allocator;
    const data = try oplVgm(gpa, &.{ .{ Hdr.ym3526, 3579545 }, .{ Hdr.y8950, 3579545 } }, &.{
        Cmd.ym3526,   0xa0, 0x11,
        Cmd.y8950,    0xa0, 0x22,
        Cmd.wait_735,
    });
    defer gpa.free(data);
    var rec = RecChip{};
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = rec.chip(), .ext = ".vgm" })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 735), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u8, 0x11), rec.regs[0x0a0]);
    try std.testing.expectEqual(@as(u8, 0x22), rec.regs[0x1a0]);
    try std.testing.expectEqual(view.ChipKind.dual_opl2, src.views().dump.?.chip);
}

test "vgm keeps second-chip timer writes off the OPL3 pairing registers" {
    const gpa = std.testing.allocator;
    const data = try oplVgm(gpa, &.{.{ Hdr.ym3812, 3579545 | 0x4000_0000 }}, &.{
        Cmd.dual_ym3812, 0x04, 0x60,
        Cmd.dual_ym3812, 0x05, 0x00,
        Cmd.dual_ym3812, 0x20, 0x21,
        Cmd.wait_735,
    });
    defer gpa.free(data);
    var rec = RecChip{};
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = rec.chip(), .ext = ".vgm" })).?;
    defer src.deinit(gpa);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0), rec.regs[0x104]);
    try std.testing.expectEqual(@as(u8, 1), rec.regs[0x105]);
    try std.testing.expectEqual(@as(u8, 0x21), rec.regs[0x120]);
}

test "vgm applies a write burst in one step up to the op cap" {
    const gpa = std.testing.allocator;
    const writes = 2000;
    const commands = try gpa.alloc(u8, writes * 3 + 1);
    defer gpa.free(commands);
    for (0..writes) |i| @memcpy(commands[i * 3 ..][0..3], &[_]u8{ Cmd.ym3812, 0x20, @truncate(i) });
    commands[writes * 3] = Cmd.wait_735;
    const data = try oplVgm(gpa, &.{.{ Hdr.ym3812, 3579545 }}, commands);
    defer gpa.free(data);
    var rec = RecChip{};
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = rec.chip(), .ext = ".vgm" })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 735), src.step(rec.chip()).frames);
    try std.testing.expectEqual(@as(u8, @truncate(writes - 1)), rec.regs[0x20]);
}
