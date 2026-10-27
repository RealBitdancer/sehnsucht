//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const max_utf8_per_byte = 3;

const high_codepoints = blk: {
    const high = "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ";
    var values: [128]u21 = undefined;
    var iter = std.unicode.Utf8View.initComptime(high).iterator();
    var index = 0;
    while (iter.nextCodepoint()) |cp| {
        if (std.unicode.utf8CodepointSequenceLength(cp) catch unreachable > max_utf8_per_byte) @compileError("CP437 glyph exceeds max_utf8_per_byte");
        values[index] = cp;
        index += 1;
    }
    if (index != values.len) @compileError("CP437 table must cover 0x80 through 0xFF");
    break :blk values;
};

pub fn codepoint(byte: u8) u21 {
    if (byte >= 0x80) return high_codepoints[byte - 0x80];
    if (byte < 0x20 or byte == 0x7f) return ' ';
    return byte;
}

pub fn decode(dest: []u8, src: []const u8) []u8 {
    var len: usize = 0;
    for (src) |byte| {
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(codepoint(byte), &encoded) catch unreachable;
        if (n > dest.len - len) break;
        @memcpy(dest[len..][0..n], encoded[0..n]);
        len += n;
    }
    while (len != 0 and dest[len - 1] == ' ') len -= 1;
    return dest[0..len];
}

pub fn decodeAlloc(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, src.len * max_utf8_per_byte);
    defer gpa.free(buf);
    return gpa.dupe(u8, decode(buf, src));
}

pub fn decodeOptional(gpa: std.mem.Allocator, src: []const u8) !?[]u8 {
    const text = try decodeAlloc(gpa, src);
    if (text.len != 0) return text;
    gpa.free(text);
    return null;
}

// --- tests -------------------------------------------------------------------

test "decode maps DOS box drawing and accents and blanks control bytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("╔═╗ Café ±", decode(&buf, "\xC9\xCD\xBB\x01Caf\x82 \xF1  "));
    try std.testing.expectEqualStrings("plain", decode(&buf, "plain"));
    try std.testing.expectEqualStrings("\u{00A0}", decode(&buf, "\xFF"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(decode(&buf, &[_]u8{ 0x80, 0x9F, 0xE0, 0xFE })));
}

test "decode stops at a whole glyph when the buffer is full" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("A╔", decode(&buf, "A\xC9\xCD"));
}

test "decodeAlloc returns an exact owned copy" {
    const text = try decodeAlloc(std.testing.allocator, "\x80\x81 ");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Çü", text);
}

test "decodeOptional drops text that is only padding" {
    try std.testing.expectEqual(@as(?[]u8, null), try decodeOptional(std.testing.allocator, "  \x00 "));
    const text = (try decodeOptional(std.testing.allocator, "\xDB")).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("█", text);
}
