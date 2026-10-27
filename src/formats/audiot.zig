//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");
const imf = @import("imf.zig");

pub const format_name = "AudioT";
pub const extensions: []const []const u8 = &.{};
pub const visualizer_name = imf.visualizer_name;
pub const view_caps = imf.view_caps;

const wolf_exts = [_][]const u8{ ".wl1", ".wl6", ".sod", ".sdm", ".sd1", ".sd2", ".sd3", ".bs6", ".bs1", ".vsi", ".co7", ".bc" };

fn matchesStem(base: []const u8, stem: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(base, stem)) return false;
    return base.len == stem.len or base[stem.len] == '.';
}

pub fn matchesPath(path: []const u8) bool {
    const base = fmt.basenameOf(path);
    return isDataName(base) or isHedName(base) or isCompressedDataName(base);
}

fn isHedName(base: []const u8) bool {
    return matchesStem(base, "AUDIOHED");
}

fn isDataName(base: []const u8) bool {
    return matchesStem(base, "AUDIOT");
}

/// `AUDIO.ext` is the Huffman-compressed archive. The dot rule keeps
/// `AUDIOT`, `AUDIOHED`, and `AUDIODCT` from matching this stem.
fn isCompressedDataName(base: []const u8) bool {
    return matchesStem(base, "AUDIO");
}

fn siblingName(gpa: std.mem.Allocator, base: []const u8) !?[]u8 {
    if (isHedName(base)) {
        return try gpa.print("AUDIOT{s}", .{base["AUDIOHED".len..]});
    }
    if (isDataName(base)) {
        return try gpa.print("AUDIOHED{s}", .{base["AUDIOT".len..]});
    }
    if (isCompressedDataName(base)) {
        return try gpa.print("AUDIOHED{s}", .{base["AUDIO".len..]});
    }
    return null;
}

fn siblingPath(gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    const sib = (try siblingName(gpa, fmt.basenameOf(path))) orelse return null;
    defer gpa.free(sib);
    return try fmt.joinDir(gpa, fmt.dirnameOf(path), sib);
}

/// An `AUDIOHED` entry falls back to the compressed data file when the
/// uncompressed one is missing (Keen 4-6 sets have no `AUDIOT`).
fn siblingAltPath(gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    const base = fmt.basenameOf(path);
    if (!isHedName(base)) return null;
    const alt = try gpa.print("AUDIO{s}", .{base["AUDIOHED".len..]});
    defer gpa.free(alt);
    return try fmt.joinDir(gpa, fmt.dirnameOf(path), alt);
}

fn sibling2Path(gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    const base = fmt.basenameOf(path);
    const ext = if (isCompressedDataName(base))
        base["AUDIO".len..]
    else if (isHedName(base))
        base["AUDIOHED".len..]
    else
        return null;
    const dict = try gpa.print("AUDIODCT{s}", .{ext});
    defer gpa.free(dict);
    return try fmt.joinDir(gpa, fmt.dirnameOf(path), dict);
}

fn rateForAudioT(ext: []const u8, forced: u32) u32 {
    if (forced != 0) return forced;
    for (wolf_exts) |w| {
        if (std.ascii.eqlIgnoreCase(ext, w)) return 700;
    }
    return 560;
}

const Chunk = struct { index: usize, off: usize, len: usize };

fn collectChunks(gpa: std.mem.Allocator, hed: []const u8, data_len: usize) ![]Chunk {
    if (hed.len < 8 or hed.len % 4 != 0) return error.BadAudioHed;
    const n = hed.len / 4;
    if (n < 2) return error.BadAudioHed;

    var list: std.ArrayList(Chunk) = .empty;
    errdefer list.deinit(gpa);

    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const a = std.mem.readInt(u32, hed[i * 4 ..][0..4], .little);
        const b = std.mem.readInt(u32, hed[(i + 1) * 4 ..][0..4], .little);
        if (b < a or b > data_len or a > data_len) continue;
        const len = b - a;
        if (len == 0) continue;
        try list.append(gpa, .{ .index = i, .off = a, .len = len });
    }
    if (list.items.len == 0) return error.EmptyAudioT;
    return try list.toOwnedSlice(gpa);
}

fn musicStart(hed: []const u8, data: []const u8, chunks: []const Chunk) usize {
    var sounds: ?usize = null;
    for (chunks) |chunk| {
        if (!std.mem.endsWith(u8, data[chunk.off..][0..chunk.len], "!ID!")) continue;
        const count = sounds orelse {
            sounds = chunk.index + 1;
            continue;
        };
        if (chunk.index + 1 != count * 2 or count * 3 >= hed.len / 4) return 0;
        for (count * 2..count * 3) |index| {
            const start = fmt.readU32Le(hed, index * 4);
            const end = fmt.readU32Le(hed, (index + 1) * 4);
            if (start == end or start == 0xffffffff) continue;
            if (end < start or end > data.len or !std.mem.eql(u8, data[start..end], "!ID!")) return 0;
        }
        return count * 3;
    }
    return 0;
}

fn musicStream(data: []const u8) ?[]const u8 {
    if (data.len < 4) return null;
    for ([_]usize{ 2, 4 }) |header| {
        const length = if (header == 2) std.mem.readInt(u16, data[0..2], .little) else fmt.readU32Le(data, 0);
        if (length == 0 or length > data.len - header) continue;
        var footer = data[header + length ..];
        if (std.mem.endsWith(u8, footer, "!ID!")) footer = footer[0 .. footer.len - 4];
        if (footer.len != 0 and footer.len != 88) continue;
        const stream = data[header..][0..length];
        if (validStream(stream)) return stream;
    }
    const bare = if (std.mem.endsWith(u8, data, "!ID!")) data[0 .. data.len - 4] else data;
    return if (std.mem.readInt(u16, data[0..2], .little) == 0 and validStream(bare)) bare else null;
}

fn validStream(stream: []const u8) bool {
    if (stream.len == 0 or stream.len % 4 != 0) return false;
    var timed = false;
    var offset: usize = 0;
    while (offset < stream.len) : (offset += 4) {
        switch (stream[offset]) {
            0...4, 8, 0x20...0x35, 0x40...0x55, 0x60...0x75, 0x80...0x95, 0xa0...0xa8, 0xb0...0xb8, 0xbd, 0xc0...0xc8, 0xe0...0xf5 => {},
            else => return false,
        }
        timed = timed or fmt.readU16Le(stream, offset + 2) != 0;
    }
    return timed;
}

const dict_bytes = 1020;
const huff_root = 254;

/// id Software's Huffman expansion (CAL_HuffExpand): 255 nodes of two
/// little-endian u16 links, root at node 254, source bits consumed LSB first.
/// A link below 256 emits that byte, anything else minus 256 is the next node.
fn huffExpand(gpa: std.mem.Allocator, dict: []const u8, src: []const u8, expanded_len: usize) ![]u8 {
    if (dict.len < dict_bytes) return error.BadAudioDict;
    const out = try gpa.alloc(u8, expanded_len);
    errdefer gpa.free(out);
    var node: usize = huff_root;
    var filled: usize = 0;
    outer: for (src) |byte| {
        var mask: u8 = 1;
        while (true) {
            const branch: usize = if (byte & mask != 0) 2 else 0;
            const val = std.mem.readInt(u16, dict[node * 4 + branch ..][0..2], .little);
            if (val < 256) {
                out[filled] = @intCast(val);
                filled += 1;
                if (filled == expanded_len) break :outer;
                node = huff_root;
            } else {
                node = val - 256;
                if (node >= 255) return error.BadAudioDict;
            }
            if (mask == 0x80) break;
            mask <<= 1;
        }
    }
    if (filled != expanded_len) return error.BadAudioChunk;
    return out;
}

pub fn companions(gpa: std.mem.Allocator, path: []const u8) anyerror!fmt.CompanionPaths {
    const sibling = try siblingPath(gpa, path);
    errdefer if (sibling) |s| gpa.free(s);
    const sibling_alt = try siblingAltPath(gpa, path);
    errdefer if (sibling_alt) |s| gpa.free(s);
    const sibling2 = try sibling2Path(gpa, path);
    return .{ .sibling = sibling, .sibling_alt = sibling_alt, .sibling2 = sibling2 };
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const base = ctx.name;
    const from_hed = isHedName(base);
    const from_audio = isCompressedDataName(base);
    if (!from_hed and !isDataName(base) and !from_audio) return null;

    const sibling = ctx.sibling orelse return error.AudioTNeedsSibling;
    const hed = if (from_hed) data else sibling;
    const audiot = if (from_hed) sibling else data;
    const compressed = from_audio or (from_hed and ctx.sibling_is_alt);

    const owned_data_name: ?[]u8 = if (!from_hed)
        null
    else if (ctx.sibling_is_alt)
        try gpa.print("AUDIO{s}", .{base["AUDIOHED".len..]})
    else
        (try siblingName(gpa, base)) orelse return error.BadAudioHed;
    defer if (owned_data_name) |p| gpa.free(p);
    const data_name: []const u8 = owned_data_name orelse base;

    const chunks = try collectChunks(gpa, hed, audiot.len);
    defer gpa.free(chunks);
    const first_music = musicStart(hed, audiot, chunks);

    var music: std.ArrayList([]const u8) = .empty;
    defer music.deinit(gpa);
    var expanded: std.ArrayList([]u8) = .empty;
    defer {
        for (expanded.items) |b| gpa.free(b);
        expanded.deinit(gpa);
    }
    var work_budget: usize = 2 * fmt.max_input_bytes;

    if (compressed) {
        const dict = ctx.sibling2 orelse return error.AudioTNeedsDict;
        // Retained expansions share one archive-wide budget. Attempts share a
        // second, charged by source size even when the chunk is discarded, so
        // a hostile header cannot burn CPU on repeated Huffman walks.
        var budget: usize = fmt.max_input_bytes;
        for (chunks) |c| {
            if (c.index < first_music) continue;
            const piece = audiot[c.off .. c.off + c.len];
            if (piece.len < 5) continue;
            const expanded_len = fmt.readU32Le(piece, 0);
            const retained_size = @as(u64, expanded_len) + 2 * @sizeOf([]u8);
            if (expanded_len < 4 or retained_size > budget) continue;
            if (piece.len > work_budget) break;
            work_budget -= piece.len;
            const body = huffExpand(gpa, dict, piece[4..], expanded_len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const stream = musicStream(body) orelse {
                gpa.free(body);
                continue;
            };
            expanded.append(gpa, body) catch |err| {
                gpa.free(body);
                return err;
            };
            try music.append(gpa, stream);
            budget -= @intCast(retained_size);
        }
    } else {
        for (chunks) |c| {
            if (c.index < first_music) continue;
            const piece = audiot[c.off .. c.off + c.len];
            if (piece.len > work_budget) break;
            work_budget -= piece.len;
            if (musicStream(piece)) |stream| try music.append(gpa, stream);
        }
    }
    if (music.items.len == 0) return error.NoMusicInAudioT;

    const idx = @min(ctx.track_index, @as(u32, @intCast(music.items.len - 1)));
    const stream = music.items[idx];

    const rate = rateForAudioT(ctx.ext, ctx.tick_rate_hz);
    const display_base = try fmt.dupeDisplayBasename(gpa, data_name);
    defer gpa.free(display_base);
    const title = try gpa.print("{s} track {d}/{d}", .{
        display_base,
        idx + 1,
        music.items.len,
    });
    defer gpa.free(title);

    return try imf.openStream(gpa, stream, .{
        .sample_rate = ctx.sample_rate,
        .rate = rate,
        .format_label = "AudioT",
        .title = title,
        .archive = .{ .count = @intCast(music.items.len), .index = idx },
    });
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

test "audiot hed chunk parse" {
    const gpa = std.testing.allocator;
    var hed: [16]u8 = undefined;
    std.mem.writeInt(u32, hed[0..4], 0, .little);
    std.mem.writeInt(u32, hed[4..8], 10, .little);
    std.mem.writeInt(u32, hed[8..12], 50, .little);
    std.mem.writeInt(u32, hed[12..16], 100, .little);
    const chunks = try collectChunks(gpa, &hed, 100);
    defer gpa.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqual(@as(usize, 10), chunks[0].len);
    try std.testing.expectEqual(@as(usize, 40), chunks[1].len);
    try std.testing.expectEqual(@as(usize, 50), chunks[2].len);
}

test "audiot matches path basenames" {
    try std.testing.expect(matchesPath("game/AUDIOT.WL6"));
    try std.testing.expect(matchesPath("AUDIOHED.CK4"));
    try std.testing.expect(matchesPath("audiot.wl1"));
    try std.testing.expect(matchesPath("AUDIOT"));
    try std.testing.expect(matchesPath("game/AUDIO.CK4"));
    try std.testing.expect(matchesPath("audio.ck5"));
    try std.testing.expect(!matchesPath("AUDIODCT.CK4"));
    try std.testing.expect(!matchesPath("song.imf"));
    try std.testing.expect(!matchesPath("audiotest.imf"));
    try std.testing.expect(!matchesPath("audiotrack.wl6"));
}

test "audiot validates short songs long lengths and sound effect lookalikes" {
    const gpa = std.testing.allocator;
    const song = [_]u8{ 8, 0, 0xb0, 0x31, 7, 0, 0xb0, 0, 7, 0 };
    try std.testing.expectEqualSlices(u8, song[2..], musicStream(&song).?);
    const marker_note = [_]u8{ 4, 0 } ++ "!ID!".*;
    try std.testing.expectEqualSlices(u8, marker_note[2..], musicStream(&marker_note).?);
    var tagged: [song.len + 88]u8 = @splat(0xff);
    @memcpy(tagged[0..song.len], &song);
    try std.testing.expectEqualSlices(u8, song[2..], musicStream(&tagged).?);
    try std.testing.expect(musicStream(song[0..9]) == null);
    var invalid = song;
    invalid[6] = 0xff;
    try std.testing.expect(musicStream(&invalid) == null);
    var effect: [800]u8 = @splat(0);
    std.mem.writeInt(u32, effect[0..4], 793, .little);
    @memset(effect[6..799], 0x40);
    try std.testing.expect(musicStream(&effect) == null);
    @memset(&effect, 0);
    try std.testing.expect(musicStream(&effect) == null);
    const long_song = try gpa.alloc(u8, 65540);
    defer gpa.free(long_song);
    @memset(long_song, 0);
    std.mem.writeInt(u32, long_song[0..4], 65536, .little);
    long_song[long_song.len - 4 ..][0..4].* = .{ 0xb0, 0x31, 7, 0 };
    try std.testing.expectEqualSlices(u8, long_song[4..], musicStream(long_song).?);
}

test "audiot section markers exclude effects and retain short raw and compressed songs" {
    const gpa = std.testing.allocator;
    const sound = [_]u8{ 4, 0, 0xb0, 0x31, 7, 0 } ++ "!ID!".*;
    const song = [_]u8{ 8, 0, 0xb0, 0x31, 7, 0, 0xb0, 0, 7, 0 };
    const dict = identityDict();
    for ([_]bool{ false, true }) |compressed| {
        var audio: std.ArrayList(u8) = .empty;
        defer audio.deinit(gpa);
        var hed: [20]u8 = @splat(0);
        for ([_][]const u8{ &sound, &sound, "!ID!", &song }, 0..) |chunk, i| {
            if (compressed and i != 2) try audio.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(chunk.len))));
            try audio.appendSlice(gpa, chunk);
            std.mem.writeInt(u32, hed[(i + 1) * 4 ..][0..4], @intCast(audio.items.len), .little);
        }
        const source = (try fmt.load(gpa, if (compressed) "AUDIO.CK4" else "AUDIOT.WL6", audio.items, .{
            .sample_rate = 44100,
            .chip = fmt.noop_chip,
            .sibling = &hed,
            .sibling2 = if (compressed) &dict else null,
        })).?;
        defer source.deinit(gpa);
        @memset(audio.items, 0);
        try std.testing.expectEqual(@as(u32, 1), source.info().archive_track_count);
        try std.testing.expectEqual(@as(u32, 2), source.views().dump.?.write_count);
        var frames: u64 = 0;
        for (0..2) |_| frames += source.step(fmt.noop_chip).frames;
        try std.testing.expectEqual(@as(u64, if (compressed) 1102 else 882), frames);
        try std.testing.expect(source.step(fmt.noop_chip).done);
    }
}

test "audiot sibling path resolution" {
    const gpa = std.testing.allocator;
    const a = (try siblingPath(gpa, "game/AUDIOHED.WL6")).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("game/AUDIOT.WL6", a);
    const b = (try siblingPath(gpa, "AUDIOT.CK4")).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("AUDIOHED.CK4", b);
    const c = (try siblingPath(gpa, "game/AUDIO.CK4")).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("game/AUDIOHED.CK4", c);
    const d = (try sibling2Path(gpa, "game/AUDIO.CK4")).?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", d);
    const e = (try siblingAltPath(gpa, "game/AUDIOHED.CK4")).?;
    defer gpa.free(e);
    try std.testing.expectEqualStrings("game/AUDIO.CK4", e);
    const f = (try sibling2Path(gpa, "game/AUDIOHED.CK4")).?;
    defer gpa.free(f);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", f);
    try std.testing.expect((try siblingAltPath(gpa, "game/AUDIOT.WL6")) == null);
    try std.testing.expect((try siblingAltPath(gpa, "game/AUDIO.CK4")) == null);
    try std.testing.expect((try sibling2Path(gpa, "game/AUDIOT.WL6")) == null);
    try std.testing.expect((try siblingPath(gpa, "song.imf")) == null);
}

/// A dictionary whose tree branches on bit k of the value at depth k, so the
/// decoded stream equals the source bytes. Exercises the walker with every
/// byte value while keeping test data readable.
fn identityDict() [1024]u8 {
    var d: [1024]u8 = @splat(0);
    var k: u4 = 0;
    while (k < 8) : (k += 1) {
        var p: u16 = 0;
        while (p < (@as(u16, 1) << k)) : (p += 1) {
            const node: u16 = 254 - ((@as(u16, 1) << k) - 1) - p;
            var bit: u16 = 0;
            while (bit < 2) : (bit += 1) {
                const child_p = p | (bit << k);
                const val: u16 = if (k == 7)
                    child_p
                else
                    256 + (254 - ((@as(u16, 1) << (k + 1)) - 1) - child_p);
                std.mem.writeInt(u16, d[node * 4 + bit * 2 ..][0..2], val, .little);
            }
        }
    }
    return d;
}

test "audiot huffman identity dictionary round-trips" {
    const gpa = std.testing.allocator;
    const dict = identityDict();
    const payload = "id Software Huffman, LSB first";
    const out = try huffExpand(gpa, &dict, payload, payload.len);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(payload, out);
}

fn makeCompressedAudio() struct { audio: [404]u8, hed: [8]u8 } {
    var expanded: [400]u8 = @splat(0);
    var i: usize = 4;
    while (i < expanded.len) : (i += 4) {
        expanded[i] = 0xB0;
        expanded[i + 1] = 0x31;
        expanded[i + 2] = 0x01;
        expanded[i + 3] = 0x00;
    }
    var audio: [404]u8 = undefined;
    std.mem.writeInt(u32, audio[0..4], expanded.len, .little);
    @memcpy(audio[4..], &expanded);
    var hed: [8]u8 = undefined;
    std.mem.writeInt(u32, hed[0..4], 0, .little);
    std.mem.writeInt(u32, hed[4..8], audio.len, .little);
    return .{ .audio = audio, .hed = hed };
}

test "audiot compressed archive with dictionary plays" {
    const gpa = std.testing.allocator;
    const dict = identityDict();
    const made = makeCompressedAudio();

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "game/AUDIO.CK4", &made.audio, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .sibling = &made.hed,
        .sibling2 = &dict,
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);

    const track = src.info();
    try std.testing.expectEqualStrings("AudioT", track.format_name);
    try std.testing.expectEqual(@as(u32, 1), track.archive_track_count);
    try std.testing.expectEqualStrings("AUDIO.CK4 track 1/1", track.title.?);
    try std.testing.expectEqual(@as(u32, 560), src.getTickRate().?);
    var frames: u64 = 0;
    for (0..4) |_| frames += src.step(fmt.noop_chip).frames;
    try std.testing.expect(frames > 0);
}

test "audiot hed entry with alt companion decodes the compressed archive" {
    const gpa = std.testing.allocator;
    const dict = identityDict();
    const made = makeCompressedAudio();

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "game/AUDIOHED.CK4", &made.hed, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .sibling = &made.audio,
        .sibling2 = &dict,
        .sibling_is_alt = true,
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);

    const track = src.info();
    try std.testing.expectEqual(@as(u32, 1), track.archive_track_count);
    try std.testing.expectEqualStrings("AUDIO.CK4 track 1/1", track.title.?);

    try std.testing.expectError(error.AudioTNeedsDict, fmt.load(gpa, "game/AUDIOHED.CK4", &made.hed, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .sibling = &made.audio,
        .sibling_is_alt = true,
    }));
}

test "audiot compressed archive needs its dictionary" {
    const gpa = std.testing.allocator;
    const made = makeCompressedAudio();
    try std.testing.expectError(error.AudioTNeedsDict, fmt.load(gpa, "AUDIO.CK4", &made.audio, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .sibling = &made.hed,
    }));
}

test "audiot hostile dictionary skips the chunk instead of crashing" {
    const gpa = std.testing.allocator;
    const made = makeCompressedAudio();
    const bad_dict: [1024]u8 = @splat(0xff);
    try std.testing.expectError(error.NoMusicInAudioT, fmt.load(gpa, "AUDIO.CK4", &made.audio, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .sibling = &made.hed,
        .sibling2 = &bad_dict,
    }));
    const short_dict: [16]u8 = @splat(0);
    try std.testing.expectError(error.NoMusicInAudioT, fmt.load(gpa, "AUDIO.CK4", &made.audio, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .sibling = &made.hed,
        .sibling2 = &short_dict,
    }));
}

test "audiot overlapping chunks stay within scan and expansion budgets" {
    const gpa = std.testing.allocator;
    const dict = identityDict();
    const made = makeCompressedAudio();

    const repeats = 84_000;
    const hed = try gpa.alloc(u8, (repeats * 2 + 1) * 4);
    defer gpa.free(hed);
    for (0..repeats * 2 + 1) |i| {
        const v: u32 = if (i % 2 == 0) 0 else made.audio.len;
        std.mem.writeInt(u32, hed[i * 4 ..][0..4], v, .little);
    }

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "game/AUDIO.CK4", &made.audio, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .sibling = hed,
        .sibling2 = &dict,
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);

    const kept = fmt.max_input_bytes / (400 + 2 * @sizeOf([]u8));
    try std.testing.expectEqual(@as(u32, @intCast(kept)), src.info().archive_track_count);
    for (0..repeats * 2 + 1) |i| {
        std.mem.writeInt(u32, hed[i * 4 ..][0..4], if (i % 2 == 0) 0 else 400, .little);
    }
    const raw = (try fmt.load(gpa, "AUDIOT.WL6", made.audio[4..], .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .sibling = hed,
    })).?;
    defer raw.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2 * fmt.max_input_bytes / 400), raw.info().archive_track_count);
}

test "audiot loads from prefetched sibling bytes without io" {
    const gpa = std.testing.allocator;
    var hed: [8]u8 = undefined;
    std.mem.writeInt(u32, hed[0..4], 0, .little);
    std.mem.writeInt(u32, hed[4..8], 500, .little);
    var audiot_bytes: [500]u8 = @splat(0);
    audiot_bytes[4..8].* = .{ 0xb0, 0x31, 1, 0 };

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "game/AUDIOT.WL6", &audiot_bytes, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .sibling = &hed,
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), src.info().archive_track_count);
    try std.testing.expectEqual(@as(u32, 700), src.getTickRate().?);

    const src2 = (try fmt.load(gpa, "game/AUDIOHED.WL6", &hed, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .sibling = &audiot_bytes,
    })) orelse return error.TestUnexpectedResult;
    defer src2.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), src2.info().archive_track_count);
}
