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

pub const name = "sequence";
pub const requires = view.ViewCaps{ .sequence = true };
pub const optional = view.ViewCaps{ .instruments = true };

const pat_gutter: u16 = 5;
const chan_min_w: u16 = 8;
const cell_text_w: u16 = 6;
const event_buf_len: usize = 512;

const CellKind = enum {
    empty,
    note,
    duration_note,
    note_off,
    program,
    jump,
    label,
    control,
    bend,
    tempo,
    sysex,
    start_program,
    aftertouch,
    wait,
    end,
};

const GridCell = struct {
    kind: CellKind = .empty,
    note: u8 = 0,
    arg: u32 = 0,
    program: u16 = view.sequence_unassigned,
    vel: u8 = 127,
    notes: std.bit_set.Integer(128) = .empty,
    branch: ?Branch = null,
};

const Branch = @FieldType(view.EventPayload, "branch");

const Layout = struct {
    compact: bool,
    show_live: bool,
    show_ctrl: bool,
    show_spectrum: bool,
    bar_w: u16,
    spectrum_w: u16,
    spectrum_x: u16,
    track_x: u16,
    info_row: u16,
    pattern_head_row: u16,
    pattern_top: u16,
    pattern_end: u16,
    show_pattern: bool,
    pat_x: u16,
    chans: u16,
    chan0: u16,
    voice_count: u16,
    spec_n: u16,
    control_id: ?u16,
    ctrl_w: u16,
    structure: bool,
    spec_ids: [view.max_pattern_channels]u16,
    grid_ids: [view.max_pattern_channels]u16,
    col_x: [view.max_pattern_channels]u16,
    col_w: [view.max_pattern_channels]u16,
};

const GridPlan = struct {
    ids: [view.max_pattern_channels]u16 = @splat(0),
    n: u16 = 0,
    control: ?u16 = null,
    flow: bool = false,
    structure: bool = false,
};

fn gridPlan(sv: view.SequenceView) GridPlan {
    var p = GridPlan{
        .flow = sv.kind == .event_stream or sv.kind == .linear_midi,
        .structure = sv.markerAt != null and sv.marker_count != 0,
    };
    var i: u16 = 0;
    while (i < sv.track_count and p.n < view.max_pattern_channels) : (i += 1) {
        const tr = sv.track(sv.ctx, i);
        if (tr.kind == .control) {
            if (p.control == null) p.control = i;
            continue;
        }
        p.ids[p.n] = i;
        p.n += 1;
    }
    return p;
}

fn visRows(lay: Layout) u16 {
    return lay.pattern_end -| lay.pattern_top;
}

fn visiblePage(n: u16, page: u16, count: u16) u16 {
    if (n == 0 or count == 0) return 0;
    var start = @min(page, n -| 1);
    if (start + count > n) start = n - count;
    return start;
}

fn computeLayout(w: u16, h: u16, plan: GridPlan, page: u16) Layout {
    const compact = h < 10;
    const top_h: u16 = if (compact) 1 else if (h < 20) @min(7, h / 2) else common.top_rows;
    const structure = plan.structure and plan.control == null;
    const ctrl_w = if (structure) structure_w else common.order_w;
    const wants_ctrl = plan.control != null or plan.flow or structure;
    const spec_room = if (wants_ctrl) @min(w / 2, @max(w -| 42, (w -| ctrl_w) / 2)) else w / 2;
    var bar_w = common.spectrumBarWidth(w);
    const spec_n: u16 = @min(if (plan.n == 0) 9 else plan.n, @max(1, (spec_room -| 5) / 2));
    if (spec_n > 9) bar_w = @max(bar_w, 2);
    while (common.spectrumPanelWidth(bar_w, spec_n) > spec_room and bar_w > 1) bar_w -= 1;
    const spectrum_w = common.spectrumPanelWidth(bar_w, spec_n);
    const spectrum_x = w -| spectrum_w;
    const show_spectrum = w >= 44;
    const show_ctrl = wants_ctrl and show_spectrum;
    const track_x: u16 = if (show_ctrl) spectrum_x -| ctrl_w else spectrum_x;
    const show_live = true;

    const info_row: u16 = top_h;
    const pattern_head_row = info_row + 1;
    const pattern_top = pattern_head_row + 1;
    const pattern_end = h;
    const show_pattern = pattern_end > pattern_top;

    var col_x: [view.max_pattern_channels]u16 = @splat(0);
    var col_w: [view.max_pattern_channels]u16 = @splat(0);
    var grid_ids: [view.max_pattern_channels]u16 = @splat(0);
    var chans: u16 = 0;
    var chan0: u16 = 0;
    const n_total = plan.n;
    const avail = w -| pat_gutter;
    if (n_total > 0 and avail >= chan_min_w) {
        if (avail / n_total >= chan_min_w) {
            chans = n_total;
            chan0 = 0;
        } else {
            chans = @max(1, avail / chan_min_w);
            chan0 = visiblePage(n_total, page, chans);
        }
        var i: u16 = 0;
        while (i < chans) : (i += 1) {
            grid_ids[i] = plan.ids[chan0 + i];
        }
        common.fillChannelCols(&col_x, &col_w, w, pat_gutter, chans);
    }

    var spec_ids: [view.max_pattern_channels]u16 = @splat(0);
    const spec_first = visiblePage(plan.n, page, @min(spec_n, plan.n));
    for (0..@min(spec_n, plan.n)) |i| spec_ids[i] = plan.ids[spec_first + i];

    return .{
        .compact = compact,
        .show_live = show_live,
        .show_ctrl = show_ctrl,
        .show_spectrum = show_spectrum,
        .bar_w = bar_w,
        .spectrum_w = spectrum_w,
        .spectrum_x = spectrum_x,
        .track_x = track_x,
        .info_row = info_row,
        .pattern_head_row = pattern_head_row,
        .pattern_top = pattern_top,
        .pattern_end = pattern_end,
        .show_pattern = show_pattern,
        .pat_x = 0,
        .chans = chans,
        .chan0 = chan0,
        .voice_count = n_total,
        .spec_n = spec_n,
        .control_id = plan.control,
        .ctrl_w = ctrl_w,
        .structure = structure,
        .spec_ids = spec_ids,
        .grid_ids = grid_ids,
        .col_x = col_x,
        .col_w = col_w,
    };
}

fn mapSpecLevels(
    ctx: *viz.DrawContext,
    lay: Layout,
    levels: *[view.max_pattern_channels]f32,
    peaks: *[view.max_pattern_channels]f32,
    glow: *[view.max_pattern_channels]f32,
) usize {
    const n: usize = @min(@as(usize, lay.spec_n), view.max_pattern_channels);
    const bank = ctx.bridge.sequence.read();
    if (bank.channels == 0) return n;
    for (0..@min(n, lay.voice_count)) |i| {
        const level = channelLevel(ctx, bank, lay.spec_ids[i]);
        levels[i] = level.level;
        peaks[i] = level.peak;
        glow[i] = level.glow;
    }
    return n;
}

const ChannelLevel = struct { level: f32 = 0, peak: f32 = 0, glow: f32 = 0 };

fn channelLevel(ctx: *const viz.DrawContext, bank: view.SequenceStateBank, id: u16) ChannelLevel {
    var out = ChannelLevel{};
    if (bank.voice_count == 0) {
        const slot = slotAt(bank, id) orelse return out;
        if (slot.opl_voice >= ctx.spec_levels.len) return out;
        return .{
            .level = ctx.spec_levels[slot.opl_voice],
            .peak = ctx.spec_peaks[slot.opl_voice],
            .glow = ctx.spec_peak_glow[slot.opl_voice],
        };
    }
    for (bank.voices[0..@min(bank.voice_count, bank.voices.len)]) |voice| {
        if (voice.channel != id) continue;
        if (voice.kind == .pcm) {
            const level = @as(f32, @floatFromInt(voice.level)) / 255;
            out.level = @max(out.level, level);
            out.peak = @max(out.peak, level);
            continue;
        }
        if (voice.opl_voice >= ctx.spec_levels.len) continue;
        out.level = @max(out.level, ctx.spec_levels[voice.opl_voice]);
        out.peak = @max(out.peak, ctx.spec_peaks[voice.opl_voice]);
        out.glow = @max(out.glow, ctx.spec_peak_glow[voice.opl_voice]);
    }
    return out;
}

fn liveShown(lay: Layout, n: u16) u16 {
    const body = lay.info_row -| 1;
    if (body == 0) return n;
    const columns = @min(@max(1, (n + body - 1) / body), @max(1, lay.track_x / 16));
    return @min(n, body * columns);
}

fn compactEntryWidth(n: u16) u16 {
    return if (n >= 10) 8 else 7;
}

fn compactCount(w: u16, n: u16) u16 {
    return @min(n, (w -| 8) / compactEntryWidth(n));
}

fn pageWindow(sv: view.SequenceView, lay: Layout, w: u16, n: u16) u16 {
    var span = n;
    if (sv.kind != .event_stream and lay.chans != 0) span = @min(span, lay.chans);
    if (lay.compact) {
        span = @min(span, compactCount(w, n));
    } else {
        span = @min(span, liveShown(lay, n));
        if (lay.show_spectrum) span = @min(span, lay.spec_n);
    }
    return @max(1, span);
}

fn slotAt(bank: view.SequenceStateBank, ch: u16) ?view.SequenceChannelState {
    if (ch >= @min(bank.channels, bank.slots.len)) return null;
    return bank.slots[ch];
}

fn bytecodeFrom(nav: *const viz.Navigation, bank: view.SequenceStateBank, ch: u16) u32 {
    if (nav.sequence_scroll != null and ch < nav.sequence_pcs.len) return nav.sequence_pcs[ch];
    return slotPc(bank, ch);
}

fn pinStartedVoices(nav: *viz.Navigation, bank: view.SequenceStateBank) void {
    if (nav.sequence_scroll == null) return;
    for (&nav.sequence_pcs, 0..) |*pc, ch| {
        if (pc.* == view.sequence_pc_none) pc.* = slotPc(bank, @intCast(ch));
    }
}

fn slotPc(bank: view.SequenceStateBank, ch: u16) u32 {
    const slot = slotAt(bank, ch) orelse return view.sequence_pc_none;
    return slot.pc;
}

fn tickLast(sv: view.SequenceView, rows: u16) u32 {
    return (sv.length_ticks +| 1) -| rows;
}

fn scrollLast(sv: view.SequenceView, nav: *const viz.Navigation, bank: view.SequenceStateBank, lay: Layout) u32 {
    const rows = visRows(lay);
    if (sv.kind == .event_stream) return sv.event_count -| rows;
    if (sv.eventsInRange != null) return tickLast(sv, rows);
    const fn_bc = sv.bytecodeWindow orelse return sv.event_count -| rows;
    var dest: [1]view.SequenceEvent = undefined;
    var max_rem: u32 = 0;
    for (lay.grid_ids[0..lay.chans]) |ch| {
        const range = fn_bc(sv.ctx, ch, bytecodeFrom(nav, bank, ch), dest[0..]);
        if (range.total_in_range > max_rem) max_rem = range.total_in_range;
    }
    return max_rem -| 1;
}

fn eventPosition(sv: view.SequenceView, tick: u32) u32 {
    if (sv.position_unit == .event_index) return @min(tick, sv.event_count -| 1);
    const at = sv.eventAt orelse return 0;
    var lo: u32 = 0;
    var hi = sv.event_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (at(sv.ctx, mid).tick <= tick) lo = mid + 1 else hi = mid;
    }
    return lo -| 1;
}

pub fn handleKey(ctx: *viz.DrawContext, key: u21) viz.KeyResult {
    const sv = ctx.views.sequence orelse return .ignored;
    const plan = gridPlan(sv);
    const lay = computeLayout(
        ctx.win.width,
        ctx.win.height,
        plan,
        ctx.nav.channel_page,
    );
    switch (key) {
        vaxis.Key.left, vaxis.Key.kp_left => {
            const max_start = plan.n -| pageWindow(sv, lay, ctx.win.width, plan.n);
            ctx.nav.channel_page = @min(ctx.nav.channel_page, max_start) -| 1;
            return .handled;
        },
        vaxis.Key.right, vaxis.Key.kp_right => {
            const max_start = plan.n -| pageWindow(sv, lay, ctx.win.width, plan.n);
            if (ctx.nav.channel_page < max_start) ctx.nav.channel_page += 1;
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
    const bank = ctx.bridge.sequence.read();
    if (ctx.nav.sequence_scroll == null and dir != std.math.minInt(i32)) {
        for (&ctx.nav.sequence_pcs, 0..) |*pc, ch| pc.* = slotPc(bank, @intCast(ch));
    }
    pinStartedVoices(ctx.nav, bank);
    const last = scrollLast(sv, ctx.nav, bank, lay);
    if (dir == std.math.minInt(i32)) {
        ctx.nav.sequence_scroll = null;
        return .handled;
    }
    if (dir == std.math.maxInt(i32)) {
        ctx.nav.sequence_scroll = last;
        return .handled;
    }
    const from: i64 = if (ctx.nav.sequence_scroll) |at| @min(at, last) else followOrigin(sv, ctx.bridge.playhead.read(), visRows(lay));
    ctx.nav.sequence_scroll = @intCast(std.math.clamp(from + dir, 0, last));
    return .handled;
}

fn followOrigin(sv: view.SequenceView, ph: view.Playhead, rows: u16) u32 {
    if (sv.kind != .event_stream) {
        if (sv.eventsInRange != null) return tickOrigin(@min(ph.tick -| rows / 2, tickLast(sv, rows)), rows);
        if (sv.bytecodeWindow != null) return 0;
    }
    return @min(eventPosition(sv, ph.tick) -| rows / 2, sv.event_count -| rows);
}

fn tickOrigin(origin: u32, rows: u16) u32 {
    return @min(origin, std.math.maxInt(u32) - @as(u32, rows));
}

pub fn draw(ctx: *viz.DrawContext) void {
    const sv = ctx.views.sequence orelse {
        paint.printAt(ctx.win, 1, 0, "sequence visualizer requires a sequence view", ctx.theme.style(.viz_notice));
        return;
    };
    const w = ctx.win.width;
    const h = ctx.win.height;
    if (w == 0 or h == 0) return;

    const ph = ctx.bridge.playhead.read();
    if (!ctx.nav.instrument_sel_user) ctx.nav.instrument_sel = ph.last_instrument;
    if (ctx.views.instruments) |bank| {
        if (bank.count != 0) ctx.nav.instrument_sel = @min(ctx.nav.instrument_sel, bank.count - 1);
    }
    const lay = computeLayout(w, h, gridPlan(sv), ctx.nav.channel_page);

    const compact_voices = lay.compact;
    if (compact_voices) drawCompactVoices(ctx, sv) else if (lay.show_live) drawLiveRegion(ctx, sv, ph, lay);
    if (lay.show_ctrl and !compact_voices) drawCtrlRegion(ctx, sv, ph, lay);
    if (lay.show_spectrum and !compact_voices) {
        {
            var levels: [view.max_pattern_channels]f32 = @splat(0);
            var peaks: [view.max_pattern_channels]f32 = @splat(0);
            var glow: [view.max_pattern_channels]f32 = @splat(0);
            const n = mapSpecLevels(ctx, lay, &levels, &peaks, &glow);
            common.drawSpectrum(
                ctx.win,
                ctx.theme,
                lay.spectrum_x,
                0,
                lay.spectrum_w,
                lay.bar_w,
                levels[0..n],
                peaks[0..n],
                glow[0..n],
                .{ .height = lay.info_row, .channel_ids = lay.spec_ids[0..n] },
            );
        }
    }
    drawInfo(ctx, sv, ph, lay);
    if (lay.show_pattern) {
        if (sv.kind == .event_stream) drawEventList(ctx, sv, ph, lay) else drawGrid(ctx, sv, ph, lay);
    }
}

fn drawCompactVoices(ctx: *viz.DrawContext, sv: view.SequenceView) void {
    const plan = gridPlan(sv);
    const count = compactCount(ctx.win.width, plan.n);
    paint.printFit(ctx.win, 1, 0, "VOICES", ctx.win.width -| 1, ctx.theme.style(.seq_track));
    if (count == 0) return;
    const first = visiblePage(plan.n, ctx.nav.channel_page, count);
    const width = (ctx.win.width -| 8) / count;
    const bank = ctx.bridge.sequence.read();
    const bars = [_][]const u8{ "·", "▁", "▂", "▃", "▄", "▅", "▆", "█" };
    for (0..count) |i| {
        const id = plan.ids[first + i];
        const slot = slotAt(bank, id) orelse continue;
        const token = compactToken(ctx.arena, bank, id, slot);
        const bar: usize = @intFromFloat(@round(std.math.clamp(channelLevel(ctx, bank, id).level, 0, 1) * 7));
        const line = ctx.arena.print("{d}:{s}{s}", .{ id + 1, token, bars[bar] }) catch return;
        const keyed = !std.mem.eql(u8, token, "---");
        paint.printFit(ctx.win, @intCast(8 + i * width), 0, line, width -| 1, if (keyed) ctx.theme.style(.voice_key_on) else ctx.theme.style(.voice_key_off));
    }
}

fn compactToken(a: std.mem.Allocator, bank: view.SequenceStateBank, id: u16, slot: view.SequenceChannelState) []const u8 {
    if (bank.voice_count == 0) {
        if (!slot.keyed) return "---";
        return a.dupe(u8, &midiToken(slot.note)) catch "---";
    }
    for (bank.voices[0..@min(bank.voice_count, bank.voices.len)]) |voice| {
        if (voice.channel != id or !voice.keyed) continue;
        if (voice.kind == .pcm) return "PCM";
        return a.dupe(u8, &midiToken(voice.note)) catch "---";
    }
    return "---";
}

const roll_ms_per_column: u32 = 40;
const roll_gap: u16 = 2;
const roll_min_w: u16 = 16;
const roll_event_cap: usize = 4096;

const RowGeometry = struct {
    meter_x: u16,
    meter_w: u16,
    roll_x: u16,
    roll_w: u16,
};

fn rowGeometry(fit: u16, kind: view.SequenceKind) RowGeometry {
    const meter_w: u16 = if (kind != .voice_programs and fit >= 16) @min(12, fit - 12) else 0;
    const text_w: u16 = if (kind == .event_stream) 12 else 28;
    const meter_x = if (meter_w != 0) @min(text_w, fit - meter_w) else fit;
    const roll_x = meter_x + meter_w + roll_gap;
    const roll_w = if (kind == .event_stream and meter_w != 0 and fit >= roll_x + roll_min_w) fit - roll_x else 0;
    return .{ .meter_x = meter_x, .meter_w = meter_w, .roll_x = roll_x, .roll_w = roll_w };
}

const RollSpan = struct { start: u32, end: u32, note: u8 };

const RollVoice = struct {
    spans: []RollSpan = &.{},
    n: u16 = 0,
    open_start: u32 = 0,
    open_note: ?u8 = null,

    fn push(self: *RollVoice, roll: *const Roll, start: u32, end: u32, note: u8) void {
        if (end <= start or end <= roll.t0 or start >= roll.t1) return;
        if (self.n != 0) {
            const prev = &self.spans[self.n - 1];
            if (roll.column(@max(prev.start, roll.t0)) == roll.column(@max(start, roll.t0))) {
                prev.end = @max(prev.end, end);
                return;
            }
        }
        if (self.n == self.spans.len) return;
        self.spans[self.n] = .{ .start = start, .end = end, .note = note };
        self.n += 1;
    }

    fn close(self: *RollVoice, roll: *const Roll, at: u32) void {
        const note = self.open_note orelse return;
        self.open_note = null;
        self.push(roll, self.open_start, at, note);
    }
};

const Roll = struct {
    t0: u32,
    t1: u32,
    now: u32,
    width: u16,
    voices: [view.max_pattern_channels]RollVoice = @splat(.{}),

    fn column(self: *const Roll, tick: u32) u16 {
        const offset: u64 = @min(tick, self.t1 - 1) -| self.t0;
        return @intCast(offset * self.width / (self.t1 - self.t0));
    }
};

fn rollNow(sv: view.SequenceView, ph: view.Playhead) u32 {
    if (sv.position_unit == .tick) return ph.tick;
    const at = sv.eventAt orelse return 0;
    if (sv.event_count == 0) return 0;
    return at(sv.ctx, eventPosition(sv, ph.tick)).tick;
}

fn rollEvents(a: std.mem.Allocator, sv: view.SequenceView, from: u32, to: u32) []const view.SequenceEvent {
    if (sv.eventsInRange) |range| {
        const dest = a.alloc(view.SequenceEvent, roll_event_cap) catch return &.{};
        const got = range(sv.ctx, from, to, dest);
        return dest[0..@min(got.written, dest.len)];
    }
    const at = sv.eventAt orelse return &.{};
    var lo: u32 = 0;
    var hi = sv.event_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (at(sv.ctx, mid).tick < from) lo = mid + 1 else hi = mid;
    }
    var list = std.ArrayList(view.SequenceEvent).initCapacity(a, roll_event_cap) catch return &.{};
    var index = lo;
    while (index < sv.event_count and list.items.len < roll_event_cap) : (index += 1) {
        const ev = at(sv.ctx, index);
        if (ev.tick >= to) break;
        list.appendAssumeCapacity(ev);
    }
    return list.items;
}

fn buildRoll(a: std.mem.Allocator, sv: view.SequenceView, ph: view.Playhead, width: u16) ?*Roll {
    const now = rollNow(sv, ph);
    const rate: u64 = @max(1, sv.tick_rate);
    const span: u32 = @intCast(@min(std.math.maxInt(u32), @max(width, rate * width * roll_ms_per_column / 1000)));
    const t0 = now -| span / 2;
    const roll = a.create(Roll) catch return null;
    roll.* = .{ .t0 = t0, .t1 = t0 +| span, .now = now, .width = width };
    if (roll.t1 == roll.t0) return null;
    for (&roll.voices) |*voice| voice.spans = a.alloc(RollSpan, width) catch return null;
    for (rollEvents(a, sv, t0 -| span, roll.t1)) |ev| {
        if (ev.track >= roll.voices.len) continue;
        const voice = &roll.voices[ev.track];
        switch (ev.kind) {
            .note_on => {
                voice.close(roll, ev.tick);
                if (ev.payload == .note) {
                    voice.open_start = ev.tick;
                    voice.open_note = ev.payload.note.note;
                }
            },
            .duration_note => {
                voice.close(roll, ev.tick);
                if (ev.payload == .note) {
                    const note = ev.payload.note;
                    voice.push(roll, ev.tick, ev.tick +| (note.duration_ticks orelse 1), note.note);
                }
            },
            .note_off => voice.close(roll, ev.tick),
            else => {},
        }
    }
    for (&roll.voices) |*voice| voice.close(roll, roll.t1);
    return roll;
}

fn drawRollScale(ctx: *viz.DrawContext, roll: *const Roll, rate: u32, x: u16, width: u16) void {
    const style = ctx.theme.style(.info_dim);
    const hz: f32 = @floatFromInt(@max(1, rate));
    const back = ctx.arena.print("-{d:.1}s", .{@as(f32, @floatFromInt(roll.now - roll.t0)) / hz}) catch return;
    const ahead = ctx.arena.print("+{d:.1}s", .{@as(f32, @floatFromInt(roll.t1 - roll.now)) / hz}) catch return;
    paint.printAt(ctx.win, x, 0, back, style);
    paint.printAt(ctx.win, x + width -| paint.textWidth(ctx.win, ahead), 0, ahead, style);
    paint.printAt(ctx.win, x + roll.column(roll.now), 0, "▼", ctx.theme.style(.order_cur));
}

fn drawRoll(ctx: *viz.DrawContext, roll: *const Roll, voice: u16, x: u16, row: u16, width: u16) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const glyphs = a.alloc([]const u8, width) catch return;
    const styles = a.alloc(vaxis.Style, width) catch return;
    @memset(glyphs, " ");
    @memset(styles, .{});
    if (voice < roll.voices.len) {
        const lane = &roll.voices[voice];
        for (lane.spans[0..lane.n], 0..) |span, i| {
            const first = roll.column(@max(span.start, roll.t0));
            const last = roll.column(span.end - 1);
            const style = if (span.end <= roll.now)
                t.style(.voice_key_off)
            else if (span.start <= roll.now)
                t.style(.voice_key_on)
            else
                t.style(.note);
            for (first..last + 1) |c| {
                glyphs[c] = "━";
                styles[c] = style;
            }
            if (span.start >= roll.t0) glyphs[first] = "╺";
            const limit = if (i + 1 < lane.n) roll.column(lane.spans[i + 1].start) else width;
            if (span.start < roll.t0 or limit < first + 4) continue;
            const token = a.dupe(u8, &midiToken(span.note)) catch continue;
            for (0..3) |k| {
                glyphs[first + k] = token[k..][0..1];
                styles[first + k] = style;
            }
        }
    }
    const now_col = roll.column(roll.now);
    if (std.mem.eql(u8, glyphs[now_col], " ")) {
        glyphs[now_col] = "│";
        styles[now_col] = t.style(.order_cur);
    }
    for (glyphs, styles, 0..) |glyph, style, c| {
        if (std.mem.eql(u8, glyph, " ")) continue;
        ctx.win.writeCell(x + @as(u16, @intCast(c)), row, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
    }
}

fn drawLiveRegion(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const plan = gridPlan(sv);
    const n = plan.n;
    if (n == 0 or lay.track_x < 8) return;
    const bank = ctx.bridge.sequence.read();
    const title_kind: []const u8 = switch (sv.kind) {
        .linear_midi => "MIDI",
        .voice_programs, .event_stream => "VOICES",
    };
    const title = a.print("{s} {d}", .{ title_kind, n }) catch return;
    paint.printAt(ctx.win, 1, 0, title, t.style(.seq_track));
    if (ctx.views.instruments) |ib| {
        const idx = if (ib.count == 0) 0 else @min(ctx.nav.instrument_sel, ib.count -| 1);
        const badge = a.print("I{X:0>2}/{d}", .{ idx, ib.count }) catch "";
        paint.printFit(ctx.win, @intCast(@min(title.len + 2, 24)), 0, badge, 10, t.style(.inst_title));
    }
    if (lay.compact) return;

    const body = lay.info_row -| 1;
    const columns = @min(@max(1, (n + body - 1) / body), @max(1, lay.track_x / 16));
    const shown = liveShown(lay, n);
    const first = visiblePage(n, ctx.nav.channel_page, shown);
    const per = (shown + columns - 1) / columns;
    const col_w = @max(8, (lay.track_x -| 1) / columns);
    const geometry = rowGeometry(col_w -| 1, sv.kind);
    const roll = if (geometry.roll_w != 0) buildRoll(a, sv, ph, geometry.roll_w) else null;
    if (roll) |r| {
        if (columns == 1) drawRollScale(ctx, r, sv.tick_rate, 1 + geometry.roll_x, geometry.roll_w);
    }

    var i: u16 = 0;
    while (i < shown) : (i += 1) {
        const id = plan.ids[first + i];
        const tr = sv.track(sv.ctx, id);
        const sl = slotAt(bank, id) orelse view.SequenceChannelState{ .program = tr.program };
        var remaining: u32 = 0;
        if (sv.kind == .voice_programs) {
            if (sv.bytecodeWindow) |fn_bc| {
                var dest: [1]view.SequenceEvent = undefined;
                remaining = fn_bc(sv.ctx, id, sl.pc, dest[0..]).total_in_range;
            }
        }
        const line = std.mem.trimEnd(u8, if (bank.voice_count != 0) chordLine(a, bank, id, sl) else liveLine(a, sv.kind, id, tr, sl, remaining, col_w < 40), " ");
        const col_i = i / per;
        const row_i = i % per;
        const x = 1 + col_i * col_w;
        const row = 1 + row_i;
        if (row >= lay.info_row) break;
        const style = if (!tr.in_use)
            t.style(.order_skip)
        else if (sl.keyed)
            t.style(.voice_key_on)
        else if (tr.kind == .drum)
            t.style(.ch_drum)
        else
            t.style(.voice_key_off);
        const fit = col_w -| 1;
        const meter_w = geometry.meter_w;
        const meter_x = geometry.meter_x;
        paint.printFit(ctx.win, x, row, line, meter_x -| @intFromBool(meter_w != 0), style);
        if (col_i != 0) drawSeparator(ctx.win, t, x - 1, row, false);
        if (meter_w != 0) {
            const level = channelLevel(ctx, bank, id);
            _ = common.drawVuMeter(ctx.win, t, x + meter_x, row, meter_w, level.level, level.peak);
        }
        if (roll) |r| drawRoll(ctx, r, id, x + geometry.roll_x, row, geometry.roll_w);
        if (sv.kind == .voice_programs and sl.pc != view.sequence_pc_none) {
            const used = paint.textWidth(ctx.win, line);
            if (fit > used + 1) {
                drawWaitBar(ctx.win, x + used + 1, row, fit - used - 1, sl.duration, style);
            }
        }
    }
}

fn chordLine(a: std.mem.Allocator, bank: view.SequenceStateBank, channel: u16, slot: view.SequenceChannelState) []const u8 {
    var buf: [384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (slot.program == view.instrument_none) {
        w.print("{d: >2} I-- ", .{channel + 1}) catch return "";
    } else w.print("{d: >2} I{X:0>2} ", .{ channel + 1, slot.program }) catch return "";
    var count: usize = 0;
    for (bank.voices[0..@min(bank.voice_count, bank.voices.len)]) |voice| {
        if (voice.channel != channel or !voice.keyed) continue;
        if (voice.kind == .pcm) {
            w.writeAll("PCM ") catch break;
        } else w.print("{s} ", .{midiToken(voice.note)}) catch break;
        count += 1;
    }
    if (count == 0) w.writeAll("---") catch return "";
    return a.dupe(u8, w.buffered()) catch "";
}

fn drawWaitBar(win: vaxis.Window, x: u16, row: u16, width: u16, duration: u8, style: vaxis.Style) void {
    if (width == 0) return;
    const filled: u16 = if (duration == 0)
        0
    else
        @intCast((@as(u32, duration) * width + 127) / 255);
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        win.writeCell(x + i, row, .{
            .char = .{ .grapheme = if (i < filled) common.peak_on else "·", .width = 1 },
            .style = style,
        });
    }
}

fn liveLine(
    a: std.mem.Allocator,
    kind: view.SequenceKind,
    id: u16,
    tr: view.SequenceTrack,
    sl: view.SequenceChannelState,
    remaining: u32,
    brief: bool,
) []const u8 {
    var buf: [48]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d: >2} ", .{id + 1}) catch return "";
    if (sl.program == 0xffff) {
        w.writeAll("I-- ") catch return "";
    } else {
        w.print("I{X:0>2} ", .{sl.program}) catch return "";
    }
    if (sl.keyed) {
        const tok = midiToken(sl.note);
        w.print("{s} ", .{tok[0..]}) catch return "";
    } else {
        w.writeAll("--- ") catch return "";
    }
    switch (kind) {
        .linear_midi => {
            if (sl.opl_voice < view.max_opl_voices) {
                w.print("v{d}", .{sl.opl_voice}) catch return "";
            } else if (tr.kind == .drum) {
                w.writeAll("DR") catch return "";
            } else {
                w.writeAll("--") catch return "";
            }
        },
        .voice_programs => {
            if (brief) {
                if (sl.pc != view.sequence_pc_none) w.print("D{X:0>2}", .{sl.duration}) catch return "";
            } else if (sl.pc != view.sequence_pc_none) {
                w.print("D{X:0>2} T{X:0>2} P{X:0>2} S{d} {X:0>3} ", .{
                    sl.duration,
                    sl.chan_tempo,
                    sl.priority,
                    sl.stack,
                    @as(u16, @intCast(@min(remaining, 0xfff))),
                }) catch return "";
                w.writeAll(if (sl.fx.slide) "s" else "-") catch return "";
                w.writeAll(if (sl.fx.vibrato) "v" else "-") catch return "";
                w.writeAll(if (sl.fx.modulate) "m" else "-") catch return "";
            } else {
                w.writeAll("--- --- --- -- --- ---") catch return "";
            }
        },
        .event_stream => {},
    }
    return a.dupe(u8, w.buffered()) catch "";
}

const ctrl_rows: u16 = 12;
const structure_w: u16 = 16;
const ctrl_span: u32 = 1024;
const ctrl_min_span: u32 = 32;

const CtrlPick = struct { n: u16 = 0, cur: ?u16 = null };

fn ctrlMatches(sv: view.SequenceView, ev: view.SequenceEvent, control_id: ?u16) bool {
    const col = eventCol(ev, sv.track_count);
    const cid = control_id orelse return col == null;
    return col == null or col.? == cid;
}

fn pickProgramCtrl(ctx: *viz.DrawContext, sv: view.SequenceView, cid: u16, vis: u16, cells: *[ctrl_rows]GridCell) CtrlPick {
    var dest: [event_buf_len]view.SequenceEvent = undefined;
    const range = sv.bytecodeWindow.?(sv.ctx, cid, slotPc(ctx.bridge.sequence.read(), cid), dest[0..]);
    var out = CtrlPick{};
    for (dest[0..@min(range.written, dest.len)]) |ev| {
        if (out.n >= vis) break;
        applyEvent(&cells[out.n], ev);
        out.n += 1;
    }
    if (out.n != 0) out.cur = 0;
    return out;
}

fn pickRangeCtrl(sv: view.SequenceView, ph: view.Playhead, control_id: ?u16, vis: u16, cells: *[ctrl_rows]GridCell) CtrlPick {
    var dest: [event_buf_len]view.SequenceEvent = undefined;
    var span = ctrl_span;
    var range = sv.eventsInRange.?(sv.ctx, ph.tick -| span, ph.tick +| span, dest[0..]);
    while (range.total_in_range > range.written and span > ctrl_min_span) {
        span /= 2;
        range = sv.eventsInRange.?(sv.ctx, ph.tick -| span, ph.tick +| span, dest[0..]);
    }
    var matches: [event_buf_len]u16 = undefined;
    var m: u16 = 0;
    var last_due: ?u16 = null;
    for (dest[0..@min(range.written, dest.len)], 0..) |ev, i| {
        if (!ctrlMatches(sv, ev, control_id)) continue;
        if (ev.tick <= ph.tick) last_due = m;
        matches[m] = @intCast(i);
        m += 1;
    }
    const first = if (last_due) |due| @min(due -| vis / 2, m -| vis) else 0;
    var out = CtrlPick{};
    while (out.n < vis and first + out.n < m) : (out.n += 1) applyEvent(&cells[out.n], dest[matches[first + out.n]]);
    if (last_due) |due| out.cur = due - first;
    return out;
}

fn pickIndexedCtrl(sv: view.SequenceView, ph: view.Playhead, control_id: ?u16, vis: u16, cells: *[ctrl_rows]GridCell) CtrlPick {
    const at = sv.eventAt.?;
    if (sv.event_count == 0) return .{};
    const pos = eventPosition(sv, ph.tick);
    var back: [ctrl_rows]view.SequenceEvent = undefined;
    var nb: u16 = 0;
    var index = pos +| 1;
    var steps: usize = 0;
    while (index > 0 and nb < vis / 2 + 1 and steps < event_buf_len) : (steps += 1) {
        index -= 1;
        const ev = at(sv.ctx, index);
        if (!ctrlMatches(sv, ev, control_id)) continue;
        back[nb] = ev;
        nb += 1;
    }
    var out = CtrlPick{};
    while (out.n < nb) : (out.n += 1) applyEvent(&cells[out.n], back[nb - 1 - out.n]);
    if (nb != 0) out.cur = nb - 1;
    index = pos +| 1;
    steps = 0;
    while (index < sv.event_count and out.n < vis and steps < event_buf_len) : ({
        index += 1;
        steps += 1;
    }) {
        const ev = at(sv.ctx, index);
        if (!ctrlMatches(sv, ev, control_id)) continue;
        applyEvent(&cells[out.n], ev);
        out.n += 1;
    }
    return out;
}

fn currentMarker(sv: view.SequenceView, position: u32) ?u32 {
    const at = sv.markerAt orelse return null;
    var lo: u32 = 0;
    var hi = sv.marker_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (at(sv.ctx, mid).position <= position) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) null else lo - 1;
}

fn drawStructure(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout, vis: u16) void {
    const t = ctx.theme;
    const at = sv.markerAt orelse return;
    const position = if (sv.position_unit == .event_index) eventPosition(sv, ph.tick) else ph.tick;
    const cur = currentMarker(sv, position);
    const first = if (cur) |c| @min(c -| vis / 2, sv.marker_count -| vis) else 0;
    var row: u16 = 0;
    while (row < vis and first + row < sv.marker_count) : (row += 1) {
        const index = first + row;
        const marker = at(sv.ctx, index);
        const is_cur = cur == index;
        if (is_cur) {
            var x: u16 = lay.track_x;
            while (x < lay.track_x + lay.ctrl_w and x < ctx.win.width) : (x += 1) {
                ctx.win.writeCell(x, 1 + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = t.style(.pat_cursor_fill),
                });
            }
        }
        const base = switch (marker.event.kind) {
            .label => t.style(.order_row),
            .end => t.style(.order_skip),
            else => t.style(.fx_cell),
        };
        const line = ctx.arena.print("{s} {s: <7} {X:0>4}", .{
            if (is_cur) "▶" else " ",
            markerText(ctx.arena, marker.event),
            marker.position,
        }) catch return;
        paint.printFit(ctx.win, lay.track_x + 1, 1 + row, line, lay.ctrl_w -| 2, t.rowStyle(is_cur, base));
    }
}

fn drawCtrlRegion(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout) void {
    const t = ctx.theme;
    const title: []const u8 = if (lay.control_id != null) "CTRL" else "FLOW";
    paint.printAt(ctx.win, lay.track_x + 3, 0, title, t.style(.order_title));
    if (lay.compact) return;
    const vis: u16 = @min(ctrl_rows, lay.info_row -| 1);
    if (lay.structure) {
        drawStructure(ctx, sv, ph, lay, vis);
        return;
    }
    var cells: [ctrl_rows]GridCell = @splat(.{});
    const picked = if (lay.control_id != null and sv.bytecodeWindow != null)
        pickProgramCtrl(ctx, sv, lay.control_id.?, vis, &cells)
    else if (sv.eventsInRange != null)
        pickRangeCtrl(sv, ph, lay.control_id, vis, &cells)
    else if (sv.eventAt != null)
        pickIndexedCtrl(sv, ph, lay.control_id, vis, &cells)
    else
        CtrlPick{};
    const n = picked.n;

    var row: u16 = 0;
    while (row < vis) : (row += 1) {
        const is_cur = if (picked.cur) |cur| row == cur else false;
        if (is_cur) {
            var x: u16 = lay.track_x;
            while (x < lay.track_x + lay.ctrl_w and x < ctx.win.width) : (x += 1) {
                ctx.win.writeCell(x, 1 + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = t.style(.pat_cursor_fill),
                });
            }
        }
        if (row < n) drawSeqCell(ctx, cells[row], lay.track_x + 2, 1 + row, cell_text_w, is_cur, sv.kind);
    }
}

fn drawInfo(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const style = t.style(.pat_bar);
    paint.fillRow(ctx.win, lay.info_row, style);
    var buf: [192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(" ") catch return;
    w.print("{s} {X:0>4}  Rate {d}  EVT {d}  ", .{
        if (sv.position_unit == .event_index) "Event" else "Tick",
        ph.tick,
        sv.tick_rate,
        sv.event_count,
    }) catch return;
    if (ph.flags.has_tempo) {
        if (sv.kind == .voice_programs) {
            w.print("Tempo {X:0>2}  ", .{ph.tempo}) catch return;
        } else w.print("Tempo {d}  ", .{ph.tempo}) catch return;
    }
    if (ctx.track.archive_track_count > 1) {
        w.print("Song {d}/{d}  ", .{
            ctx.track.archive_track_index + 1,
            ctx.track.archive_track_count,
        }) catch return;
    }
    if (sv.kind == .event_stream) {
        const n = lay.voice_count;
        const shown = if (lay.compact) compactCount(ctx.win.width, n) else liveShown(lay, n);
        if (shown != 0 and shown < n) {
            const first = visiblePage(n, ctx.nav.channel_page, shown);
            w.print("CH {d:0>2}-{d:0>2} of {d}", .{ first + 1, first + shown, n }) catch return;
        }
    } else if (lay.chans != 0 and lay.chans < lay.voice_count) {
        w.print("CH {d:0>2}-{d:0>2} of {d}", .{
            lay.chan0 + 1,
            lay.chan0 + lay.chans,
            lay.voice_count,
        }) catch return;
    }
    const text = a.dupe(u8, w.buffered()) catch return;
    paint.printFit(ctx.win, 0, lay.info_row, text, ctx.win.width, style);
}

fn eventCol(ev: view.SequenceEvent, ntracks: u16) ?u16 {
    if (ev.track < ntracks) return ev.track;
    return null;
}

fn isNote(kind: CellKind) bool {
    return kind == .note or kind == .duration_note;
}

fn visibleIndex(lay: Layout, track: u16) ?u16 {
    var i: u16 = 0;
    while (i < lay.chans) : (i += 1) {
        if (lay.grid_ids[i] == track) return i;
    }
    return null;
}

fn keepProgram(cell: *GridCell) void {
    if (cell.kind == .program or cell.kind == .start_program) cell.program = @intCast(cell.arg);
}

fn applyEvent(cell: *GridCell, ev: view.SequenceEvent) void {
    switch (ev.kind) {
        .note_on => switch (ev.payload) {
            .note => |n| {
                keepProgram(cell);
                cell.kind = .note;
                cell.note = n.note;
                if (n.note < 128) cell.notes.set(n.note);
                cell.arg = n.velocity;
            },
            else => {},
        },
        .duration_note => switch (ev.payload) {
            .note => |n| {
                keepProgram(cell);
                cell.kind = .duration_note;
                cell.note = n.note;
                if (n.note < 128) cell.notes.set(n.note);
                cell.vel = n.velocity;
                cell.arg = n.duration_ticks orelse n.velocity;
            },
            else => {},
        },
        .wait => {
            cell.kind = .wait;
            cell.arg = if (ev.payload == .wait) ev.payload.wait else 0;
        },
        .end => cell.kind = .end,
        .note_off => {
            if (isNote(cell.kind)) return;
            cell.kind = .note_off;
            switch (ev.payload) {
                .note => |n| cell.arg = n.duration_ticks orelse 0,
                else => {},
            }
        },
        .program => switch (ev.payload) {
            .program => |p| {
                if (isNote(cell.kind)) {
                    cell.program = p;
                    return;
                }
                cell.kind = .program;
                cell.arg = p;
            },
            else => {},
        },
        .start_program => switch (ev.payload) {
            .start_program => |p| {
                if (isNote(cell.kind)) return;
                cell.kind = .start_program;
                cell.arg = p;
            },
            else => {},
        },
        .jump => {
            if (isNote(cell.kind)) return;
            cell.kind = .jump;
            cell.branch = if (ev.payload == .branch) ev.payload.branch else null;
            cell.arg = switch (ev.payload) {
                .jump => |j| j,
                .branch => |b| b.target,
                else => 0,
            };
        },
        .label => {
            if (isNote(cell.kind)) return;
            cell.kind = .label;
            cell.arg = switch (ev.payload) {
                .label => |l| l,
                else => 0,
            };
        },
        .control => {
            if (isNote(cell.kind)) return;
            cell.kind = .control;
            switch (ev.payload) {
                .control => |c| {
                    cell.note = c.cc;
                    cell.arg = c.value;
                },
                else => {},
            }
        },
        .pitch_bend => {
            if (isNote(cell.kind)) return;
            cell.kind = .bend;
            cell.arg = switch (ev.payload) {
                .pitch_bend => |b| b,
                else => 0,
            };
        },
        .tempo => {
            if (isNote(cell.kind)) return;
            cell.kind = .tempo;
            cell.arg = switch (ev.payload) {
                .tempo => |v| v,
                else => 0,
            };
        },
        .sysex => {
            if (isNote(cell.kind)) return;
            cell.kind = .sysex;
            cell.arg = switch (ev.payload) {
                .sysex_ref => |s| s,
                else => 0,
            };
        },
        .aftertouch => {
            if (isNote(cell.kind)) return;
            cell.kind = .aftertouch;
            cell.arg = switch (ev.payload) {
                .aftertouch => |v| v,
                else => 0,
            };
        },
    }
}

fn fillGrid(
    ctx: *viz.DrawContext,
    sv: view.SequenceView,
    ph: view.Playhead,
    lay: Layout,
    cells: [][view.max_pattern_channels]GridCell,
    first: *u32,
    cursor_row: *?u16,
) void {
    const rows: u16 = @intCast(cells.len);
    if (rows == 0 or lay.chans == 0) return;
    const scroll = ctx.nav.sequence_scroll;

    if (sv.eventsInRange) |fn_range| {
        const origin = tickOrigin(@min(scroll orelse followOrigin(sv, ph, rows), tickLast(sv, rows)), rows);
        first.* = origin;
        var dest: [event_buf_len]view.SequenceEvent = undefined;
        const range = fn_range(sv.ctx, origin, origin + rows, dest[0..]);
        for (dest[0..@min(range.written, dest.len)]) |ev| {
            if (ev.tick < origin) continue;
            const row = ev.tick - origin;
            if (row >= rows) continue;
            const col = eventCol(ev, sv.track_count) orelse continue;
            if (lay.control_id) |cid| {
                if (col == cid) continue;
            }
            const vis_i = visibleIndex(lay, col) orelse continue;
            applyEvent(&cells[@intCast(row)][vis_i], ev);
        }
        if (ph.tick >= origin and ph.tick - origin < rows)
            cursor_row.* = @intCast(ph.tick - origin);
        return;
    }

    if (sv.bytecodeWindow) |fn_bc| {
        const bank = ctx.bridge.sequence.read();
        pinStartedVoices(ctx.nav, bank);
        const skip_rows = if (scroll) |at| @min(at, scrollLast(sv, ctx.nav, bank, lay)) else 0;
        first.* = skip_rows;
        cursor_row.* = if (scroll == null) 0 else null;
        var ci: u16 = 0;
        while (ci < lay.chans) : (ci += 1) {
            const ch = lay.grid_ids[ci];
            var dest: [event_buf_len]view.SequenceEvent = undefined;
            const from = bytecodeFrom(ctx.nav, bank, ch);
            const range = if (sv.bytecodePage) |page| page(sv.ctx, ch, from, skip_rows, dest[0..]) else fn_bc(sv.ctx, ch, from, dest[0..]);
            const skip = if (sv.bytecodePage != null) 0 else @min(skip_rows, range.total_in_range -| 1);
            var written_row: u16 = 0;
            for (dest[0..@min(range.written, dest.len)], 0..) |ev, i| {
                if (i < skip) continue;
                if (written_row >= rows) break;
                applyEvent(&cells[written_row][ci], ev);
                written_row += 1;
            }
        }
        return;
    }

    if (sv.eventAt) |fn_at| {
        const origin = @min(scroll orelse followOrigin(sv, ph, rows), sv.event_count -| rows);
        first.* = origin;
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const idx = origin + r;
            if (idx >= sv.event_count) break;
            const ev = fn_at(sv.ctx, idx);
            const col = eventCol(ev, sv.track_count) orelse continue;
            if (lay.control_id) |cid| {
                if (col == cid) continue;
            }
            const vis_i = visibleIndex(lay, col) orelse continue;
            applyEvent(&cells[r][vis_i], ev);
        }
        const position = eventPosition(sv, ph.tick);
        if (sv.event_count != 0 and position >= origin and position - origin < rows)
            cursor_row.* = @intCast(position - origin);
    }
}

fn drawGrid(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const win = ctx.win;
    const bank = ctx.bridge.sequence.read();
    var i: u16 = 0;
    while (i < lay.chans) : (i += 1) {
        const ch = lay.grid_ids[i];
        const tr = sv.track(sv.ctx, ch);
        const slot = slotAt(bank, ch);
        const head = if (tr.name.len != 0)
            tr.name
        else if (sv.kind == .voice_programs and slot != null and slot.?.keyed) blk: {
            const tok = midiToken(slot.?.note);
            break :blk a.dupe(u8, tok[0..]) catch continue;
        } else (a.print("-{d}-", .{ch + 1}) catch continue);
        const style = if (!tr.in_use)
            t.style(.order_skip)
        else switch (tr.kind) {
            .control => t.style(.ch_control),
            .drum => t.style(.ch_drum),
            .pcm => t.style(.ch_pcm),
            .melodic => t.style(.pat_head),
        };
        const head_w = @min(paint.textWidth(win, head), lay.col_w[i] -| 1);
        paint.printFit(win, lay.col_x[i] + (lay.col_w[i] -| head_w) / 2, lay.pattern_head_row, head, head_w, style);
    }

    const rows = visRows(lay);
    const cells = a.alloc([view.max_pattern_channels]GridCell, rows) catch return;
    @memset(cells, @splat(.{}));
    var first: u32 = 0;
    var cursor_row: ?u16 = null;
    fillGrid(ctx, sv, ph, lay, cells, &first, &cursor_row);

    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const row: u16 = lay.pattern_top + r;
        const is_cur = if (cursor_row) |cr| r == cr else false;
        if (is_cur) {
            var x: u16 = 0;
            while (x < win.width) : (x += 1) {
                win.writeCell(x, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = t.style(.pat_cursor_fill),
                });
            }
        }
        const gut = a.print("{X:0>3}", .{(first +% r) & 0xfff}) catch return;
        paint.printAt(win, lay.pat_x + 1, row, gut, t.rowStyle(is_cur, t.style(.pat_gutter)));
        drawSeparator(win, t, lay.pat_x + pat_gutter - 1, row, is_cur);

        var ci: u16 = 0;
        while (ci < lay.chans) : (ci += 1) {
            const cx = lay.col_x[ci];
            drawSeparator(win, t, cx + lay.col_w[ci] - 1, row, is_cur);
            drawSeqCell(ctx, cells[r][ci], cx, row, lay.col_w[ci] -| 1, is_cur, sv.kind);
        }
    }
}

fn drawEventList(ctx: *viz.DrawContext, sv: view.SequenceView, ph: view.Playhead, lay: Layout) void {
    const at = sv.eventAt orelse return;
    paint.fillRow(ctx.win, lay.pattern_head_row, ctx.theme.style(.pat_bar));
    paint.printFit(ctx.win, 1, lay.pattern_head_row, if (sv.position_unit == .event_index) "EVENT   OFFSET    VOICE   COMMAND" else "TICK    OFFSET    VOICE   COMMAND", ctx.win.width -| 2, ctx.theme.style(.pat_bar));
    const rows = visRows(lay);
    const position = eventPosition(sv, ph.tick);
    const first = @min(ctx.nav.sequence_scroll orelse followOrigin(sv, ph, rows), sv.event_count -| rows);
    const current_tick = if (sv.event_count != 0) at(sv.ctx, position).tick else 0;
    var r: u16 = 0;
    while (r < rows and first + r < sv.event_count) : (r += 1) {
        const index = first + r;
        const ev = at(sv.ctx, index);
        const current = if (sv.position_unit == .event_index) index == position else ev.tick == current_tick and ev.tick <= ph.tick;
        const row = lay.pattern_top + r;
        if (current) paint.fillRow(ctx.win, row, ctx.theme.style(.pat_cursor_fill));
        const channel = if (ev.track == view.sequence_unassigned) "FLOW" else ctx.arena.print("{d: >4}", .{ev.track + 1}) catch return;
        const text = common.describeSequenceEvent(ctx.arena, sv, ev) catch return;
        const line = ctx.arena.print("{X:0>6}  {X:0>8}  {s}    {s}", .{ if (sv.position_unit == .event_index) index else ev.tick, ev.instr_index, channel, text }) catch return;
        const style = switch (ev.kind) {
            .note_on, .duration_note, .note_off => ctx.theme.style(.note),
            .program => ctx.theme.style(.inst_cell),
            else => ctx.theme.style(.fx_cell),
        };
        paint.printFit(ctx.win, 1, row, line, ctx.win.width -| 2, ctx.theme.rowStyle(current, style));
    }
}

fn drawSeparator(win: vaxis.Window, t: Theme, x: u16, row: u16, is_cur: bool) void {
    win.writeCell(x, row, .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = t.patSeparator(is_cur),
    });
}

fn midiToken(note: u8) [3]u8 {
    const nn = common.note_names[note % common.note_names.len];
    const oct: u8 = @intCast(@min(note / 12, 9));
    return .{ nn[0], nn[1], '0' + oct };
}

fn branchLetter(kind: @FieldType(Branch, "kind")) u8 {
    return switch (kind) {
        .jump => 'J',
        .call => 'G',
        .ret => 'R',
        .loop => 'R',
        .skip => 'S',
    };
}

fn branchMnemonic(a: std.mem.Allocator, b: Branch) []const u8 {
    if (b.kind == .ret) return "RET";
    if (b.kind == .jump and b.repeats != 0) return a.print("J{X:0>2}x{d}", .{ b.target, b.repeats }) catch "J";
    return a.print("{c}{X:0>2}", .{ branchLetter(b.kind), b.target }) catch "J";
}

fn branchText(a: std.mem.Allocator, cell: GridCell, kind: view.SequenceKind) []const u8 {
    const b = cell.branch orelse return a.print("J{X:0>4}", .{cell.arg}) catch "J0000";
    if (kind == .voice_programs) {
        if (b.kind == .ret) return "RET ..";
        if (b.target == view.sequence_pc_none) return a.print("{c}----", .{branchLetter(b.kind)}) catch "J----";
        return a.print("{c}{X:0>4}", .{ branchLetter(b.kind), b.target }) catch "J0000";
    }
    const text = branchMnemonic(a, b);
    if (b.kind == .jump and b.repeats != 0) return text;
    return a.print("{s} ..", .{text}) catch text;
}

fn markerText(a: std.mem.Allocator, ev: view.SequenceEvent) []const u8 {
    return switch (ev.payload) {
        .branch => |b| branchMnemonic(a, b),
        .label => |l| a.print("L{X:0>2}", .{l}) catch "L",
        .jump => |target| a.print("J{X:0>4}", .{target}) catch "J",
        else => if (ev.kind == .end) "END" else @tagName(ev.kind),
    };
}

fn drawSeqCell(ctx: *viz.DrawContext, cell: GridCell, x: u16, row: u16, width: u16, is_cur: bool, kind: view.SequenceKind) void {
    const t = ctx.theme;
    const a = ctx.arena;
    const text, const style = switch (cell.kind) {
        .empty => .{ "--- ..", t.style(.note_empty) },
        .note => blk: {
            const line = if (cell.program != view.sequence_unassigned)
                (a.print("{s}I{X:0>2}", .{ midiToken(cell.note)[0..], cell.program }) catch "---I00")
            else blk2: {
                const tok = midiToken(cell.note);
                break :blk2 a.print("{s} {X:0>2}", .{ tok[0..], @as(u8, @truncate(cell.arg)) }) catch "--- ..";
            };
            break :blk .{ line, t.style(.note) };
        },
        .duration_note => blk: {
            const line = if (kind == .voice_programs and cell.vel == 0)
                (a.print("ON {X:0>3}", .{cell.arg}) catch "ON 000")
            else blk2: {
                const tok = midiToken(cell.note);
                break :blk2 a.print("{s}{X:0>3}", .{ tok[0..], cell.arg }) catch "---000";
            };
            break :blk .{ line, t.style(.note) };
        },
        .note_off => blk: {
            const line = if (kind == .voice_programs)
                (a.print("=== {X:0>2}", .{@as(u8, @truncate(cell.arg))}) catch "=== ..")
            else
                "=== ..";
            break :blk .{ line, t.style(.note) };
        },
        .program, .start_program => blk: {
            const line = if (cell.arg == view.instrument_none) "I-- .." else a.print("I{X:0>2} ..", .{cell.arg}) catch "I00 ..";
            break :blk .{ line, t.style(.inst_cell) };
        },
        .jump => .{ branchText(a, cell, kind), t.style(.fx_cell) },
        .label => blk: {
            const line = a.print("L{X:0>2} ..", .{@as(u8, @truncate(cell.arg))}) catch "L00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
        .control => blk: {
            const line = a.print("C{X:0>2} {X:0>2}", .{
                cell.note,
                @as(u8, @truncate(cell.arg)),
            }) catch "C00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
        .bend => blk: {
            const line = a.print("B{X:0>2} ..", .{@as(u8, @truncate(cell.arg >> 7))}) catch "B00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
        .tempo => blk: {
            const line = a.print("T{X:0>2} ..", .{cell.arg}) catch "T00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
        .sysex => blk: {
            const line = a.print("S{X:0>2} ..", .{@as(u8, @truncate(cell.arg))}) catch "S00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
        .wait => .{ a.print("W{d: >3}", .{cell.arg}) catch "WAIT", t.style(.fx_cell) },
        .end => .{ "END", t.style(.order_skip) },
        .aftertouch => blk: {
            const line = a.print("A{X:0>2} ..", .{@as(u8, @truncate(cell.arg))}) catch "A00 ..";
            break :blk .{ line, t.style(.fx_cell) };
        },
    };
    if (cell.notes.count() > 1) {
        const chord = a.print("{s}+{d}", .{ midiToken(cell.note), cell.notes.count() - 1 }) catch return;
        paint.printFit(ctx.win, x, row, chord, cell_text_w, t.rowStyle(is_cur, style));
    } else paint.printFit(ctx.win, x, row, text, width, t.rowStyle(is_cur, style));
}

pub const visualizer = viz.Visualizer.init(@This());

// --- tests -------------------------------------------------------------------

const Bridge = @import("../bridge.zig").Bridge;
const default_theme = @import("../theme.zig").default_theme;
const pcm_band_count = @import("../bridge.zig").pcm_band_count;

const SeqFix = struct {
    fn track(_: *anyopaque, index: u16) view.SequenceTrack {
        return .{
            .name = if (index == 0) "lead" else "bass",
            .channel = @intCast(index),
            .program = index + 1,
            .in_use = true,
        };
    }
    fn eventsInRange(_: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
        _ = tick0;
        _ = tick1;
        if (dest.len == 0) return .{};
        dest[0] = .{
            .tick = 0,
            .track = 0,
            .channel = 0,
            .kind = .note_on,
            .payload = .{ .note = .{ .note = 60, .velocity = 100 } },
        };
        if (dest.len > 1) {
            dest[1] = .{
                .tick = 0,
                .track = 1,
                .channel = 1,
                .kind = .program,
                .payload = .{ .program = 2 },
            };
        }
        return .{ .written = @intCast(@min(dest.len, 2)), .total_in_range = 2 };
    }
    fn instrument(_: *anyopaque, _: u16) view.InstrumentInfo {
        return .{ .patch = .{ .opl_2op = .{ .op_count = 2 } } };
    }
};

fn testRowText(screen: *vaxis.Screen, buf: []u8, row: u16, width: u16) []const u8 {
    for (0..width) |c| {
        const cell = screen.readCell(@intCast(c), row).?;
        const g = cell.char.grapheme;
        buf[c] = if (g.len == 1) g[0] else '?';
    }
    return buf[0..width];
}

fn drawFixture(win: vaxis.Window, arena: std.mem.Allocator, with_bank: bool) void {
    var br = Bridge{};
    var bank = view.SequenceStateBank{ .channels = 2 };
    bank.slots[0] = .{ .keyed = true, .note = 60, .program = 1, .opl_voice = 0 };
    br.sequence.write(bank);
    var nav: viz.Navigation = .{};
    var spec_levels: [view.max_opl_voices]f32 = @splat(0);
    spec_levels[0] = 1.0;
    var spec_peaks: [view.max_opl_voices]f32 = @splat(0);
    var spec_glow: [view.max_opl_voices]f32 = @splat(0);
    var pcm_bands: [pcm_band_count]f32 = @splat(0);
    var pcm_peaks: [pcm_band_count]f32 = @splat(0);
    var pcm_glow: [pcm_band_count]f32 = @splat(0);
    var spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = viz.DrawContext{
        .win = win,
        .theme = default_theme,
        .bridge = &br,
        .track = .{ .format_name = "CMF", .visualizer = "sequence" },
        .views = .{
            .sequence = .{
                .ctx = undefined,
                .kind = .linear_midi,
                .track_count = 2,
                .channel_count = 2,
                .tick_rate = 120,
                .length_ticks = 100,
                .track = SeqFix.track,
                .eventsInRange = SeqFix.eventsInRange,
                .event_count = 2,
            },
            .instruments = if (with_bank) .{
                .ctx = undefined,
                .count = 8,
                .get = SeqFix.instrument,
            } else null,
        },
        .spec_levels = &spec_levels,
        .spec_peaks = &spec_peaks,
        .spec_peak_glow = &spec_glow,
        .voice_count = 9,
        .nav = &nav,
        .pcm_bands = &pcm_bands,
        .pcm_band_peaks = &pcm_peaks,
        .pcm_band_peak_glow = &pcm_glow,
        .pcm_peak = 0,
        .spark = &spark,
        .arena = arena,
    };
    draw(&ctx);
}

test "command cursor distinguishes elapsed ticks from BAM event indices" {
    const Fixture = struct {
        fn track(_: *anyopaque, _: u16) view.SequenceTrack {
            return .{};
        }
        fn event(_: *anyopaque, index: u32) view.SequenceEvent {
            const ticks = [_]u32{ 0, 0, 64, 128, 128, 192 };
            return .{ .tick = ticks[index] };
        }
    };
    var sv = view.SequenceView{
        .ctx = undefined,
        .kind = .event_stream,
        .track_count = 1,
        .channel_count = 1,
        .tick_rate = 60,
        .length_ticks = 200,
        .track = Fixture.track,
        .eventAt = Fixture.event,
        .event_count = 6,
    };
    try std.testing.expectEqual(@as(u32, 2), eventPosition(sv, 100));
    try std.testing.expectEqual(@as(u32, 4), eventPosition(sv, 128));
    try std.testing.expectEqual(@as(u32, 5), eventPosition(sv, 200));
    sv.position_unit = .event_index;
    try std.testing.expectEqual(@as(u32, 3), eventPosition(sv, 3));
    try std.testing.expectEqual(@as(u32, 5), eventPosition(sv, 200));
}

test "compact sequence keeps live notes and meters above the event grid" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 78, .rows = 14, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    drawFixture(win, arena.allocator(), true);
    var buf: [78]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 1, 78), "I01 C-5") != null);
    var meter = false;
    var spectrum = false;
    for (0..7) |row| for (0..78) |col| {
        const glyph = screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme;
        meter = meter or std.mem.eql(u8, glyph, "▇");
        spectrum = spectrum or std.mem.eql(u8, glyph, "█");
    };
    try std.testing.expect(meter and spectrum);
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 9, 78), "C-5") != null);
}

test "sample voices use their measured level without an OPL channel or fictitious note" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var br = Bridge{};
    var bank = view.SequenceStateBank{ .channels = 1, .voice_count = 1 };
    bank.slots[0] = .{ .program = 48, .keyed = true };
    bank.voices[0] = .{ .channel = 0, .program = 48, .kind = .pcm, .keyed = true, .level = 128 };
    br.sequence.write(bank);
    const empty: [view.max_opl_voices]f32 = @splat(0);
    var ctx: viz.DrawContext = undefined;
    ctx.bridge = &br;
    ctx.spec_levels = &empty;
    ctx.spec_peaks = &empty;
    ctx.spec_peak_glow = &empty;
    var plan = GridPlan{ .n = 1 };
    plan.ids[0] = 0;
    const layout = computeLayout(120, 30, plan, 0);
    var levels: [view.max_pattern_channels]f32 = @splat(0);
    var peaks = levels;
    var glow = levels;
    _ = mapSpecLevels(&ctx, layout, &levels, &peaks, &glow);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), levels[0], 0.001);
    try std.testing.expectEqualStrings(" 1 I30 PCM ", chordLine(arena.allocator(), bank, 0, bank.slots[0]));
    bank.voices[0].keyed = false;
    try std.testing.expectEqualStrings(" 1 I30 ---", chordLine(arena.allocator(), bank, 0, bank.slots[0]));
}

test "a released FM voice keeps lighting its channel meter through the OPL release" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var br = Bridge{};
    var bank = view.SequenceStateBank{ .channels = 2, .voice_count = 2 };
    bank.slots[0] = .{ .program = 3 };
    bank.voices[0] = .{ .channel = 0, .program = 3, .note = 60, .opl_voice = 4 };
    bank.voices[1] = .{ .channel = 1, .program = 5, .note = 64, .opl_voice = 2, .keyed = true };
    br.sequence.write(bank);
    var opl_levels: [view.max_opl_voices]f32 = @splat(0);
    var opl_peaks = opl_levels;
    var opl_glow = opl_levels;
    opl_levels[2] = 0.9;
    opl_levels[4] = 0.25;
    opl_peaks[4] = 0.5;
    opl_glow[4] = 0.75;
    var ctx: viz.DrawContext = undefined;
    ctx.bridge = &br;
    ctx.spec_levels = &opl_levels;
    ctx.spec_peaks = &opl_peaks;
    ctx.spec_peak_glow = &opl_glow;
    var plan = GridPlan{ .n = 2 };
    plan.ids[0] = 0;
    plan.ids[1] = 1;
    const layout = computeLayout(120, 30, plan, 0);
    var levels: [view.max_pattern_channels]f32 = @splat(0);
    var peaks = levels;
    var glow = levels;
    _ = mapSpecLevels(&ctx, layout, &levels, &peaks, &glow);
    try std.testing.expectEqual(@as(f32, 0.25), levels[0]);
    try std.testing.expectEqual(@as(f32, 0.5), peaks[0]);
    try std.testing.expectEqual(@as(f32, 0.75), glow[0]);
    try std.testing.expectEqual(@as(f32, 0.9), levels[1]);
    try std.testing.expectEqualStrings(" 1 I03 ---", chordLine(arena.allocator(), bank, 0, bank.slots[0]));
}

const LongFix = struct {
    var widest: u32 = 0;
    fn track(_: *anyopaque, index: u16) view.SequenceTrack {
        return .{ .kind = if (index == 1) .control else .melodic };
    }
    fn eventsInRange(_: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
        widest = @max(widest, tick1 -| tick0);
        var written: u16 = 0;
        for ([_]u32{ 1000, 199_990, 200_010 }) |tick| {
            if (tick < tick0 or tick >= tick1 or written == dest.len) continue;
            dest[written] = .{ .tick = tick, .track = 1, .channel = 15, .kind = .control, .payload = .{ .control = .{ .cc = 7, .value = 100 } } };
            written += 1;
        }
        return .{ .written = written, .total_in_range = written };
    }
};

fn longContext(win: vaxis.Window, arena: std.mem.Allocator, br: *Bridge, nav: *viz.Navigation, empty: *const [view.max_opl_voices]f32, bands: *const [pcm_band_count]f32, spark: *const [viz.spark_retention]f32) viz.DrawContext {
    return .{
        .win = win,
        .theme = default_theme,
        .bridge = br,
        .track = .{ .format_name = "SCI0", .visualizer = "sequence" },
        .views = .{ .sequence = .{
            .ctx = undefined,
            .kind = .linear_midi,
            .track_count = 2,
            .channel_count = 16,
            .tick_rate = 60,
            .length_ticks = 300_000,
            .track = LongFix.track,
            .eventsInRange = LongFix.eventsInRange,
        } },
        .spec_levels = empty,
        .spec_peaks = empty,
        .spec_peak_glow = empty,
        .nav = nav,
        .pcm_bands = bands,
        .pcm_band_peaks = bands,
        .pcm_band_peak_glow = bands,
        .pcm_peak = 0,
        .spark = spark,
        .arena = arena,
    };
}

test "sequence scroll holds tick positions beyond 65535 and Home resumes following" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 200_000 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    _ = handleKey(&ctx, vaxis.Key.down);
    const pinned = nav.sequence_scroll.?;
    try std.testing.expect(pinned > 199_980 and pinned <= 200_000);
    _ = handleKey(&ctx, vaxis.Key.up);
    try std.testing.expectEqual(pinned - 1, nav.sequence_scroll.?);
    _ = handleKey(&ctx, vaxis.Key.home);
    try std.testing.expectEqual(@as(?u32, null), nav.sequence_scroll);
}

test "tick grid End shows the final tick and Down at the song end holds the view" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 300_000 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    const rows = visRows(computeLayout(120, 30, gridPlan(ctx.views.sequence.?), 0));
    _ = handleKey(&ctx, vaxis.Key.end);
    try std.testing.expectEqual(@as(u32, 300_000), nav.sequence_scroll.? + rows - 1);
    _ = handleKey(&ctx, vaxis.Key.home);
    _ = handleKey(&ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(u32, 300_001) - rows, nav.sequence_scroll.?);
}

test "event list End then Up moves the first drawn event at once" {
    const Fix = struct {
        fn track(_: *anyopaque, _: u16) view.SequenceTrack {
            return .{};
        }
        fn event(_: *anyopaque, index: u32) view.SequenceEvent {
            return .{ .tick = index, .kind = .note_on };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views.sequence = .{ .ctx = undefined, .kind = .event_stream, .track_count = 1, .channel_count = 1, .tick_rate = 60, .length_ticks = 100, .track = Fix.track, .eventAt = Fix.event, .event_count = 100 };
    const sv = ctx.views.sequence.?;
    const rows = visRows(computeLayout(120, 30, gridPlan(sv), 0));
    _ = handleKey(&ctx, vaxis.Key.end);
    try std.testing.expectEqual(@as(u32, 100 - rows), nav.sequence_scroll.?);
    _ = handleKey(&ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(u32, 99 - rows), @min(nav.sequence_scroll.?, sv.event_count -| rows));

    var tall = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 45, .x_pixel = 0, .y_pixel = 0 });
    defer tall.deinit(std.testing.allocator);
    ctx.win = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 45, .screen = &tall };
    const tall_rows = visRows(computeLayout(120, 45, gridPlan(sv), 0));
    _ = handleKey(&ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(u32, 99 - tall_rows), nav.sequence_scroll.?);
}

test "control track lists events near the playhead instead of the whole song" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 200_000 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    LongFix.widest = 0;
    var picked: [ctrl_rows]GridCell = @splat(.{});
    const out = pickRangeCtrl(ctx.views.sequence.?, br.playhead.read(), 1, ctrl_rows, &picked);
    try std.testing.expect(LongFix.widest <= 2 * ctrl_span);
    try std.testing.expectEqual(@as(u16, 2), out.n);
    try std.testing.expectEqual(@as(?u16, 0), out.cur);
    draw(&ctx);
    try std.testing.expect(LongFix.widest <= 2 * ctrl_span);
}

const StructureFix = struct {
    const markers = [_]view.SequenceMarker{
        .{ .position = 0, .event = .{ .kind = .label, .payload = .{ .label = 1 } } },
        .{ .position = 40, .event = .{ .kind = .jump, .payload = .{ .branch = .{ .target = 1, .kind = .jump, .repeats = 2 } } } },
        .{ .position = 90, .event = .{ .kind = .end } },
    };
    fn track(_: *anyopaque, _: u16) view.SequenceTrack {
        return .{};
    }
    fn event(_: *anyopaque, index: u32) view.SequenceEvent {
        return .{ .tick = index, .kind = .wait, .track = view.sequence_unassigned, .payload = .{ .wait = 1 } };
    }
    fn markerAt(_: *anyopaque, index: u32) view.SequenceMarker {
        return if (index < markers.len) markers[index] else .{};
    }
};

test "flow lists song structure and marks the section being played" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 55 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    const sv = view.SequenceView{
        .ctx = undefined,
        .kind = .event_stream,
        .position_unit = .event_index,
        .track_count = 2,
        .channel_count = 2,
        .tick_rate = 25,
        .length_ticks = 100,
        .track = StructureFix.track,
        .eventAt = StructureFix.event,
        .event_count = 100,
        .marker_count = StructureFix.markers.len,
        .markerAt = StructureFix.markerAt,
    };
    try std.testing.expectEqual(@as(?u32, 0), currentMarker(sv, 0));
    try std.testing.expectEqual(@as(?u32, 0), currentMarker(sv, 39));
    try std.testing.expectEqual(@as(?u32, 1), currentMarker(sv, 55));
    try std.testing.expectEqual(@as(?u32, 2), currentMarker(sv, 99));
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views = .{ .sequence = sv };
    draw(&ctx);
    var jump_row: ?u16 = null;
    var wait_shown = false;
    for (0..12) |row| {
        var buf: [120]u8 = undefined;
        const line = testRowText(&screen, &buf, @intCast(row + 1), 120);
        if (std.mem.find(u8, line, "? J01x2   0028") != null) jump_row = @intCast(row + 1);
        if (std.mem.find(u8, line, "W   1") != null) wait_shown = true;
    }
    try std.testing.expect(jump_row != null);
    try std.testing.expect(!wait_shown);
    var label_found = false;
    for (0..12) |row| {
        var buf: [120]u8 = undefined;
        if (std.mem.find(u8, testRowText(&screen, &buf, @intCast(row + 1), 120), "  L01     0000") != null) label_found = true;
    }
    try std.testing.expect(label_found);
}

const RollFix = struct {
    fn track(_: *anyopaque, _: u16) view.SequenceTrack {
        return .{};
    }
    fn eventsInRange(_: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
        const events = [_]view.SequenceEvent{
            .{ .tick = 100, .track = 0, .kind = .duration_note, .payload = .{ .note = .{ .note = 60, .velocity = 64, .duration_ticks = 20 } } },
            .{ .tick = 130, .track = 0, .kind = .note_on, .payload = .{ .note = .{ .note = 62, .velocity = 64 } } },
            .{ .tick = 140, .track = 0, .kind = .note_off, .payload = .{ .note = .{ .note = 62, .velocity = 0 } } },
        };
        var written: u16 = 0;
        for (events) |ev| {
            if (ev.tick < tick0 or ev.tick >= tick1 or written == dest.len) continue;
            dest[written] = ev;
            written += 1;
        }
        return .{ .written = written, .total_in_range = written };
    }
};

test "voice rows draw a piano roll of past and coming notes around the playhead" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 110 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views = .{ .sequence = .{
        .ctx = undefined,
        .kind = .event_stream,
        .track_count = 2,
        .channel_count = 2,
        .tick_rate = 25,
        .length_ticks = 200,
        .track = RollFix.track,
        .eventsInRange = RollFix.eventsInRange,
    } };
    draw(&ctx);

    const roll = buildRoll(arena.allocator(), ctx.views.sequence.?, br.playhead.read(), 70).?;
    try std.testing.expectEqual(@as(u16, 2), roll.voices[0].n);
    try std.testing.expectEqual(@as(u32, 120), roll.voices[0].spans[0].end);
    try std.testing.expectEqual(@as(u32, 140), roll.voices[0].spans[1].end);
    try std.testing.expectEqual(@as(u16, 0), roll.voices[1].n);

    var buf: [120]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, 0, 120), "s ") != null);
    const voice0 = testRowText(&screen, &buf, 1, 120);
    const c5 = std.mem.find(u8, voice0, "C-5") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, voice0[c5..], "D-5") != null);
    var marker = false;
    for (0..120) |col| {
        if (std.mem.eql(u8, screen.readCell(@intCast(col), 2).?.char.grapheme, "│")) marker = true;
    }
    try std.testing.expect(marker);
}

test "same-tick channel events keep a duration note in its grid cell" {
    var cell = GridCell{};
    applyEvent(&cell, .{ .kind = .duration_note, .payload = .{ .note = .{ .note = 60, .velocity = 90, .duration_ticks = 4 } } });
    applyEvent(&cell, .{ .kind = .control, .payload = .{ .control = .{ .cc = 7, .value = 100 } } });
    applyEvent(&cell, .{ .kind = .pitch_bend, .payload = .{ .pitch_bend = 0x2000 } });
    try std.testing.expectEqual(CellKind.duration_note, cell.kind);
    try std.testing.expectEqual(@as(u8, 60), cell.note);
}

test "channel paging reaches the last live row at every short pane size" {
    var plan = GridPlan{ .n = 16 };
    for (0..16) |i| plan.ids[i] = @intCast(i);
    const sv = view.SequenceView{ .ctx = undefined, .kind = .linear_midi, .track_count = 16, .channel_count = 16, .tick_rate = 96, .length_ticks = 1, .track = LongFix.track };
    var w: u16 = 44;
    while (w <= 160) : (w += 1) {
        var h: u16 = 5;
        while (h <= 30) : (h += 1) {
            const lay = computeLayout(w, h, plan, 0);
            const window = pageWindow(sv, lay, w, plan.n);
            const max_start = plan.n -| window;
            const live = if (lay.compact) compactCount(w, plan.n) else liveShown(lay, plan.n);
            if (live == 0) continue;
            try std.testing.expectEqual(plan.n, visiblePage(plan.n, max_start, live) + live);
        }
    }
}

test "piano roll keeps every drawable onset on wide panes" {
    const Dense = struct {
        fn track(_: *anyopaque, _: u16) view.SequenceTrack {
            return .{};
        }
        fn eventsInRange(_: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
            var written: u16 = 0;
            var tick = tick0 - tick0 % 2;
            while (tick < tick1 and written < dest.len) : (tick += 2) {
                dest[written] = .{ .tick = tick, .track = 0, .kind = .duration_note, .payload = .{ .note = .{ .note = 60, .velocity = 1, .duration_ticks = 1 } } };
                written += 1;
            }
            return .{ .written = written, .total_in_range = written };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sv = view.SequenceView{ .ctx = undefined, .kind = .event_stream, .track_count = 1, .channel_count = 1, .tick_rate = 25, .length_ticks = 10_000, .track = Dense.track, .eventsInRange = Dense.eventsInRange };
    const roll = buildRoll(arena.allocator(), sv, .{ .tick = 5_000 }, 300).?;
    try std.testing.expectEqual(@as(u16, 150), roll.voices[0].n);
    try std.testing.expect(roll.voices[0].spans[roll.voices[0].n - 1].start >= roll.now);
}

test "compact strip names sample lanes and fits two-digit channels" {
    var bank = view.SequenceStateBank{ .channels = 17, .voice_count = 1 };
    bank.slots[16] = .{ .program = 3, .keyed = true };
    bank.voices[0] = .{ .channel = 16, .kind = .pcm, .keyed = true, .level = 200 };
    try std.testing.expectEqualStrings("PCM", compactToken(std.testing.allocator, bank, 16, bank.slots[16]));
    try std.testing.expectEqual(@as(u16, 8), compactEntryWidth(17));
    try std.testing.expectEqual(@as(u16, 7), compactEntryWidth(9));
}

const BytecodeFix = struct {
    fn track(_: *anyopaque, index: u16) view.SequenceTrack {
        return .{ .kind = if (index == 1) .control else .melodic };
    }
    fn window(ctx: *anyopaque, ch: u16, from: u32, dest: []view.SequenceEvent) view.EventRange {
        return page(ctx, ch, from, 0, dest);
    }
    fn page(_: *anyopaque, ch: u16, from: u32, skip: u32, dest: []view.SequenceEvent) view.EventRange {
        if (from >= 100) return .{};
        const total = 100 - from;
        const written = @min(total -| skip, dest.len);
        for (dest[0..written], from + skip..) |*ev, at| ev.* = .{ .instr_index = @intCast(at), .track = ch, .channel = @intCast(ch), .kind = .duration_note, .payload = .{ .note = .{ .note = @intCast(at), .velocity = 127, .duration_ticks = 1 } } };
        return .{ .written = @intCast(written), .total_in_range = total };
    }
    fn firstRowShows(screen: *vaxis.Screen, lay: Layout, at: u8) bool {
        var buf: [120]u8 = undefined;
        const tok = midiToken(at);
        return std.mem.find(u8, testRowText(screen, &buf, lay.pattern_top, 120), &tok) != null;
    }
};

test "a pinned bytecode view keeps decoding from the program counters it pinned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    var bank: view.SequenceStateBank = .{ .channels = 2 };
    bank.slots[0].pc = 10;
    br.sequence.write(bank);
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views.sequence = .{ .ctx = undefined, .kind = .voice_programs, .track_count = 2, .channel_count = 2, .tick_rate = 72, .length_ticks = 0, .track = BytecodeFix.track, .bytecodeWindow = BytecodeFix.window };
    _ = handleKey(&ctx, vaxis.Key.end);
    try std.testing.expectEqual(@as(?u32, 89), nav.sequence_scroll);
    bank.slots[0].pc = 30;
    br.sequence.write(bank);
    try std.testing.expectEqual(@as(u32, 10), bytecodeFrom(&nav, br.sequence.read(), 0));
    _ = handleKey(&ctx, vaxis.Key.up);
    try std.testing.expectEqual(@as(?u32, 88), nav.sequence_scroll);
    _ = handleKey(&ctx, vaxis.Key.home);
    try std.testing.expectEqual(@as(u32, 30), bytecodeFrom(&nav, br.sequence.read(), 0));
}

test "a pinned bytecode grid keeps its rows while voices advance, start, or outgrow a stale scroll" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    var bank: view.SequenceStateBank = .{ .channels = 3 };
    bank.slots[0].pc = 10;
    br.sequence.write(bank);
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views.sequence = .{ .ctx = undefined, .kind = .voice_programs, .track_count = 3, .channel_count = 3, .tick_rate = 72, .length_ticks = 0, .track = BytecodeFix.track, .bytecodeWindow = BytecodeFix.window, .bytecodePage = BytecodeFix.page };
    const lay = computeLayout(120, 30, gridPlan(ctx.views.sequence.?), 0);

    _ = handleKey(&ctx, vaxis.Key.down);
    _ = handleKey(&ctx, vaxis.Key.down);
    draw(&ctx);
    try std.testing.expect(BytecodeFix.firstRowShows(&screen, lay, 12));
    bank.slots[0].pc = 14;
    bank.slots[2].pc = 50;
    br.sequence.write(bank);
    draw(&ctx);
    try std.testing.expect(BytecodeFix.firstRowShows(&screen, lay, 12));
    try std.testing.expect(BytecodeFix.firstRowShows(&screen, lay, 52));
    bank.slots[2].pc = 60;
    br.sequence.write(bank);
    draw(&ctx);
    try std.testing.expect(BytecodeFix.firstRowShows(&screen, lay, 52));

    nav.sequence_scroll = 5000;
    draw(&ctx);
    try std.testing.expect(BytecodeFix.firstRowShows(&screen, lay, 99));
}

test "an event list reports its live window and CTRL fits an 80x25 terminal" {
    const Fix = struct {
        fn track(_: *anyopaque, index: u16) view.SequenceTrack {
            return .{ .channel = @intCast(index), .in_use = true };
        }
        fn event(_: *anyopaque, index: u32) view.SequenceEvent {
            return .{ .tick = index, .track = @intCast(index % 11), .kind = .note_on };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 78, .rows = 15, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 15, .screen = &screen };
    var br = Bridge{};
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views.sequence = .{ .ctx = undefined, .kind = .event_stream, .track_count = 11, .channel_count = 11, .tick_rate = 60, .length_ticks = 40, .track = Fix.track, .eventAt = Fix.event, .event_count = 40 };
    const lay = computeLayout(78, 15, gridPlan(ctx.views.sequence.?), 0);
    draw(&ctx);
    var buf: [78]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, testRowText(&screen, &buf, lay.info_row, 78), "CH 01-09") == null);

    ctx.views.sequence = .{ .ctx = undefined, .kind = .voice_programs, .track_count = 2, .channel_count = 2, .tick_rate = 72, .length_ticks = 0, .track = BytecodeFix.track, .bytecodeWindow = BytecodeFix.window };
    draw(&ctx);
    var found = false;
    for (0..lay.info_row) |row| {
        if (std.mem.find(u8, testRowText(&screen, &buf, @intCast(row), 78), "CTRL") != null) found = true;
    }
    try std.testing.expect(found);
}

const SongFix = struct {
    fn track(_: *anyopaque, _: u16) view.SequenceTrack {
        return .{ .in_use = true };
    }
    fn controlTrack(_: *anyopaque, index: u16) view.SequenceTrack {
        return .{ .kind = if (index == 15) .control else .melodic, .in_use = true };
    }
    fn eventsInRange(_: *anyopaque, tick0: u32, tick1: u32, dest: []view.SequenceEvent) view.EventRange {
        const events = [_]view.SequenceEvent{
            .{ .tick = 0, .track = view.sequence_unassigned, .channel = 15, .kind = .label, .payload = .{ .label = 0x7f } },
            .{ .tick = 2, .track = 15, .channel = 15, .kind = .control, .payload = .{ .control = .{ .cc = 7, .value = 100 } } },
            .{ .tick = 4, .track = view.sequence_unassigned, .kind = .tempo, .payload = .{ .tempo = 0x42 } },
        };
        var written: u16 = 0;
        for (events) |ev| {
            if (ev.tick < tick0 or ev.tick >= tick1 or written == dest.len) continue;
            dest[written] = ev;
            written += 1;
        }
        return .{ .written = written, .total_in_range = written };
    }
    fn topShows(screen: *vaxis.Screen, lay: Layout, width: u16, text: []const u8) bool {
        var buf: [120]u8 = undefined;
        for (0..lay.info_row) |row| {
            if (std.mem.find(u8, testRowText(screen, &buf, @intCast(row), width), text) != null) return true;
        }
        return false;
    }
};

test "CTRL or FLOW keeps its column beside the spectrum at every pane width" {
    for ([_]GridPlan{ .{ .flow = true }, .{ .control = 9 }, .{ .flow = true, .structure = true } }) |base| {
        var n: u16 = 1;
        while (n <= view.max_pattern_channels) : (n += 1) {
            var plan = base;
            plan.n = n;
            for (0..n) |i| plan.ids[i] = @intCast(i);
            var w: u16 = 44;
            while (w <= 160) : (w += 1) {
                const lay = computeLayout(w, 15, plan, 0);
                try std.testing.expect(lay.show_ctrl);
                try std.testing.expect(lay.track_x >= 8 and lay.track_x + lay.ctrl_w <= lay.spectrum_x);
                try std.testing.expect(lay.spectrum_x + lay.spectrum_w <= w);
            }
        }
    }

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var br = Bridge{};
    br.playhead.write(.{ .tick = 4 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    for ([_]u16{ 11, 16 }) |n| {
        var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 78, .rows = 15, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(std.testing.allocator);
        screen.width_method = .unicode;
        const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 15, .screen = &screen };
        var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
        ctx.views.sequence = .{ .ctx = undefined, .kind = .linear_midi, .track_count = n, .channel_count = n, .tick_rate = 60, .length_ticks = 100, .track = SongFix.track, .eventsInRange = SongFix.eventsInRange };
        const lay = computeLayout(78, 15, gridPlan(ctx.views.sequence.?), 0);
        draw(&ctx);
        try std.testing.expect(SongFix.topShows(&screen, lay, 78, "FLOW"));
        try std.testing.expect(SongFix.topShows(&screen, lay, 78, "T42"));
    }
}

test "CTRL lists song-level cues and the loop marker beside its control track" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 30, .screen = &screen };
    var br = Bridge{};
    br.playhead.write(.{ .tick = 4 });
    var nav: viz.Navigation = .{};
    const empty: [view.max_opl_voices]f32 = @splat(0);
    const bands: [pcm_band_count]f32 = @splat(0);
    const spark: [viz.spark_retention]f32 = @splat(0);
    var ctx = longContext(win, arena.allocator(), &br, &nav, &empty, &bands, &spark);
    ctx.views.sequence = .{ .ctx = undefined, .kind = .linear_midi, .track_count = 16, .channel_count = 16, .tick_rate = 60, .length_ticks = 100, .track = SongFix.controlTrack, .eventsInRange = SongFix.eventsInRange };
    const sv = ctx.views.sequence.?;
    var picked: [ctrl_rows]GridCell = @splat(.{});
    const out = pickRangeCtrl(sv, br.playhead.read(), 15, ctrl_rows, &picked);
    try std.testing.expectEqual(@as(u16, 3), out.n);
    try std.testing.expectEqual(CellKind.label, picked[0].kind);
    try std.testing.expectEqual(@as(?u16, 2), out.cur);
    const lay = computeLayout(120, 30, gridPlan(sv), 0);
    draw(&ctx);
    try std.testing.expect(SongFix.topShows(&screen, lay, 120, "CTRL"));
    try std.testing.expect(SongFix.topShows(&screen, lay, 120, "L7F"));
}
