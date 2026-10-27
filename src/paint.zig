//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Theme = @import("theme.zig").Theme;
const default_theme = @import("theme.zig").default_theme;

pub const eighths = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇" };

pub fn printAt(win: vaxis.Window, x: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    var col = x;
    var i: usize = 0;
    while (i < text.len and col < win.width) {
        const g = glyphAt(win, text, i);
        const piece = if (codepointLen(text[i..]) == null) replacement_glyph else text[i..g.next];
        col = win.print(&.{.{ .text = piece, .style = style }}, .{
            .col_offset = col,
            .row_offset = row,
            .wrap = .none,
        }).col;
        i = g.next;
    }
}

const replacement_glyph = "\u{FFFD}";

fn codepointLen(text: []const u8) ?usize {
    const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (n > text.len or !std.unicode.utf8ValidateSlice(text[0..n])) return null;
    return n;
}

fn validPrefixLen(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) i += codepointLen(text[i..]) orelse break;
    return i;
}

pub fn skipColumns(win: vaxis.Window, text: []const u8, cols: u16) []const u8 {
    var skipped: u32 = 0;
    var i: usize = 0;
    while (i < text.len and skipped < cols) {
        const g = glyphAt(win, text, i);
        skipped += g.w;
        i = g.next;
    }
    return text[i..];
}

pub fn textWidth(win: vaxis.Window, text: []const u8) u16 {
    return columnWidth(win, text, std.math.maxInt(u16));
}

pub fn fillRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    var x: u16 = 0;
    while (x < win.width) : (x += 1) {
        win.writeCell(x, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    }
}

pub fn fillRowBg(win: vaxis.Window, row: u16, x0: u16, width: u16, bg: vaxis.Color) void {
    var x = x0;
    const end = @min(win.width, x0 +| width);
    while (x < end) : (x += 1) {
        win.writeCell(x, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = bg },
        });
    }
}

pub const Meter = struct {
    level: f32,
    peak: f32 = 0,
    glow: f32 = 0,
};

pub fn drawMeterColumn(
    win: vaxis.Window,
    theme: Theme,
    x: u16,
    top: u16,
    height: u16,
    width: u16,
    meter: Meter,
) void {
    if (height == 0 or width == 0) return;
    const h = meter.level * @as(f32, @floatFromInt(height));
    const full: u16 = @intFromFloat(h);
    const frac_idx: u16 = @intFromFloat((h - @floor(h)) * 8.0);
    const denom: f32 = @floatFromInt(@max(1, height - 1));

    var k: u16 = 0;
    while (k < height) : (k += 1) {
        const row = top + height - 1 - k;
        const style = theme.meterBar(@as(f32, @floatFromInt(k)) / denom, false);
        for (0..width) |offset| {
            const col = x + @as(u16, @intCast(offset));
            if (k < full) {
                win.writeCell(col, row, .{ .char = .{ .grapheme = "█", .width = 1 }, .style = style });
            } else if (k == full and frac_idx > 0) {
                win.writeCell(col, row, .{
                    .char = .{ .grapheme = eighths[frac_idx - 1], .width = 1 },
                    .style = style,
                });
            }
        }
    }

    const peak_row: u16 = @intFromFloat(@round(meter.peak * @as(f32, @floatFromInt(height))));
    if (peak_row == 0 or peak_row <= full or peak_row > height or meter.glow <= 0) return;
    for (0..width) |offset| {
        win.writeCell(x + @as(u16, @intCast(offset)), top + height - peak_row, .{
            .char = .{ .grapheme = "▔", .width = 1 },
            .style = theme.barPeak(meter.glow),
        });
    }
}

pub fn drawRule(win: vaxis.Window, theme: Theme, row: u16, width: u16) void {
    const style = theme.style(.list_rule);
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        win.writeCell(x, row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = style,
        });
    }
}

pub const Hotkey = struct {
    key: []const u8,
    codepoint: ?u21 = null,
    label: []const u8,
    enabled: bool = true,
    label_enabled: ?bool = null,
    glue: bool = false,

    fn labelIsEnabled(self: Hotkey) bool {
        return self.label_enabled orelse self.enabled;
    }
};

pub const HotkeyHits = struct {
    const Hit = struct { x0: i17, x1: i17, row: i17, codepoint: u21 };
    items: [16]Hit = undefined,
    len: usize = 0,

    pub fn add(self: *HotkeyHits, win: vaxis.Window, row: u16, x0: u16, x1: u16, codepoint: u21) void {
        if (self.len == self.items.len or row >= win.height or x0 >= win.width) return;
        self.items[self.len] = .{
            .x0 = @as(i17, win.x_off) + x0,
            .x1 = @as(i17, win.x_off) + @min(x1, win.width),
            .row = @as(i17, win.y_off) + row,
            .codepoint = codepoint,
        };
        self.len += 1;
    }

    pub fn keyAt(self: *const HotkeyHits, col: i16, row: i16) ?u21 {
        for (self.items[0..self.len]) |hit| {
            if (row == hit.row and col >= hit.x0 and col < hit.x1) return hit.codepoint;
        }
        return null;
    }
};

pub const key_bar_height: u16 = 2;

pub fn drawHotkeyHints(
    win: vaxis.Window,
    theme: Theme,
    row: u16,
    hints: []const Hotkey,
    x0: u16,
    hits: *HotkeyHits,
) void {
    if (hints.len == 0) return;
    const sep_style = theme.style(.key_sep);

    var x = x0;
    for (hints, 0..) |hk, i| {
        const sep_w: u16 = if (i == 0) 0 else if (hk.glue) 1 else 3;
        var chip_w: u16 = win.gwidth(hk.key);
        if (hk.label.len > 0) chip_w += 1 + win.gwidth(hk.label);
        if (x + sep_w + chip_w > win.width) break;
        if (i > 0) {
            if (hk.glue) {
                printAt(win, x, row, " ", sep_style);
                x += 1;
            } else {
                printAt(win, x, row, " · ", sep_style);
                x += 3;
            }
        }
        const key_style = if (hk.enabled) theme.style(.key_key) else theme.style(.key_key_disabled);
        const label_style = if (hk.labelIsEnabled()) theme.style(.key_label) else theme.style(.key_label_disabled);
        if (hk.enabled) if (hk.codepoint) |key| hits.add(win, row, x, x + chip_w, key);
        printAt(win, x, row, hk.key, key_style);
        x += win.gwidth(hk.key);
        if (hk.label.len > 0) {
            printAt(win, x, row, " ", label_style);
            x += 1;
            printAt(win, x, row, hk.label, label_style);
            x += win.gwidth(hk.label);
        }
    }
}

pub fn listNavigationHints(total: usize, cursor: usize) [6]Hotkey {
    const current = if (total == 0) 0 else @min(cursor, total - 1);
    const can_up = total > 0 and current > 0;
    const can_down = total > 0 and current + 1 < total;
    const can_move = can_up or can_down;
    return .{
        .{ .key = "↑", .codepoint = vaxis.Key.up, .label = "", .enabled = can_up },
        .{ .key = "↓", .codepoint = vaxis.Key.down, .label = "move", .enabled = can_down, .label_enabled = can_move, .glue = true },
        .{ .key = "PgUp", .codepoint = vaxis.Key.page_up, .label = "", .enabled = can_up },
        .{ .key = "PgDn", .codepoint = vaxis.Key.page_down, .label = "page", .enabled = can_down, .label_enabled = can_move, .glue = true },
        .{ .key = "Home", .codepoint = vaxis.Key.home, .label = "", .enabled = can_up },
        .{ .key = "End", .codepoint = vaxis.Key.end, .label = "jump", .enabled = can_down, .label_enabled = can_move, .glue = true },
    };
}

pub fn drawListKeyBar(win: vaxis.Window, theme: Theme, hints: []const Hotkey, hits: *HotkeyHits) void {
    if (win.height < key_bar_height) return;
    const row = win.height - 1;
    drawRule(win, theme, row - 1, win.width);
    fillRow(win, row, theme.style(.key_label));
    drawHotkeyHints(win, theme, row, hints, 1, hits);
}

pub fn listEnsureVisible(scroll: *usize, cursor: usize, total: usize, page_h: usize) void {
    if (total == 0 or page_h == 0) {
        scroll.* = 0;
        return;
    }
    if (total <= page_h) {
        scroll.* = 0;
        return;
    }
    if (cursor < scroll.*) scroll.* = cursor;
    if (cursor >= scroll.* + page_h) scroll.* = cursor + 1 - page_h;
    const max_s = total - page_h;
    if (scroll.* > max_s) scroll.* = max_s;
}

pub const ListNav = struct {
    key_hits: HotkeyHits = .{},
    cursor: usize = 0,
    scroll: usize = 0,
    page_h: usize = 0,
    hit_x0: u16 = 0,
    hit_x1: u16 = 0,
    hit_y0: u16 = 0,
    hit_rows: u16 = 0,

    pub fn move(self: *ListNav, count: usize, dir: i8) void {
        if (count == 0) return;
        if (dir > 0) {
            if (self.cursor + 1 < count) self.cursor += 1;
        } else {
            self.cursor -|= 1;
        }
        self.ensureCursorVisible(count);
    }

    pub fn page(self: *ListNav, count: usize, dir: i8) void {
        if (count == 0) return;
        const step = @max(@as(usize, 1), self.page_h);
        if (dir > 0) {
            self.cursor = @min(self.cursor + step, count - 1);
        } else {
            self.cursor -|= step;
        }
        self.ensureCursorVisible(count);
    }

    pub fn goHome(self: *ListNav, count: usize) void {
        if (count == 0) return;
        self.cursor = 0;
        self.ensureCursorVisible(count);
    }

    pub fn goEnd(self: *ListNav, count: usize) void {
        if (count == 0) return;
        self.cursor = count - 1;
        self.ensureCursorVisible(count);
    }

    pub fn syncTo(self: *ListNav, index: usize, count: usize) void {
        if (count == 0) return;
        self.cursor = @min(index, count - 1);
        self.ensureCursorVisible(count);
    }

    pub fn rowAt(self: *const ListNav, col: u16, row: u16, count: usize) ?usize {
        if (self.hit_rows == 0) return null;
        if (row < self.hit_y0 or row >= self.hit_y0 + self.hit_rows) return null;
        if (col < self.hit_x0 or col >= self.hit_x1) return null;
        const idx = self.scroll + (row - self.hit_y0);
        return if (idx < count) idx else null;
    }

    fn ensureCursorVisible(self: *ListNav, count: usize) void {
        listEnsureVisible(&self.scroll, self.cursor, count, @max(1, self.page_h));
    }
};

pub fn drawScrollbar(
    win: vaxis.Window,
    theme: Theme,
    list_top: u16,
    list_h: u16,
    total: usize,
    first: usize,
) void {
    if (list_h == 0 or total <= list_h) return;
    const x = win.width -| 1;
    const track = theme.style(.scroll_track);
    const thumb = theme.style(.scroll_thumb);

    var y: u16 = 0;
    while (y < list_h) : (y += 1) {
        win.writeCell(x, list_top + y, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = track,
        });
    }

    const thumb_h: u16 = @intCast(@max(@as(usize, 1), (@as(usize, list_h) * list_h) / total));
    const max_first = total - list_h;
    const travel = list_h -| thumb_h;
    const thumb_y: u16 = if (max_first == 0 or travel == 0)
        0
    else
        @intCast((first * travel) / max_first);

    var t: u16 = 0;
    while (t < thumb_h) : (t += 1) {
        win.writeCell(x, list_top + thumb_y + t, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = thumb,
        });
    }
}

const Glyph = struct { w: u16, next: usize };

const max_cluster_bytes = 64;

fn glyphAt(win: vaxis.Window, text: []const u8, i: usize) Glyph {
    if (i >= text.len) return .{ .w = 0, .next = i };
    if (std.ascii.isPrint(text[i]) and (i + 1 == text.len or std.ascii.isAscii(text[i + 1]))) return .{ .w = 1, .next = i + 1 };
    const window = text[i..@min(text.len, i + max_cluster_bytes)];
    const run = window[0..validPrefixLen(window)];
    if (run.len == 0) return .{ .w = 1, .next = i + 1 };
    var clusters = vaxis.unicode.graphemeIterator(run);
    const cluster = clusters.next() orelse return .{ .w = 1, .next = i + 1 };
    return .{ .w = win.gwidth(cluster.bytes(run)), .next = i + cluster.len };
}

pub fn columnWidth(win: vaxis.Window, text: []const u8, limit: u16) u16 {
    var cols: u16 = 0;
    var i: usize = 0;
    while (i < text.len and cols < limit) {
        const g = glyphAt(win, text, i);
        if (g.next == i) break;
        if (@as(u32, cols) + g.w > limit) break;
        cols += g.w;
        i = g.next;
    }
    return cols;
}

fn fitsWidth(win: vaxis.Window, text: []const u8, max_cols: u16) bool {
    var cols: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const g = glyphAt(win, text, i);
        if (g.next == i) break;
        if (@as(u32, cols) + g.w > max_cols) return false;
        cols += g.w;
        i = g.next;
    }
    return true;
}

fn fitText(win: vaxis.Window, text: []const u8, max_cols: u16) []const u8 {
    var end: usize = 0;
    var cols: u16 = 0;
    while (end < text.len) {
        const g = glyphAt(win, text, end);
        if (g.next == end) break;
        if (@as(u32, cols) + g.w > max_cols) break;
        cols += g.w;
        end = g.next;
    }
    return text[0..end];
}

fn fitTextTail(win: vaxis.Window, text: []const u8, max_cols: u16) []const u8 {
    if (max_cols == 0 or text.len == 0) return text[text.len..];
    var start: usize = 0;
    var end: usize = 0;
    var cols: u16 = 0;
    while (end < text.len) {
        const g = glyphAt(win, text, end);
        if (g.next == end) break;
        if (g.w > max_cols) {
            start = g.next;
            end = g.next;
            cols = 0;
            continue;
        }
        while (@as(u32, cols) + g.w > max_cols and start < end) {
            const dropped = glyphAt(win, text, start);
            cols -= dropped.w;
            start = dropped.next;
        }
        cols += g.w;
        end = g.next;
    }
    return text[start..];
}

pub fn printFit(
    win: vaxis.Window,
    x: u16,
    row: u16,
    text: []const u8,
    max_cols: u16,
    style: vaxis.Style,
) void {
    if (max_cols == 0) return;
    if (fitsWidth(win, text, max_cols)) {
        printAt(win, x, row, text, style);
        return;
    }
    const head = fitText(win, text, max_cols -| 1);
    printAt(win, x, row, head, style);
    printAt(win, x + columnWidth(win, head, max_cols), row, "…", style);
}

pub fn printFitTail(
    win: vaxis.Window,
    x: u16,
    row: u16,
    text: []const u8,
    max_cols: u16,
    style: vaxis.Style,
) void {
    if (max_cols == 0) return;
    if (fitsWidth(win, text, max_cols)) {
        printAt(win, x, row, text, style);
        return;
    }
    printAt(win, x, row, "…", style);
    printAt(win, x + 1, row, fitTextTail(win, text, max_cols -| 1), style);
}

// --- tests -------------------------------------------------------------------

test "list navigation hints reflect cursor position" {
    const first = listNavigationHints(3, 0);
    try std.testing.expect(!first[0].enabled);
    try std.testing.expect(first[1].enabled);

    const last = listNavigationHints(3, 2);
    try std.testing.expect(last[0].enabled);
    try std.testing.expect(!last[1].enabled);
}

test "ListNav clamps movement and resolves hit rows" {
    var nav = ListNav{ .page_h = 2 };
    nav.move(3, 1);
    try std.testing.expectEqual(@as(usize, 1), nav.cursor);
    nav.page(3, 1);
    try std.testing.expectEqual(@as(usize, 2), nav.cursor);
    nav.goHome(3);
    try std.testing.expectEqual(@as(usize, 0), nav.cursor);
    nav.syncTo(9, 3);
    try std.testing.expectEqual(@as(usize, 2), nav.cursor);

    nav.scroll = 1;
    nav.hit_x0 = 4;
    nav.hit_x1 = 8;
    nav.hit_y0 = 10;
    nav.hit_rows = 2;
    try std.testing.expectEqual(@as(?usize, 2), nav.rowAt(5, 11, 3));
    try std.testing.expectEqual(@as(?usize, null), nav.rowAt(3, 11, 3));
}

test "row fill and meter column stay within their bounds" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 4,
        .cols = 6,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 6,
        .height = 4,
        .screen = &screen,
    };

    fillRowBg(win, 0, 2, 2, default_theme.colors.bg);
    try std.testing.expectEqual(default_theme.colors.bg, screen.readCell(2, 0).?.style.bg);
    try std.testing.expectEqual(@as(vaxis.Color, .default), screen.readCell(1, 0).?.style.bg);

    drawMeterColumn(win, default_theme, 1, 0, 4, 2, .{ .level = 0.55 });
    try std.testing.expectEqualStrings("█", screen.readCell(1, 3).?.char.grapheme);
    try std.testing.expectEqualStrings("▁", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 3).?.char.grapheme);
}

test "printFit and printFitTail mark truncation with an ellipsis" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 1,
        .screen = &screen,
    };

    printFit(win, 0, 0, "short", 6, .{});
    try std.testing.expectEqualStrings("t", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expect(!std.mem.eql(u8, screen.readCell(5, 0).?.char.grapheme, "…"));

    printFit(win, 0, 0, "much too long", 6, .{});
    try std.testing.expectEqualStrings("m", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("…", screen.readCell(5, 0).?.char.grapheme);

    printFitTail(win, 0, 0, "path/to/dir", 6, .{});
    try std.testing.expectEqualStrings("…", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("r", screen.readCell(5, 0).?.char.grapheme);
}

test "invalid UTF-8 before a combining mark prints replacement glyphs" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 1,
        .screen = &screen,
    };

    const cp437 = "S\xF1A\xCD\x81g";
    try std.testing.expectEqual(@as(u16, 4), textWidth(win, cp437));
    printAt(win, 0, 0, cp437, .{});
    try std.testing.expectEqualStrings("S", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("\u{FFFD}", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("A\xCD\x81", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(3, 0).?.char.grapheme);

    printFit(win, 0, 0, "\x80\xCC\x80 tail", 4, .{});
    try std.testing.expectEqualStrings("\u{FFFD}", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("…", screen.readCell(3, 0).?.char.grapheme);
}

test "text width follows the grapheme clusters that vaxis draws" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 1, .cols = 16, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 16, .height = 1, .screen = &screen };
    for ([_][]const u8{ "I \u{2764}\u{FE0F} OPL", "\u{1F1EF}\u{1F1F5}ab", "\u{1F468}\u{200D}\u{1F469}x" }) |text| {
        try std.testing.expectEqual(win.gwidth(text), textWidth(win, text));
    }
    printFit(win, 0, 0, "I \u{2764}\u{FE0F} OPL", 8, .{});
    try std.testing.expectEqualStrings("L", screen.readCell(7, 0).?.char.grapheme);
}

test "glyph steps match vaxis clusters beside ASCII controls, CR LF, and joining marks" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 1, .cols = 16, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 16, .height = 1, .screen = &screen };
    const texts = [_][]const u8{ "a\tb", "x\x00y", "\x1b[0m", "a\x7fb", "ab\r\ncd\r", "e\u{301}x", "#\u{FE0F}\u{20E3}!", "~\u{200D}\u{1F469}z", "\u{600}a " };
    for (std.enums.values(vaxis.gwidth.Method)) |method| {
        screen.width_method = method;
        for (texts) |text| {
            var clusters = vaxis.unicode.graphemeIterator(text);
            var i: usize = 0;
            while (clusters.next()) |cluster| {
                const g = glyphAt(win, text, i);
                try std.testing.expectEqual(i + cluster.len, g.next);
                try std.testing.expectEqual(win.gwidth(cluster.bytes(text)), g.w);
                i = g.next;
            }
            try std.testing.expectEqual(text.len, i);
        }
    }
}

test "text after a line feed draws at the column its measurement gives" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 2, .cols = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 30, .height = 2, .screen = &screen };
    const text = "Part 1\nPart 2\xFFX";
    try std.testing.expectEqual(@as(u16, 14), textWidth(win, text));
    printFit(win, 0, 0, text, 30, .{});
    try std.testing.expectEqualStrings("P", screen.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("2", screen.readCell(11, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("\u{FFFD}", screen.readCell(12, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("X", screen.readCell(13, 0).?.char.grapheme);

    printFit(win, 0, 1, "Part 1\nPart 2 is long", 10, .{});
    try std.testing.expectEqualStrings("r", screen.readCell(8, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("…", screen.readCell(9, 1).?.char.grapheme);
}

test "a cluster wider than a cell can record draws as measured pieces" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 1, .cols = 260, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .wcwidth;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 260, .height = 1, .screen = &screen };
    const marks: [255][3]u8 = @splat("\u{903}".*);
    const text = "a" ++ @as([marks.len * 3]u8, @bitCast(marks));
    try std.testing.expectEqual(@as(u16, 256), textWidth(win, text));
    printFit(win, 0, 0, text, 256, .{});
    try std.testing.expect(std.mem.startsWith(u8, screen.readCell(0, 0).?.char.grapheme, "a"));
    var col: u16 = 0;
    while (col < 256) {
        const cell = screen.readCell(col, 0).?;
        try std.testing.expect(cell.char.grapheme.len <= max_cluster_bytes);
        col += cell.char.width;
    }
    try std.testing.expectEqual(@as(u16, 256), col);
    try std.testing.expectEqualStrings(" ", screen.readCell(256, 0).?.char.grapheme);
}

test "hotkey hit areas follow drawn cells and exclude disabled or clipped actions" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 4, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 5, .y_off = 2, .parent_x_off = 0, .parent_y_off = 0, .width = 22, .height = 1, .screen = &screen };
    const hints = [_]Hotkey{
        .{ .key = "↑", .codepoint = vaxis.Key.up, .label = "", .enabled = false },
        .{ .key = "↓", .codepoint = vaxis.Key.down, .label = "move", .glue = true },
        .{ .key = "Enter", .codepoint = vaxis.Key.enter, .label = "open" },
        .{ .key = "End", .codepoint = vaxis.Key.end, .label = "jump" },
    };
    var hits = HotkeyHits{};
    drawHotkeyHints(win, default_theme, 0, &hints, 1, &hits);
    try std.testing.expectEqual(@as(?u21, null), hits.keyAt(6, 2));
    try std.testing.expectEqual(@as(?u21, vaxis.Key.down), hits.keyAt(8, 2));
    try std.testing.expectEqual(@as(?u21, vaxis.Key.down), hits.keyAt(13, 2));
    try std.testing.expectEqual(@as(?u21, null), hits.keyAt(14, 2));
    try std.testing.expectEqual(@as(?u21, vaxis.Key.enter), hits.keyAt(26, 2));
    try std.testing.expectEqual(@as(?u21, null), hits.keyAt(26, 1));
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}
