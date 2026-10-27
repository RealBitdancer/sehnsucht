//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "XSM";
pub const extensions = &.{".xsm"};
pub const visualizer_name = "tracker";
pub const view_caps = view.ViewCaps{ .pattern = true, .instruments = true };

const xsm_columns = [_]view.ColumnId{.note};
const xsm_cell_template = view.CellTemplate{ .width = 3, .note_w = 3 };

const magic = "ofTAZ!";
const header_bytes = 8;
const channels = 9;
const inst_stride = 16;
const patch_bytes = 11;
const inst_block = channels * inst_stride;
const max_songlen: u16 = 3200;
const tick_hz: u32 = 5;

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };
const note_fnum = [_]u16{ 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686 };

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

fn applyPatch(patch: *const [patch_bytes]u8, chip: fmt.Chip, voice: u8) void {
    const off = op_offset[voice];
    for (op_regs, patch[0..op_regs.len]) |reg, val| {
        chip.writeReg(reg + off, val);
    }
    chip.writeReg(Reg.feedback + voice, patch[10]);
}

fn playNote(chip: fmt.Chip, ch: u8, note: u8) void {
    if (note == 0) {
        chip.writeReg(Reg.fnum_lo + ch, 0);
        chip.writeReg(Reg.key_block + ch, Reg.key_on);
        return;
    }
    const freq = note_fnum[note % 12];
    chip.writeReg(Reg.fnum_lo + ch, @truncate(freq));
    const block: u16 = @as(u16, note / 12) * 4;
    const b0: u8 = @truncate((freq >> 8) | Reg.key_on | block);
    chip.writeReg(Reg.key_block + ch, b0);
}

const XsmSource = struct {
    music: []const u8,
    songlen: u16,
    row: u16 = 0,
    last: u16 = 0,
    sample_rate: u32,
    frac: u32 = 0,
    patches: [channels][patch_bytes]u8 = @splat(@splat(0)),

    fn rewind(self: *XsmSource) void {
        self.row = 0;
        self.last = 0;
        self.frac = 0;
    }

    fn cell(self: *const XsmSource, row: u16, ch: u8) u8 {
        return self.music[@as(usize, row) * channels + ch];
    }

    pub fn step(self: *XsmSource, chip: fmt.Chip) fmt.StepResult {
        if (self.row >= self.songlen) {
            self.rewind();
            return .{ .frames = 0, .done = true };
        }

        const cur = self.row;
        for (0..channels) |i| {
            const ch: u8 = @intCast(i);
            if (self.cell(cur, ch) != self.cell(self.last, ch)) {
                chip.writeReg(Reg.key_block + ch, 0);
            }
        }
        for (0..channels) |i| {
            playNote(chip, @intCast(i), self.cell(cur, @intCast(i)));
        }

        self.last = cur;
        self.row = cur + 1;
        return .{ .frames = fmt.rescale(1, tick_hz, self.sample_rate, &self.frac) };
    }

    pub fn info(_: *XsmSource) fmt.TrackInfo {
        return .{
            .format_name = "XSM",
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
        };
    }

    pub fn durationFrames(self: *XsmSource) u64 {
        return @as(u64, self.songlen) * self.sample_rate / tick_hz;
    }

    pub fn playhead(self: *XsmSource) view.Playhead {
        const sounded: u16 = if (self.row == 0) 0 else self.last;
        return .{
            .row = sounded,
            .pattern = 0,
            .flags = .{ .has_row = true, .has_pattern = true },
        };
    }

    pub fn patternView(self: *XsmSource) view.PatternView {
        return .{
            .ctx = self,
            .grid = .shared_pattern,
            .occupancy = .independent,
            .columns = &xsm_columns,
            .effect_style = .raw_hex,
            .cell_template = xsm_cell_template,
            .channels = channels,
            .rows_per_pattern = self.songlen,
            .num_patterns = 1,
            .cell = viewCell,
        };
    }

    pub fn instrumentBank(self: *XsmSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = channels,
            .get = xsmInstrument,
        };
    }

    pub fn deinit(self: *XsmSource, gpa: std.mem.Allocator) void {
        gpa.free(self.music);
        gpa.destroy(self);
    }
};

fn viewCell(ptr: *anyopaque, pattern: u16, row: u16, chan: u16) view.Cell {
    const self: *XsmSource = @ptrCast(@alignCast(ptr));
    if (pattern != 0 or row >= self.songlen or chan >= channels) return .{};
    const note = self.cell(row, @intCast(chan));
    if (note == 0) return .{ .note = .rest };
    return .{ .note = .{ .pitch = .{ .semitone = note % 12, .octave = note / 12 } } };
}

const xsm_inst_names = [_][]const u8{ "CH1", "CH2", "CH3", "CH4", "CH5", "CH6", "CH7", "CH8", "CH9" };

fn xsmInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self: *XsmSource = @ptrCast(@alignCast(ptr));
    if (index >= channels) return .{};
    const p = self.patches[index];
    return .{
        .name = xsm_inst_names[index],
        .patch = .{ .opl_2op = .{
            .ops = .{
                fmt.operatorParams(p[0], p[2], p[4], p[6], p[8]),
                fmt.operatorParams(p[1], p[3], p[5], p[7], p[9]),
                .{},
                .{},
            },
            .op_count = 2,
            .feedback = @truncate((p[10] >> 1) & 7),
            .additive = p[10] & 1 != 0,
        } },
    };
}

fn parse(data: []const u8) error{InvalidXsm}!?u16 {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    if (data.len < header_bytes) return error.InvalidXsm;

    const songlen = fmt.readU16Le(data, magic.len);
    if (songlen > max_songlen) return null;
    if (songlen == 0) return error.InvalidXsm;

    const need = header_bytes + inst_block + @as(usize, songlen) * channels;
    if (data.len < need) return error.InvalidXsm;
    return songlen;
}

fn unpackMusic(dest: []u8, src: []const u8, songlen: u16) void {
    for (0..channels) |c| {
        for (0..songlen) |r| {
            dest[r * channels + c] = src[c * songlen + r];
        }
    }
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const songlen = (try parse(data)) orelse return null;
    const inst = data[header_bytes..][0..inst_block];
    const packed_music = data[header_bytes + inst_block ..][0 .. @as(usize, songlen) * channels];

    const music = try gpa.alloc(u8, packed_music.len);
    errdefer gpa.free(music);
    unpackMusic(music, packed_music, songlen);

    const src = try gpa.create(XsmSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .music = music,
        .songlen = songlen,
        .sample_rate = ctx.sample_rate,
    };
    for (0..channels) |i| {
        const ch: u8 = @intCast(i);
        @memcpy(&src.patches[i], inst[ch * inst_stride ..][0..patch_bytes]);
    }

    ctx.chip.writeReg(Reg.waveform_select, 0x20);
    for (0..channels) |i| {
        const ch: u8 = @intCast(i);
        applyPatch(&src.patches[i], ctx.chip, ch);
    }
    ctx.chip.flush();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

fn makeFile(buf: []u8, songlen: u16, music_col: []const u8) []u8 {
    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u16, buf[6..8], songlen, .little);
    @memset(buf[header_bytes..][0..inst_block], 0);
    const off = header_bytes + inst_block;
    @memcpy(buf[off..][0..music_col.len], music_col);
    return buf[0 .. off + music_col.len];
}

const Rec = struct {
    a0: [2]u8 = .{ 0, 0 },
    fn write(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (reg == Reg.fnum_lo or reg == Reg.fnum_lo + 1) self.a0[reg - Reg.fnum_lo] = val;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

test "xsm loads and steps a one-row file" {
    const gpa = std.testing.allocator;
    var buf: [header_bytes + inst_block + channels]u8 = undefined;
    const data = makeFile(&buf, 1, &[_]u8{ 12, 0, 0, 0, 0, 0, 0, 0, 0 });
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".xsm",
    })).?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("XSM", src.info().format_name);
    try std.testing.expectEqualStrings("tracker", src.info().visualizer);
    try std.testing.expectEqual(@as(u64, 44100 / tick_hz), src.durationFrames().?);
    try std.testing.expect(src.views().pattern != null);
    try std.testing.expect(src.views().order == null);
    try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}

test "xsm rejects bad files" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".xsm" };
    try std.testing.expect(try load(gpa, "NOTAZ!", ctx) == null);
    try std.testing.expectError(error.InvalidXsm, load(gpa, magic, ctx));
}

test "xsm unpacks column-major notes" {
    var rec = Rec{};
    const gpa = std.testing.allocator;
    var buf: [header_bytes + inst_block + channels * 2]u8 = undefined;
    const data = makeFile(&buf, 2, &[_]u8{
        12, 24, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    });
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".xsm",
    })).?;
    defer src.deinit(gpa);

    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, @truncate(note_fnum[0])), rec.a0[0]);
    try std.testing.expectEqual(@as(u8, @truncate(note_fnum[1])), rec.a0[1]);
}
