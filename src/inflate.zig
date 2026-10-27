//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub fn decode(gpa: std.mem.Allocator, data: []const u8, container: flate.Container, limit: usize) ![]u8 {
    const padded_len = std.math.add(usize, data.len, 8) catch return error.StreamTooLong;
    const padded = try gpa.alloc(u8, @max(padded_len, 10));
    defer gpa.free(padded);
    @memcpy(padded[0..data.len], data);
    @memset(padded[data.len..], 0);
    var input: Io.Reader = .{
        .vtable = &.{ .stream = exhausted },
        .buffer = padded,
        .seek = 0,
        .end = padded.len,
    };
    var window: [flate.max_window_len]u8 = undefined;
    var decoder: flate.Decompress = .init(&input, container, &window);
    const bytes = try decoder.reader.allocRemaining(gpa, .limited(limit));
    errdefer gpa.free(bytes);
    if (input.seek > data.len) return error.ReadFailed;
    switch (decoder.container_metadata) {
        .raw => {},
        .gzip => |footer| {
            if (footer.crc != std.hash.Crc32.hash(bytes) or footer.count != @as(u32, @truncate(bytes.len)))
                return error.ReadFailed;
        },
        .zlib => |footer| {
            if (footer.adler != std.hash.Adler32.hash(bytes)) return error.ReadFailed;
        },
    }
    return bytes;
}

fn exhausted(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

// --- tests -------------------------------------------------------------------

test "compressed input rejects truncation, damaged checksums and oversized output" {
    const gzip = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff,
        0xf3, 0x0f, 0xf0, 0x51, 0xc8, 0x2d, 0x2d, 0xce, 0x4c, 0x56,
        0xf0, 0x1f, 0x65, 0x8d, 0xb2, 0xe8, 0xce, 0x02, 0x00, 0xe0,
        0xab, 0x44, 0x93, 0x80, 0x02, 0x00, 0x00,
    };
    const expected = comptime blk: {
        const unit = "OPL music ";
        var buf: [unit.len * 64]u8 = undefined;
        for (0..64) |i| buf[i * unit.len ..][0..unit.len].* = unit.*;
        const final = buf;
        break :blk &final;
    };
    const gpa = std.testing.allocator;
    for ([_]flate.Container{ .raw, .gzip }) |container| {
        const data = if (container == .raw) gzip[10 .. gzip.len - 8] else &gzip;
        const bytes = try decode(gpa, data, container, expected.len);
        defer gpa.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
        for (0..data.len) |len| {
            try std.testing.expectError(error.ReadFailed, decode(gpa, data[0..len], container, expected.len));
        }
        try std.testing.expectError(error.StreamTooLong, decode(gpa, data, container, expected.len - 1));
    }
    var damaged = gzip;
    damaged[damaged.len - 8] ^= 1;
    try std.testing.expectError(error.ReadFailed, decode(gpa, &damaged, .gzip, expected.len));
    damaged = gzip;
    damaged[damaged.len - 4] ^= 1;
    try std.testing.expectError(error.ReadFailed, decode(gpa, &damaged, .gzip, expected.len));
}
