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
