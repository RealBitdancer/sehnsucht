//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Bridge = @import("../bridge.zig").Bridge;
const pcm_band_count = @import("../bridge.zig").pcm_band_count;
const pcmBandFreq = @import("../bridge.zig").pcmBandFreq;
const common = @import("common.zig");
const paint = @import("../paint.zig");
const format = @import("../format.zig");
const view = @import("../view.zig");
const viz = @import("../visualizer.zig");

const peak_cells: u16 = 14;
const peak_group_w: u16 = 5 + peak_cells + 1;

pub const name = "stream";
pub const requires = view.ViewCaps{};
pub const optional = view.ViewCaps{ .dump = true, .instruments = true };

fn rackWidth(w: u16, h: u16) u16 {
    return if (w >= 68 and h >= 12) @min(40, w / 2) else 0;
}

fn adpcmCount(ctx: *viz.DrawContext) u16 {
    return if (ctx.views.dump) |dump| @min(dump.adpcm_voices, 2) else 0;
}

fn adpcmRackHeight(ctx: *viz.DrawContext) u16 {
    const count = adpcmCount(ctx);
    if (count == 0) return 0;
    const fm_rows = @min(ctx.voice_count, view.max_opl_voices);
    const tall = count * 4 + 1;
    return if (ctx.win.height >= 5 + tall + fm_rows) tall else count * 2 + 1;
}

fn visibleVoices(ctx: *viz.DrawContext) u16 {
    const count: u16 = @min(ctx.voice_count, view.max_opl_voices);
    if (rackWidth(ctx.win.width, ctx.win.height) != 0) return @min(count, ctx.win.height -| 5 -| adpcmRackHeight(ctx));
    if (ctx.win.height >= 9) return @min(count, (ctx.win.width -| 8) / 4);
    return count;
}

pub fn handleKey(ctx: *viz.DrawContext, key: u21) viz.KeyResult {
    const count: u16 = @min(ctx.voice_count, view.max_opl_voices);
    const page = @max(1, visibleVoices(ctx));
    const last = count -| page;
    switch (key) {
        vaxis.Key.left, vaxis.Key.kp_left => ctx.nav.channel_page -|= page,
        vaxis.Key.right, vaxis.Key.kp_right => ctx.nav.channel_page = @min(ctx.nav.channel_page +| page, last),
        else => return .ignored,
    }
    return .handled;
}

pub fn draw(ctx: *viz.DrawContext) void {
    const w = ctx.win.width;
    const h = ctx.win.height;
    if (w < 44 or h < 5) return;

    drawStrip(ctx, 0, w);
    if (h < 9) {
        const master_h: u16 = if (h >= 6) 1 else 0;
        drawAnalyzer(ctx, 1, w, h - 1 - master_h);
        if (master_h == 1) drawMasterRow(ctx, h - 1, w);
        return;
    }
    const rack_w = rackWidth(w, h);
    if (rack_w != 0) drawVoiceRack(ctx, rack_w, h - 2) else drawCompactRack(ctx);
    const top: u16 = if (rack_w == 0) 2 else 1;
    const analyzer_x: u16 = if (rack_w == 0) 0 else rack_w + 1;
    const pcm_count = if (rack_w == 0) adpcmCount(ctx) else 0;
    const pcm = ctx.bridge.pcm.read();
    for (pcm.voices[0..pcm_count], 0..) |voice, i| {
        drawAdpcm(ctx, voice, @intCast(i), ctx.win.child(.{
            .x_off = 1,
            .y_off = top + @as(u16, @intCast(i)),
            .width = w - 2,
            .height = 1,
        }));
    }
    const spectrum_top = top + pcm_count;
    const analyzer = panel(ctx, analyzer_x, spectrum_top, w - analyzer_x, h - spectrum_top - 1, "PCM SPECTRUM");
    var spectrum = ctx.*;
    spectrum.win = analyzer;
    drawAnalyzer(&spectrum, 0, analyzer.width, analyzer.height);
    drawMasterRow(ctx, h - 1, w);
}

fn panel(ctx: *viz.DrawContext, x: u16, y: u16, width: u16, height: u16, title: []const u8) vaxis.Window {
    const frame = ctx.win.child(.{ .x_off = x, .y_off = y, .width = width, .height = height });
    const body = frame.child(.{ .border = .{ .where = .all, .glyphs = .single_rounded, .style = ctx.theme.style(.spectrum_frame) } });
    const text = ctx.arena.print(" {s} ", .{title}) catch title;
    paint.printFit(frame, 2, 0, text, width -| 4, ctx.theme.style(.spectrum_title));
    return body;
}

fn drawVoiceRack(ctx: *viz.DrawContext, width: u16, height: u16) void {
    const count: u16 = @min(ctx.voice_count, view.max_opl_voices);
    const shown = visibleVoices(ctx);
    const first = @min(ctx.nav.channel_page, count -| shown);
    const chip = if (ctx.views.dump) |dump| switch (dump.chip) {
        .opl2 => "OPL2",
        .opl3 => "OPL3",
        .dual_opl2 => "DUAL OPL2",
        .dual_opl3 => "DUAL OPL3",
    } else "OPL";
    const pcm_count = adpcmCount(ctx);
    const fm_top = adpcmRackHeight(ctx);
    const title = ctx.arena.print("{s}{s} {d:0>2}-{d:0>2}/{d:0>2}", .{ chip, if (pcm_count > 0) " + ADPCM" else "", first + 1, first + shown, count }) catch return;
    const body = panel(ctx, 0, 1, width, height, title);
    if (pcm_count > 0) {
        const pcm = ctx.bridge.pcm.read();
        const voice_height = (fm_top - 1) / pcm_count;
        for (pcm.voices[0..pcm_count], 0..) |voice, i| {
            drawAdpcm(ctx, voice, @intCast(i), body.child(.{
                .y_off = @as(u16, @intCast(i)) * voice_height,
                .height = voice_height,
            }));
        }
        paint.drawRule(body, ctx.theme, fm_top - 1, body.width);
    }
    const dual = ctx.views.dump != null and ctx.views.dump.?.chip == .dual_opl3;
    paint.printFit(body, 0, fm_top, if (dual) "IC:CH NOTE FM LR  LEVEL" else "CH NOTE FM LR  LEVEL", body.width, ctx.theme.style(.info_label));
    const snap = ctx.bridge.chip.read();
    for (0..shown) |i| {
        const channel = first + i;
        const voice = snap.voices[channel];
        const row = fm_top + @as(u16, @intCast(i)) + 1;
        const style = if (voice.keyed) ctx.theme.style(.voice_key_on) else ctx.theme.style(.voice_key_off);
        const note = if (voice.keyed) voiceNote(voice) else "---".*;
        const kind = switch (@as(view.OplChanType, @fromBackingInt(voice.chan_type))) {
            .melody => "2",
            .four_op_hi => "4",
            .four_op_lo => "+",
            .drum => "D",
        };
        const pan = if (ctx.views.dump != null and ctx.views.dump.?.chip == .opl2) "--" else switch (voice.pan) {
            0 => "--",
            1 => "L-",
            2 => "-R",
            3 => "LR",
        };
        const line = if (dual)
            ctx.arena.print("{d}:{d:0>2} {s}  {s} {s}", .{ channel / 18 + 1, channel % 18 + 1, note, kind, pan }) catch return
        else
            ctx.arena.print("{d:0>2} {s}  {s} {s}", .{ channel + 1, note, kind, pan }) catch return;
        paint.printFit(body, 0, row, line, body.width, style);
        const meter_x: u16 = if (dual) 16 else 14;
        _ = common.drawVuMeter(body, ctx.theme, meter_x, row, body.width -| meter_x, ctx.spec_levels[channel], ctx.spec_peaks[channel]);
    }
    if (fm_top + shown + 3 < body.height) {
        const top = fm_top + shown + 2;
        paint.printFit(body, 0, top, "RECENT WRITES", body.width, ctx.theme.style(.info_label));
        var log: [view.write_log_cap]common.LoggedWrite = undefined;
        const writes = common.recentWrites(ctx.bridge, &log);
        const latest = writes[writes.len -| (body.height - top - 1)..];
        for (latest, 0..) |entry, i| {
            const line = ctx.arena.print("{X:0>8} {d}:{X:0>3} = {X:0>2}", .{ entry.index, (entry.write.reg >> 9) + 1, entry.write.reg & 0x1ff, entry.write.val }) catch return;
            paint.printFit(body, 0, top + 1 + @as(u16, @intCast(i)), line, body.width, ctx.theme.style(.fx_cell));
        }
    }
}

fn drawAdpcm(ctx: *viz.DrawContext, voice: view.PcmVoice, index: u16, win: vaxis.Window) void {
    const paused = ctx.bridge.paused.load(.acquire);
    const active = voice.playing and !voice.muted and !paused;
    const status = if (!voice.playing) "IDLE" else if (paused) "PAUS" else if (voice.muted) "MUTE" else if (voice.repeat) "LOOP" else "PLAY";
    const rate = (voice.rate +| 50) / 100;
    const text = ctx.arena.print("ADPCM {d} {s} {d: >2}.{d}k", .{ index + 1, status, rate / 10, rate % 10 }) catch return;
    const style = if (active) ctx.theme.style(.voice_key_on) else ctx.theme.style(.voice_key_off);
    paint.printFit(win, 0, 0, text, @min(win.width, 21), style);
    const level = if (active) @as(f32, @floatFromInt(voice.level)) / 255.0 else 0;
    if (win.height == 1) {
        if (win.width > 22) _ = common.drawVuMeter(win, ctx.theme, 21, 0, win.width - 21, level, 0);
        return;
    }
    const volume = ctx.arena.print("VOL {d: >3}%", .{@as(u16, voice.volume) * 100 / 255}) catch return;
    paint.printFit(win, 22, 0, volume, win.width -| 22, ctx.theme.style(.info_value));
    paint.printAt(win, 0, 1, "LEVEL", ctx.theme.style(.info_label));
    _ = common.drawVuMeter(win, ctx.theme, 6, 1, win.width -| 6, level, 0);
    if (win.height < 4) return;

    const length = voice.end -| voice.start;
    const position: u64 = @min(voice.position -| voice.start, length);
    const memory = voice.present and voice.external and length > 0;
    const percent = if (memory) position * 100 / length else 0;
    const address = if (memory)
        ctx.arena.print("MEM {X:0>6}/{X:0>6} {d: >3}%", .{ voice.position, voice.end, percent }) catch return
    else if (voice.present and voice.external)
        ctx.arena.print("MEM {X:0>6}/{X:0>6}", .{ voice.position, voice.end }) catch return
    else if (voice.present and !voice.external)
        "CPU DATA"
    else
        "NO SAMPLE";
    paint.printFit(win, 0, 2, address, win.width, ctx.theme.style(.info_dim));
    const filled = if (memory) position * win.width / length else 0;
    for (0..win.width) |col| {
        const on = col < filled;
        win.writeCell(@intCast(col), 3, .{
            .char = .{ .grapheme = if (on) "━" else "─", .width = 1 },
            .style = if (on) ctx.theme.style(.progress_on) else ctx.theme.style(.progress_off),
        });
    }
}

fn voiceNote(voice: view.OplVoiceSnap) [3]u8 {
    const pitch = common.pitchFromFnum(voice.fnum, voice.block, &view.standard_fnum_notes, 0) orelse return "---".*;
    return common.noteToken(pitch.semitone, pitch.octave);
}

fn drawCompactRack(ctx: *viz.DrawContext) void {
    const count: u16 = @min(ctx.voice_count, view.max_opl_voices);
    const shown = visibleVoices(ctx);
    const first = @min(ctx.nav.channel_page, count -| shown);
    const snap = ctx.bridge.chip.read();
    const title = ctx.arena.print("OPL {d:0>2}", .{first + 1}) catch return;
    paint.printAt(ctx.win, 1, 1, title, ctx.theme.style(.spectrum_title));
    for (0..shown) |i| {
        const voice = snap.voices[first + i];
        const note = if (voice.keyed) voiceNote(voice) else "---".*;
        paint.printAt(ctx.win, @intCast(8 + i * 4), 1, &note, if (voice.keyed) ctx.theme.style(.voice_key_on) else ctx.theme.style(.voice_key_off));
    }
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
                    const num = a.print("{d}", .{r}) catch return;
                    const style = if (r == hz) t.style(.rate_value) else dim;
                    paint.printAt(win, x, row, num, style);
                    x += @intCast(num.len);
                }
            } else {
                const num = a.print("{d}", .{hz}) catch return;
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
            .char = .{ .grapheme = if (on) common.peak_on else common.peak_off, .width = 1 },
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
    const decimal = std.mem.print(&decimal_buf, "{d}", .{
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

test "stream pages FM voices and shows ADPCM activity without FM writes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 20, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 20,
        .screen = &screen,
    };
    var br = Bridge{};
    var snap = view.ChipSnapshot{};
    snap.voices[0] = .{ .keyed = true, .fnum = 363, .block = 4 };
    br.chip.write(snap);
    var nav: viz.Navigation = .{};
    var spec_levels: [view.max_opl_voices]f32 = @splat(0);
    var spec_peaks: [view.max_opl_voices]f32 = @splat(0);
    var spec_glow: [view.max_opl_voices]f32 = @splat(0);
    var pcm_bands: [pcm_band_count]f32 = @splat(0);
    pcm_bands[0] = 1.0;
    var pcm_peaks: [pcm_band_count]f32 = @splat(0);
    var pcm_glow: [pcm_band_count]f32 = @splat(0);
    var spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = viz.DrawContext{
        .win = win,
        .theme = @import("../theme.zig").default_theme,
        .bridge = &br,
        .track = .{
            .format_name = "VGM",
            .visualizer = "stream",
            .system = "Yamaha YMF262 (OPL3)",
        },
        .views = .{
            .dump = .{
                .write_count = 999,
                .header_tick = 560,
                .clock_ym3812 = 3579545,
            },
        },
        .spec_levels = &spec_levels,
        .spec_peaks = &spec_peaks,
        .spec_peak_glow = &spec_glow,
        .voice_count = 9,
        .nav = &nav,
        .pcm_bands = &pcm_bands,
        .pcm_band_peaks = &pcm_peaks,
        .pcm_band_peak_glow = &pcm_glow,
        .pcm_peak = 0.5,
        .spark = &spark,
        .arena = arena_state.allocator(),
    };
    screen.clear();
    draw(&ctx);

    var buf: [80]u8 = undefined;
    const top = testRowText(&screen, &buf, 0, 80);
    try std.testing.expect(std.mem.find(u8, top, "Song") != null);
    try std.testing.expect(std.mem.find(u8, top, "ONCE") != null);
    try std.testing.expect(std.mem.find(u8, top, "System") != null);
    try std.testing.expect(std.mem.find(u8, top, "PEAK") != null);
    try std.testing.expect(std.mem.find(u8, top, "W 999") == null);
    try std.testing.expect(std.mem.find(u8, top, "Tick 560") == null);

    const bot = testRowText(&screen, &buf, 19, 80);
    try std.testing.expect(std.mem.find(u8, bot, "L ") != null);
    try std.testing.expect(std.mem.find(u8, bot, "R ") != null);
    try std.testing.expect(std.mem.find(u8, bot, "RMS") != null);

    var found_note = false;
    var found_spectrum = false;
    var found_opl = false;
    var found_bar = false;
    var r: u16 = 0;
    while (r < 20) : (r += 1) {
        const line = testRowText(&screen, &buf, r, 80);
        found_note = found_note or std.mem.find(u8, line, "01 C-4") != null;
        found_spectrum = found_spectrum or std.mem.find(u8, line, "PCM SPECTRUM") != null;
        found_opl = found_opl or std.mem.find(u8, line, "OPL2 01-09/09") != null;
        for (42..80) |col| {
            if (std.mem.eql(u8, screen.readCell(@intCast(col), r).?.char.grapheme, "█")) found_bar = true;
        }
    }
    try std.testing.expect(found_note);
    try std.testing.expect(found_spectrum);
    try std.testing.expect(found_opl);
    try std.testing.expect(found_bar);

    ctx.voice_count = 18;
    ctx.views.dump.?.chip = .opl3;
    ctx.win.height = 14;
    snap.voices[17] = .{ .keyed = true, .fnum = 363, .block = 5, .pan = 2 };
    br.chip.write(snap);
    try std.testing.expectEqual(viz.KeyResult.handled, handleKey(&ctx, vaxis.Key.right));
    screen.clear();
    draw(&ctx);
    const last_voice = testRowText(&screen, &buf, 11, 80);
    try std.testing.expect(std.mem.find(u8, last_voice, "18 C-5  2 -R") != null);
    try std.testing.expectEqual(viz.KeyResult.handled, handleKey(&ctx, vaxis.Key.left));
    try std.testing.expectEqual(@as(u16, 0), nav.channel_page);

    ctx.voice_count = 36;
    ctx.views.dump.?.chip = .dual_opl3;
    ctx.views.dump.?.adpcm_voices = 2;
    snap.voices[35] = .{ .keyed = true, .fnum = 363, .block = 5, .pan = 2 };
    br.chip.write(snap);
    br.pcm.write(.{ .voices = .{
        .{ .present = true, .playing = true, .rate = 16000, .level = 200 },
        .{ .present = true, .playing = true, .repeat = true, .rate = 8000, .level = 100 },
    } });
    for (0..9) |_| _ = handleKey(&ctx, vaxis.Key.right);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 11, 80), "2:18 C-5  2 -R") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "ADPCM 1 PLAY 16.0k") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "ADPCM 2 LOOP  8.0k") != null);

    ctx.win.height = 20;
    ctx.voice_count = 9;
    ctx.views.dump.?.chip = .opl2;
    ctx.views.dump.?.adpcm_voices = 1;
    br.chip.write(.{});
    var pcm: view.PcmState = .{};
    pcm.voices[0] = .{
        .present = true,
        .playing = true,
        .external = true,
        .rate = 15999,
        .volume = 255,
        .level = 200,
        .start = 0x1000,
        .end = 0x3000,
        .position = 0x2000,
    };
    br.pcm.write(pcm);
    screen.clear();
    draw(&ctx);
    try std.testing.expectEqual(@as(u32, 0), br.write_log_i.load(.acquire));
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "ADPCM 1 PLAY 16.0k") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "VOL 100%") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "MEM 002000/003000  50%") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 8, 40), "01 ---") != null);
    try std.testing.expect(!std.meta.eql(ctx.theme.style(.meter_empty), screen.readCell(7, 3).?.style));
    try std.testing.expectEqualStrings("━", screen.readCell(19, 5).?.char.grapheme);
    try std.testing.expectEqualStrings("─", screen.readCell(20, 5).?.char.grapheme);

    pcm.voices[0].position = 0x2800;
    br.pcm.write(pcm);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "75%") != null);
    try std.testing.expectEqualStrings("━", screen.readCell(28, 5).?.char.grapheme);
    try std.testing.expectEqualStrings("─", screen.readCell(29, 5).?.char.grapheme);

    br.paused.store(true, .release);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "PAUS") != null);
    try std.testing.expectEqualDeep(ctx.theme.style(.meter_empty), screen.readCell(7, 3).?.style);
    br.paused.store(false, .release);

    pcm.voices[0].end = 0x0800;
    br.pcm.write(pcm);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "MEM 002800/000800") != null);
    try std.testing.expect(std.mem.findScalar(u8, testRowText(&screen, &buf, 4, 40), '%') == null);

    pcm.voices[0].external = false;
    pcm.voices[0].muted = true;
    br.pcm.write(pcm);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "MUTE") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "CPU DATA") != null);
    try std.testing.expectEqualDeep(ctx.theme.style(.meter_empty), screen.readCell(7, 3).?.style);
    try std.testing.expectEqualStrings("─", screen.readCell(1, 5).?.char.grapheme);

    br.resetVisualState();
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 40), "IDLE  0.0k") != null);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 4, 40), "NO SAMPLE") != null);
    try std.testing.expectEqualDeep(ctx.theme.style(.meter_empty), screen.readCell(7, 3).?.style);

    ctx.win.width = 60;
    br.pcm.write(pcm);
    screen.clear();
    draw(&ctx);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 2, 60), "ADPCM 1 MUTE 16.0k") != null);
}

fn testRowText(screen: *vaxis.Screen, buf: []u8, row: u16, width: u16) []const u8 {
    for (0..width) |c| {
        const cell = screen.readCell(@intCast(c), row).?;
        const g = cell.char.grapheme;
        buf[c] = if (g.len == 1) g[0] else '?';
    }
    return buf[0..width];
}

test "taller panes never show fewer FM voices beside two ADPCM voices" {
    var ctx: viz.DrawContext = undefined;
    ctx.views = .{ .dump = .{ .adpcm_voices = 2 } };
    for ([_]u8{ 9, 18, 36 }) |voice_count| {
        ctx.voice_count = voice_count;
        var previous: u16 = 0;
        var height: u16 = 12;
        while (height <= 80) : (height += 1) {
            ctx.win = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = height, .screen = undefined };
            const voices = visibleVoices(&ctx);
            try std.testing.expect(voices >= previous);
            previous = voices;
        }
        try std.testing.expectEqual(@as(u16, voice_count), previous);
    }
}

test "register history drops slots the writer may be overwriting" {
    var br = Bridge{};
    var log: [view.write_log_cap]common.LoggedWrite = undefined;
    try std.testing.expectEqual(@as(usize, 0), common.recentWrites(&br, &log).len);
    for (0..5) |i| {
        br.write_log[i].store(@bitCast(view.RegWrite{ .reg = @intCast(0xa0 + i), .val = 1 }), .release);
    }
    br.write_log_i.store(5, .release);
    const few = common.recentWrites(&br, &log);
    try std.testing.expectEqual(@as(usize, 5), few.len);
    try std.testing.expectEqual(@as(u16, 0xa4), few[4].write.reg);
    br.write_log_i.store(std.math.maxInt(u32), .release);
    const wrapped = common.recentWrites(&br, &log);
    try std.testing.expectEqual(@as(usize, view.write_log_cap - 1), wrapped.len);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, wrapped[wrapped.len - 1].index);
}
