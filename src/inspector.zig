//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");
const viz = @import("visualizer.zig");
const view = @import("view.zig");
const paint = @import("paint.zig");
const common = @import("visualizers/common.zig");

pub const Section = enum { song, instrument, macros, pattern, channels, events, branches, order, chip };

pub const State = struct {
    open: bool = false,
    section: Section = .song,
    scroll: u32 = 0,
    horizontal: u16 = 0,
    channel: u16 = 0,
    bounds: Bounds = .{},
    body: Bounds = .{},
    page_rows: u16 = 1,
    max_scroll: u32 = 0,
    max_horizontal: u16 = 0,
    branch_first: u32 = 0,
    close_hits: paint.HotkeyHits = .{},
    footer_hits: paint.HotkeyHits = .{},

    pub fn resetHits(self: *State) void {
        self.bounds = .{};
        self.body = .{};
        self.close_hits = .{};
        self.footer_hits = .{};
    }
};

const Bounds = struct {
    x: i17 = 0,
    y: i17 = 0,
    width: u16 = 0,
    height: u16 = 0,

    fn contains(self: Bounds, col: i16, row: i16) bool {
        return col >= self.x and row >= self.y and col < self.x + self.width and row < self.y + self.height;
    }

    fn fromWindow(win: vaxis.Window) Bounds {
        return .{ .x = win.x_off, .y = win.y_off, .width = win.width, .height = win.height };
    }
};

pub fn handleMouse(state: *State, mouse: vaxis.Mouse) ?u21 {
    if (mouse.type == .release or mouse.type == .motion) return null;
    if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
        if (state.bounds.contains(mouse.col, mouse.row)) {
            if (mouse.button == .wheel_up) state.scroll -|= 3 else state.scroll = @min(state.scroll +| 3, state.max_scroll);
        }
        return null;
    }
    if (mouse.button != .left or mouse.type != .press) return null;
    if (state.close_hits.keyAt(mouse.col, mouse.row)) |key| return key;
    if (state.footer_hits.keyAt(mouse.col, mouse.row)) |key| return key;
    if (!state.bounds.contains(mouse.col, mouse.row)) return vaxis.Key.escape;
    if (state.section == .branches and state.body.contains(mouse.col, mouse.row)) {
        const row: u32 = @intCast(mouse.row - state.body.y);
        if (row < state.page_rows) state.scroll = @min(state.branch_first + row, state.max_scroll);
    }
    return null;
}

fn available(ctx: *viz.DrawContext, section: Section) bool {
    return switch (section) {
        .song, .chip => true,
        .instrument => ctx.views.instruments != null,
        .macros => if (ctx.views.instruments) |bank| bank.macroStep != null else false,
        .channels => ctx.bridge.channels.read().channels != 0 or ctx.bridge.sequence.read().channels != 0,
        .events => ctx.views.sequence != null,
        .branches => if (ctx.views.sequence) |sv| sv.branch_count != 0 and sv.branchAt != null else false,
        .order => ctx.views.order != null,
        .pattern => ctx.views.pattern != null,
    };
}

pub fn handleKey(ctx: *viz.DrawContext, state: *State, key: u21) viz.KeyResult {
    if (key == 'i' or key == 'I') {
        state.open = !state.open;
        return .handled;
    }
    if (!state.open) return .ignored;
    switch (key) {
        vaxis.Key.enter, vaxis.Key.kp_enter => {
            if (state.section == .branches) if (ctx.views.sequence) |sv| {
                if (sv.branchAt) |get| {
                    const b = get(sv.ctx, @intCast(@min(state.scroll, sv.branch_count -| 1)));
                    ctx.bridge.branch_request.store(b.label, .release);
                }
            };
        },
        'c', 'C' => {
            if (state.section == .events) if (ctx.views.sequence) |sv| if (sv.bytecodePage != null) {
                state.channel = if (sv.track_count == 0) 0 else (state.channel + 1) % sv.track_count;
                state.scroll = 0;
            };
        },
        vaxis.Key.escape => state.open = false,
        '`' => {
            const count = @typeInfo(Section).@"enum".field_names.len;
            var next = (@as(usize, @backingInt(state.section)) + 1) % count;
            while (!available(ctx, @fromBackingInt(@intCast(next)))) next = (next + 1) % count;
            state.section = @fromBackingInt(@intCast(next));
            state.scroll = 0;
            state.horizontal = 0;
        },
        vaxis.Key.up, vaxis.Key.kp_up => state.scroll -|= 1,
        vaxis.Key.down, vaxis.Key.kp_down => state.scroll +|= 1,
        vaxis.Key.page_up, vaxis.Key.kp_page_up => state.scroll -|= state.page_rows,
        vaxis.Key.page_down, vaxis.Key.kp_page_down => state.scroll +|= state.page_rows,
        vaxis.Key.home, vaxis.Key.kp_home => state.scroll = 0,
        vaxis.Key.end, vaxis.Key.kp_end => state.scroll = std.math.maxInt(u32),
        vaxis.Key.left, vaxis.Key.kp_left => state.horizontal -|= 8,
        vaxis.Key.right, vaxis.Key.kp_right => state.horizontal +|= 8,
        'j', 'J', 'k', 'K' => {
            if (ctx.views.instruments) |bank| {
                if (key == 'j' or key == 'J') ctx.nav.instrument_sel -|= 1 else ctx.nav.instrument_sel = @min(ctx.nav.instrument_sel +| 1, bank.count -| 1);
                ctx.nav.instrument_sel_user = true;
                if (state.section == .instrument or state.section == .macros) state.scroll = 0;
            }
        },
        else => return .ignored,
    }
    return .handled;
}

const Lines = struct {
    a: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Lines, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.a, try self.a.print(fmt, args));
    }

    fn fields(self: *Lines, value: anytype) !void {
        const info = @typeInfo(@TypeOf(value)).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (field_name[0] == '_') continue;
            const v = @field(value, field_name);
            var label: [field_name.len]u8 = field_name[0..field_name.len].*;
            for (&label) |*c| if (c.* == '_') {
                c.* = ' ';
            };
            label[0] = std.ascii.toUpper(label[0]);
            if (comptime std.mem.eql(u8, field_name, "instrument") and field_type == u16) {
                if (v == view.instrument_none) try self.add("{s:<24} --", .{label}) else try self.add("{s:<24} {d}", .{ label, v });
            } else switch (@typeInfo(field_type)) {
                .int, .float => try self.add("{s:<24} {d}", .{ label, v }),
                .bool => try self.add("{s:<24} {s}", .{ label, if (v) "yes" else "no" }),
                .@"enum" => try self.add("{s:<24} {s}", .{ label, @tagName(v) }),
                else => {},
            }
        }
    }
};

pub fn draw(ctx: *viz.DrawContext, state: *State) void {
    state.resetHits();
    if (ctx.win.width < 8 or ctx.win.height < 6) return;
    if (!available(ctx, state.section)) state.section = .song;
    for (0..ctx.win.height) |row| for (0..ctx.win.width) |col| {
        var cell = ctx.win.readCell(@intCast(col), @intCast(row)) orelse continue;
        cell.style = ctx.theme.style(.info_dim);
        ctx.win.writeCell(@intCast(col), @intCast(row), cell);
    };
    const margin_x: u16 = @min(4, (ctx.win.width -| 40) / 2);
    const margin_y: u16 = @min(3, (ctx.win.height -| 12) / 2);
    const width: u16 = @min(100, ctx.win.width - margin_x * 2);
    const height: u16 = @min(30, ctx.win.height - margin_y * 2);
    const panel = ctx.win.child(.{
        .x_off = (ctx.win.width - width) / 2,
        .y_off = (ctx.win.height - height) / 2,
        .width = width,
        .height = height,
    });
    panel.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = ctx.theme.style(.shell_fill) });
    const body = panel.child(.{ .border = .{ .where = .all, .glyphs = .single_rounded, .style = ctx.theme.style(.viz_frame) } });
    state.bounds = .fromWindow(panel);
    state.body = .fromWindow(body);
    state.page_rows = body.height -| 2;
    const names = [_][]const u8{ "Song", "Instrument", "Macros", "Pattern", "Channels", "Events", "Branches", "Order", "Chip" };
    const title = ctx.arena.print(" Inspect: {s} ", .{names[@backingInt(state.section)]}) catch return;
    paint.printFit(panel, 2, 0, title, panel.width -| 10, ctx.theme.style(.inst_title));
    paint.drawHotkeyHints(panel, ctx.theme, 0, &.{.{ .key = "[X]", .codepoint = vaxis.Key.escape, .label = "" }}, panel.width - 6, &state.close_hits);
    var content = ctx.*;
    content.win = body;
    drawContent(&content, state);
    drawFooter(&content, state);
}

fn drawFooter(ctx: *viz.DrawContext, state: *State) void {
    var buf: [12]paint.Hotkey = undefined;
    var hints: std.ArrayList(paint.Hotkey) = .initBuffer(&buf);
    hints.appendSliceAssumeCapacity(&.{
        .{ .key = "↑", .codepoint = vaxis.Key.up, .label = "", .enabled = state.scroll > 0 },
        .{ .key = "↓", .codepoint = vaxis.Key.down, .label = if (state.section == .branches) "select" else "scroll", .enabled = state.scroll < state.max_scroll, .label_enabled = state.max_scroll != 0, .glue = true },
    });
    if (state.section == .branches) {
        hints.appendAssumeCapacity(.{ .key = "Enter", .codepoint = vaxis.Key.enter, .label = "jump" });
    }
    hints.appendSliceAssumeCapacity(&.{
        .{ .key = "`", .codepoint = '`', .label = "section" },
        .{ .key = "Esc", .codepoint = vaxis.Key.escape, .label = "close" },
    });
    if (state.section != .branches) {
        hints.appendAssumeCapacity(.{ .key = "←", .codepoint = vaxis.Key.left, .label = "", .enabled = state.horizontal != 0 });
        hints.appendAssumeCapacity(.{ .key = "→", .codepoint = vaxis.Key.right, .label = "pan", .enabled = state.horizontal < state.max_horizontal, .glue = true });
    }
    if (state.section == .instrument or state.section == .macros) {
        const bank = ctx.views.instruments orelse return;
        hints.appendAssumeCapacity(.{ .key = "J", .codepoint = 'j', .label = "", .enabled = ctx.nav.instrument_sel > 0 });
        hints.appendAssumeCapacity(.{ .key = "K", .codepoint = 'k', .label = "instrument", .enabled = ctx.nav.instrument_sel +| 1 < bank.count, .glue = true });
    }
    if (state.section == .events) if (ctx.views.sequence) |sv| {
        if (sv.bytecodePage != null) hints.appendAssumeCapacity(.{ .key = "C", .codepoint = 'c', .label = "channel" });
    };
    paint.drawHotkeyHints(ctx.win, ctx.theme, ctx.win.height - 1, hints.items, 1, &state.footer_hits);
}

fn drawContent(ctx: *viz.DrawContext, state: *State) void {
    state.max_scroll = 0;
    state.max_horizontal = 0;
    var lines = Lines{ .a = ctx.arena };
    if (state.section == .events) {
        drawEvents(ctx, state);
        return;
    }
    if (state.section == .branches) {
        drawBranches(ctx, state);
        return;
    }
    collect(ctx, state.section, &lines) catch return;
    const rows = ctx.win.height -| 2;
    state.max_scroll = @as(u32, @intCast(lines.items.items.len)) -| rows;
    state.scroll = @min(state.scroll, state.max_scroll);
    const shown = lines.items.items[state.scroll..][0..@min(rows, lines.items.items.len - state.scroll)];
    var max_width: u16 = 0;
    for (shown) |line| max_width = @max(max_width, paint.columnWidth(ctx.win, line, 4096));
    state.max_horizontal = max_width -| (ctx.win.width -| 2);
    state.horizontal = @min(state.horizontal, state.max_horizontal);
    for (shown, 0..) |line, row| {
        const clipped = paint.skipColumns(ctx.win, line, state.horizontal);
        paint.printFit(ctx.win, 1, @intCast(row), clipped, ctx.win.width -| 2, if (row % 2 == 0) ctx.theme.style(.info_value) else ctx.theme.style(.inst_value));
    }
    const footer = ctx.arena.print("{d}-{d}/{d}", .{ state.scroll + @intFromBool(lines.items.items.len > 0), @min(state.scroll + rows, lines.items.items.len), lines.items.items.len }) catch return;
    paint.printFit(ctx.win, 1, ctx.win.height - 2, footer, ctx.win.width -| 2, ctx.theme.style(.info_dim));
}

fn collect(ctx: *viz.DrawContext, section: Section, lines: *Lines) !void {
    switch (section) {
        .song => {
            try lines.add("Format                   {s}", .{ctx.track.format_name});
            if (ctx.track.title) |s| try lines.add("Title                    {s}", .{s});
            if (ctx.track.artist) |s| try lines.add("Artist                   {s}", .{s});
            if (ctx.track.game) |s| try lines.add("Game                     {s}", .{s});
            if (ctx.track.system) |s| try lines.add("System                   {s}", .{s});
            try lines.add("Song                     {d}/{d}", .{ ctx.track.archive_track_index + 1, @max(1, ctx.track.archive_track_count) });
            try lines.add("Loop                     {s}", .{if (ctx.track.loop) "yes" else "no"});
            const ph = ctx.bridge.playhead.read();
            inline for (@typeInfo(view.PlayheadFlags).@"struct".field_names) |field_name| {
                if (comptime std.mem.startsWith(u8, field_name, "has_")) {
                    if (@field(ph.flags, field_name)) try lines.add("{s:<24} {d}", .{ field_name[4..], @field(ph, field_name[4..]) });
                }
            }
            if (ctx.views.pattern) |pv| {
                try lines.add("Grid                     {s}", .{@tagName(pv.grid)});
                try lines.add("Patterns / rows / voices {d} / {d} / {d}", .{ pv.num_patterns, pv.rows_per_pattern, pv.channels });
                try lines.add("Sample playback          {s}", .{if (pv.mixed_pcm) "yes" else "no"});
                if (pv.rate_text.len != 0) try lines.add("Rate                     {s}", .{pv.rate_text});
            }
            if (ctx.views.sequence) |sv| {
                try lines.add("Sequence                 {s}", .{@tagName(sv.kind)});
                try lines.add("Tracks / channels        {d} / {d}", .{ sv.track_count, sv.channel_count });
                if (sv.kind == .voice_programs)
                    try lines.add("Rate                     {d}", .{sv.tick_rate})
                else
                    try lines.add("Events / ticks / rate    {d} / {d} / {d}", .{ sv.event_count, sv.length_ticks, sv.tick_rate });
            }
            if (ctx.views.dump) |dump| {
                try lines.fields(dump);
                if (dump.loop) |loop| try lines.add("Loop offset              {d} {s}", .{ loop.offset, @tagName(loop.unit) });
            }
        },
        .instrument => {
            const bank = ctx.views.instruments orelse return;
            if (bank.count == 0) return;
            const index = @min(ctx.nav.instrument_sel, bank.count - 1);
            const ins = bank.get(bank.ctx, index);
            try lines.add("Instrument {X:0>2}/{d}  {s}", .{ index, bank.count, ins.name });
            switch (ins.patch) {
                .empty => try lines.add("Unused", .{}),
                .midi => |p| try lines.fields(p),
                .sample => |p| {
                    try lines.add("Sample                   {s}", .{p.filename});
                    try lines.fields(p);
                },
                .opl_2op, .opl_4op => |p| {
                    try lines.add("{d} operators  feedback {d}/{d}  algorithm {d}  {s}", .{ p.op_count, p.feedback, p.feedback2, p.algorithm, if (p.additive) "additive" else "FM" });
                    try lines.add("Pan {d}  fine tune {d}  percussion {d}", .{ p.panning, p.fine_tune, p.perc_voice });
                    try lines.add("OP  MULT KSL LEVEL  ATT DEC SUS REL WAVE  TREM VIB SUST KSR", .{});
                    for (p.ops[0..@min(p.op_count, 4)], 0..) |op, i| {
                        try lines.add("{d: >2}  {d: >4} {d: >3} {d: >5}  {d: >3} {d: >3} {d: >3} {d: >3} {d: >4}  {s: >4} {s: >3} {s: >4} {s: >3}", .{ i + 1, op.mult, op.ksl, op.level, op.attack, op.decay, op.sustain, op.release, op.wave, onOff(op.tremolo), onOff(op.vibrato), onOff(op.sustaining), onOff(op.ksr) });
                    }
                },
            }
            if (ins.hasMacros()) try lines.fields(ins.macros);
        },
        .macros => {
            const bank = ctx.views.instruments orelse return;
            const get = bank.macroStep orelse return;
            if (bank.count == 0) return;
            const index = @min(ctx.nav.instrument_sel, bank.count - 1);
            const ins = bank.get(bank.ctx, index);
            try lines.add("Instrument {X:0>2}  {s}", .{ index, ins.name });
            try lines.fields(ins.macros);
            for ([_]view.MacroKind{ .fmreg, .arpeggio, .vibrato }) |kind| {
                var step: u16 = 0;
                while (step < ins.macroLen(kind)) : (step += 1) {
                    const m = get(bank.ctx, index, kind, step);
                    if (m.empty) continue;
                    try lines.add("{s} {d:0>3}  duration {d}  pan {d}  slide {d}  flags {X}  {s}", .{ @tagName(kind), step, m.duration, m.panning, m.freq_slide, m.flags, if (m.disabled) "disabled" else "" });
                    if (kind == .arpeggio) try lines.add("  Note {d}", .{m.arp_note});
                    if (kind == .vibrato) try lines.add("  Delta {d}", .{m.vib_delta});
                    if (kind == .fmreg) {
                        try lines.add("  Feedback {d}  additive {s}", .{ m.feedback, onOff(m.additive) });
                        for (m.ops, 0..) |op, i| {
                            try lines.add("  Operator {d}", .{i + 1});
                            try lines.fields(op);
                        }
                    }
                }
            }
        },
        .channels => {
            const seq = ctx.bridge.sequence.read();
            if (seq.voice_count != 0) {
                var keyed: u16 = 0;
                for (seq.voices[0..@min(seq.voice_count, seq.voices.len)]) |voice| keyed += @intFromBool(voice.keyed);
                try lines.add("ACTIVE VOICES  {d}", .{keyed});
                for (seq.voices[0..@min(seq.voice_count, seq.voices.len)]) |voice| {
                    if (voice.kind == .pcm) {
                        try lines.add("CH {d: >2}  PCM  I{X:0>2}  level {d}/255  {s}", .{ voice.channel + 1, voice.program, voice.level, onOff(voice.keyed) });
                    } else try lines.add("CH {d: >2}  {s}  I{X:0>2}  velocity {d}  voice {d}  {s}  {s}", .{ voice.channel + 1, common.noteToken(voice.note % 12, voice.note / 12), voice.program, voice.velocity, voice.opl_voice, @tagName(voice.kind), onOff(voice.keyed) });
                }
            }
            for (seq.slots[0..@min(seq.channels, seq.slots.len)], 0..) |slot, i| {
                try lines.add("CHANNEL {d}", .{i + 1});
                try lines.fields(slot);
                try lines.fields(slot.fx);
            }
            const channels = ctx.bridge.channels.read();
            const cursors = ctx.bridge.pattern_cursors.read();
            for (channels.slots[0..@min(channels.channels, channels.slots.len)], 0..) |slot, i| {
                try lines.add("CHANNEL {d}", .{i + 1});
                try lines.fields(slot);
                for (slot.effects, 0..) |fx, col| try lines.add("Effect {d}                 {X:0>2} {X:0>4}", .{ col + 1, fx.cmd, fx.param });
                if (i < cursors.channels) try lines.fields(cursors.slots[i]);
                if (ctx.views.pattern) |pv| if (pv.channelInfo) |get| {
                    const ch = get(pv.ctx, @intCast(i));
                    try lines.add("Name                     {s}", .{ch.name});
                    try lines.fields(ch);
                    if (ch.four_op_pair) |pair| try lines.add("Paired channel           {d}", .{pair + 1});
                };
            }
        },
        .pattern => {
            const pv = ctx.views.pattern orelse return;
            const ph = ctx.bridge.playhead.read();
            const cursors = ctx.bridge.pattern_cursors.read();
            if (pv.patternName) |get| try lines.add("Pattern {d}  {s}", .{ ph.pattern, get(pv.ctx, ph.pattern) });
            for (0..pv.channels) |ch| {
                const cursor = if (ch < cursors.channels and ch < cursors.slots.len) cursors.slots[ch] else view.PatternCursor{};
                const pattern = if (cursor.active) cursor.pattern else ph.pattern;
                const row = if (cursor.active) cursor.row else ph.row;
                if (pattern >= pv.num_patterns or row >= pv.rows_per_pattern) continue;
                const cell = pv.cell(pv.ctx, pattern, row, @intCast(ch));
                try lines.add("CHANNEL {d}  pattern {d}  row {d}", .{ ch + 1, pattern, row });
                switch (cell.note) {
                    .pitch => |pitch| try lines.add("  Note {s}  {s}", .{ common.noteToken(pitch.semitone, pitch.octave), if (pitch.fixed) "fixed" else "" }),
                    else => try lines.add("  Note {s}", .{@tagName(cell.note)}),
                }
                if (cell.instrument) |value| try lines.add("  Instrument {d}", .{value});
                if (cell.volume) |value| try lines.add("  Volume {d}", .{value});
                for (cell.effects, 0..) |effect, i| {
                    if (effect.cmd == 0 and effect.param == 0) continue;
                    const desc = if (pv.effectLexicon) |get| get(pv.ctx, effect.cmd, effect.param).text else "";
                    try lines.add("  Effect {d}  {X:0>2} {X:0>4}  {s}", .{ i + 1, effect.cmd, effect.param, desc });
                }
                switch (cell.extra) {
                    .delay => |value| try lines.add("  Delay {d}", .{value}),
                    .pitch => |value| try lines.add("  Pitch {d}", .{value}),
                    .retrigger => try lines.add("  Retrigger", .{}),
                    .none => {},
                }
            }
            if (pv.riffName) |get| for (0..pv.riff_count) |i| try lines.add("Riff {d}  {s}", .{ i, get(pv.ctx, @intCast(i)) });
        },
        .order => {
            const order = ctx.views.order orelse return;
            if (order.restart) |restart| try lines.add("Restart at {d}", .{restart});
            var i: u16 = 0;
            while (i < order.len) : (i += 1) {
                const entry = order.entry(order.ctx, i);
                try lines.add("{d:0>3}  {s}  pattern {d}  target {d}", .{ i, @tagName(entry.kind), entry.pattern, entry.jump_to });
                if (order.channelRef) |get| {
                    const count = if (ctx.views.pattern) |p| p.channels else 0;
                    for (0..count) |ch| {
                        const ref = get(order.ctx, i, @intCast(ch));
                        try lines.add("  CH {d: >2}  offset {X:0>8}  pattern {d}  transpose {d}  {s}", .{ ch + 1, ref.start, ref.pattern, ref.transpose, @tagName(ref.target) });
                    }
                }
            }
        },
        .chip => {
            const chip = ctx.bridge.chip.read();
            const chip_name = common.chipName(ctx.views.dump, ctx.track.opl3);
            const dual_opl2 = if (ctx.views.dump) |dump| dump.chip == .dual_opl2 else false;
            const per_chip: usize = if (dual_opl2) 9 else 18;
            try lines.add("CHIP 1  {s}  NEW {s}", .{ chip_name, onOff(chip.new_bit) });
            for (chip.voices[0..@min(ctx.voice_count, chip.voices.len)], 0..) |voice, i| {
                if (i == per_chip) try lines.add("CHIP 2  {s}  NEW {s}", .{ chip_name, onOff(if (dual_opl2) chip.new_bit else chip.second_new_bit) });
                try lines.add("{d: >2}  {s}  FNUM {d: >4}  BLOCK {d}  PAN {d}  TYPE {d}", .{ i % per_chip + 1, onOff(voice.keyed), voice.fnum, voice.block, voice.pan, voice.chan_type });
            }
            const pcm = ctx.bridge.pcm.read();
            for (pcm.voices, 0..) |voice, i| {
                if (!voice.present) continue;
                try lines.add("Y8950 ADPCM {d}  {s}  {s}  {s}", .{ i + 1, onOff(voice.playing), if (voice.external) "MEMORY" else "CPU", if (voice.repeat) "REPEAT" else "ONCE" });
                try lines.add("  Rate {d} Hz  Volume {d}/255  Speaker {s}", .{ voice.rate, voice.volume, onOff(!voice.muted) });
                try lines.add("  Start {X:0>6}  End (exclusive) {X:0>6}  Position {X:0>6}", .{ voice.start, voice.end, voice.position });
            }
            try lines.add("RECENT REGISTER WRITES", .{});
            var log: [view.write_log_cap]common.LoggedWrite = undefined;
            for (common.recentWrites(ctx.bridge, &log)) |entry| {
                try lines.add("{X:0>8}  {d}:{X:0>3} = {X:0>2}", .{ entry.index, (entry.write.reg >> 9) + 1, entry.write.reg & 0x1ff, entry.write.val });
            }
        },
        .events, .branches => unreachable,
    }
}

fn drawEvents(ctx: *viz.DrawContext, state: *State) void {
    const sv = ctx.views.sequence orelse return;
    const rows = ctx.win.height -| 2;
    var page: []view.SequenceEvent = &.{};
    var count = sv.event_count;
    if (sv.bytecodePage) |get| {
        state.channel = @min(state.channel, sv.track_count -| 1);
        const bank = ctx.bridge.sequence.read();
        const from = if (state.channel < bank.channels and state.channel < bank.slots.len) bank.slots[state.channel].pc else view.sequence_pc_none;
        count = get(sv.ctx, state.channel, from, 0, &.{}).total_in_range;
        state.max_scroll = count -| rows;
        state.scroll = @min(state.scroll, state.max_scroll);
        page = ctx.arena.alloc(view.SequenceEvent, rows) catch return;
        const range = get(sv.ctx, state.channel, from, state.scroll, page);
        page = page[0..@min(page.len, range.written)];
    } else if (sv.eventAt == null) {
        paint.printFit(ctx.win, 1, 1, "This source has no event index.", ctx.win.width -| 2, ctx.theme.style(.info_dim));
        return;
    }
    state.max_scroll = count -| rows;
    state.scroll = @min(state.scroll, state.max_scroll);
    const lines = ctx.arena.alloc([]const u8, rows) catch return;
    var n: u16 = 0;
    var max_width: u16 = 0;
    while (n < rows and state.scroll + n < count) : (n += 1) {
        const event = if (sv.bytecodePage != null) (if (n < page.len) page[n] else break) else sv.eventAt.?(sv.ctx, state.scroll + n);
        const text = common.describeSequenceEvent(ctx.arena, sv, event) catch return;
        const track = if (event.track == view.sequence_unassigned) "FLOW" else ctx.arena.print("CH {d}", .{event.track + 1}) catch return;
        lines[n] = ctx.arena.print("{d: >6}  @{d: >8}  {X:0>6}  {s: <6}  {s}", .{ state.scroll + n, event.tick, event.instr_index, track, text }) catch return;
        max_width = @max(max_width, paint.columnWidth(ctx.win, lines[n], 4096));
    }
    state.max_horizontal = max_width -| (ctx.win.width -| 2);
    state.horizontal = @min(state.horizontal, state.max_horizontal);
    for (lines[0..n], 0..) |line, row| {
        paint.printFit(ctx.win, 1, @intCast(row), paint.skipColumns(ctx.win, line, state.horizontal), ctx.win.width -| 2, ctx.theme.style(.seq_event));
    }
    const footer = ctx.arena.print("{d}-{d}/{d}", .{ state.scroll + @intFromBool(count != 0), @min(state.scroll + rows, count), count }) catch return;
    paint.printFit(ctx.win, 1, ctx.win.height - 2, footer, ctx.win.width -| 2, ctx.theme.style(.info_dim));
}

fn onOff(on: bool) []const u8 {
    return if (on) "ON" else "OFF";
}

fn drawBranches(ctx: *viz.DrawContext, state: *State) void {
    const sv = ctx.views.sequence orelse return;
    const get = sv.branchAt orelse return;
    state.max_scroll = sv.branch_count -| 1;
    state.scroll = @min(state.scroll, state.max_scroll);
    const rows = ctx.win.height -| 2;
    const first = state.scroll -| (rows / 2);
    state.branch_first = first;
    for (0..rows) |row| {
        const index = first + row;
        if (index >= sv.branch_count) break;
        const b = get(sv.ctx, @intCast(index));
        const line = ctx.arena.print("{s}  Branch {d}    tick {d}", .{ if (index == state.scroll) ">" else " ", b.label, b.tick }) catch return;
        paint.printFit(ctx.win, 1, @intCast(row), line, ctx.win.width -| 2, if (index == state.scroll) ctx.theme.style(.pat_cursor_fill) else ctx.theme.style(.info_value));
    }
}

const Bridge = @import("bridge.zig").Bridge;
const pcm_band_count = @import("bridge.zig").pcm_band_count;
const default_theme = @import("theme.zig").default_theme;

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
    levels: [view.max_opl_voices]f32 = @splat(0),
    bands: [pcm_band_count]f32 = @splat(0),
    spark: [viz.spark_retention]f32 = @splat(0),

    fn context(self: *DrawHarness, win: vaxis.Window, views: view.SourceViews, arena: std.mem.Allocator) viz.DrawContext {
        return .{
            .win = win,
            .theme = default_theme,
            .bridge = &self.br,
            .track = .{ .format_name = "TEST", .visualizer = "sequence" },
            .views = views,
            .spec_levels = &self.levels,
            .spec_peaks = &self.levels,
            .spec_peak_glow = &self.levels,
            .nav = &self.nav,
            .pcm_bands = &self.bands,
            .pcm_band_peaks = &self.bands,
            .pcm_band_peak_glow = &self.bands,
            .pcm_peak = 0,
            .spark = &self.spark,
            .arena = arena,
        };
    }
};

const ProgramFix = struct {
    const len: u32 = 100_000;
    const lookahead: u32 = 0x10000;
    const wide_name: [120]u8 = @splat('W');

    fn track(_: *anyopaque, _: u16) view.SequenceTrack {
        return .{};
    }
    fn event(_: *anyopaque, index: u32) view.SequenceEvent {
        return .{ .tick = index, .kind = .end };
    }
    fn page(_: *anyopaque, ch: u16, from: u32, skip: u32, dest: []view.SequenceEvent) view.EventRange {
        if (from >= len) return .{};
        const total = @min(len - from, @as(u64, skip) + dest.len + lookahead);
        const written = @min(total -| skip, dest.len);
        for (dest[0..written], skip..) |*ev, at| ev.* = .{ .instr_index = from + @as(u32, @intCast(at)), .track = ch, .kind = .end };
        return .{ .written = @intCast(written), .total_in_range = total };
    }
    fn instrument(_: *anyopaque, _: u16) view.InstrumentInfo {
        return .{};
    }
    fn wideInstrument(_: *anyopaque, _: u16) view.InstrumentInfo {
        return .{ .name = &wide_name, .macros = .{ .fmreg_len = 1 } };
    }
    fn voicePrograms() view.SequenceView {
        return .{ .ctx = undefined, .kind = .voice_programs, .track_count = 2, .channel_count = 2, .tick_rate = 72, .length_ticks = 0, .track = track, .bytecodePage = page };
    }
    fn eventStream() view.SequenceView {
        return .{ .ctx = undefined, .kind = .event_stream, .track_count = 2, .channel_count = 2, .tick_rate = 120, .length_ticks = 100, .track = track, .eventAt = event, .event_count = 100 };
    }
};

test "The pan range follows the widest row on screen" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{ .instruments = .{ .ctx = undefined, .count = 1, .get = ProgramFix.wideInstrument } }, arena.allocator());
    var state = State{ .open = true, .section = .instrument };
    draw(&ctx, &state);
    try std.testing.expect(state.max_horizontal > 0);
    _ = handleKey(&ctx, &state, vaxis.Key.right);
    _ = handleKey(&ctx, &state, vaxis.Key.end);
    draw(&ctx, &state);
    try std.testing.expect(state.scroll > 0);
    try std.testing.expectEqual(@as(u16, 0), state.max_horizontal);
    try std.testing.expectEqual(@as(u16, 0), state.horizontal);
}

test "C changes the voice-program channel only in the events section" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    var bank = view.SequenceStateBank{ .channels = 2 };
    bank.slots[0].pc = 0;
    bank.slots[1].pc = 0;
    h.br.sequence.write(bank);
    var ctx = h.context(win, .{ .sequence = ProgramFix.eventStream() }, arena.allocator());
    var state = State{ .open = true, .section = .events };
    draw(&ctx, &state);
    _ = handleKey(&ctx, &state, vaxis.Key.page_down);
    _ = handleKey(&ctx, &state, 'c');
    try std.testing.expectEqual(@as(u32, state.page_rows), state.scroll);
    try std.testing.expectEqual(@as(u16, 0), state.channel);

    ctx.views.sequence = ProgramFix.voicePrograms();
    state.section = .chip;
    _ = handleKey(&ctx, &state, vaxis.Key.end);
    draw(&ctx, &state);
    const chip_scroll = state.scroll;
    try std.testing.expect(chip_scroll > 0);
    _ = handleKey(&ctx, &state, 'C');
    try std.testing.expectEqual(chip_scroll, state.scroll);
    try std.testing.expectEqual(@as(u16, 0), state.channel);

    state.section = .events;
    draw(&ctx, &state);
    _ = handleKey(&ctx, &state, vaxis.Key.page_down);
    _ = handleKey(&ctx, &state, 'c');
    try std.testing.expectEqual(@as(u32, 0), state.scroll);
    try std.testing.expectEqual(@as(u16, 1), state.channel);
}

test "J and K keep the scroll outside the instrument and macro sections" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 14, .cols = 78, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 78, .height = 14, .screen = &screen };
    var h = DrawHarness{};
    var ctx = h.context(win, .{ .sequence = ProgramFix.eventStream(), .instruments = .{ .ctx = undefined, .count = 4, .get = ProgramFix.instrument } }, arena.allocator());
    var state = State{ .open = true, .section = .events };
    draw(&ctx, &state);
    _ = handleKey(&ctx, &state, vaxis.Key.page_down);
    _ = handleKey(&ctx, &state, 'k');
    try std.testing.expectEqual(@as(u16, 1), h.nav.instrument_sel);
    try std.testing.expectEqual(@as(u32, state.page_rows), state.scroll);

    state.section = .instrument;
    _ = handleKey(&ctx, &state, 'j');
    try std.testing.expectEqual(@as(u16, 0), h.nav.instrument_sel);
    try std.testing.expectEqual(@as(u32, 0), state.scroll);
}
