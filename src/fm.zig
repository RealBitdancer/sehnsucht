//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("format.zig");
const view = @import("view.zig");

pub const operator_offsets = [_]u16{ 0, 1, 2, 8, 9, 10, 16, 17, 18 };

pub fn channelRegister(channel: u8, base: u16) u16 {
    return base + channel % 9 + @as(u16, channel / 9) * 0x100;
}

pub fn operatorOffset(channel: u8) u16 {
    return operator_offsets[channel % 9] + @as(u16, channel / 9) * 0x100;
}

pub fn operator(chip: fmt.Chip, offset: u16, op: view.OperatorParams, volume: u8) void {
    const flags = @as(u8, @intFromBool(op.tremolo)) << 7 | @as(u8, @intFromBool(op.vibrato)) << 6 | @as(u8, @intFromBool(op.sustaining)) << 5 | @as(u8, @intFromBool(op.ksr)) << 4;
    chip.writeReg(0x20 + offset, flags | op.mult);
    level(chip, offset, op, volume);
    chip.writeReg(0x60 + offset, @as(u8, op.attack) << 4 | op.decay);
    chip.writeReg(0x80 + offset, @as(u8, op.sustain) << 4 | op.release);
    chip.writeReg(0xe0 + offset, op.wave);
}

pub fn level(chip: fmt.Chip, offset: u16, op: view.OperatorParams, volume: u8) void {
    const amplitude: u8 = @intCast((@as(u16, 63 - @as(u8, op.level)) * volume + 63) / 127);
    chip.writeReg(0x40 + offset, @as(u8, op.ksl) << 6 | (63 - amplitude));
}

pub fn patch(chip: fmt.Chip, channel: u8, ins: view.OplPatch, volume: u8) void {
    for (0..ins.op_count) |i| {
        const offset = operatorOffset(channel + @as(u8, if (i >= 2) 3 else 0)) + @as(u16, if (i % 2 == 1) 3 else 0);
        operator(chip, offset, ins.ops[i], if (carrier(ins, i)) volume else 127);
    }
    pan(chip, channel, ins, 64);
}

pub fn carrier(ins: view.OplPatch, index: usize) bool {
    if (ins.op_count != 4) return index == 1 or ins.additive;
    return switch (index) {
        0 => ins.algorithm & 2 != 0,
        1 => ins.algorithm == 1,
        2 => ins.algorithm == 3,
        else => true,
    };
}

pub fn patchLevel(chip: fmt.Chip, channel: u8, ins: view.OplPatch, volume: u8) void {
    for (0..ins.op_count) |i| {
        if (!carrier(ins, i)) continue;
        const offset = operatorOffset(channel + @as(u8, if (i >= 2) 3 else 0)) + @as(u16, if (i % 2 == 1) 3 else 0);
        level(chip, offset, ins.ops[i], volume);
    }
}

pub fn pan(chip: fmt.Chip, channel: u8, ins: view.OplPatch, position: u8) void {
    const speakers: u8 = if (position < 32) 0x10 else if (position >= 96) 0x20 else 0x30;
    chip.writeReg(channelRegister(channel, 0xc0), @as(u8, ins.feedback) << 1 | (if (ins.op_count == 4) (ins.algorithm >> 1) & 1 else @as(u8, @intFromBool(ins.additive))) | speakers);
    if (ins.op_count == 4) chip.writeReg(channelRegister(channel + 3, 0xc0), @as(u8, ins.feedback2) << 1 | (ins.algorithm & 1) | speakers);
}

pub fn frequency(note: f64) u16 {
    var fnum = 440.0 * std.math.pow(f64, 2, (std.math.clamp(note, 0, 127) - 69) / 12) * 1048576.0 / 49716.0;
    var block: u16 = 0;
    while (fnum > 1023 and block < 7) : (block += 1) fnum /= 2;
    return block << 10 | @as(u16, @intFromFloat(@min(1023, @round(fnum))));
}

pub fn pitch(chip: fmt.Chip, channel: u8, note: f64, keyed: bool) void {
    const f = frequency(note);
    chip.writeReg(channelRegister(channel, 0xa0), @truncate(f));
    chip.writeReg(channelRegister(channel, 0xb0), @as(u8, @intCast(f >> 8)) | if (keyed) @as(u8, 0x20) else 0);
}

pub fn off(chip: fmt.Chip, channel: u8) void {
    chip.writeReg(channelRegister(channel, 0xb0), 0);
}

pub fn bankOperator(bytes: []const u8, wave: u8) view.OperatorParams {
    return .{
        .ksl = @truncate(bytes[0]),
        .mult = @truncate(bytes[1]),
        .attack = @truncate(bytes[3]),
        .sustain = @truncate(bytes[4]),
        .sustaining = bytes[5] != 0,
        .decay = @truncate(bytes[6]),
        .release = @truncate(bytes[7]),
        .level = @truncate(bytes[8]),
        .tremolo = bytes[9] != 0,
        .vibrato = bytes[10] != 0,
        .ksr = bytes[11] != 0,
        .wave = @truncate(wave),
    };
}
