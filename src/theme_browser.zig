//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const paint = @import("paint.zig");
const Theme = @import("theme.zig").Theme;

pub const State = struct {
    nav: paint.ListNav = .{},

    pub fn draw(
        self: *State,
        win: vaxis.Window,
        selected_theme: Theme,
        available: []const Theme,
        selected_index: usize,
    ) void {
        const header_rows: u16 = 3;
        const with_bar = win.height >= header_rows + paint.key_bar_height + 1;
        const bar_h: u16 = if (with_bar) paint.key_bar_height else 0;
        if (win.height < header_rows + 1) return;

        const count = available.len;
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(
            &title_buf,
            "Themes · {d} theme{s}",
            .{ count, if (count == 1) "" else "s" },
        ) catch "Themes";
        paint.printFit(win, 1, 0, title, win.width -| 2, selected_theme.style(.playlist_title));

        const list_h = win.height - header_rows - bar_h;
        self.nav.page_h = list_h;
        const cursor = @min(self.nav.cursor, count -| 1);
        self.nav.cursor = cursor;
        paint.listEnsureVisible(&self.nav.scroll, cursor, count, list_h);
        const first = self.nav.scroll;
        const show_sb = count > list_h;
        const row_w = if (show_sb) win.width -| 1 else win.width;

        self.nav.hit_x0 = @intCast(@max(0, win.x_off));
        self.nav.hit_x1 = @as(u16, @intCast(@max(0, win.x_off))) + row_w;
        self.nav.hit_y0 = @as(u16, @intCast(@max(0, win.y_off))) + header_rows;
        self.nav.hit_rows = @intCast(@min(@as(usize, list_h), count - first));

        const marker_w: u16 = 2;
        const gap: u16 = 2;
        const name_x = marker_w;
        const usable = row_w -| marker_w -| gap;
        const name_w = @min(@as(u16, 24), @max(@as(u16, 10), usable / 3));
        const description_x = name_x + name_w + gap;

        const header_style = selected_theme.style(.list_header);
        paint.printAt(win, name_x, 1, "Theme", header_style);
        if (description_x < row_w) paint.printAt(win, description_x, 1, "Description", header_style);
        paint.drawRule(win, selected_theme, 2, row_w);

        var row: u16 = 0;
        while (row < list_h) : (row += 1) {
            const idx = first + row;
            if (idx >= count) break;
            const y = header_rows + row;
            const is_cursor = idx == cursor;
            const is_selected = idx == selected_index;
            const bg = if (is_cursor)
                selected_theme.colors.list_cursor_bg
            else if (is_selected)
                selected_theme.colors.playlist_playing_bg
            else
                selected_theme.colors.bg;
            const fg = if (is_cursor)
                selected_theme.colors.list_cursor_fg
            else if (is_selected)
                selected_theme.colors.playlist_playing_fg
            else
                selected_theme.colors.list_row_fg;
            const style = selected_theme.listEntry(fg, bg, is_cursor or is_selected);

            paint.fillRowBg(win, y, 0, row_w, bg);

            paint.printAt(win, 0, y, if (is_selected) "▶" else " ", style);
            paint.printFit(win, name_x, y, available[idx].display_name, name_w, style);
            if (description_x < row_w) {
                paint.printFit(
                    win,
                    description_x,
                    y,
                    available[idx].description,
                    row_w - description_x,
                    style,
                );
            }
        }

        if (show_sb) paint.drawScrollbar(win, selected_theme, header_rows, list_h, count, first);
        if (with_bar) drawKeyBar(win, selected_theme, count, cursor);
    }
};

fn drawKeyBar(win: vaxis.Window, theme: Theme, count: usize, cursor: usize) void {
    const hints = paint.listNavigationHints(count, cursor) ++ [_]paint.Hotkey{
        .{ .key = "Enter", .label = "apply", .enabled = count > 0 },
    };
    paint.drawListKeyBar(win, theme, &hints);
}

// --- tests -------------------------------------------------------------------

test "theme browser navigation clamps to available themes" {
    var state = State{};
    state.nav.move(2, 1);
    state.nav.move(2, 1);
    try std.testing.expectEqual(@as(usize, 1), state.nav.cursor);
    state.nav.goHome(2);
    try std.testing.expectEqual(@as(usize, 0), state.nav.cursor);
    state.nav.goEnd(2);
    try std.testing.expectEqual(@as(usize, 1), state.nav.cursor);
}
