//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const common = @import("common.zig");
const paint = @import("../paint.zig");
const view = @import("../view.zig");
const Theme = @import("../theme.zig").Theme;
const viz = @import("../visualizer.zig");

const chan_min_w: u16 = 8;
const compact_spectrum_w: u16 = "SPECTRUM".len;
const two_op_instrument_w: u16 = 26;
const order_text_w: u16 = common.order_w - 1;
const per_channel_order_w: u16 = "9:7FFF-64i".len + 1;
const region_rows: u16 = 12;

pub const name = "tracker";
pub const requires = view.ViewCaps{ .pattern = true };
pub const optional = view.ViewCaps{ .order = true, .instruments = true };

const Layout = struct {
    compact: bool,
    show_top: bool,
    show_instrument: bool,
    show_order: bool,
    show_spectrum: bool,
    show_extra: bool,
    extra: viz.TrackerFocus,
    extra_x: u16,
    gauge_w: u16,
    bar_w: u16,
    spectrum_voices: u16,
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
    gutter: u16,
    chans: u16,
    chan0: u16,
    col_x: [view.max_pattern_channels]u16,
    col_w: [view.max_pattern_channels]u16,
};

fn roleOf(pv: view.PatternView, chan: u16) view.FourOpRole {
    if (pv.channelInfo) |info| return info(pv.ctx, chan).four_op_role;
    return .none;
}

fn channelCount(pv: view.PatternView) u16 {
    return @min(pv.channels, view.max_pattern_channels);
}

fn splitsPair(pv: view.PatternView, start: u16, count: u16) bool {
    return roleOf(pv, start) == .lo or roleOf(pv, start + count - 1) == .hi;
}

fn visiblePage(pv: view.PatternView, page: u16, count: u16) u16 {
    const n = channelCount(pv);
    if (n == 0 or count == 0) return 0;
    const last = n - @min(count, n);
    const start = @min(page, last);
    if (count < 2 or start == 0 or start == last) return start;
    var dist: u16 = 0;
    while (dist <= count / 2) : (dist += 1) {
        if (dist <= start and !splitsPair(pv, start - dist, count)) return start - dist;
        if (start + dist <= last and !splitsPair(pv, start + dist, count)) return start + dist;
    }
    return start;
}

fn nextPage(pv: view.PatternView, page: u16, count: u16, max_start: u16, forward: bool) u16 {
    var next = @min(page, max_start);
    const shown = visiblePage(pv, next, count);
    while (if (forward) next < max_start else next > 0) {
        next = if (forward) next + 1 else next - 1;
        if (visiblePage(pv, next, count) != shown) break;
    }
    return next;
}

fn gutterWidth(rows: u16) u16 {
    return if (rows > 255) 5 else 4;
}

fn cellSpan(pv: view.PatternView) u16 {
    const t = pv.cell_template;
    var x: u16 = 0;
    var end: u16 = 0;
    for (pv.columns) |id| {
        const field: u16, const step: u16 = switch (id) {
            .note => .{ t.note_w, @as(u16, t.note_w) + 1 },
            .instrument => .{ t.inst_w, @as(u16, t.inst_w) + 1 },
            .volume => .{ t.vol_w, @as(u16, t.vol_w) + 1 },
            .effect, .effect2 => .{ @as(u16, t.fx_w) + @intFromBool(pv.effect_style == .nibble), @as(u16, t.fx_w) + 1 },
            .extra => .{ t.extra_w, t.extra_w },
        };
        end = @max(end, x +| field);
        x +|= step;
    }
    return end;
}

fn stripWidth(label: []const u8, len: u16) u16 {
    return @intCast(std.fmt.count("{s} {d}/{d} ", .{ label, len, len }));
}

const Extra = struct { kind: viz.TrackerFocus, len: u16 };

fn computeLayout(
    w: u16,
    h: u16,
    pv: view.PatternView,
    voice_count: u8,
    page: u16,
    order: ?view.OrderView,
    has_inst: bool,
    extra: ?Extra,
) Layout {
    const has_order = order != null;
    const all_voices: u16 = @max(9, @min(voice_count, view.max_opl_voices));
    const bar_w = @min(common.spectrumBarWidth(w), @max(1, ((w / 2) -| 5 -| all_voices) / all_voices));
    const full_spectrum_w = common.spectrumPanelWidth(bar_w, all_voices);
    const beside: u16 = if (has_inst) two_op_instrument_w else if (extra != null) common.order_w else 0;
    const order_column_w: u16 = if (order) |ov| (if (perChannelOrder(ov)) per_channel_order_w else common.order_w) else 0;
    const compact = h < 20 or full_spectrum_w + beside + order_column_w > w;
    const show_top = true;
    const top_h: u16 = if (compact) 1 else common.top_rows + 1;
    const order_w: u16 = if (!compact) order_column_w else if (order) |ov| stripWidth("ORDER", ov.len) else 0;
    const inst_min: u16 = if (has_inst and !compact) two_op_instrument_w else 0;
    const spectrum_voices = all_voices;
    const spectrum_w = if (compact) @min(w, compact_spectrum_w) else full_spectrum_w;
    const spectrum_x = w -| spectrum_w;
    const show_spectrum = w >= 44;
    const show_order = has_order and spectrum_x >= order_w;
    const order_x: u16 = if (show_order) spectrum_x -| order_w else spectrum_x;
    const extra_w: u16 = if (extra) |ex| (if (compact) stripWidth(extraLabel(ex.kind), ex.len) else common.order_w) else 0;
    const show_extra = extra_w != 0 and order_x >= extra_w + inst_min;
    const extra_x: u16 = if (show_extra) order_x - extra_w else order_x;
    const show_instrument = has_inst;
    const gauge_w = std.math.clamp((extra_x -| 23) / 2, 1, 20);
    const gutter = gutterWidth(pv.rows_per_pattern);

    const info_row: u16 = top_h;
    const pattern_head_row = info_row + 1;
    const pattern_top = pattern_head_row + 1;
    const pattern_end = h;
    const show_pattern = pattern_end > pattern_top;

    var col_x: [view.max_pattern_channels]u16 = @splat(0);
    var col_w: [view.max_pattern_channels]u16 = @splat(0);
    var chans: u16 = 0;
    var chan0: u16 = 0;
    const n_total = channelCount(pv);
    const avail = w -| gutter;
    const fit_w = @max(chan_min_w, pv.cell_template.width, cellSpan(pv) +| 1);
    if (n_total > 0 and avail >= fit_w) {
        if (avail / n_total >= fit_w) {
            chans = n_total;
            chan0 = 0;
        } else {
            chans = @min(n_total, @max(1, avail / fit_w));
            chan0 = visiblePage(pv, page, chans);
        }
        common.fillChannelCols(&col_x, &col_w, w, gutter, chans);
    }

    return .{
        .compact = compact,
        .show_top = show_top,
        .show_instrument = show_instrument,
        .show_order = show_order,
        .show_spectrum = show_spectrum,
        .show_extra = show_extra,
        .extra = if (extra) |ex| ex.kind else .macros,
        .extra_x = extra_x,
        .gauge_w = gauge_w,
        .bar_w = bar_w,
        .spectrum_voices = spectrum_voices,
        .spectrum_w = spectrum_w,
        .spectrum_x = spectrum_x,
        .order_x = order_x,
        .top = 0,
        .info_row = info_row,
        .pattern_head_row = pattern_head_row,
        .pattern_top = pattern_top,
        .pattern_end = pattern_end,
        .show_pattern = show_pattern,
        .pat_x = 0,
        .gutter = gutter,
        .chans = chans,
        .chan0 = chan0,
        .col_x = col_x,
        .col_w = col_w,
    };
}

fn extraRegion(ctx: *viz.DrawContext) ?viz.TrackerFocus {
    const regions = presentRegions(ctx);
    const focus = ctx.nav.tracker_focus;
    if (focus == .macros or focus == .live or focus == .riffs) {
        for (regions.items[0..regions.n]) |r| {
            if (r == focus) return focus;
        }
    }
    for (regions.items[0..regions.n]) |r| {
        if (r == .macros or r == .live or r == .riffs) return r;
    }
    return null;
}

fn paneLayout(ctx: *viz.DrawContext, pv: view.PatternView) Layout {
    const extra: ?Extra = if (extraRegion(ctx)) |kind| .{ .kind = kind, .len = if (kind == .macros) bankMacroRows(ctx) else extraLen(ctx, kind) } else null;
    return computeLayout(
        ctx.win.width,
        ctx.win.height,
        pv,
        ctx.voice_count,
        ctx.nav.channel_page,
        ctx.views.order,
        ctx.views.instruments != null,
        extra,
    );
}

const RegionList = struct {
    items: [7]viz.TrackerFocus = undefined,
    n: usize = 0,
};

fn presentRegions(ctx: *viz.DrawContext) RegionList {
    const live = ctx.bridge.channels.read().channels != 0;
    const macros = bankMacroRows(ctx) != 0;
    const riffs = if (ctx.views.pattern) |pv| pv.riff_count > 0 else false;
    var list = RegionList{};
    list.items[list.n] = .pattern;
    list.n += 1;
    if (ctx.views.instruments != null) {
        list.items[list.n] = .instrument;
        list.n += 1;
    }
    if (ctx.views.order != null) {
        list.items[list.n] = .order;
        list.n += 1;
    }
    if (macros) {
        list.items[list.n] = .macros;
        list.n += 1;
    }
    if (live) {
        list.items[list.n] = .live;
        list.n += 1;
    }
    list.items[list.n] = .spectrum;
    list.n += 1;
    if (riffs) {
        list.items[list.n] = .riffs;
        list.n += 1;
    }
    return list;
}

pub fn handleKey(ctx: *viz.DrawContext, key: u21) viz.KeyResult {
    const pv = ctx.views.pattern orelse return .ignored;
    const lay = paneLayout(ctx, pv);
    const count = @max(lay.chans, 1);
    const max_start = channelCount(pv) -| count;
    switch (key) {
        vaxis.Key.left, vaxis.Key.kp_left => {
            ctx.nav.channel_page = nextPage(pv, ctx.nav.channel_page, count, max_start, false);
            return .handled;
        },
        vaxis.Key.right, vaxis.Key.kp_right => {
            ctx.nav.channel_page = nextPage(pv, ctx.nav.channel_page, count, max_start, true);
            return .handled;
        },
        '`' => {
            const regions = presentRegions(ctx);
            if (regions.n == 0) return .handled;
            var idx: usize = 0;
            for (regions.items[0..regions.n], 0..) |r, i| {
                if (r == ctx.nav.tracker_focus) idx = i;
            }
            ctx.nav.tracker_focus = regions.items[(idx + 1) % regions.n];
            return .handled;
        },
        else => {},
    }
    const dir: i32 = switch (key) {
        vaxis.Key.up, vaxis.Key.kp_up => -1,
        vaxis.Key.down, vaxis.Key.kp_down => 1,
        vaxis.Key.page_up, vaxis.Key.kp_page_up => -8,
        vaxis.Key.page_down, vaxis.Key.kp_page_down => 8,
        vaxis.Key.home, vaxis.Key.kp_home => std.math.minInt(i32),
        vaxis.Key.end, vaxis.Key.kp_end => std.math.maxInt(i32),
        else => return .ignored,
    };
    scrollFocus(ctx, dir, lay);
    return .handled;
}

fn followOrigin(cur: u16, vis: u16, total: u16) u16 {
    if (total <= vis) return 0;
    const half = vis / 2;
    return if (cur > half) @min(cur -| half, total - vis) else 0;
}

fn bankMacroRows(ctx: *viz.DrawContext) u16 {
    const bank = ctx.views.instruments orelse return 0;
    var rows: u16 = 0;
    for (0..bank.count) |i| rows = @max(rows, bank.get(bank.ctx, @intCast(i)).macroRows());
    return rows;
}

fn macroLen(ctx: *viz.DrawContext) u16 {
    const bank = ctx.views.instruments orelse return 1;
    if (bank.count == 0) return 1;
    const idx = @min(ctx.nav.instrument_sel, bank.count -| 1);
    const ins = bank.get(bank.ctx, idx);
    return @max(ins.macroRows(), 1);
}

fn scrollFocus(ctx: *viz.DrawContext, dir: i32, lay: Layout) void {
    const pv = ctx.views.pattern orelse return;
    const ph = ctx.bridge.playhead.read();
    switch (ctx.nav.tracker_focus) {
        .pattern => {
            const vis = lay.pattern_end -| lay.pattern_top;
            const count = @max(pv.rows_per_pattern, 1);
            ctx.nav.pattern_scroll = scrollOrigin(ctx.nav.pattern_scroll, followOrigin(ph.row, vis, count), count -| vis, dir);
        },
        .instrument => {
            const count = if (ctx.views.instruments) |b| b.count else 1;
            applyScroll(&ctx.nav.instrument_sel, count, dir);
            ctx.nav.instrument_sel_user = true;
        },
        .order => {
            const ov = ctx.views.order orelse return;
            const count = @max(ov.len, 1);
            ctx.nav.order_scroll = scrollOrigin(ctx.nav.order_scroll, @min(ph.order, count - 1), count - 1, dir);
        },
        .macros => applyScroll(&ctx.nav.macro_scroll, macroLen(ctx), dir),
        .riffs => applyScroll(&ctx.nav.riff_scroll, @max(pv.riff_count, 1), dir),
        .live => {
            const bank = ctx.bridge.channels.read();
            const n = @min(bank.channels, bank.slots.len);
            const last = if (lay.compact) n -| 1 else n -| region_rows;
            ctx.nav.live_scroll = scrollOrigin(ctx.nav.live_scroll, 0, last, dir) orelse 0;
        },
        .spectrum => {},
    }
}

fn scrollOrigin(current: ?u16, follow: u16, max: u16, dir: i32) ?u16 {
    if (dir == std.math.minInt(i32)) return null;
    if (dir == std.math.maxInt(i32)) return max;
    const from: i32 = if (current) |at| @min(at, max) else follow;
    return @intCast(std.math.clamp(from + dir, 0, max));
}

fn perChannelOrder(ov: view.OrderView) bool {
    return ov.channelRef != null and ov.kind != .shared_index;
}

fn applyScroll(slot: *u16, count: u16, dir: i32) void {
    if (dir == std.math.minInt(i32)) {
        slot.* = 0;
        return;
    }
    if (dir == std.math.maxInt(i32)) {
        slot.* = count -| 1;
        return;
    }
    const next: i32 = @as(i32, @min(slot.*, count -| 1)) + dir;
    if (next < 0) slot.* = 0 else slot.* = @intCast(@min(next, @as(i32, count -| 1)));
}

pub fn draw(ctx: *viz.DrawContext) void {
    const pv = ctx.views.pattern orelse {
        paint.printAt(ctx.win, 1, 0, "tracker visualizer requires a pattern view", ctx.theme.style(.viz_notice));
        return;
    };
    const w = ctx.win.width;
    const h = ctx.win.height;
    if (w == 0 or h == 0) return;

    const playhead = ctx.bridge.playhead.read();
    if (!ctx.nav.instrument_sel_user) ctx.nav.instrument_sel = playhead.last_instrument;
    if (ctx.views.instruments) |bank| {
        if (bank.count != 0) ctx.nav.instrument_sel = @min(ctx.nav.instrument_sel, bank.count - 1);
    }

    const lay = paneLayout(ctx, pv);

    if (lay.show_instrument) drawInstrumentRegion(ctx, playhead, lay);
    if (lay.show_extra) drawExtraRegion(ctx, playhead, lay);
    if (lay.show_order) drawOrderRegion(ctx, playhead, lay);
    if (lay.show_spectrum) {
        if (lay.compact) {
            paint.printFit(ctx.win, lay.spectrum_x, lay.top, "SPECTRUM", lay.spectrum_w, ctx.theme.style(.spectrum_title));
        } else {
            common.drawSpectrum(
                ctx.win,
                ctx.theme,
                lay.spectrum_x,
                lay.top,
                lay.spectrum_w,
                lay.bar_w,
                ctx.spec_levels[0..lay.spectrum_voices],
                ctx.spec_peaks[0..lay.spectrum_voices],
                ctx.spec_peak_glow[0..lay.spectrum_voices],
                .{},
            );
        }
    }
    drawInfo(ctx, playhead, pv, lay);
    if (lay.show_pattern) drawPattern(ctx, playhead, pv, lay);
    if (pv.mixed_pcm and lay.show_pattern) {
        const row = lay.pattern_end -| 1;
        paint.printAt(ctx.win, 1, row, "PCM", ctx.theme.style(.ch_pcm));
    }
}

fn drawInfo(ctx: *viz.DrawContext, ph: view.Playhead, pv: view.PatternView, lay: Layout) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const win = ctx.win;
    const style = t.style(.pat_bar);
    paint.fillRow(win, lay.info_row, style);
    var buf: [192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(" ") catch return;
    if (ph.flags.has_row) w.print("Line {s}  ", .{rowLabel(a, ph.row, pv.rows_per_pattern) orelse return}) catch return;
    if (ph.flags.has_pattern) w.print("Pattern {d:0>2}/{d:0>2}  ", .{ ph.pattern, pv.num_patterns }) catch return;
    if (ph.flags.has_order) {
        const n = if (ctx.views.order) |ov| ov.len else pv.num_patterns;
        w.print("Order {d:0>2}/{d:0>2}  ", .{ ph.order, n }) catch return;
    }
    if (ph.flags.has_speed) w.print("Speed {d}  ", .{ph.speed}) catch return;
    if (pv.rate_text.len != 0) w.print("Rate {s}  ", .{pv.rate_text}) catch return;
    if (ph.flags.has_tempo) w.print("Tempo {d}  ", .{ph.tempo}) catch return;
    if (ph.flags.has_bpm) w.print("BPM {d}  ", .{ph.bpm}) catch return;
    if (ph.flags.has_pit) w.print("PIT {d}  ", .{ph.pit}) catch return;
    if (ph.flags.has_macro_speedup) w.print("Macro {d}  ", .{ph.macro_speedup}) catch return;
    if (ctx.views.instruments != null) w.print("Inst {X:0>2}  ", .{ph.last_instrument}) catch return;
    const range: []const u8 = if (lay.chans != 0 and lay.chans < channelCount(pv))
        a.print("CH {d:0>2}-{d:0>2} of {d} ", .{ lay.chan0 + 1, lay.chan0 + lay.chans, channelCount(pv) }) catch return
    else
        "";
    const range_x = win.width -| paint.textWidth(win, range);
    const text = a.dupe(u8, w.buffered()) catch return;
    paint.printFit(win, 0, lay.info_row, text, range_x, style);
    paint.printAt(win, range_x, lay.info_row, range, style);
}

fn rowLabel(a: std.mem.Allocator, row: u16, rows_per_pattern: u16) ?[]const u8 {
    if (rows_per_pattern > 255) return a.print("{X:0>3}", .{row}) catch null;
    if (rows_per_pattern > 99) return a.print("{X:0>2}", .{row}) catch null;
    return a.print("{d:0>2}", .{row}) catch null;
}

fn drawInstrumentRegion(ctx: *viz.DrawContext, ph: view.Playhead, lay: Layout) void {
    _ = ph;
    const bank = ctx.views.instruments orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    const idx = ctx.nav.instrument_sel;
    const ins = if (bank.count != 0) bank.get(bank.ctx, idx) else view.InstrumentInfo{};
    const inst_right = if (lay.show_extra) lay.extra_x else lay.order_x;
    if (lay.compact) {
        const head = a.print("I{X:0>2}/{d}", .{ idx, bank.count }) catch return;
        const strip = common.instrumentTitle(a, head, ins) orelse return;
        const fit = inst_right -| 1;
        paint.printFit(ctx.win, 0, lay.top, if (paint.textWidth(ctx.win, head) < fit) strip else head, fit, t.style(.inst_title));
        return;
    }
    const head = a.print("INSTRUMENT {X:0>2}", .{idx}) catch return;
    const title = common.instrumentTitle(a, head, ins) orelse return;
    paint.printFit(ctx.win, 0, lay.top, title, inst_right, t.style(.inst_title));
    if (!lay.show_extra) {
        if (extraRegion(ctx)) |ex| {
            if (ctx.nav.tracker_focus == ex) {
                drawExtraBody(ctx, 0, lay.top + 1, inst_right, region_rows, ex);
                return;
            }
            if (extraStrip(ctx, ex)) |strip| paint.printFit(ctx.win, 0, lay.top + 1, strip, @min(inst_right, common.gauge_value_x) -| 1, t.style(.order_title));
        }
    }
    common.drawInstrumentGauges(ctx.win, t, a, ins, 0, lay.top + 2, lay.gauge_w, inst_right);
}

fn stripPosition(at: u16, len: u16) u16 {
    return if (len == 0) 0 else @min(at, len - 1) + 1;
}

fn extraLabel(kind: viz.TrackerFocus) []const u8 {
    return switch (kind) {
        .macros => "MACRO",
        .live => "LIVE",
        .riffs => "RIFF",
        else => "",
    };
}

fn extraLen(ctx: *viz.DrawContext, kind: viz.TrackerFocus) u16 {
    return switch (kind) {
        .macros => macroLen(ctx),
        .live => blk: {
            const bank = ctx.bridge.channels.read();
            break :blk @min(bank.channels, bank.slots.len);
        },
        .riffs => if (ctx.views.pattern) |pv| pv.riff_count else 0,
        else => 0,
    };
}

fn extraStrip(ctx: *viz.DrawContext, kind: viz.TrackerFocus) ?[]const u8 {
    const at: u16 = switch (kind) {
        .macros => ctx.nav.macro_scroll,
        .live => ctx.nav.live_scroll,
        .riffs => ctx.nav.riff_scroll,
        else => return null,
    };
    const len = extraLen(ctx, kind);
    return ctx.arena.print("{s} {d}/{d}", .{ extraLabel(kind), stripPosition(at, len), len }) catch null;
}

fn extraTitle(kind: viz.TrackerFocus) []const u8 {
    return switch (kind) {
        .macros => "MACROS",
        .live => "LIVE",
        .riffs => "RIFFS",
        else => "",
    };
}

fn drawExtraRegion(ctx: *viz.DrawContext, ph: view.Playhead, lay: Layout) void {
    _ = ph;
    const t = ctx.theme;
    const title = extraTitle(lay.extra);
    if (title.len == 0) return;
    if (lay.compact) {
        const strip = extraStrip(ctx, lay.extra) orelse title;
        paint.printFit(ctx.win, lay.extra_x, lay.top, strip, lay.order_x -| lay.extra_x -| 1, t.style(.order_title));
        return;
    }
    paint.printAt(ctx.win, lay.extra_x + 2, lay.top, title, t.style(.order_title));
    drawExtraBody(ctx, lay.extra_x, lay.top + 1, common.order_w, region_rows, lay.extra);
}

fn liveLine(a: std.mem.Allocator, ch: u16, st: view.ChannelState) ?[]const u8 {
    const label = ch + 1;
    if (st.instrument == view.instrument_none) {
        return if (st.keyed)
            a.print("{d} -- {X:0>2}", .{ label, st.vol_car }) catch null
        else
            a.print("{d} -- --", .{label}) catch null;
    }
    if (st.keyed) {
        return a.print("{d} I{X:0>2} {X:0>2}", .{ label, st.instrument, st.vol_car }) catch null;
    }
    return a.print("{d} I{X:0>2} --", .{ label, st.instrument }) catch null;
}

fn drawExtraBody(
    ctx: *viz.DrawContext,
    x: u16,
    top: u16,
    width: u16,
    vis: u16,
    kind: viz.TrackerFocus,
) void {
    const t = ctx.theme;
    const a = ctx.arena;
    switch (kind) {
        .macros => {
            const bank = ctx.views.instruments orelse return;
            if (bank.count == 0) return;
            const idx = @min(ctx.nav.instrument_sel, bank.count -| 1);
            const ins = bank.get(bank.ctx, idx);
            if (bank.macroStep) |step_fn| {
                const n = @max(ins.macroRows(), 1);
                var first: u16 = 0;
                if (n > vis) first = @min(ctx.nav.macro_scroll, n - vis);
                var i: u16 = 0;
                while (i < vis) : (i += 1) {
                    const step = first + i;
                    if (step >= n) break;
                    const arp = step_fn(bank.ctx, idx, .arpeggio, step);
                    const fm = step_fn(bank.ctx, idx, .fmreg, step);
                    const vib = step_fn(bank.ctx, idx, .vibrato, step);
                    var buf: [24]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buf);
                    w.print("{X:0>2}", .{step}) catch continue;
                    if (!arp.empty) {
                        w.print(" {d}", .{arp.arp_note}) catch {};
                    } else if (!fm.empty) {
                        w.print(" {d}", .{fm.duration}) catch {};
                    } else if (!vib.empty) {
                        w.print(" {d}", .{vib.vib_delta}) catch {};
                    } else {
                        w.writeAll(" --") catch {};
                    }
                    const line = a.dupe(u8, w.buffered()) catch continue;
                    const is_cur = step == ctx.nav.macro_scroll;
                    paint.printFit(ctx.win, x + 1, top + i, line, width -| 1, if (is_cur) t.style(.macro_pos) else t.style(.inst_value));
                }
                return;
            }
            var row: u16 = 0;
            if (ins.macros.fmreg_len != 0 and row < vis) {
                const line = a.print("FM {d}", .{ins.macros.fmreg_len}) catch return;
                paint.printFit(ctx.win, x + 1, top + row, line, width -| 1, t.style(.inst_value));
                row += 1;
            }
            if (ins.macros.arpeggio_len != 0 and row < vis) {
                const line = a.print("ARP {d}/{d}", .{ ins.macros.arpeggio_len, ins.macros.arpeggio_speed }) catch return;
                paint.printFit(ctx.win, x + 1, top + row, line, width -| 1, t.style(.inst_value));
                row += 1;
            }
            if ((ins.macros.vibrato_len != 0 or ins.macros.vibrato_speed != 0) and row < vis) {
                const line = a.print("VIB {d}/{d}", .{ ins.macros.vibrato_len, ins.macros.vibrato_speed }) catch return;
                paint.printFit(ctx.win, x + 1, top + row, line, width -| 1, t.style(.inst_value));
            }
        },
        .live => {
            const bank = ctx.bridge.channels.read();
            const n = @min(bank.channels, bank.slots.len);
            const first = @min(ctx.nav.live_scroll, n -| vis);
            var i: u16 = 0;
            while (i < vis and first + i < n) : (i += 1) {
                const line = liveLine(a, first + i, bank.slots[first + i]) orelse continue;
                paint.printFit(ctx.win, x + 1, top + i, line, width -| 1, t.style(.trk_live));
            }
        },
        .riffs => {
            const pv = ctx.views.pattern orelse return;
            const n = pv.riff_count;
            var first: u16 = 0;
            if (n > vis) first = @min(ctx.nav.riff_scroll, n - vis);
            var i: u16 = 0;
            while (i < vis) : (i += 1) {
                const id = first + i;
                if (id >= n) break;
                const label = if (pv.riffName) |f| f(pv.ctx, id) else "";
                const line = if (label.len != 0)
                    a.print("{X:0>2} {s}", .{ id, label }) catch continue
                else
                    a.print("{X:0>2}", .{id}) catch continue;
                paint.printFit(ctx.win, x + 1, top + i, line, width -| 1, t.style(.order_row));
            }
        },
        else => {},
    }
}

fn drawOrderRegion(ctx: *viz.DrawContext, ph: view.Playhead, lay: Layout) void {
    const ov = ctx.views.order orelse return;
    const t = ctx.theme;
    const a = ctx.arena;
    if (lay.compact) {
        const text = a.print("ORDER {d}/{d}", .{ ctx.nav.order_scroll orelse ph.order, ov.len }) catch return;
        const max_w = lay.spectrum_x -| lay.order_x -| 1;
        paint.printFit(ctx.win, lay.order_x, lay.top, text, max_w, t.style(.order_title));
        return;
    }
    paint.printAt(ctx.win, lay.order_x + 3, lay.top, "ORDER", t.style(.order_title));
    if (perChannelOrder(ov)) {
        drawPerChannelOrder(ctx, ov, ph, lay);
        return;
    }
    const count = @max(1, ov.len);
    const selected = ctx.nav.order_scroll;
    const first = followOrigin(selected orelse ph.order, region_rows, count);
    var i: u16 = 0;
    while (i < region_rows) : (i += 1) {
        const slot = first + i;
        if (slot >= ov.len) break;
        const entry = ov.entry(ov.ctx, slot);
        const is_cur = slot == ph.order;
        const row = lay.top + 1 + i;
        const line = orderLine(a, ov, slot, entry, is_cur) orelse continue;
        const style = if (is_cur) t.style(.order_cur) else if (selected == slot) t.style(.pat_cursor_fill) else switch (entry.kind) {
            .jump, .skip => t.style(.order_skip),
            .end => t.style(.order_skip),
            .pattern => if (ov.kind != .shared_index) t.style(.order_ptr) else t.style(.order_row),
        };
        paint.printFit(ctx.win, lay.order_x + 1, row, line, order_text_w, style);
    }
}

fn drawPerChannelOrder(ctx: *viz.DrawContext, ov: view.OrderView, ph: view.Playhead, lay: Layout) void {
    if (ov.len == 0) return;
    const t = ctx.theme;
    const a = ctx.arena;
    const slot = @min(ctx.nav.order_scroll orelse ph.order, ov.len - 1);
    const is_cur = slot == ph.order;
    const marker = if (is_cur) "▶" else " ";
    const head = a.print("{s} {d: >2}/{d: >2}", .{ marker, slot, ov.len }) catch return;
    paint.printFit(ctx.win, lay.order_x + 1, lay.top + 1, head, per_channel_order_w - 1, if (is_cur) t.style(.order_cur) else t.style(.order_row));
    const ref = ov.channelRef orelse return;
    const nch: u16 = if (ctx.views.pattern) |pv| channelCount(pv) else 9;
    const first_row = lay.top + 2;
    const rows = lay.info_row -| first_row;
    const first = @min(lay.chan0, nch -| rows);
    var i: u16 = 0;
    while (i < rows and first + i < nch) : (i += 1) {
        const ch = first + i;
        const cr = ref(ov.ctx, slot, ch);
        const mag: u8 = @intCast(@min(@abs(cr.transpose), 99));
        const sign: u8 = if (cr.transpose < 0) '-' else '+';
        const tgt: u8 = if (cr.target == .instrument) 'i' else 'n';
        const line = if (ov.kind == .per_channel_index)
            a.print("{d}:{d:0>3}{c}{d}{c}", .{ ch + 1, cr.pattern, sign, mag, tgt }) catch continue
        else
            a.print("{d}:{X:0>3}{c}{d}{c}", .{ ch + 1, cr.start, sign, mag, tgt }) catch continue;
        paint.printFit(ctx.win, lay.order_x + 1, first_row + i, line, per_channel_order_w - 1, t.style(.order_ptr));
    }
}

fn orderLine(
    a: std.mem.Allocator,
    ov: view.OrderView,
    slot: u16,
    entry: view.OrderEntry,
    is_cur: bool,
) ?[]const u8 {
    const marker = if (is_cur) "▶" else " ";
    if (ov.kind != .shared_index) {
        return a.print("{s}{d: >3}  {d:0>2}", .{ marker, slot, entry.pattern }) catch null;
    }
    return switch (entry.kind) {
        .pattern => a.print("{s}{d: >3}  {d:0>2}", .{ marker, slot, entry.pattern }) catch null,
        .jump => a.print("{s}{d: >3} J{d:0>2}", .{ marker, slot, entry.jump_to }) catch null,
        .skip => a.print("{s}{d: >3} +++", .{ marker, slot }) catch null,
        .end => a.print("{s}{d: >3} ---", .{ marker, slot }) catch null,
    };
}

fn drawPattern(ctx: *viz.DrawContext, ph: view.Playhead, pv: view.PatternView, lay: Layout) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const win = ctx.win;
    const cursors = ctx.bridge.pattern_cursors.read();
    var lead: ?view.PatternCursor = null;
    var independent = false;
    if (pv.grid == .per_channel_stream) for (cursors.slots[0..@min(cursors.channels, cursors.slots.len)]) |cursor| {
        if (!cursor.active) continue;
        const first_active = lead orelse {
            lead = cursor;
            continue;
        };
        if (cursor.row != first_active.row or cursor.pattern != first_active.pattern) independent = true;
    };
    const at_row = if (lead) |c| c.row else ph.row;
    const at_pattern = if (lead) |c| c.pattern else ph.pattern;
    var i: u16 = 0;
    while (i < lay.chans) : (i += 1) {
        const ch = lay.chan0 + i;
        const cursor = if (ch < cursors.channels and ch < cursors.slots.len) cursors.slots[ch] else view.PatternCursor{};
        const head = if (independent and cursor.active) a.print("P{d} R{d}", .{ cursor.pattern, cursor.row }) catch continue else channelHead(a, pv, ch, ctx.bridge.chip.read()) orelse continue;
        const style = channelHeadStyle(t, pv, ch);
        const head_w: u16 = @intCast(@min(head.len, lay.col_w[i]));
        paint.printAt(win, lay.col_x[i] + (lay.col_w[i] -| head_w) / 2, lay.pattern_head_row, head, style);
    }

    const rows_total = pv.rows_per_pattern;
    const vis = lay.pattern_end -| lay.pattern_top;
    const first = @min(ctx.nav.pattern_scroll orelse followOrigin(at_row, vis, rows_total), rows_total -| vis);

    var r: u16 = first;
    while (r < rows_total and r - first < vis) : (r += 1) {
        const row: u16 = lay.pattern_top + (r - first);
        const is_cur = r == at_row;
        if (is_cur and !independent) {
            var x: u16 = 0;
            while (x < win.width) : (x += 1) {
                win.writeCell(x, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = t.style(.pat_cursor_fill),
                });
            }
        }
        const gut = rowLabel(a, r, pv.rows_per_pattern) orelse return;
        paint.printAt(win, lay.pat_x + 1, row, gut, t.rowStyle(is_cur, t.style(.pat_gutter)));
        drawSeparator(win, t, lay.pat_x + lay.gutter - 1, row, is_cur);

        var ci: u16 = 0;
        while (ci < lay.chans) : (ci += 1) {
            const ch = lay.chan0 + ci;
            const cx = lay.col_x[ci];
            drawSeparator(win, t, cx + lay.col_w[ci] - 1, row, is_cur);
            const cursor = if (pv.grid == .per_channel_stream and ch < cursors.channels and ch < cursors.slots.len) cursors.slots[ch] else view.PatternCursor{};
            const origin = if (cursor.active and ctx.nav.pattern_scroll == null) followOrigin(cursor.row, vis, rows_total) else first;
            const channel_row = origin + (r - first);
            const current = if (cursor.active) channel_row == cursor.row else is_cur;
            const pattern = if (cursor.active) cursor.pattern else at_pattern;
            if (pattern >= pv.num_patterns or channel_row >= rows_total) continue;
            const cell = pv.cell(pv.ctx, pattern, channel_row, ch);
            var clipped = ctx.*;
            clipped.win = win.child(.{ .x_off = cx, .y_off = row, .width = lay.col_w[ci] -| 1, .height = 1 });
            if (current) paint.fillRow(clipped.win, 0, t.style(.pat_cursor_fill));
            drawCell(&clipped, pv, cell, 0, 0, current);
        }
    }
}

fn channelHead(a: std.mem.Allocator, pv: view.PatternView, ch: u16, snap: view.ChipSnapshot) ?[]const u8 {
    var opl_voice: ?u16 = ch;
    if (pv.channelInfo) |info| {
        const ci = info(pv.ctx, ch);
        if (ci.four_op_role == .hi) return a.dupe(u8, "4OP-H") catch null;
        if (ci.four_op_role == .lo) return a.dupe(u8, "4OP-L") catch null;
        if (ci.name.len != 0) return a.dupe(u8, ci.name) catch null;
        opl_voice = if (ci.opl_voice) |voice| voice else null;
    }
    if (opl_voice) |index| if (index < snap.voices.len) {
        const voice = snap.voices[index];
        if (voice.keyed) {
            if (common.pitchFromFnum(voice.fnum, voice.block, pv.fnum_notes, pv.fnum_octave_offset)) |p| {
                const tok = common.noteToken(p.semitone, p.octave);
                return a.dupe(u8, tok[0..]) catch null;
            }
        }
    };
    return a.print("-{d}-", .{ch + 1}) catch null;
}

fn channelHeadStyle(t: Theme, pv: view.PatternView, ch: u16) vaxis.Style {
    if (pv.channelInfo) |info| {
        const ci = info(pv.ctx, ch);
        if (ci.four_op_role != .none) return t.style(.ch_4op);
        return switch (ci.kind) {
            .pcm => t.style(.ch_pcm),
            .drum => t.style(.ch_drum),
            .control => t.style(.ch_control),
            .fm => t.style(.pat_head),
        };
    }
    return t.style(.pat_head);
}

fn drawSeparator(win: vaxis.Window, t: Theme, x: u16, row: u16, is_cur: bool) void {
    win.writeCell(x, row, .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = t.patSeparator(is_cur),
    });
}

fn drawCell(ctx: *viz.DrawContext, pv: view.PatternView, cell: view.Cell, x: u16, row: u16, is_cur: bool) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const packed_set = pv.occupancy == .packed_event and view.packedEventIsInstrumentSet(cell);
    const packed_pitched = pv.occupancy == .packed_event and view.packedEventIsPitched(cell);
    const packed_cmd = pv.occupancy == .packed_event and !packed_set and !packed_pitched;

    var col_x = x;
    for (pv.columns) |id| {
        switch (id) {
            .note => {
                if (packed_set) {
                    const inst = cell.instrument orelse 0;
                    const text = a.print("I{X:0>2}", .{inst}) catch return;
                    paint.printAt(ctx.win, col_x, row, text, t.rowStyle(is_cur, t.style(.inst_cell)));
                    col_x +|= @as(u16, pv.cell_template.note_w) + 1;
                    continue;
                }
                if (packed_cmd) {
                    paint.printAt(ctx.win, col_x, row, "---", t.rowStyle(is_cur, t.style(.note_empty)));
                    col_x +|= @as(u16, pv.cell_template.note_w) + 1;
                    continue;
                }
                const text, const style = noteText(a, t, cell.note);
                paint.printAt(ctx.win, col_x, row, text, t.rowStyle(is_cur, style));
                col_x +|= @as(u16, pv.cell_template.note_w) + 1;
            },
            .instrument => {
                if (packed_set or (packed_cmd and cell.instrument == null)) {
                    paint.printAt(ctx.win, col_x, row, "..", t.rowStyle(is_cur, t.style(.note_empty)));
                } else if (cell.instrument) |inst| {
                    const text = formatDigits(a, inst, pv.inst_digits, pv.cell_template.inst_w) orelse return;
                    paint.printAt(ctx.win, col_x, row, text, t.rowStyle(is_cur, t.style(.inst_cell)));
                } else {
                    paint.printAt(ctx.win, col_x, row, "..", t.rowStyle(is_cur, t.style(.note_empty)));
                }
                col_x +|= @as(u16, pv.cell_template.inst_w) + 1;
            },
            .volume => {
                if (cell.volume) |vol| {
                    const text = formatDigits(a, vol, pv.vol_digits, pv.cell_template.vol_w) orelse return;
                    paint.printAt(ctx.win, col_x, row, text, t.rowStyle(is_cur, t.style(.vol_cell)));
                } else {
                    paint.printAt(ctx.win, col_x, row, "..", t.rowStyle(is_cur, t.style(.note_empty)));
                }
                col_x +|= @as(u16, pv.cell_template.vol_w) + 1;
            },
            .effect => {
                if (packed_set) {
                    paint.printAt(ctx.win, col_x, row, emptyFx(pv.cell_template.fx_w), t.rowStyle(is_cur, t.style(.note_empty)));
                } else {
                    drawEffect(ctx, pv, cell.effects[0], col_x, row, is_cur);
                }
                col_x +|= @as(u16, pv.cell_template.fx_w) + 1;
            },
            .effect2 => {
                drawEffect(ctx, pv, cell.effects[1], col_x, row, is_cur);
                col_x +|= @as(u16, pv.cell_template.fx_w) + 1;
            },
            .extra => {
                const ch: []const u8 = switch (cell.extra) {
                    .retrigger => "R",
                    .delay => |d| a.print("D{X:0>1}", .{d}) catch "D",
                    .pitch => |p| a.print("{d}", .{p}) catch "+",
                    .none => " ",
                };
                paint.printAt(ctx.win, col_x, row, ch, t.rowStyle(is_cur, t.style(.fx_cell)));
                col_x +|= pv.cell_template.extra_w;
            },
        }
    }
}

fn noteText(a: std.mem.Allocator, t: Theme, note: view.Note) struct { []const u8, vaxis.Style } {
    return switch (note) {
        .none => .{ "---", t.style(.note_empty) },
        .off => .{ "OFF", t.style(.note) },
        .cut => .{ "CUT", t.style(.note) },
        .rest => .{ "RST", t.style(.note) },
        .hold => .{ "HLD", t.style(.note) },
        .pitch => |p| .{
            a.print("{s}{d}", .{
                common.note_names[p.semitone % common.note_names.len],
                p.octave,
            }) catch "---",
            if (p.fixed) t.style(.note_fixed) else t.style(.note),
        },
    };
}

fn formatDigits(a: std.mem.Allocator, value: u16, digits: view.DigitStyle, width: u8) ?[]const u8 {
    return switch (digits) {
        .hex => switch (width) {
            1 => a.print("{X}", .{value}) catch null,
            else => a.print("{X:0>2}", .{value}) catch null,
        },
        .decimal => a.print("{d:0>2}", .{value}) catch null,
    };
}

fn emptyFx(width: u8) []const u8 {
    return if (width >= 3) "···" else "··";
}

fn drawEffect(ctx: *viz.DrawContext, pv: view.PatternView, fx: view.Effect, x: u16, row: u16, is_cur: bool) void {
    const t = ctx.theme;
    const a = ctx.arena;
    if (fx.cmd == 0) {
        paint.printAt(ctx.win, x, row, emptyFx(pv.cell_template.fx_w), t.rowStyle(is_cur, t.style(.note_empty)));
        return;
    }
    const desc = if (pv.effectLexicon) |lex| lex(pv.ctx, fx.cmd, fx.param) else view.EffectDesc{};
    if (pv.effect_style == .nibble) {
        const text = a.print("{X:0>2}", .{fx.cmd}) catch return;
        paint.printAt(ctx.win, x, row, text, t.rowStyle(is_cur, t.style(.fx_cell)));
        if (desc.text.len == 1) {
            paint.printAt(
                ctx.win,
                x + pv.cell_template.fx_w,
                row,
                desc.text,
                t.rowStyle(is_cur, t.style(.fx_letter)),
            );
        }
        return;
    }
    const text = switch (pv.effect_style) {
        .nibble => unreachable,
        .letter_param => blk: {
            const letter = desc.letter orelse if (fx.cmd >= 'A' and fx.cmd <= 'Z') fx.cmd else hexLetter(fx.cmd);
            break :blk a.print("{c}{X:0>2}", .{ letter, fx.param }) catch return;
        },
        .raw_hex => if (pv.cell_template.fx_w >= 4)
            a.print("{X:0>2}{X:0>2}", .{ fx.cmd, fx.param }) catch return
        else
            a.print("{X:0>2}", .{fx.cmd}) catch return,
        .decimal => a.print("{d:0>3}", .{fx.param}) catch return,
    };
    const style = if (pv.effect_style == .letter_param) t.style(.fx_letter) else t.style(.fx_cell);
    paint.printAt(ctx.win, x, row, text, t.rowStyle(is_cur, style));
}

fn hexLetter(cmd: u8) u8 {
    const n = cmd & 0x0f;
    return if (n < 10) '0' + n else 'A' + (n - 10);
}

pub const visualizer = viz.Visualizer.init(@This());

// --- tests -------------------------------------------------------------------

const pcm_band_count = @import("../bridge.zig").pcm_band_count;
const Bridge = @import("../bridge.zig").Bridge;
const default_theme = @import("../theme.zig").default_theme;

const HscFix = struct {
    fn cell(_: *anyopaque, pattern: u16, row: u16, chan: u16) view.Cell {
        if (pattern != 0 or row != 0 or chan != 0) return .{};
        return .{
            .note = .{ .pitch = .{ .semitone = 1, .octave = 4 } },
            .effects = .{ .{ .cmd = 0x12, .param = 0 }, .{} },
        };
    }
};

const A2mFix = struct {
    fn cell(_: *anyopaque, pattern: u16, row: u16, chan: u16) view.Cell {
        if (pattern != 0 or row != 0 or chan != 0) return .{};
        return .{
            .note = .{ .pitch = .{ .semitone = 0, .octave = 4 } },
            .instrument = 1,
            .effects = .{ .{ .cmd = 'C', .param = 0x20 }, .{ .cmd = '2', .param = 0x01 } },
        };
    }
    fn channelInfo(_: *anyopaque, chan: u16) view.ChannelInfo {
        if (chan >= 15) {
            const names = [_][]const u8{ "BD", "SD", "TT", "TC", "HH" };
            return .{ .name = names[@min(chan - 15, 4)], .kind = .drum };
        }
        if (chan == 0) return .{ .four_op_pair = 0, .four_op_role = .hi };
        if (chan == 1) return .{ .four_op_pair = 0, .four_op_role = .lo };
        return .{};
    }
};

const PairedFix = struct {
    const pairs = [_]u16{ 0, 2, 4, 9, 11, 13 };
    fn cell(_: *anyopaque, _: u16, _: u16, _: u16) view.Cell {
        return .{};
    }
    fn channelInfo(_: *anyopaque, chan: u16) view.ChannelInfo {
        for (pairs) |hi| {
            if (chan == hi) return .{ .four_op_role = .hi };
            if (chan == hi + 1) return .{ .four_op_role = .lo };
        }
        return .{};
    }
};

const a2m_columns = [_]view.ColumnId{ .note, .instrument, .effect, .effect2 };
const hsc_columns = [_]view.ColumnId{ .note, .effect };

fn testRowText(screen: *vaxis.Screen, buf: []u8, row: u16, width: u16) []const u8 {
    for (0..width) |c| {
        const cell = screen.readCell(@intCast(c), row).?;
        const g = cell.char.grapheme;
        buf[c] = if (g.len == 1) g[0] else '?';
    }
    return buf[0..width];
}

const DrawHarness = struct {
    br: Bridge = .{},
    nav: viz.Navigation = .{},
    spec_levels: [view.max_opl_voices]f32 = @splat(0),
    spec_peaks: [view.max_opl_voices]f32 = @splat(0),
    spec_glow: [view.max_opl_voices]f32 = @splat(0),
    pcm_bands: [pcm_band_count]f32 = @splat(0),
    pcm_peaks: [pcm_band_count]f32 = @splat(0),
    pcm_glow: [pcm_band_count]f32 = @splat(0),
    spark: [viz.spark_retention]f32 = @splat(0),

    fn context(
        self: *DrawHarness,
        win: vaxis.Window,
        views: view.SourceViews,
        arena: std.mem.Allocator,
        voice_count: u8,
    ) viz.DrawContext {
        return .{
            .win = win,
            .theme = default_theme,
            .bridge = &self.br,
            .track = .{ .format_name = "TEST", .visualizer = "tracker", .artist = "Composer" },
            .views = views,
            .spec_levels = &self.spec_levels,
            .spec_peaks = &self.spec_peaks,
            .spec_peak_glow = &self.spec_glow,
            .voice_count = voice_count,
            .nav = &self.nav,
            .pcm_bands = &self.pcm_bands,
            .pcm_band_peaks = &self.pcm_peaks,
            .pcm_band_peak_glow = &self.pcm_glow,
            .pcm_peak = 0,
            .spark = &self.spark,
            .arena = arena,
        };
    }
};

test "independent channel cursors follow their own patterns and rows" {
    const Fixture = struct {
        fn cell(_: *anyopaque, pattern: u16, row: u16, channel: u16) view.Cell {
            if (pattern != channel or row != (if (channel == 0) @as(u16, 10) else 40)) return .{};
            return .{ .note = .{ .pitch = .{ .semitone = if (channel == 0) 0 else 7, .octave = 4 } } };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    h.br.playhead.write(.{ .pattern = 0, .row = 10 });
    var cursors = view.PatternCursorBank{ .channels = 2 };
    cursors.slots[0] = .{ .active = true, .pattern = 0, .row = 10 };
    cursors.slots[1] = .{ .active = true, .pattern = 1, .row = 40 };
    h.br.pattern_cursors.write(cursors);
    var ctx = h.context(win, .{ .pattern = .{ .ctx = undefined, .grid = .per_channel_stream, .occupancy = .independent, .columns = &.{.note}, .effect_style = .raw_hex, .cell_template = .{ .width = 4, .note_w = 3 }, .channels = 2, .rows_per_pattern = 64, .num_patterns = 2, .cell = Fixture.cell } }, arena.allocator(), 9);
    draw(&ctx);
    var both = false;
    for (0..14) |row| {
        var buf: [78]u8 = undefined;
        const line = testRowText(&screen, &buf, @intCast(row), 78);
        if (std.mem.find(u8, line, "C-4") != null and std.mem.find(u8, line, "G-4") != null) both = true;
    }
    try std.testing.expect(both);
}

test "inspector reaches sequence events beyond the 16-bit grid scroll range" {
    const inspector = @import("../inspector.zig");
    const Fixture = struct {
        fn track(_: *anyopaque, _: u16) view.SequenceTrack {
            return .{};
        }
        fn event(_: *anyopaque, index: u32) view.SequenceEvent {
            return .{ .tick = index, .kind = .end };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{ .sequence = .{ .ctx = undefined, .kind = .event_stream, .track_count = 1, .channel_count = 1, .tick_rate = 120, .length_ticks = 70000, .track = Fixture.track, .eventAt = Fixture.event, .event_count = 70001 } }, arena.allocator(), 9);
    var state = inspector.State{ .open = true, .section = .events };
    _ = inspector.handleKey(&ctx, &state, vaxis.Key.end);
    inspector.draw(&ctx, &state);
    var buf: [78]u8 = undefined;
    const line = testRowText(&screen, &buf, @intCast(state.body.y + state.page_rows - 1), 78);
    try std.testing.expect(std.mem.find(u8, line, "70000") != null);
    try std.testing.expect(std.mem.find(u8, line, "End") != null);
}

test "A2M dual FX and of 20 at 78 and 44x5" {
    const gpa = std.testing.allocator;
    const pv = view.PatternView{
        .ctx = undefined,
        .grid = .shared_pattern,
        .occupancy = .independent,
        .columns = &a2m_columns,
        .effect_style = .letter_param,
        .cell_template = .{ .width = 14, .note_w = 3, .inst_w = 2, .fx_w = 3 },
        .channels = 20,
        .rows_per_pattern = 64,
        .num_patterns = 1,
        .cell = A2mFix.cell,
        .channelInfo = A2mFix.channelInfo,
    };

    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = 78,
            .height = 14,
            .screen = &screen,
        };
        var h = DrawHarness{};
        var ctx = h.context(win, .{ .pattern = pv }, arena_state.allocator(), 18);
        draw(&ctx);
        var found_of = false;
        var found_fx1 = false;
        var found_fx2 = false;
        var r: u16 = 0;
        while (r < 14) : (r += 1) {
            var buf: [78]u8 = undefined;
            const line = testRowText(&screen, &buf, r, 78);
            if (std.mem.find(u8, line, "of 20") != null) found_of = true;
            if (std.mem.find(u8, line, "C20") != null) found_fx1 = true;
            if (std.mem.find(u8, line, "201") != null) found_fx2 = true;
        }
        try std.testing.expect(found_of);
        try std.testing.expect(found_fx1);
        try std.testing.expect(found_fx2);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .rows = 5, .cols = 44, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = 44,
            .height = 5,
            .screen = &screen,
        };
        var h = DrawHarness{};
        var ctx = h.context(win, .{ .pattern = pv }, arena_state.allocator(), 18);
        draw(&ctx);
        var found_of = false;
        var r: u16 = 0;
        while (r < 5) : (r += 1) {
            var buf: [44]u8 = undefined;
            const line = testRowText(&screen, &buf, r, 44);
            if (std.mem.find(u8, line, "of 20") != null) found_of = true;
        }
        try std.testing.expect(found_of);
    }
}

test "channel paging reaches every channel of A2M four-operator layouts" {
    for ([_]u16{ 18, 20 }) |n| {
        const pv = view.PatternView{
            .ctx = undefined,
            .grid = .shared_pattern,
            .occupancy = .independent,
            .columns = &a2m_columns,
            .effect_style = .letter_param,
            .cell_template = .{ .width = 14 },
            .channels = n,
            .rows_per_pattern = 64,
            .num_patterns = 1,
            .cell = PairedFix.cell,
            .channelInfo = PairedFix.channelInfo,
        };
        var count: u16 = 1;
        while (count < n) : (count += 1) {
            var seen = std.bit_set.Integer(32).empty;
            var page: u16 = 0;
            while (page <= n - count) : (page += 1) {
                const start = visiblePage(pv, page, count);
                try std.testing.expect(start + count <= n);
                for (start..start + count) |ch| seen.set(ch);
            }
            try std.testing.expectEqual(@as(usize, n), seen.count());
        }
    }
}

test "pattern scroll pins at row zero and Home resumes following" {
    var nav = viz.Navigation{};
    try std.testing.expectEqual(@as(?u16, 3), scrollOrigin(nav.pattern_scroll, 4, 48, -1));
    nav.pattern_scroll = 1;
    try std.testing.expectEqual(@as(?u16, 0), scrollOrigin(nav.pattern_scroll, 30, 48, -1));
    try std.testing.expectEqual(@as(?u16, 0), scrollOrigin(0, 30, 48, -8));
    try std.testing.expectEqual(@as(?u16, 48), scrollOrigin(0, 30, 48, std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(?u16, 47), scrollOrigin(48, 30, 48, -1));
    try std.testing.expectEqual(@as(?u16, null), scrollOrigin(12, 30, 48, std.math.minInt(i32)));
}

test "live channel lines number from one and mark instrument_none" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1 -- --", liveLine(a, 0, .{}).?);
    try std.testing.expectEqualStrings("20 IC8 3F", liveLine(a, 19, .{ .instrument = 200, .keyed = true, .vol_car = 0x3f }).?);
}

test "tall LIVE and MACROS columns print two-digit channels and headers whole" {
    const Fix = struct {
        fn plain(_: *anyopaque, _: u16) view.InstrumentInfo {
            return .{ .name = "Piano", .patch = .{ .opl_2op = .{} } };
        }
        fn macros(_: *anyopaque, _: u16) view.InstrumentInfo {
            return .{ .name = "Piano", .patch = .{ .opl_2op = .{} }, .macros = .{ .arpeggio_len = 12, .arpeggio_speed = 15, .vibrato_speed = 255 } };
        }
        fn entry(_: *anyopaque, _: u16) view.OrderEntry {
            return .{ .kind = .pattern };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 20, .cols = 88, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 88, .height = 20, .screen = &screen };
    var h = DrawHarness{};
    var bank = view.ChannelStateBank{ .channels = 18 };
    for (bank.slots[0..18]) |*slot| slot.* = .{ .instrument = 5, .keyed = true, .vol_car = 0x3f };
    bank.slots[10].keyed = false;
    h.br.channels.write(bank);
    var ctx = h.context(win, .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &a2m_columns, .effect_style = .letter_param, .cell_template = .{ .width = 14 }, .channels = 18, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .instruments = .{ .ctx = undefined, .count = 256, .get = Fix.plain },
        .order = .{ .ctx = undefined, .len = 128, .kind = .shared_index, .entry = Fix.entry },
    }, arena.allocator(), 18);
    draw(&ctx);
    const lay = paneLayout(&ctx, ctx.views.pattern.?);
    try std.testing.expect(!lay.compact and lay.show_extra);
    const col = lay.extra_x + 1;
    var buf: [88]u8 = undefined;
    try std.testing.expectEqualStrings("10 I05 3F", testRowText(&screen, &buf, lay.top + 10, 88)[col..][0..9]);
    try std.testing.expectEqualStrings("11 I05 --", testRowText(&screen, &buf, lay.top + 11, 88)[col..][0..9]);

    ctx.views.instruments = .{ .ctx = undefined, .count = 256, .get = Fix.macros };
    draw(&ctx);
    try std.testing.expectEqualStrings("ARP 12/15", testRowText(&screen, &buf, lay.top + 1, 88)[col..][0..9]);
    try std.testing.expectEqualStrings("VIB 0/255", testRowText(&screen, &buf, lay.top + 2, 88)[col..][0..9]);
}

test "inspector names the chip from the dump while NEW stays a separate field" {
    const inspector = @import("../inspector.zig");
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    h.br.chip.write(.{ .new_bit = true });
    var ctx = h.context(win, .{ .dump = .{ .chip = .opl2 } }, arena.allocator(), 9);
    var state = inspector.State{ .open = true, .section = .chip };
    inspector.draw(&ctx, &state);
    var found = false;
    for (0..14) |row| {
        var buf: [78]u8 = undefined;
        if (std.mem.find(u8, testRowText(&screen, &buf, @intCast(row), 78), "CHIP 1  OPL2  NEW ON") != null) found = true;
    }
    try std.testing.expect(found);
}

test "channel paging keeps pairs whole whenever a start within half a page allows it" {
    for ([_]u16{ 18, 20 }) |n| {
        const pv = view.PatternView{
            .ctx = undefined,
            .grid = .shared_pattern,
            .occupancy = .independent,
            .columns = &a2m_columns,
            .effect_style = .letter_param,
            .cell_template = .{ .width = 14 },
            .channels = n,
            .rows_per_pattern = 64,
            .num_patterns = 1,
            .cell = PairedFix.cell,
            .channelInfo = PairedFix.channelInfo,
        };
        var count: u16 = 2;
        while (count < n) : (count += 1) {
            const last = n - count;
            var page: u16 = 1;
            while (page < last) : (page += 1) {
                if (!splitsPair(pv, visiblePage(pv, page, count), count)) continue;
                var start = page -| count / 2;
                while (start <= @min(last, page + count / 2)) : (start += 1) {
                    try std.testing.expect(splitsPair(pv, start, count));
                }
            }
        }
    }
}

test "every left or right press moves the paired channel grid" {
    const pv = view.PatternView{
        .ctx = undefined,
        .grid = .shared_pattern,
        .occupancy = .independent,
        .columns = &a2m_columns,
        .effect_style = .letter_param,
        .cell_template = .{ .width = 14 },
        .channels = 18,
        .rows_per_pattern = 64,
        .num_patterns = 1,
        .cell = PairedFix.cell,
        .channelInfo = PairedFix.channelInfo,
    };
    var count: u16 = 2;
    while (count < 18) : (count += 1) {
        const max_start = 18 - count;
        var page: u16 = 0;
        while (visiblePage(pv, page, count) < max_start) {
            const next = nextPage(pv, page, count, max_start, true);
            try std.testing.expect(visiblePage(pv, next, count) > visiblePage(pv, page, count));
            page = next;
        }
        while (visiblePage(pv, page, count) > 0) {
            const prev = nextPage(pv, page, count, max_start, false);
            try std.testing.expect(visiblePage(pv, prev, count) < visiblePage(pv, page, count));
            page = prev;
        }
    }
}

test "compact strips reach every live channel and keep macro positions in range" {
    const Bank = struct {
        fn get(_: *anyopaque, index: u16) view.InstrumentInfo {
            return .{ .name = "Lead", .macros = .{ .fmreg_len = if (index == 0) 16 else 4 } };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 15, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 15, .screen = &screen };
    var h = DrawHarness{};
    h.br.channels.write(.{ .channels = 9 });
    const views: view.SourceViews = .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &hsc_columns, .effect_style = .raw_hex, .cell_template = .{ .width = 7 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .instruments = .{ .ctx = undefined, .count = 2, .get = Bank.get },
    };
    var ctx = h.context(win, views, arena.allocator(), 9);
    const Probe = struct {
        fn shows(c: *viz.DrawContext, s: *vaxis.Screen, text: []const u8) bool {
            draw(c);
            var buf: [78]u8 = undefined;
            return std.mem.find(u8, testRowText(s, &buf, 0, 78), text) != null;
        }
    };

    h.nav.tracker_focus = .live;
    for (0..3) |_| _ = handleKey(&ctx, vaxis.Key.down);
    try std.testing.expect(Probe.shows(&ctx, &screen, "LIVE 4/9"));
    _ = handleKey(&ctx, vaxis.Key.end);
    try std.testing.expect(Probe.shows(&ctx, &screen, "LIVE 9/9"));

    h.nav.tracker_focus = .macros;
    h.nav.instrument_sel = 0;
    h.nav.instrument_sel_user = true;
    for (0..9) |_| _ = handleKey(&ctx, vaxis.Key.down);
    try std.testing.expect(Probe.shows(&ctx, &screen, "MACRO 10/16"));
    _ = handleKey(&ctx, vaxis.Key.end);
    h.nav.instrument_sel = 1;
    try std.testing.expect(Probe.shows(&ctx, &screen, "MACRO 4/4"));
    _ = handleKey(&ctx, vaxis.Key.up);
    try std.testing.expect(Probe.shows(&ctx, &screen, "MACRO 3/4"));

    h.br.channels.write(.{ .channels = 20 });
    h.nav.tracker_focus = .live;
    _ = handleKey(&ctx, vaxis.Key.end);
    try std.testing.expect(Probe.shows(&ctx, &screen, "LIVE 20/20"));
    var tall = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer tall.deinit(gpa);
    var tall_ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 30, .screen = &tall }, views, arena.allocator(), 9);
    _ = handleKey(&tall_ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(u16, 20 - region_rows - 1), h.nav.live_scroll);
}

test "left paging recovers at once from a page left stale by a wider pane" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 200, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 200, .height = 30, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{ .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &a2m_columns, .effect_style = .letter_param, .cell_template = .{ .width = 14 }, .channels = 18, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell } }, arena.allocator(), 18);
    h.nav.channel_page = 14;
    const pv = ctx.views.pattern.?;
    const lay = paneLayout(&ctx, pv);
    _ = handleKey(&ctx, vaxis.Key.left);
    try std.testing.expect(visiblePage(pv, h.nav.channel_page, lay.chans) < visiblePage(pv, 14, lay.chans));
}

test "agreeing cursors set the frame's current row even when the playhead lags" {
    const Fixture = struct {
        fn cell(_: *anyopaque, _: u16, row: u16, _: u16) view.Cell {
            if (row != 11) return .{};
            return .{ .note = .{ .pitch = .{ .semitone = 0, .octave = 4 } } };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    h.br.playhead.write(.{ .pattern = 0, .row = 10 });
    var cursors = view.PatternCursorBank{ .channels = 2 };
    cursors.slots[0] = .{ .active = true, .pattern = 0, .row = 11 };
    cursors.slots[1] = .{ .active = true, .pattern = 0, .row = 11 };
    h.br.pattern_cursors.write(cursors);
    var ctx = h.context(win, .{ .pattern = .{ .ctx = undefined, .grid = .per_channel_stream, .occupancy = .independent, .columns = &.{.note}, .effect_style = .raw_hex, .cell_template = .{ .width = 4, .note_w = 3 }, .channels = 2, .rows_per_pattern = 64, .num_patterns = 1, .cell = Fixture.cell } }, arena.allocator(), 9);
    draw(&ctx);
    for (0..14) |row| {
        var buf: [78]u8 = undefined;
        try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, @intCast(row), 78), "P0 R") == null);
    }
}

test "compact strips keep the patch summary and the whole order total" {
    const Fix = struct {
        fn get(_: *anyopaque, _: u16) view.InstrumentInfo {
            return .{ .name = "Lead Synth Bright with a long A2M name", .patch = .{ .opl_4op = .{ .feedback = 3, .feedback2 = 2, .algorithm = 1 } } };
        }
        fn entry(_: *anyopaque, _: u16) view.OrderEntry {
            return .{ .kind = .pattern };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 15, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 15, .screen = &screen };
    var h = DrawHarness{};
    h.br.playhead.write(.{ .order = 10 });
    var ctx = h.context(win, .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &hsc_columns, .effect_style = .raw_hex, .cell_template = .{ .width = 7 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .instruments = .{ .ctx = undefined, .count = 31, .get = Fix.get },
        .order = .{ .ctx = undefined, .len = 16, .kind = .shared_index, .entry = Fix.entry },
    }, arena.allocator(), 9);
    draw(&ctx);
    var buf: [78]u8 = undefined;
    const line = testRowText(&screen, &buf, 0, 78);
    try std.testing.expect(std.mem.find(u8, line, "I00/31  4OP  FB 3/2  ALG 1") != null);
    try std.testing.expect(std.mem.find(u8, line, "ORDER 10/16") != null);

    var narrow = try vaxis.Screen.init(gpa, .{ .rows = 15, .cols = 44, .x_pixel = 0, .y_pixel = 0 });
    defer narrow.deinit(gpa);
    narrow.width_method = .unicode;
    h.br.channels.write(.{ .channels = 18 });
    h.br.playhead.write(.{ .order = 127 });
    var narrow_ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 44, .height = 15, .screen = &narrow }, .{
        .pattern = ctx.views.pattern,
        .instruments = ctx.views.instruments,
        .order = .{ .ctx = undefined, .len = 128, .kind = .shared_index, .entry = Fix.entry },
    }, arena.allocator(), 18);
    draw(&narrow_ctx);
    const strips = testRowText(&narrow, buf[0..44], 0, 44);
    for ([_][]const u8{ "I00/31", "LIVE 1/18", "ORDER 127/128", "SPECTRUM" }) |text| {
        try std.testing.expect(std.mem.find(u8, strips, text) != null);
    }

    const Macros = struct {
        fn get(_: *anyopaque, _: u16) view.InstrumentInfo {
            return .{ .name = "Lead", .patch = .{ .opl_4op = .{} }, .macros = .{ .fmreg_len = 255 } };
        }
    };
    narrow_ctx.views.instruments = .{ .ctx = undefined, .count = 256, .get = Macros.get };
    draw(&narrow_ctx);
    const macro_strips = testRowText(&narrow, buf[0..44], 0, 44);
    for ([_][]const u8{ "I00/256", "MACRO 1/255", "ORDER 127/128", "SPECTRUM" }) |text| {
        try std.testing.expect(std.mem.find(u8, macro_strips, text) != null);
    }
}

test "pattern scroll steps from the drawn row after the pane grows" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var small = try vaxis.Screen.init(gpa, .{ .rows = 15, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer small.deinit(gpa);
    var tall = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer tall.deinit(gpa);
    var h = DrawHarness{};
    const views: view.SourceViews = .{ .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &hsc_columns, .effect_style = .raw_hex, .cell_template = .{ .width = 7 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell } };
    var small_ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 15, .screen = &small }, views, arena.allocator(), 9);
    var tall_ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 30, .screen = &tall }, views, arena.allocator(), 9);
    _ = handleKey(&small_ctx, vaxis.Key.end);
    const lay = paneLayout(&tall_ctx, views.pattern.?);
    _ = handleKey(&tall_ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(?u16, 64 - (lay.pattern_end - lay.pattern_top) - 1), h.nav.pattern_scroll);
}

test "tall panes show every region, as columns where they fit and as strips where they do not" {
    const Fix = struct {
        fn get(_: *anyopaque, _: u16) view.InstrumentInfo {
            return .{ .name = "Bass", .patch = .{ .opl_2op = .{} } };
        }
        fn entry(_: *anyopaque, _: u16) view.OrderEntry {
            return .{ .kind = .pattern };
        }
    };
    const Case = struct { width: u16, voices: u8, compact: bool, rows: []const []const u8 };
    const cases = [_]Case{
        .{ .width = 78, .voices = 18, .compact = false, .rows = &.{ "INSTRUMENT 00", "LIVE 1/18", "CAR" } },
        .{ .width = 78, .voices = 9, .compact = false, .rows = &.{ "INSTRUMENT 00", "LIVE", "ORDER", "CAR" } },
        .{ .width = 44, .voices = 18, .compact = true, .rows = &.{ "I00/2", "LIVE 1/18", "ORDER 0/4", "SPECTRUM" } },
        .{ .width = 44, .voices = 9, .compact = true, .rows = &.{ "I00/2", "LIVE 1/9", "ORDER 0/4", "SPECTRUM" } },
    };
    const gpa = std.testing.allocator;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .rows = 20, .cols = case.width, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = case.width, .height = 20, .screen = &screen };
        var h = DrawHarness{};
        h.br.channels.write(.{ .channels = case.voices });
        var ctx = h.context(win, .{
            .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &a2m_columns, .effect_style = .letter_param, .cell_template = .{ .width = 14 }, .channels = case.voices, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
            .instruments = .{ .ctx = undefined, .count = 2, .get = Fix.get },
            .order = .{ .ctx = undefined, .len = 4, .kind = .shared_index, .entry = Fix.entry },
        }, arena.allocator(), case.voices);
        draw(&ctx);
        const lay = paneLayout(&ctx, ctx.views.pattern.?);
        try std.testing.expectEqual(case.compact, lay.compact);
        if (!case.compact) try std.testing.expectEqual(@as(u16, case.voices), lay.spectrum_voices);
        var buf: [78]u8 = undefined;
        for (case.rows) |text| {
            var found = false;
            for (0..14) |row| {
                const line = testRowText(&screen, buf[0..case.width], @intCast(row), case.width);
                if (std.mem.find(u8, line, text) != null) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "per-channel order lists number channels as the grid heads do" {
    const Fix = struct {
        fn entry(_: *anyopaque, _: u16) view.OrderEntry {
            return .{ .kind = .pattern };
        }
        fn channelRef(_: *anyopaque, _: u16, chan: u16) view.ChannelRef {
            return .{ .start = 0x12 + @as(u32, chan) };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &hsc_columns, .effect_style = .raw_hex, .cell_template = .{ .width = 7 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .order = .{ .ctx = undefined, .len = 4, .kind = .per_channel, .entry = Fix.entry, .channelRef = Fix.channelRef },
    }, arena.allocator(), 9);
    draw(&ctx);
    var buf: [120]u8 = undefined;
    var first = false;
    var last = false;
    for (0..16) |row| {
        const line = testRowText(&screen, &buf, @intCast(row), 120);
        if (std.mem.find(u8, line, "1:012+0n") != null) first = true;
        if (std.mem.find(u8, line, "9:01A+0n") != null) last = true;
        try std.testing.expect(std.mem.find(u8, line, "0:012") == null);
    }
    try std.testing.expect(first);
    try std.testing.expect(last);
}

test "per-channel order lines keep four-digit starts and two-digit transpositions whole" {
    const Fix = struct {
        fn entry(_: *anyopaque, _: u16) view.OrderEntry {
            return .{ .kind = .pattern };
        }
        fn channelRef(_: *anyopaque, _: u16, chan: u16) view.ChannelRef {
            return .{ .start = 0x7FF7 + @as(u32, chan), .transpose = -64, .target = .instrument };
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &hsc_columns, .effect_style = .raw_hex, .cell_template = .{ .width = 7 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .order = .{ .ctx = undefined, .len = 4, .kind = .per_channel, .entry = Fix.entry, .channelRef = Fix.channelRef },
    }, arena.allocator(), 9);
    draw(&ctx);
    const lay = paneLayout(&ctx, ctx.views.pattern.?);
    try std.testing.expect(!lay.compact and lay.show_order);
    var buf: [120]u8 = undefined;
    var want_buf: [16]u8 = undefined;
    for (0..9) |ch| {
        const row: u16 = @intCast(2 + ch);
        const want = try std.fmt.bufPrint(&want_buf, "{d}:{X}-64i", .{ ch + 1, 0x7FF7 + ch });
        try std.testing.expectEqualStrings(want, testRowText(&screen, &buf, row, 120)[lay.order_x + 1 ..][0..want.len]);
        try std.testing.expectEqualStrings("│", screen.readCell(lay.spectrum_x, row).?.char.grapheme);
    }
}

test "inspector splits a dual OPL2 capture into two nine-voice chips" {
    const inspector = @import("../inspector.zig");
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 40, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 40, .screen = &screen };
    var h = DrawHarness{};
    h.br.chip.write(.{ .new_bit = true });
    var ctx = h.context(win, .{ .dump = .{ .chip = .dual_opl2 } }, arena.allocator(), 18);
    var state = inspector.State{ .open = true, .section = .chip };
    inspector.draw(&ctx, &state);
    var second = false;
    var tenth = false;
    for (0..40) |row| {
        var buf: [78]u8 = undefined;
        const line = testRowText(&screen, &buf, @intCast(row), 78);
        if (std.mem.find(u8, line, "CHIP 2  OPL2  NEW ON") != null) second = true;
        if (std.mem.find(u8, line, "10  ") != null and std.mem.find(u8, line, "FNUM") != null) tenth = true;
    }
    try std.testing.expect(second);
    try std.testing.expect(!tenth);
}

test "every shown channel keeps its last cell column clear of the separator" {
    const Fix = struct {
        fn radCell(_: *anyopaque, _: u16, row: u16, _: u16) view.Cell {
            if (row != 0) return .{};
            return .{ .note = .{ .pitch = .{ .semitone = 0, .octave = 4 } }, .instrument = 1, .effects = .{ .{ .cmd = 'A', .param = 0x12 }, .{} }, .extra = .retrigger };
        }
        fn ldsCell(_: *anyopaque, _: u16, row: u16, _: u16) view.Cell {
            if (row != 0) return .{};
            return .{ .effects = .{ .{ .cmd = 0x0c, .param = 0x3f }, .{} } };
        }
    };
    const rad: view.PatternView = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &.{ .note, .instrument, .effect, .extra }, .effect_style = .letter_param, .cell_template = .{ .width = 12, .note_w = 3, .inst_w = 2, .fx_w = 3, .extra_w = 1 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = Fix.radCell };
    const lds: view.PatternView = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &.{ .note, .instrument, .effect }, .effect_style = .raw_hex, .cell_template = .{ .width = 11, .note_w = 3, .inst_w = 2, .fx_w = 4 }, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = Fix.ldsCell };
    const Case = struct { width: u16, pv: view.PatternView, text: []const u8 };
    const cases = [_]Case{
        .{ .width = 112, .pv = rad, .text = "A12 R" },
        .{ .width = 118, .pv = rad, .text = "A12 R" },
        .{ .width = 103, .pv = lds, .text = "0C3F" },
        .{ .width = 108, .pv = lds, .text = "0C3F" },
    };
    const gpa = std.testing.allocator;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = case.width, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = case.width, .height = 14, .screen = &screen };
        var h = DrawHarness{};
        var ctx = h.context(win, .{ .pattern = case.pv }, arena.allocator(), 9);
        draw(&ctx);
        const lay = paneLayout(&ctx, case.pv);
        var buf: [118]u8 = undefined;
        try std.testing.expect(lay.chans != 0);
        try std.testing.expectEqual(@as(usize, lay.chans), std.mem.count(u8, testRowText(&screen, &buf, lay.pattern_top, case.width), case.text));
    }

    const fmt = @import("../format.zig");
    const hsc: view.PatternView = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .packed_event, .columns = &fmt.hsc_columns, .effect_style = .nibble, .cell_template = fmt.hsc_cell_template, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = HscFix.cell };
    try std.testing.expectEqual(@as(u16, 9), computeLayout(78, 14, hsc, 9, 0, null, false, null).chans);
}

test "paged channel columns hold as many whole cells as the pane fits" {
    const Fix = struct {
        fn hscCell(_: *anyopaque, _: u16, row: u16, _: u16) view.Cell {
            if (row != 0) return .{};
            return .{ .note = .{ .pitch = .{ .semitone = 1, .octave = 4 } }, .effects = .{ .{ .cmd = 0x12, .param = 0 }, .{} } };
        }
        fn a2mCell(_: *anyopaque, _: u16, row: u16, _: u16) view.Cell {
            if (row != 0) return .{};
            return .{ .note = .{ .pitch = .{ .semitone = 0, .octave = 4 } }, .instrument = 1, .effects = .{ .{ .cmd = 'C', .param = 0x20 }, .{ .cmd = '2', .param = 0x01 } } };
        }
    };
    const fmt = @import("../format.zig");
    const hsc: view.PatternView = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .packed_event, .columns = &fmt.hsc_columns, .effect_style = .nibble, .cell_template = fmt.hsc_cell_template, .channels = 9, .rows_per_pattern = 64, .num_patterns = 1, .cell = Fix.hscCell };
    const a2m: view.PatternView = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &a2m_columns, .effect_style = .letter_param, .cell_template = .{ .width = 15 }, .channels = 20, .rows_per_pattern = 64, .num_patterns = 1, .cell = Fix.a2mCell };
    const Case = struct { width: u16, pv: view.PatternView, chans: u16, text: []const u8 };
    const cases = [_]Case{
        .{ .width = 44, .pv = hsc, .chans = 5, .text = "C#4 12" },
        .{ .width = 75, .pv = hsc, .chans = 8, .text = "C#4 12" },
        .{ .width = 98, .pv = a2m, .chans = 6, .text = "C-4 01 C20 201" },
        .{ .width = 158, .pv = a2m, .chans = 10, .text = "C-4 01 C20 201" },
    };
    const gpa = std.testing.allocator;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = case.width, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = case.width, .height = 14, .screen = &screen };
        var h = DrawHarness{};
        var ctx = h.context(win, .{ .pattern = case.pv }, arena.allocator(), 9);
        draw(&ctx);
        const lay = paneLayout(&ctx, case.pv);
        var buf: [158]u8 = undefined;
        try std.testing.expectEqual(case.chans, lay.chans);
        try std.testing.expectEqual(@as(usize, case.chans), std.mem.count(u8, testRowText(&screen, &buf, lay.pattern_top, case.width), case.text));
    }
}

test "the auxiliary region keeps its kind and width while playback changes instrument" {
    const Bank = struct {
        fn get(_: *anyopaque, index: u16) view.InstrumentInfo {
            return .{ .name = "Lead", .patch = .{ .opl_2op = .{} }, .macros = .{ .fmreg_len = if (index == 1) 12 else 0 } };
        }
        fn step(_: *anyopaque, index: u16, kind: view.MacroKind, at: u16) view.MacroStep {
            return if (index == 1 and kind == .fmreg and at < 12) .{ .empty = false, .duration = 1 } else .{};
        }
    };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 22, .cols = 118, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    var small = try vaxis.Screen.init(gpa, .{ .rows = 15, .cols = 118, .x_pixel = 0, .y_pixel = 0 });
    defer small.deinit(gpa);
    var h = DrawHarness{};
    h.br.channels.write(.{ .channels = 18 });
    var ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 118, .height = 22, .screen = &screen }, .{
        .pattern = .{ .ctx = undefined, .grid = .shared_pattern, .occupancy = .independent, .columns = &a2m_columns, .effect_style = .letter_param, .cell_template = .{ .width = 14 }, .channels = 18, .rows_per_pattern = 64, .num_patterns = 1, .cell = PairedFix.cell },
        .instruments = .{ .ctx = undefined, .count = 3, .get = Bank.get, .macroStep = Bank.step },
    }, arena.allocator(), 18);
    var compact_ctx = h.context(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 118, .height = 15, .screen = &small }, ctx.views, arena.allocator(), 18);
    const pv = ctx.views.pattern.?;
    var buf: [118]u8 = undefined;
    var strip_x: ?u16 = null;
    for ([_]u16{ 1, 2, 1, 2 }) |inst| {
        h.br.playhead.write(.{ .last_instrument = inst });
        draw(&ctx);
        const lay = paneLayout(&ctx, pv);
        try std.testing.expect(lay.show_extra and lay.extra == .macros);
        try std.testing.expectEqualStrings("MACROS", testRowText(&screen, &buf, lay.top, 118)[lay.extra_x + 2 ..][0..6]);
        draw(&compact_ctx);
        const strip = paneLayout(&compact_ctx, pv);
        try std.testing.expect(strip.compact and strip.show_extra and strip.extra == .macros);
        try std.testing.expectEqual(strip_x orelse strip.extra_x, strip.extra_x);
        strip_x = strip.extra_x;
    }

    h.nav.tracker_focus = .macros;
    draw(&ctx);
    try std.testing.expectEqual(viz.TrackerFocus.macros, paneLayout(&ctx, pv).extra);
    _ = handleKey(&ctx, '`');
    try std.testing.expectEqual(viz.TrackerFocus.live, h.nav.tracker_focus);
}
