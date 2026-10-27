//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const cp437 = @import("../cp437.zig");
const fmt = @import("../format.zig");
const view = @import("../view.zig");
const chip_adapter = @import("../chip.zig");

pub const format_name = "IMF";
pub const extensions = &.{ ".imf", ".wlf", ".adlib" };
pub const visualizer_name = "stream";
pub const view_caps = view.ViewCaps{ .dump = true };

const ImfSource = struct {
    data: []const u8,
    pos: usize = 0,
    sample_rate: u32,
    rate: std.atomic.Value(u32),
    applied_rate: u32,
    frac: u32 = 0,
    total_ticks: u64,
    /// Null for a bare file: it carries no title and IMF synthesizes none, so
    /// the shell falls back to the file name without its extension.
    title: ?[]const u8,
    title_embedded: bool = false,
    artist: ?[]const u8 = null,
    game_name: ?[]const u8 = null,
    format_label: []const u8,
    archive: ?ArchiveTag = null,

    const max_ops_per_step: u32 = 4096;

    pub fn step(self: *ImfSource, chip: fmt.Chip) fmt.StepResult {
        var ops: u32 = 0;
        while (ops < max_ops_per_step) : (ops += 1) {
            if (self.pos + 4 > self.data.len) {
                self.pos = 0;
                return .{ .frames = 0, .done = true };
            }
            const reg = self.data[self.pos];
            const val = self.data[self.pos + 1];
            const delay = fmt.readU16Le(self.data, self.pos + 2);
            self.pos += 4;

            chip.writeReg(reg, val);
            if (delay == 0) continue;

            const rate = @max(1, self.rate.load(.monotonic));
            if (rate != self.applied_rate) {
                self.applied_rate = rate;
                self.frac = 0;
            }
            return .{ .frames = fmt.rescale(delay, rate, self.sample_rate, &self.frac) };
        }
        return .{ .frames = 0 };
    }

    pub fn info(self: *ImfSource) fmt.TrackInfo {
        const archive = self.archive orelse ArchiveTag{};
        return .{
            .title = self.title,
            .title_embedded = self.title_embedded,
            .artist = self.artist,
            .game = self.game_name,
            .format_name = self.format_label,
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .rate_adjustable = true,
            .archive_track_count = archive.count,
            .archive_track_index = archive.index,
        };
    }

    pub fn getTickRate(self: *ImfSource) u32 {
        return self.rate.load(.monotonic);
    }

    pub fn setTickRate(self: *ImfSource, hz: u32) void {
        if (hz > 0) self.rate.store(hz, .monotonic);
    }

    pub fn durationFrames(self: *ImfSource) u64 {
        const rate = @max(1, self.rate.load(.monotonic));
        return self.total_ticks * self.sample_rate / rate;
    }

    pub fn dumpView(self: *ImfSource) view.DumpView {
        return .{
            .chip = .opl2,
            .write_count = @intCast(self.data.len / 4),
            .header_tick = self.applied_rate,
        };
    }

    pub fn deinit(self: *ImfSource, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        if (self.title) |t| gpa.free(t);
        if (self.artist) |a| gpa.free(a);
        if (self.game_name) |g| gpa.free(g);
        gpa.destroy(self);
    }
};

fn totalTicks(stream: []const u8) u64 {
    var ticks: u64 = 0;
    var pos: usize = 0;
    while (pos + 4 <= stream.len) : (pos += 4) {
        ticks += fmt.readU16Le(stream, pos + 2);
    }
    return ticks;
}

fn rateForExt(ext: []const u8) u32 {
    if (std.ascii.eqlIgnoreCase(ext, ".wlf")) return 700;
    if (std.ascii.eqlIgnoreCase(ext, ".imf") or std.ascii.eqlIgnoreCase(ext, ".adlib")) return 560;
    return 0;
}

fn formatLabel(rate: u32, ext: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(ext, ".wlf") or rate == 700) return "WLF";
    if (std.ascii.eqlIgnoreCase(ext, ".adlib")) return "ADLIB";
    return "IMF";
}

pub const ArchiveTag = struct { count: u32 = 0, index: u32 = 0 };

pub const StreamOptions = struct {
    sample_rate: u32,
    rate: u32,
    format_label: []const u8,
    title: ?[]const u8 = null,
    title_embedded: bool = false,
    artist: ?[]const u8 = null,
    game_name: ?[]const u8 = null,
    archive: ?ArchiveTag = null,
};

pub fn openStream(gpa: std.mem.Allocator, stream: []const u8, opts: StreamOptions) !fmt.MusicSource {
    const copy = try gpa.dupe(u8, stream);
    errdefer gpa.free(copy);
    const title = if (opts.title) |t| try gpa.dupe(u8, t) else null;
    errdefer if (title) |t| gpa.free(t);
    const artist = if (opts.artist) |a| try gpa.dupe(u8, a) else null;
    errdefer if (artist) |a| gpa.free(a);
    const game = if (opts.game_name) |g| try gpa.dupe(u8, g) else null;
    errdefer if (game) |g| gpa.free(g);
    const src = try gpa.create(ImfSource);
    errdefer gpa.destroy(src);
    const rate = @max(1, opts.rate);
    src.* = .{
        .data = copy,
        .sample_rate = opts.sample_rate,
        .rate = .init(rate),
        .applied_rate = rate,
        .total_ticks = totalTicks(copy),
        .title = title,
        .title_embedded = opts.title_embedded,
        .artist = artist,
        .game_name = game,
        .format_label = opts.format_label,
        .archive = opts.archive,
    };
    return fmt.MusicSource.init(src, visualizer_name);
}

/// A stray byte or two past the last complete 4-byte record is common in the
/// wild, from zero padding and from wrapper lengths that count it. Drop the
/// partial record rather than the file, which `step` already tolerates.
fn wholeRecords(s: []const u8) []const u8 {
    return s[0 .. s.len - s.len % 4];
}

pub fn commandStream(data: []const u8) ?[]const u8 {
    if (data.len < 4) return null;
    if (hasLongLength(data)) return data[4 .. 4 + fmt.readU32Le(data, 0)];
    const len_word = std.mem.readInt(u16, data[0..2], .little);
    if (len_word != 0) {
        // A declared length can overrun the file when the last record was lost
        // in transit. Keep what arrived, as the ADLIB wrapper already does.
        const avail = data.len - 2;
        const body = wholeRecords(data[2 .. 2 + @min(len_word, avail)]);
        return if (body.len == 0) null else body;
    }
    return wholeRecords(data);
}

fn hasLongLength(data: []const u8) bool {
    if (data.len < 8) return false;
    const length = fmt.readU32Le(data, 0);
    if (length == 0 or length % 4 != 0 or length > data.len - 4) return false;
    if (fmt.readU16Le(data, 0) == 0) {
        const footer = data[4 + length ..];
        return footer.len < 4 or isNielsenTag(footer) or isMuseTag(footer);
    }
    return alignmentScore(data[4 .. 4 + length]) > alignmentScore(data[2 .. 2 + length]);
}

fn alignmentScore(data: []const u8) i64 {
    var score: i64 = 0;
    for (0..@min(data.len / 4, 42)) |i| {
        score += @as(i64, fmt.readU16Le(data, i * 4)) - fmt.readU16Le(data, i * 4 + 2);
    }
    return score;
}

const Tag = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
};

/// Bytes past a type-1 file's declared stream, where tag footers live.
fn type1Footer(data: []const u8) []const u8 {
    if (data.len < 4) return "";
    if (hasLongLength(data)) return data[4 + fmt.readU32Le(data, 0) ..];
    const len_word: usize = std.mem.readInt(u16, data[0..2], .little);
    if (len_word == 0) return "";
    const end = 2 + len_word;
    if (end >= data.len) return "";
    return data[end..];
}

fn nextString(rest: *[]const u8) []const u8 {
    const s = rest.*;
    const z = std.mem.findScalar(u8, s, 0) orelse {
        rest.* = s[s.len..];
        return s;
    };
    rest.* = s[z + 1 ..];
    return s[0..z];
}

/// Three strings, each at most 255 bytes plus NUL, and a 9-byte program field.
const nielsen_tag_max = 1 + 3 * 256 + 9;

const text_bytes = 255 * cp437.max_utf8_per_byte;

fn isNielsenTag(footer: []const u8) bool {
    return footer.len > 0 and footer[0] == 0x1a and footer.len <= nielsen_tag_max;
}

fn isMuseTag(footer: []const u8) bool {
    return footer.len == 88 and footer[17] == 0 and footer[81] == 0;
}

/// Unofficial tag footers, as AdPlug reads them: Adam Nielsen's `0x1A` tag
/// (title, author, remarks strings) or Muse's fixed 88-byte block.
fn parseTag(footer: []const u8) Tag {
    if (isNielsenTag(footer)) {
        var rest = footer[1..];
        const title = nextString(&rest);
        const artist = nextString(&rest);
        return .{ .title = title, .artist = artist };
    }
    if (isMuseTag(footer)) {
        return .{ .title = std.mem.sliceTo(footer[2..18], 0) };
    }
    return .{};
}

const AdlibWrapper = struct {
    title: []const u8,
    game: []const u8,
    stream: []const u8,
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn adlibWrapper(data: []const u8) ?AdlibWrapper {
    if (data.len < 6 or !std.mem.eql(u8, data[0..5], "ADLIB") or data[5] != 1) return null;
    const title_end = std.mem.findScalarPos(u8, data, 6, 0) orelse return null;
    const game_end = std.mem.findScalarPos(u8, data, title_end + 1, 0) orelse return null;
    // Game NUL then one filler byte, then a u32le payload length (not type-1 IMF's u16).
    const size_off = game_end + 2;
    if (size_off + 4 > data.len) return null;
    const size = std.mem.readInt(u32, data[size_off..][0..4], .little);
    const body = data[size_off + 4 ..];
    const stream = wholeRecords(if (size == 0) body else body[0..@min(size, body.len)]);
    if (stream.len < 4) return null;
    return .{
        .title = data[6..title_end],
        .game = data[title_end + 1 .. game_end],
        .stream = stream,
    };
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    var rate = rateForExt(ctx.ext);
    if (rate == 0) return null;
    if (ctx.tick_rate_hz != 0) rate = ctx.tick_rate_hz;
    const wrapper = adlibWrapper(data);
    const stream = if (wrapper) |w| w.stream else (commandStream(data) orelse return null);
    if (totalTicks(stream) == 0) return null;
    const tag: Tag = if (wrapper == null) parseTag(type1Footer(data)) else .{};
    var title_buf: [text_bytes]u8 = undefined;
    var artist_buf: [text_bytes]u8 = undefined;
    var game_buf: [text_bytes]u8 = undefined;
    const title = nonEmpty(cp437.decode(&title_buf, if (wrapper) |w| w.title else tag.title));
    return try openStream(gpa, stream, .{
        .sample_rate = ctx.sample_rate,
        .rate = rate,
        .format_label = formatLabel(rate, ctx.ext),
        .title = title,
        .title_embedded = title != null,
        .artist = nonEmpty(cp437.decode(&artist_buf, tag.artist)),
        .game_name = if (wrapper) |w| nonEmpty(cp437.decode(&game_buf, w.game)) else null,
    });
}

pub fn labelForPath(path: []const u8) []const u8 {
    return formatLabel(0, fmt.extensionOf(path));
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

test "adlib wrapper: metadata and body play, plain files pass through" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x08, 0x00, 0x00, 0x00, 0xb0, 0x31, 0x01, 0x00, 0xb0, 0x32, 0x02, 0x00 };
    const wrapped: []const u8 = "ADLIB" ++ [_]u8{1} ++ "My Song" ++ [_]u8{0} ++ "My Game" ++
        [_]u8{ 0, 1 } ++ body;

    var chip = opal.Opal.init(44100);
    const src = (try fmt.load(gpa, "x.adlib", wrapped, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);
    const track = src.info();
    try std.testing.expectEqualStrings("My Song", track.title.?);
    try std.testing.expect(track.title_embedded);
    try std.testing.expectEqualStrings("My Game", track.game.?);
    try std.testing.expectEqualStrings("ADLIB", track.format_name);
    try std.testing.expectEqual(@as(u64, 3 * 44100 / 560), src.durationFrames().?);

    const no_body: []const u8 = "ADLIB" ++ [_]u8{ 1, 0, 0, 1 };
    try std.testing.expect(adlibWrapper(&body) == null);
    try std.testing.expect(adlibWrapper("ADLIB") == null);
    try std.testing.expect(adlibWrapper(no_body) == null);
}

test "imf delay frac-carry over one second of ticks" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    for (0..560) |_| {
        try body.appendSlice(gpa, &[_]u8{ 0xB0, 0x31, 0x01, 0x00 });
    }
    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "song.imf", body.items, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);

    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 2000);
    try std.testing.expectEqual(@as(u64, 44100), drained.frames);
    try std.testing.expectEqual(@as(?u64, 44100), src.durationFrames());
}

test "imf type-1 length prefix" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x04, 0x00, 0x20, 0x01, 0x01, 0x00, 0xFF, 0xFF };
    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "a.imf", &data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expect(!src.step(chip_adapter.fromOpal(&chip)).done);
    try std.testing.expect(src.step(chip_adapter.fromOpal(&chip)).done);
}

test "IMF distinguishes early four byte lengths from two byte lengths with an initial zero write" {
    const stream = [_]u8{ 0, 0, 0, 0, 0x20, 0x21, 0, 0, 0xb0, 0x31, 2, 0 };
    const footer = "\x1aTitle\x00Artist\x00\x00";
    const short = [_]u8{ 12, 0 } ++ stream ++ footer;
    const long = [_]u8{ 12, 0, 0, 0 } ++ stream ++ footer;
    for ([_][]const u8{ short, long }) |data| {
        try std.testing.expectEqualSlices(u8, &stream, commandStream(data).?);
        const src = (try load(std.testing.allocator, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".imf" })).?;
        defer src.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 3), src.views().dump.?.write_count);
        try std.testing.expectEqual(@as(?u64, 2 * 44100 / 560), src.durationFrames());
        try std.testing.expectEqualStrings("Title", src.info().title.?);
        try std.testing.expectEqualStrings("Artist", src.info().artist.?);
    }

    var large: [65536 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, large[0..4], 65536, .little);
    @memcpy(large[4..][0..stream.len], &stream);
    try std.testing.expectEqualSlices(u8, large[4..], commandStream(&large).?);
}

test "imf type 0 past 64 KiB with a delayed first record is not cut at a four byte length" {
    const gpa = std.testing.allocator;
    const ctx: fmt.LoadContext = .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".imf" };
    const data = try gpa.alloc(u8, 100_000);
    defer gpa.free(data);
    @memcpy(data[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0x00 });
    for (1..data.len / 4) |i| @memcpy(data[i * 4 ..][0..4], &[_]u8{ 0xb0, 0x31, 0x05, 0x00 });
    try std.testing.expectEqualSlices(u8, data, commandStream(data).?);
    const whole = (try load(gpa, data, ctx)).?;
    defer whole.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 25_000), whole.views().dump.?.write_count);
    try std.testing.expectEqual(@as(?u64, (1 + 24_999 * 5) * 44100 / 560), whole.durationFrames());

    const footer = "\x1aTitle\x00Artist\x00\x00";
    const tagged = data[0 .. 4 + 65536 + footer.len];
    @memcpy(tagged[4 + 65536 ..], footer);
    try std.testing.expectEqualSlices(u8, tagged[4..][0..65536], commandStream(tagged).?);
    try std.testing.expectEqualSlices(u8, tagged[4..][0..65536], commandStream(tagged[0 .. 4 + 65536 + 2]).?);
    const long = (try load(gpa, tagged, ctx)).?;
    defer long.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 16_384), long.views().dump.?.write_count);
    try std.testing.expectEqualStrings("Title", long.info().title.?);
}

test "imf nielsen tag footer supplies CP437 title and artist as UTF-8" {
    const gpa = std.testing.allocator;
    const data: []const u8 = [_]u8{ 0x08, 0x00 } ++
        [_]u8{ 0x20, 0x01, 0x01, 0x00, 0xB0, 0x31, 0x01, 0x00 } ++
        [_]u8{0x1a} ++ "My Tune \xCD" ++ [_]u8{0} ++ "An Auth\x94r" ++ [_]u8{0} ++ "remarks" ++ [_]u8{0};
    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "a.imf", data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);
    const track = src.info();
    try std.testing.expectEqualStrings("My Tune ═", track.title.?);
    try std.testing.expect(track.title_embedded);
    try std.testing.expectEqualStrings("An Authör", track.artist.?);
    try std.testing.expectEqual(@as(?u64, 2 * 44100 / 560), src.durationFrames());
}

test "imf muse tag footer supplies the title" {
    const gpa = std.testing.allocator;
    const footer = comptime blk: {
        var f: [88]u8 = @splat(0);
        @memcpy(f[2..11], "MuseTitle");
        break :blk f;
    };
    const data: []const u8 = &([_]u8{ 0x04, 0x00, 0x20, 0x01, 0x01, 0x00 } ++ footer);
    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "a.imf", data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);
    const track = src.info();
    try std.testing.expectEqualStrings("MuseTitle", track.title.?);
    try std.testing.expect(track.title_embedded);
    try std.testing.expect(track.artist == null);
}

test "imf non-tag trailing bytes leave metadata empty" {
    const gpa = std.testing.allocator;
    const data: []const u8 = [_]u8{ 0x04, 0x00, 0x20, 0x01, 0x01, 0x00 } ++ "just some text";
    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "a.imf", data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);
    try std.testing.expect(src.info().title == null);
    try std.testing.expect(src.info().artist == null);
}

test "imf rejects incomplete and zero-time streams" {
    try std.testing.expect(commandStream(&.{ 0x01, 0x00, 0x20, 0x01 }) == null);
    try std.testing.expect(commandStream(&.{ 0x02, 0x00, 0x20, 0x01 }) == null);

    var chip = opal.Opal.init(44100);
    const zero_time = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect((try fmt.load(std.testing.allocator, "a.imf", &zero_time, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })) == null);
}

test "imf plays past a partial trailing record" {
    const gpa = std.testing.allocator;

    // Type 0 whose length is two bytes past a whole number of records, as the
    // Corridor 7 rips are: a leading zero word makes it type 0, two records,
    // then zero padding that stops short of the third.
    const strays = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x20, 0x01, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(usize, 8), commandStream(&strays).?.len);

    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "a.imf", &strays, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expect(src.step(chip_adapter.fromOpal(&chip)).frames > 0);
    try std.testing.expect(src.step(chip_adapter.fromOpal(&chip)).done);

    // A type-1 length that counts a partial record keeps the whole ones.
    const declared = [_]u8{ 0x06, 0x00, 0x20, 0x01, 0x01, 0x00, 0x40, 0x30 };
    try std.testing.expectEqual(@as(usize, 4), commandStream(&declared).?.len);

    // A length overrunning the file, as titlermx.imf does after losing its
    // final record in transit, keeps every record that did arrive.
    const overrun = [_]u8{ 0x0C, 0x00, 0x20, 0x01, 0x01, 0x00, 0xB8, 0x00 };
    try std.testing.expectEqual(@as(usize, 4), commandStream(&overrun).?.len);

    try std.testing.expect(commandStream(&.{ 0x02, 0x00, 0x20, 0x01 }) == null);
    try std.testing.expect(commandStream(&.{ 0xFF, 0xFF, 0x20, 0x01 }) == null);
}

test "imf live rate cycle" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0xB0, 0x31, 0x01, 0x00 };
    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "a.imf", &data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 560), src.getTickRate().?);
    try std.testing.expectEqual(@as(?u64, 44100 / 560), src.durationFrames());
    try std.testing.expectEqual(@as(u32, 700), src.cycleTickRate().?);
    try std.testing.expectEqual(@as(?u64, 44100 / 700), src.durationFrames());
    try std.testing.expectEqual(@as(u32, 280), src.cycleTickRate().?);
    try std.testing.expectEqual(@as(?u64, 44100 / 280), src.durationFrames());
    try std.testing.expectEqual(@as(u32, 560), src.cycleTickRate().?);
}

test "imf rate change resets fractional carry" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x00, 0xB0, 0x31, 0x01, 0x00 };
    var chip = opal.Opal.init(48000);
    const src_opt = try fmt.load(gpa, "a.imf", &data, .{
        .sample_rate = 48000,
        .chip = chip_adapter.fromOpal(&chip),
    });
    var src = src_opt.?;
    defer src.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 85), src.step(chip_adapter.fromOpal(&chip)).frames);
    try std.testing.expectEqual(@as(u32, 700), src.cycleTickRate().?);
    try std.testing.expectEqual(@as(u64, 68), src.step(chip_adapter.fromOpal(&chip)).frames);
}

test "imf wlf defaults to 700" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x00 };
    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "a.wlf", &data, .{ .sample_rate = 44100, .chip = chip_adapter.fromOpal(&chip) });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 700), src.getTickRate().?);
    try std.testing.expectEqualStrings("WLF", src.info().format_name);
    try std.testing.expectEqual(@as(?u64, 44100 / 700), src.durationFrames());
}

test "imf path labels follow the extension" {
    try std.testing.expectEqualStrings("IMF", labelForPath("a.imf"));
    try std.testing.expectEqualStrings("WLF", labelForPath("a.wlf"));
    try std.testing.expectEqualStrings("ADLIB", labelForPath("x.adlib"));
}

test "openStream carries archive metadata into TrackInfo" {
    const gpa = std.testing.allocator;
    const stream = [_]u8{ 0x00, 0x00, 0x01, 0x00 };
    var src = try openStream(gpa, &stream, .{
        .sample_rate = 44100,
        .rate = 560,
        .format_label = "AudioT",
        .title = "AUDIOT.WL6 track 2/27",
        .archive = .{ .count = 27, .index = 1 },
    });
    defer src.deinit(gpa);
    const track = src.info();
    try std.testing.expectEqual(@as(u32, 27), track.archive_track_count);
    try std.testing.expectEqual(@as(u32, 1), track.archive_track_index);
    try std.testing.expect(!track.title_embedded);

    var plain = try openStream(gpa, &stream, .{
        .sample_rate = 44100,
        .rate = 560,
        .format_label = "IMF",
        .title = "a.imf",
    });
    defer plain.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), plain.info().archive_track_count);
}

test "imf --rate override via LoadContext" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x00 };
    var chip = opal.Opal.init(44100);
    const src_opt = try fmt.load(gpa, "a.imf", &data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .tick_rate_hz = 280,
    });
    try std.testing.expect(src_opt != null);
    var src = src_opt.?;
    defer src.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 280), src.getTickRate().?);
}

test "a bare imf reports no title so the shell falls back to the file name" {
    const gpa = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x01, 0x00 };
    var chip = opal.Opal.init(44100);
    var src = (try fmt.load(gpa, "music/duke2.imf", &data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
    })).?;
    defer src.deinit(gpa);
    const track = src.info();
    try std.testing.expect(track.title == null);
    try std.testing.expect(!track.title_embedded);
}

test "imf applies a burst of zero-delay writes in one step" {
    const gpa = std.testing.allocator;
    var data: [4 + 2000 * 4 + 4]u8 = @splat(0);
    for (0..2000) |i| @memcpy(data[4 + i * 4 ..][0..4], &[_]u8{ 0x20, @truncate(i), 0, 0 });
    @memcpy(data[4 + 2000 * 4 ..][0..4], &[_]u8{ 0xb0, 0x20, 0x10, 0x00 });
    const Rec = struct {
        writes: u32 = 0,
        fn write(ptr: *anyopaque, _: u16, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
        }
        fn flushNop(_: *anyopaque) void {}
    };
    var rec: Rec = .{};
    const chip: fmt.Chip = .{ .ptr = &rec, .vtable = &.{ .writeReg = Rec.write, .flush = Rec.flushNop } };
    const src = (try fmt.load(gpa, "burst.imf", &data, .{ .sample_rate = 44100, .chip = chip })).?;
    defer src.deinit(gpa);
    rec.writes = 0;
    try std.testing.expect(src.step(chip).frames > 0);
    try std.testing.expectEqual(@as(u32, 2002), rec.writes);
}
