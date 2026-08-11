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
    if (text.len == 0) return;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{
        .col_offset = x,
        .row_offset = row,
        .wrap = .none,
    });
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
    label: []const u8,
    enabled: bool = true,
    label_enabled: ?bool = null,
    glue: bool = false,

    fn labelIsEnabled(self: Hotkey) bool {
        return self.label_enabled orelse self.enabled;
    }
};

pub const key_bar_height: u16 = 2;

pub fn drawHotkeyHints(
    win: vaxis.Window,
    theme: Theme,
    row: u16,
    hints: []const Hotkey,
    x0: u16,
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
        .{ .key = "↑", .label = "", .enabled = can_up },
        .{ .key = "↓", .label = "move", .enabled = can_down, .label_enabled = can_move, .glue = true },
        .{ .key = "PgUp", .label = "", .enabled = can_up },
        .{ .key = "PgDn", .label = "page", .enabled = can_down, .label_enabled = can_move, .glue = true },
        .{ .key = "Home", .label = "", .enabled = can_up },
        .{ .key = "End", .label = "jump", .enabled = can_down, .label_enabled = can_move, .glue = true },
    };
}

pub fn drawListKeyBar(win: vaxis.Window, theme: Theme, hints: []const Hotkey) void {
    if (win.height < key_bar_height) return;
    const row = win.height - 1;
    drawRule(win, theme, row - 1, win.width);
    fillRow(win, row, theme.style(.key_label));
    drawHotkeyHints(win, theme, row, hints, 1);
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
    const track_bg = theme.colors.scroll_track_bg;
    const thumb_bg = theme.colors.scroll_thumb_bg;

    var y: u16 = 0;
    while (y < list_h) : (y += 1) {
        win.writeCell(x, list_top + y, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .fg = track_bg, .bg = track_bg },
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
            .style = .{ .fg = thumb_bg, .bg = thumb_bg },
        });
    }
}

fn fitText(win: vaxis.Window, text: []const u8, max_cols: u16) []const u8 {
    if (win.gwidth(text) <= max_cols) return text;
    var end: usize = 0;
    var cols: u16 = 0;
    while (end < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        const next = @min(text.len, end + n);
        const w = win.gwidth(text[end..next]);
        if (cols + w > max_cols) break;
        cols += w;
        end = next;
    }
    return text[0..end];
}

fn fitTextTail(win: vaxis.Window, text: []const u8, max_cols: u16) []const u8 {
    if (win.gwidth(text) <= max_cols) return text;
    var start: usize = 0;
    while (start < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        start = @min(text.len, start + n);
        if (win.gwidth(text[start..]) <= max_cols) return text[start..];
    }
    return text[text.len..];
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
    if (win.gwidth(text) <= max_cols) {
        printAt(win, x, row, text, style);
        return;
    }
    const head = fitText(win, text, max_cols - 1);
    printAt(win, x, row, head, style);
    printAt(win, x + win.gwidth(head), row, "…", style);
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
    if (win.gwidth(text) <= max_cols) {
        printAt(win, x, row, text, style);
        return;
    }
    printAt(win, x, row, "…", style);
    printAt(win, x + 1, row, fitTextTail(win, text, max_cols - 1), style);
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
