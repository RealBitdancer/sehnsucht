//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const pcm_band_count = @import("../bridge.zig").pcm_band_count;
const pcmBandFreq = @import("../bridge.zig").pcmBandFreq;
const common = @import("common.zig");
const paint = @import("../paint.zig");
const format = @import("../format.zig");
const viz = @import("../visualizer.zig");

const peak_cells: u16 = 14;
const peak_group_w: u16 = 5 + peak_cells + 1;

pub const name = "stream";

pub fn draw(ctx: *viz.DrawContext) void {
    const w = ctx.win.width;
    const h = ctx.win.height;
    if (w < 44 or h < 5) return;

    drawStrip(ctx, 0, w);
    const master_h: u16 = if (h >= 6) 1 else 0;
    drawAnalyzer(ctx, 1, w, h - 1 - master_h);
    if (master_h == 1) drawMasterRow(ctx, h - 1, w);
}

fn drawStrip(ctx: *viz.DrawContext, row: u16, w: u16) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const win = ctx.win;
    paint.fillRow(win, row, t.style(.info_value));

    const dim = t.style(.info_dim);
    const label = t.style(.info_label);
    const value = t.style(.info_value);
    const left_end = w -| peak_group_w -| 2;

    var x: u16 = 1;
    paint.printAt(win, x, row, "Song ", label);
    x += 5;
    const loop_txt = if (ctx.track.loop) "◆ LOOP" else "○ ONCE";
    const loop_style = if (ctx.track.loop) t.style(.loop_badge_on) else t.style(.loop_badge_off);
    paint.printAt(win, x, row, loop_txt, loop_style);
    x += 8;

    if (ctx.tick_rate_hz) |hz| {
        var rate_w: u16 = 5 + 3;
        if (ctx.rate_adjustable) {
            for (format.tick_rates, 0..) |r, i| {
                if (i > 0) rate_w += 1;
                rate_w += @intCast(std.fmt.count("{d}", .{r}));
            }
        } else {
            rate_w += @intCast(std.fmt.count("{d}", .{hz}));
        }
        if (x + rate_w <= left_end) {
            paint.printAt(win, x, row, "Rate ", label);
            x += 5;
            if (ctx.rate_adjustable) {
                for (format.tick_rates, 0..) |r, i| {
                    if (i > 0) {
                        paint.printAt(win, x, row, "·", dim);
                        x += 1;
                    }
                    const num = std.fmt.allocPrint(a, "{d}", .{r}) catch return;
                    const style = if (r == hz) t.style(.rate_value) else dim;
                    paint.printAt(win, x, row, num, style);
                    x += @intCast(num.len);
                }
            } else {
                const num = std.fmt.allocPrint(a, "{d}", .{hz}) catch return;
                paint.printAt(win, x, row, num, t.style(.rate_value));
                x += @intCast(num.len);
            }
            paint.printAt(win, x, row, " Hz", label);
            x += 5;
        }
    }

    if (ctx.track.system) |sys| {
        if (sys.len > 0 and x + 10 < left_end) {
            paint.printAt(win, x, row, "System ", label);
            x += 7;
            paint.printFit(win, x, row, sys, left_end -| x, value);
        }
    }

    drawPeakMeter(ctx, row, w -| peak_group_w -| 1);
}

fn drawPeakMeter(ctx: *viz.DrawContext, row: u16, x: u16) void {
    const t = ctx.theme;
    const win = ctx.win;
    paint.printAt(win, x, row, "PEAK ", t.style(.peak_label));
    const fill: u16 = @intFromFloat(ctx.pcm_peak * @as(f32, @floatFromInt(peak_cells)));
    for (0..peak_cells) |i| {
        const on = i < fill;
        win.writeCell(x + 5 + @as(u16, @intCast(i)), row, .{
            .char = .{ .grapheme = if (on) "▮" else "▯", .width = 1 },
            .style = t.infoMeter(
                @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(peak_cells - 1)),
                on,
            ),
        });
    }
}

/// Columns spread the bands evenly, so a narrow pane samples every nth band
/// rather than dropping the top of the spectrum.
fn bandForColumn(column: usize, columns: usize) usize {
    if (columns < 2) return 0;
    return column * (pcm_band_count - 1) / (columns - 1);
}

fn drawAnalyzer(ctx: *viz.DrawContext, top: u16, w: u16, h: u16) void {
    if (h < 4 or w < 8) return;
    const t = ctx.theme;
    const win = ctx.win;

    const bar_rows = h - 1;
    const base_row = top + bar_rows;

    const cell_w: u16 = @max(2, @as(u16, @intCast((w + pcm_band_count / 2) / pcm_band_count)));
    const n_show: usize = @min(pcm_band_count, @as(usize, w / cell_w));
    if (n_show == 0) return;
    const used: u16 = @intCast(n_show * cell_w);
    const x0 = (w - used) / 2;

    for (0..n_show) |i| {
        const band_i = bandForColumn(i, n_show);
        const bar_x: u16 = x0 + @as(u16, @intCast(i)) * cell_w;
        paint.drawMeterColumn(win, t, bar_x, top, bar_rows, cell_w - 1, .{
            .level = ctx.pcm_bands[band_i],
            .peak = ctx.pcm_band_peaks[band_i],
            .glow = ctx.pcm_band_peak_glow[band_i],
        });
    }

    var bx: u16 = 0;
    while (bx < w) : (bx += 1) {
        win.writeCell(bx, base_row, .{
            .char = .{ .grapheme = "▔", .width = 1 },
            .style = t.style(.analyzer_base),
        });
    }
    drawFreqLabels(ctx, base_row, x0, cell_w, n_show);
}

const label_marks = [_]u32{ 100, 250, 500, 1000, 2000, 5000, 10000, 20000 };

fn drawFreqLabels(ctx: *viz.DrawContext, row: u16, x0: u16, cell_w: u16, n_show: usize) void {
    const t = ctx.theme;
    const win = ctx.win;
    const sr = ctx.bridge.sample_rate;
    const f_first = pcmBandFreq(sr, 0);
    const f_last = pcmBandFreq(sr, pcm_band_count - 1);

    var last_end: u16 = 0;
    for (label_marks) |mark| {
        const fm: f32 = @floatFromInt(mark);
        if (fm < f_first or fm > f_last) continue;

        var best: usize = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (0..n_show) |i| {
            const d = @abs(@log(pcmBandFreq(sr, bandForColumn(i, n_show))) - @log(fm));
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }

        const text = supFreq(ctx.arena, mark) orelse continue;
        const text_w = win.gwidth(text);
        const solid_center = x0 + @as(u16, @intCast(best)) * cell_w + (cell_w - 1) / 2;
        var x = solid_center -| text_w / 2;
        if (x + text_w > win.width) x = win.width -| text_w;
        if (x < last_end + 2 and last_end > 0) continue;
        paint.printAt(win, x, row, text, t.style(.freq_label));
        last_end = x + text_w;
    }
}

fn supFreq(a: std.mem.Allocator, hz: u32) ?[]const u8 {
    const kilo = hz >= 1000 and hz % 1000 == 0;
    var decimal_buf: [10]u8 = undefined;
    const decimal = std.fmt.bufPrint(&decimal_buf, "{d}", .{
        if (kilo) hz / 1000 else hz,
    }) catch return null;

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (decimal) |c| w.writeAll(common.sup_digits[c - '0']) catch return null;
    if (kilo) w.writeAll(common.sup_k) catch return null;
    return a.dupe(u8, w.buffered()) catch null;
}

fn drawMasterRow(ctx: *viz.DrawContext, row: u16, w: u16) void {
    const t = ctx.theme;
    const win = ctx.win;
    const meter_w: u16 = @min(20, (w -| 18) / 4);
    if (meter_w < 3) return;

    var col: u16 = 1;
    paint.printAt(win, col, row, "L ", t.style(.master_label));
    col += 2;
    col = common.drawVuMeter(win, t, col, row, meter_w, ctx.vu_l, ctx.vu_peak_l);
    paint.printAt(win, col, row, "  R ", t.style(.master_label));
    col += 4;
    col = common.drawVuMeter(win, t, col, row, meter_w, ctx.vu_r, ctx.vu_peak_r);
    paint.printAt(win, col, row, "  RMS ", t.style(.master_label));
    col += 6;
    drawSparkline(ctx, col, row, w -| 1 -| col);
}

fn drawSparkline(ctx: *viz.DrawContext, x: u16, row: u16, width: u16) void {
    if (width == 0) return;
    const t = ctx.theme;
    const win = ctx.win;
    var max_v: f32 = 0.0001;
    for (ctx.spark[0..ctx.spark_len]) |v| max_v = @max(max_v, v);

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        const back: usize = width - 1 - i;
        if (back < ctx.spark_len) {
            const idx = (ctx.spark_head + viz.spark_retention - 1 - back) % viz.spark_retention;
            const frac = std.math.clamp(ctx.spark[idx] / max_v, 0.0, 1.0);
            const gi: usize = @intFromFloat(@round(frac * @as(f32, @floatFromInt(common.spark_glyphs.len - 1))));
            win.writeCell(x + i, row, .{
                .char = .{ .grapheme = common.spark_glyphs[gi], .width = 1 },
                .style = t.meterBar(frac, false),
            });
        } else {
            win.writeCell(x + i, row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = t.style(.shell_fill),
            });
        }
    }
}

pub const visualizer = viz.Visualizer.init(@This());

// --- tests -------------------------------------------------------------------

test "supFreq renders axis labels in superscript, abbreviating exact kilohertz" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("¹⁰⁰", supFreq(arena, 100).?);
    try std.testing.expectEqualStrings("²⁵⁰", supFreq(arena, 250).?);
    try std.testing.expectEqualStrings("⁵⁰⁰", supFreq(arena, 500).?);
    try std.testing.expectEqualStrings("¹ᵏ", supFreq(arena, 1000).?);
    try std.testing.expectEqualStrings("²ᵏ", supFreq(arena, 2000).?);
    try std.testing.expectEqualStrings("²⁰ᵏ", supFreq(arena, 20000).?);
    try std.testing.expectEqualStrings("⁰", supFreq(arena, 0).?);
    try std.testing.expectEqualStrings("¹⁵⁰⁰", supFreq(arena, 1500).?);
}

test "supFreq covers every label the frequency axis can draw" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (label_marks) |mark| {
        const text = supFreq(arena, mark) orelse return error.TestUnexpectedResult;
        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
}
