//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const common = @import("common.zig");
const paint = @import("../paint.zig");
const format = @import("../format.zig");
const Theme = @import("../theme.zig").Theme;
const viz = @import("../visualizer.zig");

const pat_gutter: u16 = 4;
const chan_min_w: u16 = 8;
const chan_max_w: u16 = 20;
const order_end: u8 = 0xFF;
const order_jump_bit: u8 = 0x80;

pub const name = "tracker";

const instrument_labels = [_][]const u8{
    "Tremolo",
    "Vibrato",
    "Sustaining",
    "Scale Rate",
    "Multiplier",
    "ScaleLevel",
    "Volume",
    "Attack",
    "Decay",
    "Sustain",
    "Release",
    "Wave Type",
};

const Gauge = struct { value: u8, max: u8 };

const Layout = struct {
    show_top: bool,
    show_instrument: bool,
    gauge_w: u16,
    bar_w: u16,
    spectrum_w: u16,
    spectrum_x: u16,
    order_x: u16,
    top: u16,
    info_row: u16,
    pattern_head_row: u16,
    pattern_top: u16,
    pattern_end: u16,
    show_pattern: bool,
    pat_x: u16,
    chans: u16,
    col_x: [9]u16,
    col_w: [9]u16,
};

fn computeLayout(w: u16, top: u16, bottom: u16, view_channels: u16) ?Layout {
    if (w < 44 or bottom <= top) return null;
    const content_h = bottom - top;
    if (content_h < 4) return null;

    const show_top = content_h >= 20;
    const bar_w = common.spectrumBarWidth(w);
    const spectrum_w = common.spectrumPanelWidth(bar_w);
    const spectrum_x = w - spectrum_w;
    const order_x = spectrum_x - common.order_w;
    const show_instrument = show_top and w >= 80;
    const gauge_w = std.math.clamp((order_x -| 22) / 2, 8, 20);

    const info_row: u16 = if (show_top) top + common.top_rows else top;
    const pattern_head_row = info_row + 1;
    const pattern_top = pattern_head_row + 1;
    const pattern_end = bottom;
    const show_pattern = pattern_end > pattern_top + 2;

    var col_x: [9]u16 = @splat(0);
    var col_w: [9]u16 = @splat(0);
    var chans: u16 = 0;
    var pat_x: u16 = 0;
    const n: u16 = @min(view_channels, 9);
    if (n > 0) {
        const avail = w - pat_gutter;
        if (avail / n >= chan_min_w) {
            chans = n;
            const base = @min(avail / n, chan_max_w);
            const extra = if (avail / n >= chan_max_w) 0 else avail % n;
            pat_x = (w - (pat_gutter + base * n + extra)) / 2;
            var x = pat_x + pat_gutter;
            for (0..chans) |i| {
                const cw = base + @as(u16, @intFromBool(i < extra));
                col_x[i] = x;
                col_w[i] = cw;
                x += cw;
            }
        } else {
            chans = avail / chan_min_w;
            var x = pat_gutter;
            for (0..chans) |i| {
                col_x[i] = x;
                col_w[i] = chan_min_w;
                x += chan_min_w;
            }
        }
    }

    return .{
        .show_top = show_top,
        .show_instrument = show_instrument,
        .gauge_w = gauge_w,
        .bar_w = bar_w,
        .spectrum_w = spectrum_w,
        .spectrum_x = spectrum_x,
        .order_x = order_x,
        .top = top,
        .info_row = info_row,
        .pattern_head_row = pattern_head_row,
        .pattern_top = pattern_top,
        .pattern_end = pattern_end,
        .show_pattern = show_pattern,
        .pat_x = pat_x,
        .chans = chans,
        .col_x = col_x,
        .col_w = col_w,
    };
}

pub fn draw(ctx: *viz.DrawContext) void {
    const view = ctx.view orelse {
        const t = ctx.theme;
        paint.printAt(ctx.win, 1, 0, "tracker visualizer requires TrackerView", t.style(.viz_notice));
        return;
    };
    const lay = computeLayout(ctx.win.width, 0, ctx.win.height, view.channels) orelse return;
    const pos = ctx.bridge.readTrackerPos();
    const t = ctx.theme;

    if (lay.show_instrument) drawInstrument(ctx, pos.last_instrument, lay.top, lay.gauge_w);
    if (lay.show_top) {
        drawOrder(ctx, pos.order_pos, lay.order_x, lay.top);
        common.drawSpectrum(ctx.win, t, lay.spectrum_x, lay.top, lay.spectrum_w, lay.bar_w, ctx.spec_levels, ctx.spec_peaks, ctx.spec_peak_glow);
    }
    drawInfo(ctx, pos, lay.info_row);
    if (lay.show_pattern) drawPattern(ctx, pos, lay);
}

fn drawInstrument(ctx: *viz.DrawContext, inst_index: u8, top: u16, gauge_w: u16) void {
    const view = ctx.view orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    const ins = view.instrument(view.ctx, inst_index);
    const val1_x: u16 = 13;
    const g1_x: u16 = 17;
    const val2_x: u16 = 18 + gauge_w;
    const g2_x: u16 = 22 + gauge_w;

    const title = std.fmt.allocPrint(a, "INSTRUMENT {X:0>2}   FB {d}  {s}", .{
        inst_index,
        ins.feedback,
        if (ins.additive) "ADD" else "FM",
    }) catch return;
    paint.printAt(ctx.win, 1, top, title, t.style(.inst_title));

    const ops = [2]format.OperatorParams{ ins.modulator, ins.carrier };
    for (instrument_labels, 0..) |label, i| {
        const row: u16 = top + 1 + @as(u16, @intCast(i));
        paint.printAt(ctx.win, 1, row, label, t.style(.inst_label));
        for (ops, 0..) |op, oi| {
            const vcol: u16 = if (oi == 0) val1_x else val2_x;
            const gcol: u16 = if (oi == 0) g1_x else g2_x;
            switch (i) {
                0, 1, 2, 3 => {
                    const on = switch (i) {
                        0 => op.tremolo,
                        1 => op.vibrato,
                        2 => op.sustaining,
                        else => op.ksr,
                    };
                    paint.printAt(ctx.win, vcol, row, if (on) "ON " else "OFF", if (on) t.style(.inst_flag_on) else t.style(.inst_flag_off));
                },
                else => {
                    const gauge: Gauge = switch (i) {
                        4 => .{ .value = op.mult, .max = 15 },
                        5 => .{ .value = op.ksl, .max = 3 },
                        6 => .{ .value = 63 - @as(u8, op.level), .max = 63 },
                        7 => .{ .value = op.attack, .max = 15 },
                        8 => .{ .value = op.decay, .max = 15 },
                        9 => .{ .value = op.sustain, .max = 15 },
                        10 => .{ .value = op.release, .max = 15 },
                        else => .{ .value = op.wave, .max = 7 },
                    };
                    const text = std.fmt.allocPrint(a, "{d: >3}", .{gauge.value}) catch return;
                    paint.printAt(ctx.win, vcol, row, text, t.style(.inst_value));
                    drawGauge(ctx.win, t, gcol, row, gauge.value, gauge.max, gauge_w);
                },
            }
        }
    }
}

fn orderLength(view: format.TrackerView) usize {
    return std.mem.indexOfScalar(u8, view.order, order_end) orelse view.order.len;
}

fn drawGauge(win: vaxis.Window, t: Theme, x: u16, row: u16, value: u8, max: u8, width: u16) void {
    const filled = (@as(u16, value) * width + max / 2) / max;
    for (0..width) |i| {
        const on = i < filled;
        win.writeCell(x + @as(u16, @intCast(i)), row, .{
            .char = .{ .grapheme = if (on) "█" else "·", .width = 1 },
            .style = if (on) t.style(.gauge_on) else t.style(.gauge_off),
        });
    }
}

fn drawOrder(ctx: *viz.DrawContext, cur: u8, x: u16, top: u16) void {
    const view = ctx.view orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    paint.printAt(ctx.win, x + 3, top, "ORDER", t.style(.order_title));

    const count = @max(1, orderLength(view));

    const visible: usize = 12;
    var first: usize = 0;
    if (count > visible) {
        const half = visible / 2;
        first = if (cur > half) @min(cur - half, count - visible) else 0;
    }

    for (0..visible) |i| {
        const slot = first + i;
        if (slot >= count) break;
        const row: u16 = top + 1 + @as(u16, @intCast(i));
        const entry = view.order[slot];
        const is_cur = slot == cur;
        const marker = if (is_cur) "▶" else " ";
        const line = if (entry & order_jump_bit != 0)
            std.fmt.allocPrint(a, "{s} {d: >2} J{d:0>2}", .{ marker, slot, entry & ~order_jump_bit }) catch return
        else
            std.fmt.allocPrint(a, "{s} {d: >2}  {d:0>2}", .{ marker, slot, entry }) catch return;
        const style = if (is_cur)
            t.style(.order_cur)
        else if (entry & order_jump_bit != 0)
            t.style(.order_skip)
        else
            t.style(.order_row);
        paint.printAt(ctx.win, x + 1, row, line, style);
    }
}

fn drawInfo(ctx: *viz.DrawContext, pos: format.TrackerPos, row: u16) void {
    const view = ctx.view orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    const win = ctx.win;
    const left_style = t.style(.pat_bar);

    paint.fillRow(win, row, left_style);

    const count = orderLength(view);
    const left = std.fmt.allocPrint(
        a,
        " Line {d:0>2}  Pattern {X:0>2}  Order {d:0>2}/{d:0>2}  Speed {d}",
        .{ pos.row, pos.pattern, pos.order_pos, count, pos.speed },
    ) catch return;
    paint.printAt(win, 0, row, left, left_style);
}

fn drawPattern(ctx: *viz.DrawContext, pos: format.TrackerPos, lay: Layout) void {
    const view = ctx.view orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    const chans: usize = lay.chans;
    const win = ctx.win;

    for (0..chans) |ch| {
        const head = std.fmt.allocPrint(a, "-{d}-", .{ch + 1}) catch return;
        paint.printAt(win, lay.col_x[ch] + (lay.col_w[ch] - 3) / 2, lay.pattern_head_row, head, t.style(.pat_head));
    }

    const rows_total: u16 = view.rows_per_pattern;
    const top = lay.pattern_top;
    const vis: u16 = lay.pattern_end -| top;
    var first: u16 = 0;
    if (rows_total > vis) {
        const cur: u16 = pos.row;
        const half = vis / 2;
        first = if (cur > half) @min(cur - half, rows_total - vis) else 0;
    }

    var r: u16 = first;
    while (r < rows_total and r - first < vis) : (r += 1) {
        const row: u16 = top + (r - first);
        const is_cur = r == pos.row;
        if (is_cur) {
            var x: u16 = 0;
            while (x < win.width) : (x += 1) {
                win.writeCell(x, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = t.style(.pat_cursor_fill),
                });
            }
        }

        const gut = std.fmt.allocPrint(a, "{d:0>2}", .{r}) catch return;
        paint.printAt(win, lay.pat_x + 1, row, gut, t.rowStyle(is_cur, t.style(.pat_gutter)));
        drawSeparator(win, t, lay.pat_x + pat_gutter - 1, row, is_cur);

        for (0..chans) |ch| {
            const cx = lay.col_x[ch];
            drawSeparator(win, t, cx + lay.col_w[ch] - 1, row, is_cur);
            const cell = view.cell(view.ctx, pos.pattern, @intCast(r), @intCast(ch));
            switch (cell.kind) {
                .note => {
                    const text = std.fmt.allocPrint(a, "{s}{d}", .{
                        common.note_names[cell.semitone % common.note_names.len],
                        cell.octave,
                    }) catch return;
                    paint.printAt(win, cx, row, text, t.rowStyle(is_cur, t.style(.note)));
                    drawEffect(win, t, a, cx + 4, row, cell.arg, is_cur);
                },
                .note_off => {
                    paint.printAt(win, cx, row, "OFF", t.rowStyle(is_cur, t.style(.note)));
                    drawEffect(win, t, a, cx + 4, row, cell.arg, is_cur);
                },
                .set_instrument => {
                    const text = std.fmt.allocPrint(a, "I{X:0>2}", .{cell.arg}) catch return;
                    paint.printAt(win, cx, row, text, t.rowStyle(is_cur, t.style(.inst_cell)));
                },
                .effect_only => {
                    paint.printAt(win, cx, row, "···", t.rowStyle(is_cur, t.style(.note_empty)));
                    drawEffect(win, t, a, cx + 4, row, cell.arg, is_cur);
                },
                .empty => {
                    paint.printAt(win, cx, row, "--- ··", t.rowStyle(is_cur, t.style(.note_empty)));
                },
            }
        }
    }
}

fn drawSeparator(win: vaxis.Window, t: Theme, x: u16, row: u16, is_cur: bool) void {
    win.writeCell(x, row, .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = t.patSeparator(is_cur),
    });
}

fn drawEffect(win: vaxis.Window, t: Theme, a: std.mem.Allocator, x: u16, row: u16, arg: u8, is_cur: bool) void {
    if (arg == 0) {
        paint.printAt(win, x, row, "··", t.rowStyle(is_cur, t.style(.note_empty)));
        return;
    }
    const text = std.fmt.allocPrint(a, "{X:0>2}", .{arg}) catch return;
    paint.printAt(win, x, row, text, t.rowStyle(is_cur, t.style(.fx_cell)));
}

pub const visualizer = viz.Visualizer.init(@This());
