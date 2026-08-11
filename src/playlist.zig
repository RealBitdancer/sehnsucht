//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const paint = @import("paint.zig");
const format = @import("format.zig");
const remote = @import("remote.zig");
const Theme = @import("theme.zig").Theme;

pub const extensions = [_][]const u8{ ".m3u", ".m3u8" };

pub fn isPlaylistPath(path: []const u8) bool {
    return format.hasExtension(path, &extensions);
}

fn isAbsoluteEntry(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return true;
    if (isWindowsDrivePrefix(p)) return true;
    return remote.hasUrlScheme(p);
}

fn isWindowsDrivePrefix(p: []const u8) bool {
    if (p.len < 2 or p[1] != ':' or !std.ascii.isAlphabetic(p[0])) return false;
    return p.len == 2 or p[2] == '/' or p[2] == '\\';
}

fn hasControlBytes(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7F) return true;
    }
    return false;
}

fn scrubControlBytes(s: []u8) void {
    for (s) |*c| {
        if (c.* < 0x20 or c.* == 0x7F) c.* = ' ';
    }
}

fn resolveEntry(gpa: std.mem.Allocator, dir: []const u8, line: []const u8) ![]const u8 {
    if (remote.isFileUrl(line)) return remote.fileUrlToPath(gpa, line);
    const norm = try gpa.dupe(u8, line);
    std.mem.replaceScalar(u8, norm, '\\', '/');
    if (isAbsoluteEntry(line)) return norm;
    defer gpa.free(norm);
    const joined = try format.joinDir(gpa, dir, norm);
    if (remote.isRemotePath(joined)) {
        defer gpa.free(joined);
        return remote.encodeUrlAlloc(gpa, joined);
    }
    return joined;
}

pub const Parsed = struct {
    entries: []const []const u8,
    titles: []const ?[]const u8,
    rates: []const u32,
    name: ?[]const u8,
};

const Extinf = struct {
    title: ?[]const u8 = null,
    rate: u32 = 0,
};

fn parseExtinf(line: []const u8) Extinf {
    if (!std.ascii.startsWithIgnoreCase(line, "#EXTINF:")) return .{};
    const rest = line["#EXTINF:".len..];
    var in_quotes = false;
    const comma = for (rest, 0..) |c, k| {
        if (c == '"') in_quotes = !in_quotes;
        if (c == ',' and !in_quotes) break k;
    } else return .{};
    const title = std.mem.trim(u8, rest[comma + 1 ..], " \t");
    return .{
        .title = if (title.len == 0) null else title,
        .rate = extinfRate(rest[0..comma]),
    };
}

fn extinfRate(attrs: []const u8) u32 {
    var i: usize = 0;
    while (i + 5 <= attrs.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(attrs[i .. i + 5], "rate=")) continue;
        if (i > 0 and !std.ascii.isWhitespace(attrs[i - 1])) continue;
        const val = attrs[i + 5 ..];
        const end = for (val, 0..) |c, k| {
            if (!std.ascii.isDigit(c)) break k;
        } else val.len;
        if (end == 0) continue;
        const hz = std.fmt.parseInt(u32, val[0..end], 10) catch continue;
        if (std.mem.indexOfScalar(u32, &format.tick_rates, hz) != null) return hz;
    }
    return 0;
}

fn playlistName(line: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(line, "#PLAYLIST:")) return null;
    const name = std.mem.trim(u8, line["#PLAYLIST:".len..], " \t");
    if (name.len == 0) return null;
    return name;
}

/// The `#EXTINF` line ahead of an entry. Its title is owned until an entry
/// takes it, so a dropped entry has to release it.
const Pending = struct {
    title: ?[]const u8 = null,
    rate: u32 = 0,

    fn replace(self: *Pending, gpa: std.mem.Allocator, extinf: Extinf) !void {
        const copy = if (extinf.title) |t| try gpa.dupe(u8, t) else null;
        if (copy) |c| scrubControlBytes(c);
        self.clear(gpa);
        self.* = .{ .title = copy, .rate = extinf.rate };
    }

    fn clear(self: *Pending, gpa: std.mem.Allocator) void {
        if (self.title) |t| gpa.free(t);
        self.* = .{};
    }
};

pub fn parse(
    gpa: std.mem.Allocator,
    playlist_path: []const u8,
    data: []const u8,
) !Parsed {
    const dir = format.dirnameOf(playlist_path);
    const from_remote = remote.isRemotePath(playlist_path);
    const body = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;

    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| gpa.free(e);
        entries.deinit(gpa);
    }
    var titles: std.ArrayList(?[]const u8) = .empty;
    errdefer {
        for (titles.items) |t| if (t) |s| gpa.free(s);
        titles.deinit(gpa);
    }
    var rates: std.ArrayList(u32) = .empty;
    errdefer rates.deinit(gpa);
    var pending: Pending = .{};
    defer pending.clear(gpa);
    var list_name: ?[]const u8 = null;
    errdefer if (list_name) |s| gpa.free(s);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.ascii.startsWithIgnoreCase(line, "#EXTINF:")) {
                try pending.replace(gpa, parseExtinf(line));
            } else if (playlistName(line)) |nm| {
                const copy = try gpa.dupe(u8, nm);
                scrubControlBytes(copy);
                if (list_name) |old| gpa.free(old);
                list_name = copy;
            }
            continue;
        }
        if (hasControlBytes(line)) {
            pending.clear(gpa);
            continue;
        }
        const entry = resolveEntry(gpa, dir, line) catch |err| switch (err) {
            error.InvalidFileUrl => {
                pending.clear(gpa);
                continue;
            },
            error.OutOfMemory => |e| return e,
        };
        const reachable = !from_remote or remote.isRemotePath(entry);
        if (!reachable or !isPlayableEntry(entry)) {
            gpa.free(entry);
            pending.clear(gpa);
            continue;
        }
        entries.append(gpa, entry) catch |err| {
            gpa.free(entry);
            return err;
        };
        // The title's owner becomes `titles` the moment the append lands, so
        // clear it before anything else can fail and free it twice.
        try titles.append(gpa, pending.title);
        pending.title = null;
        try rates.append(gpa, pending.rate);
        pending.rate = 0;
    }
    const out_entries = try entries.toOwnedSlice(gpa);
    errdefer {
        for (out_entries) |e| gpa.free(e);
        gpa.free(out_entries);
    }
    const out_titles = try titles.toOwnedSlice(gpa);
    errdefer {
        for (out_titles) |t| if (t) |s| gpa.free(s);
        gpa.free(out_titles);
    }
    const out_rates = try rates.toOwnedSlice(gpa);
    return .{ .entries = out_entries, .titles = out_titles, .rates = out_rates, .name = list_name };
}

fn isPlayableEntry(entry: []const u8) bool {
    if (remote.hasUrlScheme(entry) and !remote.isRemotePath(entry)) return false;
    return format.isPlayablePath(entry);
}

pub fn free(gpa: std.mem.Allocator, parsed: Parsed) void {
    for (parsed.entries) |e| gpa.free(e);
    gpa.free(parsed.entries);
    for (parsed.titles) |t| if (t) |s| gpa.free(s);
    gpa.free(parsed.titles);
    gpa.free(parsed.rates);
    if (parsed.name) |s| gpa.free(s);
}

pub const ListState = struct {
    nav: paint.ListNav = .{},
    pending_jump: ?usize = null,

    pub fn requestPlay(self: *ListState, count: usize) void {
        if (count == 0) return;
        self.pending_jump = @min(self.nav.cursor, count - 1);
    }

    pub fn draw(
        self: *ListState,
        win: vaxis.Window,
        theme: Theme,
        arena: std.mem.Allocator,
        list_name: []const u8,
        entries: []const []const u8,
        titles: []const ?[]const u8,
        played: []const bool,
        unplayable: []const bool,
        playing_index: ?usize,
    ) void {
        const n = entries.len;
        const header_rows: u16 = 3;
        const with_bar = win.height >= header_rows + paint.key_bar_height + 1;
        const bar_h: u16 = if (with_bar) paint.key_bar_height else 0;
        if (win.height < header_rows + 1) return;

        if (n == 0) {
            const msg = "playlist is empty";
            const x = (win.width -| @as(u16, @intCast(msg.len))) / 2;
            const y = (win.height -| bar_h) / 2;
            paint.printAt(win, x, y, msg, theme.style(.playlist_empty));
            if (with_bar) drawKeyBar(win, theme, 0, 0, false);
            return;
        }

        const playing: ?usize = if (playing_index) |pi| @min(pi, n - 1) else null;
        const cursor = @min(self.nav.cursor, n - 1);
        self.nav.cursor = cursor;

        const list_h = win.height - header_rows - bar_h;
        self.nav.page_h = list_h;
        paint.listEnsureVisible(&self.nav.scroll, cursor, n, list_h);
        const first = self.nav.scroll;

        const plural: []const u8 = if (n == 1) "" else "s";
        const title = if (list_name.len > 0)
            std.fmt.allocPrint(arena, "{s} · {d} track{s}", .{
                list_name,
                n,
                plural,
            }) catch list_name
        else
            std.fmt.allocPrint(arena, "{d} track{s}", .{ n, plural }) catch "tracks";
        paint.printFit(win, 1, 0, title, win.width -| 2, theme.style(.playlist_title));

        const show_sb = n > list_h;
        const row_w = if (show_sb) win.width -| 1 else win.width;

        self.nav.hit_x0 = @intCast(@max(0, win.x_off));
        self.nav.hit_x1 = @as(u16, @intCast(@max(0, win.x_off))) + row_w;
        self.nav.hit_y0 = @as(u16, @intCast(@max(0, win.y_off))) + header_rows;
        self.nav.hit_rows = @intCast(@min(@as(usize, list_h), n - first));

        const fmt_w: u16 = 8;
        const num_w: u16 = 4;
        const marker_w: u16 = 2;
        const gap: u16 = 2;
        const title_x = marker_w + num_w + gap;
        const title_w = row_w -| title_x -| gap -| fmt_w;
        const fmt_x = title_x + title_w + gap;

        const col_style = theme.style(.list_header);
        paint.printAt(win, marker_w + 2, 1, "#", col_style);
        if (title_w > 0) paint.printAt(win, title_x, 1, "Title", col_style);
        if (fmt_x + 6 <= row_w) paint.printAt(win, fmt_x, 1, "Format", col_style);
        paint.drawRule(win, theme, 2, row_w);

        const focus_bg = theme.colors.list_cursor_bg;
        const focus_fg = theme.colors.list_cursor_fg;
        const open_bg = theme.colors.playlist_playing_bg;
        const open_fg = theme.colors.playlist_playing_fg;

        var row: u16 = 0;
        while (row < list_h) : (row += 1) {
            const idx = first + row;
            if (idx >= n) break;
            const y = header_rows + row;
            const is_cursor = idx == cursor;
            const is_playing = if (playing) |p| idx == p else false;
            const is_unplayable = idx < unplayable.len and unplayable[idx];

            const bg = if (is_cursor) focus_bg else if (is_playing) open_bg else theme.colors.bg;
            const fg = if (is_cursor) focus_fg else if (is_playing) open_fg else theme.colors.list_row_fg;
            const style = theme.listEntry(fg, bg, is_cursor or is_playing);
            const row_style: vaxis.Style = if (is_unplayable and !(is_cursor or is_playing))
                theme.listEntry(theme.colors.playlist_dead_fg, bg, false)
            else
                style;

            paint.fillRowBg(win, y, 0, row_w, bg);

            const marker: []const u8 = if (is_playing) "▶" else if (is_unplayable) "✗" else " ";
            const marker_style: vaxis.Style = if (is_unplayable and !is_cursor)
                theme.listEntry(theme.colors.playlist_dead_mark_fg, bg, false)
            else
                style;
            paint.printAt(win, 0, y, marker, marker_style);

            const is_played = idx < played.len and played[idx];
            const num_style: vaxis.Style = if (is_cursor or is_playing)
                style
            else if (is_unplayable)
                row_style
            else if (is_played)
                .{ .fg = theme.colors.playlist_played_fg, .bg = bg }
            else
                style;
            const num = std.fmt.allocPrint(arena, "{d: >3}", .{idx + 1}) catch continue;
            paint.printAt(win, marker_w, y, num, num_style);

            if (title_w > 0) {
                const curated: ?[]const u8 = if (idx < titles.len) titles[idx] else null;
                const name = curated orelse remote.displayBasename(arena, entries[idx]);
                paint.printFit(win, title_x, y, name, title_w, row_style);
            }

            if (fmt_x < row_w) {
                const fmt_label = formatLabel(arena, entries[idx]);
                paint.printFit(win, fmt_x, y, fmt_label, row_w -| fmt_x, row_style);
            }
        }

        if (show_sb) paint.drawScrollbar(win, theme, header_rows, list_h, n, first);
        const cursor_unplayable = cursor < unplayable.len and unplayable[cursor];
        if (with_bar) drawKeyBar(win, theme, n, cursor, cursor_unplayable);
    }
};

fn drawKeyBar(win: vaxis.Window, theme: Theme, count: usize, cursor: usize, cursor_unplayable: bool) void {
    const hints = paint.listNavigationHints(count, cursor) ++ [_]paint.Hotkey{
        .{
            .key = "Enter",
            .label = if (cursor_unplayable) "retry" else "play",
            .enabled = count > 0,
        },
    };
    paint.drawListKeyBar(win, theme, &hints);
}

fn formatLabel(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (format.displayLabelForPath(path)) |label| return label;
    const ext = format.extensionOf(path);
    if (ext.len <= 1) return "?";
    const body = ext[1..];
    const out = arena.alloc(u8, body.len) catch return body;
    return std.ascii.upperString(out, body);
}

// --- tests -------------------------------------------------------------------

test "format column labels come from the owning format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("AudioT", formatLabel(arena, "music/audiot/AUDIOT.DEMO"));
    try std.testing.expectEqualStrings("VGM", formatLabel(arena, "a.vgz"));
    try std.testing.expectEqualStrings("WLF", formatLabel(arena, "a.wlf"));
    try std.testing.expectEqualStrings("HSC", formatLabel(arena, "http://x/tune.hsc"));
    try std.testing.expectEqualStrings("TXT", formatLabel(arena, "stray.txt"));
    try std.testing.expectEqualStrings("?", formatLabel(arena, "noext"));
}

fn parseOomBody(gpa: std.mem.Allocator) !void {
    const text =
        \\#EXTM3U
        \\#EXTINF:123 rate=560,Owned Title
        \\song.imf
        \\
    ;
    const parsed = try parse(gpa, "music/list.m3u", text);
    defer free(gpa, parsed);
}

test "parse transfers pending title ownership safely on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseOomBody,
        .{},
    );
}

test "parse skips BOM, directives, comments, blanks, and CRLF" {
    const gpa = std.testing.allocator;
    const text = "\xEF\xBB\xBF#EXTM3U\r\n\r\n#EXTINF:123,Some Title\r\nsongs/a.hsc\r\n  b.vgm  \r\n";
    const parsed = try parse(gpa, "music/list.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("music/songs/a.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("music/b.vgm", parsed.entries[1]);
    try std.testing.expectEqualStrings("Some Title", parsed.titles[0].?);
    try std.testing.expect(parsed.titles[1] == null);
}

test "EXTINF titles stay aligned across dropped entries" {
    const gpa = std.testing.allocator;
    const text =
        \\#EXTINF:-1 tvg-id="x",Dropped Entry Title
        \\readme.txt
        \\#EXTINF:200,Kept Title
        \\# a comment between directive and entry
        \\a.hsc
        \\b.vgm
        \\#EXTINF:10,
        \\c.dro
        \\#EXTINF:5,Tail Without Entry
        \\
    ;
    const parsed = try parse(gpa, "x.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.entries.len);
    try std.testing.expectEqualStrings("Kept Title", parsed.titles[0].?);
    try std.testing.expect(parsed.titles[1] == null);
    try std.testing.expect(parsed.titles[2] == null);
}

test "parse captures the #PLAYLIST name" {
    const gpa = std.testing.allocator;
    const with = "#EXTM3U\n#PLAYLIST:  Chip Hits \na.hsc\n";
    const parsed = try parse(gpa, "x.m3u", with);
    defer free(gpa, parsed);
    try std.testing.expectEqualStrings("Chip Hits", parsed.name.?);

    const without = "a.hsc\n";
    const parsed2 = try parse(gpa, "x.m3u", without);
    defer free(gpa, parsed2);
    try std.testing.expect(parsed2.name == null);

    const tricky = "#playlist:First\n#PLAYLIST:Second\n#PLAYLIST:\na.hsc\n";
    const parsed3 = try parse(gpa, "x.m3u", tricky);
    defer free(gpa, parsed3);
    try std.testing.expectEqualStrings("Second", parsed3.name.?);
}

test "parseExtinf splits title and rate in one pass" {
    try std.testing.expectEqualStrings("Hello, World", parseExtinf("#EXTINF:5,Hello, World").title.?);
    try std.testing.expectEqualStrings(
        "Real Title",
        parseExtinf("#EXTINF:-1 tvg-name=\"A, B\",Real Title").title.?,
    );
    try std.testing.expectEqualStrings(
        "Song",
        parseExtinf("#extinf:0 a=\"x\" b=\"y,z\",Song").title.?,
    );
    try std.testing.expect(parseExtinf("#EXTINF:-1 tvg-name=\"A, B,Title").title == null);
    try std.testing.expect(parseExtinf("#EXTINF:7").title == null);
    try std.testing.expect(parseExtinf("#EXTGRP:group").title == null);

    try std.testing.expectEqual(@as(u32, 700), parseExtinf("#EXTINF:-1 rate=700,Wolf Get Them").rate);
    try std.testing.expectEqual(@as(u32, 280), parseExtinf("#EXTINF:-1 rate=280,Duke Theme").rate);
    try std.testing.expectEqual(@as(u32, 560), parseExtinf("#EXTINF:12 rate=560 tvg-id=\"x\",Keen").rate);
    try std.testing.expectEqual(@as(u32, 0), parseExtinf("#EXTINF:-1,No Rate").rate);
    try std.testing.expectEqual(@as(u32, 0), parseExtinf("#EXTINF:-1 rate=44100,Bad").rate);
    try std.testing.expectEqual(@as(u32, 0), parseExtinf("#EXTINF:-1 bitrate=700,Not Rate").rate);
}

test "parse keeps rate= aligned with entries" {
    const gpa = std.testing.allocator;
    const text =
        \\#EXTINF:-1 rate=700,Wolf
        \\a.imf
        \\#EXTINF:-1,Plain VGM
        \\b.vgm
        \\#EXTINF:-1 rate=280,Duke
        \\c.imf
        \\
    ;
    const parsed = try parse(gpa, "x.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.rates.len);
    try std.testing.expectEqual(@as(u32, 700), parsed.rates[0]);
    try std.testing.expectEqual(@as(u32, 0), parsed.rates[1]);
    try std.testing.expectEqual(@as(u32, 280), parsed.rates[2]);
}

test "parse keeps absolute entries and normalizes backslashes" {
    const gpa = std.testing.allocator;
    const text = "C:\\tunes\\a.imf\n/opt/tunes/b.dro\nsub\\c.hsc\n";
    const parsed = try parse(gpa, "lists/all.m3u8", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.entries.len);
    try std.testing.expectEqualStrings("C:/tunes/a.imf", parsed.entries[0]);
    try std.testing.expectEqualStrings("/opt/tunes/b.dro", parsed.entries[1]);
    try std.testing.expectEqualStrings("lists/sub/c.hsc", parsed.entries[2]);
}

test "parse keeps fetchable URL entries absolute and drops other schemes" {
    const gpa = std.testing.allocator;
    const text =
        \\https://modland.com/pub/modules/Ad%20Lib/DOSBox/-%20unknown/dune1.dro
        \\HTTP://example.com/t.imf
        \\ftp://ftp.modland.com/pub/modules/Ad%20Lib/x.hsc
        \\
    ;
    const parsed = try parse(gpa, "music/modland.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings(
        "https://modland.com/pub/modules/Ad%20Lib/DOSBox/-%20unknown/dune1.dro",
        parsed.entries[0],
    );
    try std.testing.expectEqualStrings("HTTP://example.com/t.imf", parsed.entries[1]);
}

test "parse translates file URLs to local paths and drops malformed ones" {
    const gpa = std.testing.allocator;
    const text =
        \\file:///C:/tunes/a%20b.hsc
        \\file://localhost/opt/tunes/c.dro
        \\file://localhost
        \\
    ;
    const parsed = try parse(gpa, "x.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("C:/tunes/a b.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("/opt/tunes/c.dro", parsed.entries[1]);
}

test "remote playlists keep only http(s) entries" {
    const gpa = std.testing.allocator;
    const text = "track1.hsc\n" ++
        "\\\\evil\\share\\a.hsc\n" ++
        "file:///C:/secret/b.hsc\n" ++
        "file://evil/share/c.hsc\n" ++
        "C:\\local\\d.hsc\n" ++
        "/etc/e.hsc\n" ++
        "https://modland.com/pub/f.hsc\n";
    const parsed = try parse(gpa, "https://example.com/list/all.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("https://example.com/list/track1.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("https://modland.com/pub/f.hsc", parsed.entries[1]);
}

test "relative entries on a remote playlist are percent-encoded" {
    const gpa = std.testing.allocator;
    const text = "my song.dro\nsub/x%20y.imf\n";
    const parsed = try parse(gpa, "https://example.com/l.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("https://example.com/my%20song.dro", parsed.entries[0]);
    try std.testing.expectEqualStrings("https://example.com/sub/x%20y.imf", parsed.entries[1]);
}

test "parse rejects entries with control bytes and scrubs display text" {
    const gpa = std.testing.allocator;
    const text = "#PLAYLIST:evil\x1b]0;pwned\x07name\n" ++
        "#EXTINF:-1,title\x1b[31mred\n" ++
        "good.hsc\n" ++
        "https://evil.com/\x1b]0;pwned\x07x.hsc\n";
    const parsed = try parse(gpa, "x.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("good.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("title [31mred", parsed.titles[0].?);
    try std.testing.expectEqualStrings("evil ]0;pwned name", parsed.name.?);
}

test "a colon inside a plain filename does not make the entry absolute" {
    const gpa = std.testing.allocator;
    const text = "a:song.hsc\nC:\\tunes\\b.imf\nC:c.imf\n";
    const parsed = try parse(gpa, "music/list.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.entries.len);
    try std.testing.expectEqualStrings("music/a:song.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("C:/tunes/b.imf", parsed.entries[1]);
    try std.testing.expectEqualStrings("music/C:c.imf", parsed.entries[2]);
}

test "parse drops entries no format claims, including nested playlists" {
    const gpa = std.testing.allocator;
    const text = "readme.txt\ncover.jpg\ninner.m3u\ntune.hsc\nAUDIOT.WL6\n";
    const parsed = try parse(gpa, "x.m3u", text);
    defer free(gpa, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("tune.hsc", parsed.entries[0]);
    try std.testing.expectEqualStrings("AUDIOT.WL6", parsed.entries[1]);
}

test "playlist path detection is case-insensitive" {
    try std.testing.expect(isPlaylistPath("a.M3U"));
    try std.testing.expect(isPlaylistPath("b.m3u8"));
    try std.testing.expect(!isPlaylistPath("c.hsc"));
    try std.testing.expect(!isPlaylistPath("m3u"));
}
