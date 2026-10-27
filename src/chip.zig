//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const opal = @import("opal");
const format = @import("format.zig");

fn writeReg(ctx: *anyopaque, reg: u16, val: u8) void {
    const chip: *opal.Opal = @ptrCast(@alignCast(ctx));
    if (reg < 0x200) chip.writeRegBuffered(reg, val);
}

fn flush(ctx: *anyopaque) void {
    const chip: *opal.Opal = @ptrCast(@alignCast(ctx));
    chip.flushWriteBuf();
}

const vtable = format.Chip.VTable{ .writeReg = writeReg, .flush = flush };

pub fn fromOpal(chip: *opal.Opal) format.Chip {
    return .{ .ptr = chip, .vtable = &vtable };
}

pub fn enableNew(chip: format.Chip) void {
    chip.writeReg(0x105, 1);
}

pub fn withStereoC0(reg: u16, val: u8) u8 {
    const low = reg & 0xff;
    if (low >= 0xc0 and low <= 0xc8) return val | 0x30;
    return val;
}

/// A second OPL2 in bank 1 must not reach OPL3 0x104 and 0x105 through its timer and IRQ registers.
pub fn writeOpl2(chip: format.Chip, reg: u16, val: u8) void {
    if (reg >= 0x102 and reg <= 0x105) return chip.traceReg(reg, val);
    chip.writeReg(reg, withStereoC0(reg, val));
}

// --- tests -------------------------------------------------------------------

const std = @import("std");

test "writeOpl2 traces the second chip's timer registers instead of writing them" {
    const Rec = struct {
        written: [0x200]bool = @splat(false),
        traced: [0x200]bool = @splat(false),
        fn write(ptr: *anyopaque, reg: u16, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.written[reg] = true;
        }
        fn trace(ptr: *anyopaque, reg: u16, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.traced[reg] = true;
        }
        fn flushNop(_: *anyopaque) void {}
    };
    var rec: Rec = .{};
    const chip: format.Chip = .{ .ptr = &rec, .vtable = &.{ .writeReg = Rec.write, .flush = Rec.flushNop, .traceReg = Rec.trace } };
    for ([_]u16{ 0x004, 0x101, 0x102, 0x104, 0x105, 0x108 }) |reg| writeOpl2(chip, reg, 0x60);
    for ([_]u16{ 0x004, 0x101, 0x108 }) |reg| try std.testing.expect(rec.written[reg] and !rec.traced[reg]);
    for ([_]u16{ 0x102, 0x104, 0x105 }) |reg| try std.testing.expect(rec.traced[reg] and !rec.written[reg]);
}

test "withStereoC0 sets speaker bits only on feedback registers" {
    try std.testing.expectEqual(@as(u8, 0x31), withStereoC0(0xc0, 0x01));
    try std.testing.expectEqual(@as(u8, 0x3e), withStereoC0(0x1c8, 0x0e));
    try std.testing.expectEqual(@as(u8, 0x20), withStereoC0(0xb0, 0x20));
    try std.testing.expectEqual(@as(u8, 0x01), withStereoC0(0x105, 0x01));
}
