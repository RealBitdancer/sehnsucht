//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const view = @import("view.zig");

pub const memory_size = 2 * 1024 * 1024;

pub const Adpcm = struct {
    memory: []u8,
    clock: u32,
    sample_rate: u32,
    registers: [14]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff },
    playing: bool = false,
    address: u32 = 0,
    low_nibble: bool = false,
    current_byte: u8 = 0,
    fraction: u16 = 0,
    clock_fraction: u64 = 0,
    prediction: i32 = 0,
    previous: i32 = 0,
    step_size: i32 = 127,
    level: u8 = 0,

    pub fn write(self: *Adpcm, reg: u8, value: u8) void {
        if (reg < 7 or reg > 0x14) return;
        self.registers[reg - 7] = value;
        switch (reg) {
            7 => {
                if (value & 0x80 != 0) self.start();
                if (value & 0x80 == 0 or value & 0x41 != 0) {
                    self.playing = false;
                    self.prediction = 0;
                    self.previous = 0;
                    self.level = 0;
                }
                if (value & 0xe0 == 0x60) self.address = self.startAddress();
            },
            0x0f => {
                if (self.registers[0] & 0xe0 == 0x60 and self.address < self.endAddress()) {
                    if (self.address < self.memory.len) self.memory[self.address] = value;
                    self.address += 1;
                }
            },
            else => {},
        }
    }

    fn addressShift(self: *const Adpcm) u5 {
        return if (self.registers[1] & 3 != 0) 5 else 2;
    }

    fn word(self: *const Adpcm, index: usize) u32 {
        return std.mem.readInt(u16, self.registers[index..][0..2], .little);
    }

    fn startAddress(self: *const Adpcm) u32 {
        return self.word(2) << self.addressShift();
    }

    fn endAddress(self: *const Adpcm) u32 {
        return (self.word(4) + 1) << self.addressShift();
    }

    fn limitAddress(self: *const Adpcm) u32 {
        return ((self.word(12) + 1) << self.addressShift()) - 1;
    }

    fn start(self: *Adpcm) void {
        self.playing = true;
        self.address = if (self.registers[0] & 0x20 != 0) self.startAddress() else 0;
        self.low_nibble = false;
        self.current_byte = 0;
        self.fraction = 0;
        self.prediction = 0;
        self.previous = 0;
        self.step_size = 127;
    }

    fn tick(self: *Adpcm) void {
        if (!self.playing) return;
        const phase = @as(u32, self.fraction) + self.word(9);
        self.fraction = @truncate(phase);
        if (phase < 65536) return;
        const external = self.registers[0] & 0x20 != 0;
        if (!self.low_nibble and external)
            self.current_byte = if (self.address < self.memory.len) self.memory[self.address] else 0xff;
        const nibble: u4 = @truncate(if (self.low_nibble) self.current_byte else self.current_byte >> 4);
        self.low_nibble = !self.low_nibble;
        if (!self.low_nibble) {
            if (external) {
                if (self.address + 1 == self.endAddress()) {
                    if (self.registers[0] & 0x10 != 0) {
                        self.start();
                    } else {
                        self.playing = false;
                        self.previous = 0;
                        self.prediction = 0;
                        return;
                    }
                } else if (self.address == self.limitAddress()) {
                    self.address = 0;
                } else {
                    self.address = (self.address + 1) & (memory_size - 1);
                }
            } else {
                self.current_byte = self.registers[8];
            }
        }
        self.previous = self.prediction;
        const magnitude = @divTrunc((@as(i32, nibble & 7) * 2 + 1) * self.step_size, 8);
        self.prediction = std.math.clamp(self.prediction + (if (nibble & 8 != 0) -magnitude else magnitude), -32768, 32767);
        const scale = [_]i32{ 57, 57, 57, 57, 77, 102, 128, 153 };
        self.step_size = std.math.clamp(@divTrunc(self.step_size * scale[nibble & 7], 64), 127, 24576);
    }

    pub fn sample(self: *Adpcm) i32 {
        const period = @as(u64, self.sample_rate) * 72;
        self.clock_fraction += self.clock;
        while (self.clock_fraction >= period) {
            self.clock_fraction -= period;
            self.tick();
        }
        if (!self.playing or self.registers[0] & 8 != 0) return 0;
        const interpolated = (@as(i64, self.previous) * (65536 - @as(i64, self.fraction)) + @as(i64, self.prediction) * self.fraction) >> 16;
        return @intCast((interpolated * self.registers[11]) >> 11);
    }

    pub fn state(self: *const Adpcm) view.PcmVoice {
        return .{
            .present = true,
            .playing = self.playing,
            .repeat = self.registers[0] & 0x10 != 0,
            .external = self.registers[0] & 0x20 != 0,
            .muted = self.registers[0] & 8 != 0,
            .start = self.startAddress(),
            .end = self.endAddress(),
            .position = self.address,
            .rate = @intCast(@as(u64, self.clock) * self.word(9) / (72 * 65536)),
            .volume = self.registers[11],
            .level = self.level,
        };
    }
};

test "Delta-T prediction and interpolation match reference samples across a loop" {
    var memory: [64]u8 = undefined;
    for (&memory, 0..) |*byte, i| byte.* = @truncate(i * 73 + 17);
    var voice = Adpcm{ .memory = &memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(9, 2);
    voice.write(11, 8);
    voice.write(16, 0x31);
    voice.write(17, 0x45);
    voice.write(18, 255);
    voice.write(7, 0xb0);
    for (0..200) |_| _ = voice.sample();
    const expected = [_]i32{ -838, -115, 609, 1013, 1105, 1197, 1289, 0, -5, -10, -15, -16, -9, -2, 5, 6 };
    for (expected) |sample| try std.testing.expectEqual(sample, voice.sample());
}

test "ADPCM memory playback obeys end repeat reset and speaker controls" {
    var memory = [_]u8{ 0x77, 0x18, 0xf0, 0x62 };
    var voice = Adpcm{ .memory = &memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(0x10, 0xff);
    voice.write(0x11, 0xff);
    voice.write(0x12, 0xff);
    voice.write(7, 0xa0);
    var audible = false;
    for (0..9) |_| audible = voice.sample() != 0 or audible;
    try std.testing.expect(audible);
    try std.testing.expect(!voice.playing);
    try std.testing.expectEqual(@as(i32, 0), voice.sample());
    voice.write(7, 0xb0);
    for (0..40) |_| _ = voice.sample();
    try std.testing.expect(voice.playing);
    voice.write(7, 0xb8);
    for (0..20) |_| try std.testing.expectEqual(@as(i32, 0), voice.sample());
    try std.testing.expect(voice.playing);
    voice.write(7, 1);
    try std.testing.expect(!voice.playing);
    voice.write(9, 0xff);
    voice.write(10, 0xff);
    voice.write(7, 0xa0);
    for (0..9) |_| _ = voice.sample();
    try std.testing.expectEqual(@as(u32, 0), voice.address);
    try std.testing.expect(voice.playing);
}

test "ADPCM limit register wraps the address before the end" {
    var memory: [64]u8 = @splat(0x77);
    var voice = Adpcm{ .memory = &memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(0x0b, 0xff);
    voice.write(0x0c, 0xff);
    voice.write(0x13, 0);
    voice.write(0x14, 0);
    voice.write(0x10, 0xff);
    voice.write(0x11, 0xff);
    voice.write(7, 0xa0);
    for (0..40) |_| _ = voice.sample();
    try std.testing.expect(voice.playing);
    try std.testing.expect(voice.address <= 3);
}

test "ADPCM address wraps at the memory size when it starts past the end" {
    const gpa = std.testing.allocator;
    const memory = try gpa.alloc(u8, memory_size);
    defer gpa.free(memory);
    @memset(memory, 0x77);
    var voice = Adpcm{ .memory = memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(8, 0x01);
    voice.write(9, 0xff);
    voice.write(0x0a, 0xff);
    voice.write(0x0b, 0);
    voice.write(0x0c, 0);
    voice.write(0x10, 0xff);
    voice.write(0x11, 0xff);
    voice.write(0x13, 0xff);
    voice.write(0x14, 0xff);
    voice.write(7, 0xa0);
    voice.write(8, 0x00);
    for (0..4096) |_| _ = voice.sample();
    try std.testing.expect(voice.address < memory_size);
}

test "ADPCM CPU writes stop at an end address at the top of memory" {
    const gpa = std.testing.allocator;
    const memory = try gpa.alloc(u8, memory_size);
    defer gpa.free(memory);
    @memset(memory, 0);
    var voice = Adpcm{ .memory = memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(8, 0x01);
    voice.write(9, 0xff);
    voice.write(0x0a, 0xff);
    voice.write(0x0b, 0xff);
    voice.write(0x0c, 0xff);
    voice.write(7, 0x60);
    for (0..40) |_| voice.write(0x0f, 0xab);
    try std.testing.expectEqual(@as(u32, memory_size), voice.address);
    try std.testing.expectEqual(@as(u8, 0xab), memory[memory_size - 1]);
    try std.testing.expectEqual(@as(u8, 0), memory[0]);
}

test "ADPCM CPU memory writes and direct data stay independent of FM registers" {
    var memory: [64]u8 = @splat(0xff);
    var voice = Adpcm{ .memory = &memory, .clock = 72 * 44100, .sample_rate = 44100 };
    voice.write(8, 2);
    voice.write(9, 1);
    voice.write(0x0b, 1);
    voice.write(7, 0x60);
    voice.write(0x0f, 0x12);
    voice.write(0x0f, 0x34);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, memory[32..34]);
    voice.write(0x10, 0xff);
    voice.write(0x11, 0xff);
    voice.write(0x12, 0xff);
    voice.write(7, 0x80);
    voice.write(0x0f, 0x77);
    var peak: u32 = 0;
    for (0..20) |_| peak = @max(peak, @abs(voice.sample()));
    try std.testing.expect(peak > 0);
    voice.write(0x12, 0);
    try std.testing.expectEqual(@as(i32, 0), voice.sample());
    try std.testing.expect(voice.playing);
}
