//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.data.len -| self.pos) return error.InvalidMusicData;
        const bytes = self.data[self.pos..][0..n];
        self.pos += n;
        return bytes;
    }

    pub fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    pub fn int(self: *Reader, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    pub fn float(self: *Reader) !f32 {
        const value: f32 = @bitCast(try self.int(u32));
        if (!std.math.isFinite(value)) return error.InvalidMusicData;
        return value;
    }

    pub fn vlq(self: *Reader) !u32 {
        var value: u32 = 0;
        for (0..4) |_| {
            const b = try self.byte();
            value = (value << 7) | (b & 0x7f);
            if (b & 0x80 == 0) return value;
        }
        return error.InvalidMusicData;
    }
};

pub fn text(bytes: []const u8) []const u8 {
    return std.mem.trimEnd(u8, bytes[0 .. std.mem.findScalar(u8, bytes, 0) orelse bytes.len], " ");
}
