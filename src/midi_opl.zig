//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("format.zig");
const view = @import("view.zig");
const fm = @import("fm.zig");

pub const Channel = struct {
    program: u16 = 0,
    volume: u8 = 127,
    expression: u8 = 127,
    bend: u16 = 8192,
    sustain: bool = false,
    enabled: bool = true,
    polyphony: u8 = 9,
    velocity_enabled: bool = true,
    protected: bool = false,
    pan: u8 = 64,
};

const Voice = struct {
    channel: u8 = 0,
    program: u16 = 0,
    note: u8 = 0,
    sounding_note: u8 = 0,
    velocity: u8 = 0,
    keyed: bool = false,
    released: bool = false,
    age: u64 = 0,
    remaining: ?u32 = null,
    pair: ?u8 = null,
};

pub const Driver = struct {
    patches: []const view.OplPatch,
    channels: [16]Channel = @splat(.{}),
    voices: [18]Voice = @splat(.{}),
    generation: u64 = 0,
    opl3: bool = false,
    pairs: u6 = 0,

    pub fn reset(self: *Driver, chip: fmt.Chip) void {
        self.voices = @splat(.{});
        self.generation = 0;
        self.pairs = 0;
        chip.writeReg(1, 0x20);
        chip.writeReg(0xbd, 0);
        if (self.opl3) {
            chip.writeReg(0x105, 1);
            chip.writeReg(0x104, 0);
        }
        for (0..self.voiceCount()) |i| fm.off(chip, @intCast(i));
    }

    fn voiceCount(self: *const Driver) usize {
        return if (self.opl3) 18 else 9;
    }

    fn owner(self: *const Driver, index: u8) ?u8 {
        if (self.voices[index].keyed) return index;
        for (self.voices, 0..) |voice, i| if (voice.keyed and voice.pair == index) return @intCast(i);
        return null;
    }

    fn pairMask(index: u8) u6 {
        return @as(u6, 1) << @intCast(index / 9 * 3 + index % 9);
    }

    fn volume(self: *const Driver, voice: Voice) u8 {
        const ch = self.channels[voice.channel];
        return @intCast((@as(u32, ch.volume) * ch.expression * voice.velocity + 8064) / (127 * 127));
    }

    fn pitch(self: *const Driver, chip: fmt.Chip, index: u8) void {
        const voice = self.voices[index];
        const semitones = (@as(f64, @floatFromInt(self.channels[voice.channel].bend)) - 8192) * 12 / 8192;
        const note = @as(f64, @floatFromInt(voice.sounding_note)) + semitones;
        fm.pitch(chip, index, note, voice.keyed);
        if (voice.pair) |pair| fm.pitch(chip, pair, note, false);
    }

    fn stop(self: *Driver, chip: fmt.Chip, index: u8) void {
        self.voices[index].keyed = false;
        self.voices[index].remaining = null;
        self.pitch(chip, index);
    }

    fn unpair(self: *Driver, chip: fmt.Chip, index: u8) void {
        for (&self.voices, 0..) |*voice, i| if (voice.pair) |pair| if (i == index or pair == index) {
            voice.pair = null;
            self.pairs &= ~pairMask(@intCast(i));
            chip.writeReg(0x104, self.pairs);
        };
    }

    fn release(self: *Driver, chip: fmt.Chip, index: u8) void {
        const voice = &self.voices[index];
        voice.remaining = null;
        if (self.channels[voice.channel].sustain) voice.released = true else self.stop(chip, index);
    }

    pub fn noteOn(self: *Driver, chip: fmt.Chip, channel: u8, note: u8, velocity: u8, duration: ?u32) bool {
        return self.noteOnTuned(chip, channel, note, note, velocity, duration);
    }

    pub fn noteOnTuned(self: *Driver, chip: fmt.Chip, channel: u8, note: u8, sounding_note: u8, velocity: u8, duration: ?u32) bool {
        if (channel >= self.channels.len) return false;
        const ch = self.channels[channel];
        if (velocity == 0) {
            self.noteOff(chip, channel, note);
            return false;
        }
        if (!ch.enabled or ch.polyphony == 0 or ch.program >= self.patches.len) return false;
        const patch = self.patches[ch.program];
        const paired = patch.op_count == 4;
        if (paired and !self.opl3) return false;
        var count: u8 = 0;
        var oldest: ?u8 = null;
        for (self.voices, 0..) |voice, i| {
            if (!voice.keyed or voice.channel != channel) continue;
            count += 1;
            if (oldest == null or voice.age < self.voices[oldest.?].age) oldest = @intCast(i);
        }
        if (count >= ch.polyphony) if (oldest) |index| self.stop(chip, index);
        var selected: ?u8 = null;
        var best_age: u64 = std.math.maxInt(u64);
        for (0..self.voiceCount()) |i| {
            if (paired and i % 9 >= 3) continue;
            const index: u8 = @intCast(i);
            const occupied = [_]?u8{ self.owner(index), if (paired) self.owner(index + 3) else null };
            var age: u64 = 0;
            var protected = false;
            for (occupied) |slot| if (slot) |owner_index| {
                const voice = self.voices[owner_index];
                if (self.channels[voice.channel].protected and voice.channel != channel) protected = true;
                age = @max(age, voice.age);
            };
            if (!protected and (selected == null or age < best_age)) {
                selected = index;
                best_age = age;
                if (age == 0) break;
            }
        }
        const index = selected orelse return false;
        if (self.owner(index)) |slot| self.stop(chip, slot);
        if (paired) if (self.owner(index + 3)) |slot| self.stop(chip, slot);
        self.unpair(chip, index);
        self.generation +%= 1;
        self.voices[index] = .{ .channel = channel, .program = ch.program, .note = note, .sounding_note = sounding_note, .velocity = if (ch.velocity_enabled) velocity else 127, .keyed = true, .age = self.generation, .remaining = duration, .pair = if (paired) index + 3 else null };
        if (paired) {
            self.voices[index + 3] = .{};
            self.pairs |= pairMask(index);
            chip.writeReg(0x104, self.pairs);
        }
        fm.patch(chip, index, patch, self.volume(self.voices[index]));
        if (self.opl3) fm.pan(chip, index, patch, ch.pan);
        self.pitch(chip, index);
        return true;
    }

    pub fn noteOff(self: *Driver, chip: fmt.Chip, channel: u8, note: u8) void {
        for (&self.voices, 0..) |*voice, i| {
            if (!voice.keyed or voice.channel != channel or voice.note != note) continue;
            self.release(chip, @intCast(i));
        }
    }

    pub fn advance(self: *Driver, chip: fmt.Chip, ticks: u32) void {
        for (&self.voices, 0..) |*voice, i| {
            if (voice.remaining) |remaining| {
                if (ticks >= remaining) self.release(chip, @intCast(i)) else voice.remaining = remaining - ticks;
            }
        }
    }

    pub fn nextRelease(self: *const Driver) ?u32 {
        var next: ?u32 = null;
        for (self.voices) |voice| {
            if (voice.remaining) |remaining| next = @min(next orelse remaining, remaining);
        }
        return next;
    }

    pub fn bend(self: *Driver, chip: fmt.Chip, channel: u8, value: u16) void {
        self.channels[channel].bend = @min(value, 16383);
        for (self.voices, 0..) |voice, i| if (voice.keyed and voice.channel == channel) self.pitch(chip, @intCast(i));
    }

    pub fn setPolyphony(self: *Driver, chip: fmt.Chip, channel: u8, count: u8) void {
        self.channels[channel].polyphony = count;
        while (true) {
            var active: usize = 0;
            var oldest: ?u8 = null;
            for (self.voices, 0..) |voice, i| {
                if (!voice.keyed or voice.channel != channel) continue;
                active += 1;
                if (oldest == null or voice.age < self.voices[oldest.?].age) oldest = @intCast(i);
            }
            if (active <= count) return;
            self.stop(chip, oldest.?);
        }
    }

    pub fn control(self: *Driver, chip: fmt.Chip, channel: u8, cc: u8, value: u8) void {
        const ch = &self.channels[channel];
        switch (cc) {
            7 => ch.volume = value,
            10 => {
                ch.pan = value;
                if (self.opl3) for (self.voices, 0..) |voice, i| {
                    if (voice.keyed and voice.channel == channel) fm.pan(chip, @intCast(i), self.patches[voice.program], value);
                };
            },
            11 => ch.expression = value,
            64 => {
                ch.sustain = value >= 64;
                if (!ch.sustain) for (self.voices, 0..) |voice, i| {
                    if (voice.keyed and voice.channel == channel and voice.released) self.stop(chip, @intCast(i));
                };
            },
            120 => {
                for (self.voices, 0..) |voice, i| {
                    if (voice.keyed and voice.channel == channel) self.stop(chip, @intCast(i));
                }
            },
            123 => {
                for (self.voices, 0..) |voice, i| {
                    if (voice.keyed and voice.channel == channel) self.release(chip, @intCast(i));
                }
            },
            121 => {
                ch.expression = 127;
                ch.sustain = false;
                for (self.voices, 0..) |voice, i| {
                    if (voice.keyed and voice.channel == channel and voice.released) self.stop(chip, @intCast(i));
                }
                self.bend(chip, channel, 8192);
            },
            else => {},
        }
        if (cc == 7 or cc == 11 or cc == 121) for (self.voices, 0..) |voice, i| {
            if (!voice.keyed or voice.channel != channel) continue;
            fm.patchLevel(chip, @intCast(i), self.patches[voice.program], self.volume(voice));
        };
    }

    pub fn state(self: *const Driver) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = 16 };
        for (self.channels, 0..) |channel, i| bank.slots[i] = .{ .program = channel.program, .bend = channel.bend };
        for (self.voices, 0..) |voice, i| {
            if (voice.age == 0) continue;
            bank.voices[bank.voice_count] = .{ .channel = voice.channel, .program = voice.program, .note = voice.note, .velocity = voice.velocity, .opl_voice = @intCast(i), .keyed = voice.keyed };
            bank.voice_count += 1;
            if (!voice.keyed) continue;
            const slot = &bank.slots[voice.channel];
            slot.keyed = true;
            slot.note = voice.note;
            slot.opl_voice = @intCast(i);
        }
        return bank;
    }
};

// --- tests -------------------------------------------------------------------

fn keyedCount(bank: view.SequenceStateBank) u16 {
    var count: u16 = 0;
    for (bank.voices[0..bank.voice_count]) |voice| count += @intFromBool(voice.keyed);
    return count;
}

test "duration releases respect sustain without ending overlapping notes" {
    var driver = Driver{ .patches = &.{.{}} };
    driver.control(fmt.noop_chip, 0, 64, 127);
    _ = driver.noteOn(fmt.noop_chip, 0, 60, 100, 1);
    _ = driver.noteOn(fmt.noop_chip, 0, 60, 100, 2);
    driver.advance(fmt.noop_chip, 1);
    try std.testing.expectEqual(@as(u16, 2), keyedCount(driver.state()));
    try std.testing.expectEqual(@as(?u32, 1), driver.nextRelease());
    driver.control(fmt.noop_chip, 0, 64, 0);
    try std.testing.expectEqual(@as(u16, 1), keyedCount(driver.state()));
    driver.advance(fmt.noop_chip, 1);
    try std.testing.expectEqual(@as(u16, 0), keyedCount(driver.state()));
}

test "OPL3 allocation reserves both halves and protects four-operator voices" {
    var driver = Driver{ .patches = &.{ .{ .op_count = 4 }, .{} }, .opl3 = true };
    driver.reset(fmt.noop_chip);
    driver.channels[0].protected = true;
    for (0..6) |i| _ = driver.noteOn(fmt.noop_chip, 0, @intCast(60 + i), 100, 1);
    try std.testing.expectEqual(@as(u6, 63), driver.pairs);
    try std.testing.expectEqual(@as(u16, 6), keyedCount(driver.state()));
    try std.testing.expect(!driver.noteOn(fmt.noop_chip, 1, 72, 100, null));
    try std.testing.expectEqual(@as(u16, 6), keyedCount(driver.state()));
    driver.channels[1].program = 1;
    for (0..6) |i| try std.testing.expect(driver.noteOn(fmt.noop_chip, 1, @intCast(72 + i), 100, null));
    try std.testing.expectEqual(@as(u16, 12), keyedCount(driver.state()));
    for (driver.voices, 0..) |voice, index| {
        if (voice.keyed and voice.channel == 1) try std.testing.expect(index % 9 >= 6);
    }
    driver.advance(fmt.noop_chip, 1);
    try std.testing.expectEqual(@as(u6, 63), driver.pairs);
    try std.testing.expectEqual(@as(u16, 6), keyedCount(driver.state()));
    try std.testing.expect(driver.noteOn(fmt.noop_chip, 1, 80, 100, null));
    try std.testing.expectEqual(@as(u6, 62), driver.pairs);
}

const Registers = struct {
    values: [0x200]u8 = @splat(0),
    fn write(ptr: *anyopaque, reg: u16, value: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.values[reg] = value;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

test "a released note keeps its pitch while it decays" {
    var regs: Registers = .{};
    const chip = regs.chip();
    var driver = Driver{ .patches = &.{.{}} };
    driver.reset(chip);
    const f = fm.frequency(69);
    _ = driver.noteOn(chip, 0, 69, 100, 4);
    try std.testing.expectEqual(@as(u8, @intCast(f >> 8)) | 0x20, regs.values[0xb0]);
    driver.advance(chip, 4);
    try std.testing.expectEqual(@as(u8, @truncate(f)), regs.values[0xa0]);
    try std.testing.expectEqual(@as(u8, @intCast(f >> 8)), regs.values[0xb0]);
    driver.control(chip, 0, 64, 127);
    _ = driver.noteOn(chip, 0, 69, 100, null);
    driver.noteOff(chip, 0, 69);
    try std.testing.expectEqual(@as(u8, @intCast(f >> 8)) | 0x20, regs.values[0xb0]);
    driver.control(chip, 0, 64, 0);
    try std.testing.expectEqual(@as(u8, @intCast(f >> 8)), regs.values[0xb0]);
}

test "a released four-operator voice keeps its pair until a note takes the slot" {
    var regs: Registers = .{};
    const chip = regs.chip();
    var driver = Driver{ .patches = &.{ .{ .op_count = 4 }, .{} }, .opl3 = true };
    driver.reset(chip);
    const f = fm.frequency(69);
    _ = driver.noteOn(chip, 0, 69, 100, null);
    driver.noteOff(chip, 0, 69);
    try std.testing.expectEqual(@as(u8, 1), regs.values[0x104]);
    for ([_]u16{ 0, 3 }) |channel| {
        try std.testing.expectEqual(@as(u8, @truncate(f)), regs.values[0xa0 + channel]);
        try std.testing.expectEqual(@as(u8, @intCast(f >> 8)), regs.values[0xb0 + channel]);
    }
    driver.channels[1].program = 1;
    try std.testing.expect(driver.noteOn(chip, 1, 72, 100, null));
    try std.testing.expectEqual(@as(u8, 0), regs.values[0x104]);
    try std.testing.expectEqual(@as(u16, 1), driver.state().voices[0].channel);
}

test "pitch bend spans twelve semitones each way" {
    var regs: Registers = .{};
    const chip = regs.chip();
    var driver = Driver{ .patches = &.{.{}} };
    driver.reset(chip);
    _ = driver.noteOn(chip, 0, 60, 100, null);
    for ([_]u16{ 16383, 0 }, [_]f64{ 60 + 12.0 * 8191.0 / 8192.0, 48 }) |value, note| {
        driver.bend(chip, 0, value);
        const f = fm.frequency(note);
        try std.testing.expectEqual(@as(u8, @truncate(f)), regs.values[0xa0]);
        try std.testing.expectEqual(@as(u8, @intCast(f >> 8)) | 0x20, regs.values[0xb0]);
    }
}

test "a released voice stays published until a note or a four-operator pair takes it" {
    var driver = Driver{ .patches = &.{ .{}, .{ .op_count = 4 } }, .opl3 = true };
    driver.reset(fmt.noop_chip);
    for (0..4) |i| _ = driver.noteOn(fmt.noop_chip, 0, @intCast(60 + i), 100, null);
    for (0..4) |i| driver.noteOff(fmt.noop_chip, 0, @intCast(60 + i));
    const released = driver.state();
    try std.testing.expectEqual(@as(u16, 4), released.voice_count);
    for (released.voices[0..4], 0..) |voice, i| {
        try std.testing.expect(!voice.keyed);
        try std.testing.expectEqual(@as(u16, 0), voice.channel);
        try std.testing.expectEqual(@as(u8, @intCast(i)), voice.opl_voice);
    }
    try std.testing.expect(!released.slots[0].keyed);
    driver.channels[1].program = 1;
    try std.testing.expect(driver.noteOn(fmt.noop_chip, 1, 72, 100, null));
    const paired = driver.state();
    try std.testing.expectEqual(@as(u16, 3), paired.voice_count);
    try std.testing.expectEqual(@as(u16, 1), paired.voices[0].channel);
    try std.testing.expect(paired.voices[0].keyed);
    for (paired.voices[1..3], [_]u8{ 1, 2 }) |voice, opl_voice| {
        try std.testing.expectEqual(@as(u16, 0), voice.channel);
        try std.testing.expectEqual(opl_voice, voice.opl_voice);
    }
}

test "all sound off and controller reset leave idle voice slots alone" {
    const Counter = struct {
        writes: usize = 0,
        fn write(ptr: *anyopaque, _: u16, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
        }
        fn flush(_: *anyopaque) void {}
    };
    var counter: Counter = .{};
    const chip: fmt.Chip = .{ .ptr = &counter, .vtable = &.{ .writeReg = Counter.write, .flush = Counter.flush } };
    var driver = Driver{ .patches = &.{.{}} };
    driver.reset(chip);
    driver.control(chip, 0, 64, 127);
    _ = driver.noteOn(chip, 0, 60, 100, null);
    _ = driver.noteOn(chip, 0, 62, 100, null);
    driver.noteOff(chip, 0, 60);
    driver.noteOff(chip, 0, 62);
    driver.control(chip, 0, 64, 0);
    try std.testing.expect(driver.noteOn(chip, 1, 64, 100, null));
    counter.writes = 0;
    driver.control(chip, 0, 120, 0);
    driver.control(chip, 0, 121, 0);
    try std.testing.expectEqual(@as(usize, 0), counter.writes);
    try std.testing.expectEqual(@as(u16, 1), keyedCount(driver.state()));
    try std.testing.expectEqual(@as(u16, 1), driver.state().voices[0].channel);
}
