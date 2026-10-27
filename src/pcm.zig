//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const Sample = struct {
    data: []const i16 = &.{},
    channels: u2 = 1,
    loop_start: u32 = 0,
    loop_end: u32 = 0,

    pub fn frames(self: Sample) usize {
        return self.data.len / @max(self.channels, 1);
    }
};

pub const Voice = struct {
    sample: Sample = .{},
    position: u64 = 0,
    increment: u64 = 0,
    volume: u16 = 256,
    pan: u8 = 128,
    active: bool = false,

    pub fn start(self: *Voice, sample: Sample, hz: u32, rate: u32) void {
        self.sample = sample;
        self.position = 0;
        self.setRate(hz, rate);
        self.active = sample.frames() != 0 and (sample.channels == 1 or sample.channels == 2) and hz != 0 and rate != 0;
    }

    pub fn setRate(self: *Voice, hz: u32, rate: u32) void {
        self.increment = (@as(u64, hz) << 32) / @max(rate, 1);
    }

    pub fn mix(self: *Voice, stereo: []i32) void {
        if (!self.active) return;
        const frames = self.sample.frames();
        const loop_end = @min(self.sample.loop_end, frames);
        const looping = loop_end > self.sample.loop_start;
        const end = if (looping) loop_end else frames;
        var i: usize = 0;
        while (i + 1 < stereo.len) : (i += 2) {
            var index: usize = @intCast(self.position >> 32);
            if (index >= end) {
                if (!looping) {
                    self.active = false;
                    return;
                }
                const loop_begin = @as(u64, self.sample.loop_start) << 32;
                const length = @as(u64, end - self.sample.loop_start) << 32;
                self.position = loop_begin + (self.position - loop_begin) % length;
                index = @intCast(self.position >> 32);
            }
            const next = if (index + 1 < end) index + 1 else if (looping) self.sample.loop_start else index;
            const fraction: i64 = @intCast((self.position & 0xffffffff) >> 16);
            for (0..2) |channel| {
                const source_channel = if (self.sample.channels == 2) channel else 0;
                const a: i64 = self.sample.data[index * self.sample.channels + source_channel];
                const b: i64 = self.sample.data[next * self.sample.channels + source_channel];
                const sample = a + @divTrunc((b - a) * fraction, 65536);
                const pan: i64 = if (channel == 0) 255 - @as(i64, self.pan) else self.pan;
                const value = @divTrunc(sample * @min(self.volume, 256) * pan, 256 * 255);
                stereo[i + channel] = @intCast(std.math.clamp(@as(i64, stereo[i + channel]) + value, std.math.minInt(i32), std.math.maxInt(i32)));
            }
            self.position +|= self.increment;
        }
        if (!looping and self.position >> 32 >= end) self.active = false;
    }
};

// --- tests -------------------------------------------------------------------

test "PCM loop preserves fractional position across render calls" {
    const samples = [_]i16{ 0, 1000, 2000, 3000 };
    var voice = Voice{ .pan = 0 };
    voice.start(.{ .data = &samples, .loop_start = 1, .loop_end = 3 }, 22050, 44100);
    var first: [10]i32 = @splat(0);
    voice.mix(&first);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 500, 0, 1000, 0, 1500, 0, 2000, 0 }, &first);
    var tail: [6]i32 = @splat(0);
    voice.mix(&tail);
    try std.testing.expectEqualSlices(i32, &.{ 1500, 0, 1000, 0, 1500, 0 }, &tail);
}

test "PCM one-shot stops at its end and leaves other voices intact" {
    const samples = [_]i16{ 1000, -2000 };
    var voice = Voice{ .pan = 255 };
    voice.start(.{ .data = &samples, .channels = 2 }, 44100, 44100);
    var out = [_]i32{ 7, 7, 7, 7 };
    voice.mix(&out);
    try std.testing.expectEqualSlices(i32, &.{ 7, -1993, 7, 7 }, &out);
    try std.testing.expect(!voice.active);
}
