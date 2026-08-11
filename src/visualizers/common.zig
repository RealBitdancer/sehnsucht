//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Theme = @import("../theme.zig").Theme;
const paint = @import("../paint.zig");

pub const spec_bar_rows: u16 = 10;
pub const top_rows: u16 = spec_bar_rows + 3;
pub const order_w: u16 = 10;

pub const note_names = [_][]const u8{ "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" };
pub const spark_glyphs = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
pub const sup_digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };
pub const sup_k = "ᵏ";

pub fn drawVuMeter(
    win: vaxis.Window,
    theme: Theme,
    x: u16,
    row: u16,
    width: u16,
    level: f32,
    peak: f32,
) u16 {
    if (width == 0) return x;
    const wf: f32 = @floatFromInt(width);
    const filled: u16 = @intFromFloat(std.math.clamp(level, 0.0, 1.0) * wf);
    const peak_cell: ?u16 = if (peak > 0.001)
        @intFromFloat(std.math.clamp(peak, 0.0, 1.0) * (wf - 1.0))
    else
        null;
    const denom: f32 = @floatFromInt(@max(1, width - 1));

    var col = x;
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        const is_peak = if (peak_cell) |p| i == p and i >= filled else false;
        const lit = i < filled or is_peak;
        const style = if (lit)
            theme.meterBar(@as(f32, @floatFromInt(i)) / denom, is_peak)
        else
            theme.style(.meter_empty);
        win.writeCell(col, row, .{ .char = .{ .grapheme = "▇", .width = 1 }, .style = style });
        col += 1;
    }
    return col;
}

pub fn spectrumBarWidth(win_w: u16) u16 {
    return if (win_w >= 160) 5 else if (win_w >= 130) 4 else if (win_w >= 100) 3 else if (win_w >= 70) 2 else 1;
}

pub fn spectrumPanelWidth(bar_w: u16) u16 {
    return 2 + 4 + 9 * bar_w + 8;
}

pub fn drawSpectrum(
    win: vaxis.Window,
    theme: Theme,
    x: u16,
    y: u16,
    box_w: u16,
    bar_w: u16,
    levels: *const [9]f32,
    peaks: *const [9]f32,
    peak_glow: *const [9]f32,
) void {
    const box = win.child(.{
        .x_off = x,
        .y_off = y,
        .width = box_w,
        .height = top_rows,
        .border = .{ .where = .all, .glyphs = .single_rounded, .style = theme.style(.spectrum_frame) },
    });
    paint.printAt(win, x + (box_w -| 10) / 2, y, " SPECTRUM ", theme.style(.spectrum_title));

    const bar_rows = spec_bar_rows;
    const digit_row = bar_rows;

    for (0..9) |ch| {
        const bar_x: u16 = @intCast(2 + ch * (bar_w + 1));
        const level = levels[ch];
        paint.drawMeterColumn(box, theme, bar_x, 0, bar_rows, bar_w, .{
            .level = level,
            .peak = peaks[ch],
            .glow = peak_glow[ch],
        });

        const active = level > 0.01;
        paint.printAt(box, bar_x + (bar_w - 1) / 2, digit_row, sup_digits[ch + 1], if (active) theme.style(.spec_digit_on) else theme.style(.spec_digit_off));
    }
}
