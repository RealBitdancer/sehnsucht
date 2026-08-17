//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const opal = @import("opal");
const format = @import("format.zig");

fn writeReg(ctx: *anyopaque, reg: u16, val: u8) void {
    const chip: *opal.Opal = @ptrCast(@alignCast(ctx));
    chip.writeRegBuffered(reg, val);
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

// --- tests -------------------------------------------------------------------

const std = @import("std");

test "withStereoC0 sets speaker bits only on feedback registers" {
    try std.testing.expectEqual(@as(u8, 0x31), withStereoC0(0xc0, 0x01));
    try std.testing.expectEqual(@as(u8, 0x3e), withStereoC0(0x1c8, 0x0e));
    try std.testing.expectEqual(@as(u8, 0x20), withStereoC0(0xb0, 0x20));
    try std.testing.expectEqual(@as(u8, 0x01), withStereoC0(0x105, 0x01));
}
