//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "Example";
pub const extensions = &.{".example"};
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

const ExampleSource = struct {
    data: []const u8,
    pos: usize = 0,
    sample_rate: u32,
    frac: u32 = 0,
    total_ticks: u64,

    pub fn step(self: *ExampleSource, chip: fmt.Chip) fmt.StepResult {
        if (self.pos + 4 > self.data.len) {
            self.pos = 0;
            return .{ .frames = 0, .done = true };
        }
        const reg = self.data[self.pos];
        const value = self.data[self.pos + 1];
        const delay = fmt.readU16Le(self.data, self.pos + 2);
        self.pos += 4;
        chip.writeReg(reg, value);
        return .{ .frames = fmt.rescale(delay, 560, self.sample_rate, &self.frac) };
    }

    pub fn info(_: *ExampleSource) fmt.TrackInfo {
        return .{
            .format_name = "Example",
            .system = "OPL2",
            .loop = true,
        };
    }

    pub fn durationFrames(self: *ExampleSource) u64 {
        return self.total_ticks * self.sample_rate / 560;
    }

    pub fn dumpView(self: *ExampleSource) view.DumpView {
        return .{
            .chip = .opl2,
            .write_count = @intCast(self.data.len / 4),
            .header_tick = 560,
        };
    }

    pub fn deinit(self: *ExampleSource, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.destroy(self);
    }
};

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    if (data.len < 4 or data.len % 4 != 0) return error.InvalidExample;

    const copy = try gpa.dupe(u8, data);
    errdefer gpa.free(copy);
    const src = try gpa.create(ExampleSource);
    errdefer gpa.destroy(src);

    var total_ticks: u64 = 0;
    var pos: usize = 0;
    while (pos < copy.len) : (pos += 4) {
        total_ticks += fmt.readU16Le(copy, pos + 2);
    }
    src.* = .{
        .data = copy,
        .sample_rate = ctx.sample_rate,
        .total_ticks = total_ticks,
    };
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

test "example format loads and steps" {
    const data = [_]u8{ 0x20, 0x01, 0x01, 0x00 };
    var src = (try load(std.testing.allocator, &data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .name = "song.example",
    })).?;
    defer src.deinit(std.testing.allocator);

    try std.testing.expect(src.step(fmt.noop_chip).frames > 0);
    try std.testing.expect(src.step(fmt.noop_chip).done);
}
