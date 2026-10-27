//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Theme = @import("../theme.zig").Theme;
const default_theme = @import("../theme.zig").default_theme;
const Bridge = @import("../bridge.zig").Bridge;
const paint = @import("../paint.zig");
const view = @import("../view.zig");

pub const LoggedWrite = struct { index: u32, write: view.RegWrite };

pub fn recentWrites(bridge: *const Bridge, out: *[view.write_log_cap]LoggedWrite) []const LoggedWrite {
    const end = bridge.write_log_i.load(.acquire);
    const count = @min(end, view.write_log_cap);
    for (out[0..count], 0..) |*slot, i| {
        const index = end -% @as(u32, @intCast(count - i));
        slot.* = .{ .index = index, .write = @bitCast(bridge.write_log[index % view.write_log_cap].load(.acquire)) };
    }
    const next = bridge.write_log_i.load(.acquire) +% 1;
    var first: usize = 0;
    while (first < count and next -% out[first].index > view.write_log_cap) first += 1;
    return out[first..count];
}

pub fn chipName(dump: ?view.DumpView, opl3: bool) []const u8 {
    const chip = if (dump) |d| d.chip else return if (opl3) "OPL3" else "OPL2";
    return switch (chip) {
        .opl2, .dual_opl2 => "OPL2",
        .opl3, .dual_opl3 => "OPL3",
    };
}

pub const spec_bar_rows: u16 = 10;
pub const top_rows: u16 = spec_bar_rows + 3;
pub const order_w: u16 = 10;
pub const gauge_value_x: u16 = 14;

pub const note_names = [_][]const u8{ "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" };
pub const spark_glyphs = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
pub const peak_on = "▮";
pub const peak_off = "▯";
pub const sup_digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };
pub const sup_k = "ᵏ";

pub fn specLabelWidth(one_based: u16) u16 {
    return if (one_based < 10) 1 else 2;
}

fn writeSpecLabel(win: vaxis.Window, x: u16, row: u16, one_based: u16, style: vaxis.Style) void {
    if (one_based == 0) return;
    if (one_based < 10) {
        win.writeCell(x, row, .{
            .char = .{ .grapheme = sup_digits[one_based], .width = 1 },
            .style = style,
        });
        return;
    }
    win.writeCell(x, row, .{
        .char = .{ .grapheme = sup_digits[@min(one_based / 10, 9)], .width = 1 },
        .style = style,
    });
    win.writeCell(x +| 1, row, .{
        .char = .{ .grapheme = sup_digits[one_based % 10], .width = 1 },
        .style = style,
    });
}

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

pub fn spectrumPanelWidth(bar_w: u16, n: u16) u16 {
    const bars = @max(n, 1);
    return 2 + 4 + bars * bar_w + (bars -| 1);
}

pub fn fillChannelCols(col_x: []u16, col_w: []u16, width: u16, gutter: u16, chans: u16) void {
    const n = @min(chans, @min(@as(u16, @intCast(col_x.len)), @as(u16, @intCast(col_w.len))));
    if (n == 0) return;
    const avail = width -| gutter;
    const base = avail / n;
    const extra = avail % n;
    var x = gutter;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const cw = @max(1, base + @as(u16, @intFromBool(i < extra)));
        col_x[i] = x;
        col_w[i] = cw;
        x += cw;
    }
}

pub fn drawSpectrum(
    win: vaxis.Window,
    theme: Theme,
    x: u16,
    y: u16,
    box_w: u16,
    bar_w: u16,
    levels: []const f32,
    peaks: []const f32,
    peak_glow: []const f32,
    options: struct { height: u16 = top_rows, channel_ids: ?[]const u16 = null },
) void {
    const n = @min(levels.len, @min(peaks.len, peak_glow.len));
    if (n == 0) return;
    const box = win.child(.{
        .x_off = x,
        .y_off = y,
        .width = box_w,
        .height = options.height,
        .border = .{ .where = .all, .glyphs = .single_rounded, .style = theme.style(.spectrum_frame) },
    });
    paint.printAt(win, x + (box_w -| 10) / 2, y, " SPECTRUM ", theme.style(.spectrum_title));

    const digit_row = box.height -| 1;
    const bar_rows = @min(spec_bar_rows, digit_row);

    for (0..n) |ch| {
        const bar_x: u16 = @intCast(2 + ch * (bar_w + 1));
        const level = levels[ch];
        paint.drawMeterColumn(box, theme, bar_x, 0, bar_rows, bar_w, .{
            .level = level,
            .peak = peaks[ch],
            .glow = peak_glow[ch],
        });

        const one: u16 = if (options.channel_ids) |ids| ids[ch] + 1 else @intCast(ch + 1);
        const active = level > 0.01;
        const style = if (active) theme.style(.spec_digit_on) else theme.style(.spec_digit_off);
        const lx = bar_x + (bar_w -| specLabelWidth(one)) / 2;
        writeSpecLabel(box, lx, digit_row, one, style);
    }
}

pub const instrument_labels = [_][]const u8{
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

pub fn drawInstrumentGauges(
    win: vaxis.Window,
    theme: Theme,
    arena: std.mem.Allocator,
    ins: view.InstrumentInfo,
    x: u16,
    top: u16,
    gauge_w: u16,
    clip_right: u16,
) void {
    switch (ins.patch) {
        .opl_2op, .opl_4op => {},
        else => return,
    }
    const patch = ins.opl();
    const val1_x: u16 = x + gauge_value_x;
    const g1_x: u16 = x + 18;
    const val2_x: u16 = x + 19 + gauge_w;
    const g2_x: u16 = x + 23 + gauge_w;
    const n_ops: usize = @min(@as(usize, if (patch.op_count == 0) 2 else patch.op_count), 4);
    const four_width = (clip_right -| val1_x) / 4;
    const ops = patch.ops[0..n_ops];
    if (top > 0 and ins.patch == .opl_2op) {
        const mod_x = if (patch.carrier_first) val2_x else val1_x;
        const car_x = if (patch.carrier_first) val1_x else val2_x;
        if (mod_x + 3 <= clip_right) paint.printAt(win, mod_x, top - 1, "MOD", theme.style(.inst_title));
        if (car_x + 3 <= clip_right) paint.printAt(win, car_x, top - 1, "CAR", theme.style(.inst_title));
    }
    if (top > 0 and n_ops > 2) for (0..n_ops) |i| {
        const column = val1_x + @as(u16, @intCast(i)) * four_width;
        const label = arena.print("OP{d}", .{i + 1}) catch return;
        paint.printFit(win, column, top - 1, label, @min(four_width, clip_right -| column), theme.style(.inst_title));
    };
    for (instrument_labels, 0..) |label, i| {
        const row: u16 = top + @as(u16, @intCast(i));
        paint.printFit(win, x + 1, row, label, clip_right -| x -| 1, theme.style(.inst_label));
        for (ops, 0..) |op, oi| {
            const vcol: u16 = if (n_ops > 2) val1_x + @as(u16, @intCast(oi)) * four_width else if (oi == 0) val1_x else val2_x;
            const gcol: u16 = if (n_ops > 2) vcol + 4 else if (oi == 0) g1_x else g2_x;
            const gauge_width = @min(if (n_ops > 2) four_width -| 5 else gauge_w, clip_right -| gcol);
            if (vcol >= clip_right) continue;
            switch (i) {
                0, 1, 2, 3 => {
                    const on = switch (i) {
                        0 => op.tremolo,
                        1 => op.vibrato,
                        2 => op.sustaining,
                        else => op.ksr,
                    };
                    paint.printFit(win, vcol, row, if (on) "ON " else "OFF", @min(3, clip_right -| vcol), if (on) theme.style(.inst_flag_on) else theme.style(.inst_flag_off));
                },
                else => {
                    const value: u8, const max: u8 = switch (i) {
                        4 => .{ op.mult, 15 },
                        5 => .{ op.ksl, 3 },
                        6 => .{ 63 - @as(u8, op.level), 63 },
                        7 => .{ op.attack, 15 },
                        8 => .{ op.decay, 15 },
                        9 => .{ op.sustain, 15 },
                        10 => .{ op.release, 15 },
                        else => .{ op.wave, 7 },
                    };
                    const text = arena.print("{d: >3}", .{value}) catch return;
                    paint.printFit(win, vcol, row, text, @min(3, clip_right -| vcol), theme.style(.inst_value));
                    drawGauge(win, theme, gcol, row, value, max, gauge_width);
                },
            }
        }
    }
}

pub fn instrumentMode(ins: view.InstrumentInfo) []const u8 {
    return switch (ins.patch) {
        .empty => "UNUSED",
        .midi => "MIDI",
        .opl_4op => "4OP",
        .sample => "PCM",
        .opl_2op => |patch| if (patch.additive) "ADD" else "FM",
    };
}

pub fn instrumentTitle(a: std.mem.Allocator, head: []const u8, ins: view.InstrumentInfo) ?[]const u8 {
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (ins.patch == .empty) {
        w.print("{s}   UNUSED", .{head}) catch return null;
        return a.dupe(u8, w.buffered()) catch null;
    }
    const patch = ins.opl();
    w.print("{s}  {s}", .{ head, instrumentMode(ins) }) catch return null;
    if (ins.patch == .opl_2op or ins.patch == .opl_4op) w.print("  FB {d}", .{patch.feedback}) catch return null;
    if (ins.patch == .opl_4op) w.print("/{d}  ALG {d}", .{ patch.feedback2, patch.algorithm }) catch return null;
    if (patch.fine_tune != 0) w.print("  SL {d}", .{patch.fine_tune}) catch return null;
    if (ins.macros.arpeggio_len != 0) w.print("  ARP {d}/{d}", .{ ins.macros.arpeggio_len, ins.macros.arpeggio_speed }) catch return null;
    if (ins.name.len != 0) return a.print("{s}  {s}", .{ w.buffered(), ins.name }) catch null;
    return a.dupe(u8, w.buffered()) catch null;
}

fn drawGauge(win: vaxis.Window, t: Theme, x: u16, row: u16, value: u8, max: u8, width: u16) void {
    if (max == 0) return;
    const filled = (@as(u16, value) * width + max / 2) / max;
    for (0..width) |i| {
        const on = i < filled;
        win.writeCell(x + @as(u16, @intCast(i)), row, .{
            .char = .{ .grapheme = if (on) "█" else "·", .width = 1 },
            .style = if (on) t.style(.gauge_on) else t.style(.gauge_off),
        });
    }
}

pub fn pitchFromFnum(fnum: u10, block: u3, notes: *const [12]u16, octave_offset: i8) ?struct { semitone: u8, octave: u8 } {
    if (fnum == 0) return null;
    var best: i8 = 0;
    var best_d: u16 = 0xffff;
    var i: i8 = -1;
    while (i <= 12) : (i += 1) {
        const ref: u16 = if (i < 0) notes[11] / 2 else if (i == 12) notes[0] * 2 else notes[@intCast(i)];
        const d: u16 = if (fnum > ref) fnum - ref else ref - fnum;
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    const octave = @as(i16, block) + octave_offset + @as(i16, if (best < 0) -1 else if (best == 12) 1 else 0);
    return .{ .semitone = @intCast(@mod(best, 12)), .octave = @intCast(@max(0, octave)) };
}

pub fn noteToken(semitone: u8, octave: u8) [3]u8 {
    const name = note_names[semitone % note_names.len];
    return .{ name[0], name[1], '0' + @as(u8, @min(octave, 9)) };
}

pub fn describeSequenceEvent(a: std.mem.Allocator, sv: view.SequenceView, ev: view.SequenceEvent) ![]const u8 {
    if (sv.eventLexicon) |lexicon| {
        const desc = lexicon(sv.ctx, ev);
        if (desc.text.len != 0) return if (ev.payload == .control) a.print("{s} {d}", .{ desc.text, ev.payload.control.value }) else desc.text;
    }
    return switch (ev.payload) {
        .none => if (ev.kind == .end) "End" else @tagName(ev.kind),
        .note => |n| blk: {
            if (sv.kind == .voice_programs and (ev.kind == .note_off or n.velocity == 0)) {
                break :blk a.print("{s}  duration {d}", .{ if (ev.kind == .note_off) "Release" else "Play current note", n.duration_ticks orelse 0 });
            }
            if (ev.kind == .note_off and n.note >= 128) break :blk "Release";
            const token = noteToken(n.note % 12, n.note / 12);
            if (n.duration_ticks) |duration| break :blk a.print("{s} {s}  velocity {d}  duration {d}", .{ if (ev.kind == .note_off) "Release" else "Note", token, n.velocity, duration });
            break :blk a.print("{s} {s}  velocity {d}", .{ if (ev.kind == .note_off) "Release" else "Note", token, n.velocity });
        },
        .program => |p| if (p == view.instrument_none) "Instrument --" else a.print("Instrument {X:0>2}", .{p}),
        .wait => |ticks| a.print("Wait {d} ticks", .{ticks}),
        .tempo => |tempo| a.print("Tempo {d}", .{tempo}),
        .control => |c| a.print("Control {d} = {d}", .{ c.cc, c.value }),
        .pitch_bend => |bend| a.print("Pitch bend {d}", .{bend}),
        .aftertouch => |value| a.print("Aftertouch {d}", .{value}),
        .label => |label| a.print("Label {X:0>2}", .{label}),
        .branch => |b| if (sv.kind == .voice_programs) offsetBranch(a, b) else switch (b.kind) {
            .ret => "Return from chorus",
            .call => a.print("Call label {X}", .{b.target}),
            .loop => a.print("Loop to label {X}", .{b.target}),
            .skip => a.print("Skip label {X}", .{b.target}),
            .jump => a.print("Repeat label {X}, {d} times", .{ b.target, b.repeats }),
        },
        .jump => |target| a.print("Jump {X}", .{target}),
        .start_program => |program| a.print("Start program {X}", .{program}),
        .sysex_ref => |ref| a.print("SysEx {X}", .{ref}),
    };
}

const drum_names = [_][]const u8{ "BD", "SD", "TT", "TC", "HH" };

pub fn drawOplStrip(
    win: vaxis.Window,
    theme: Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    voice_count: u8,
    snap: view.ChipSnapshot,
    levels: []const f32,
) void {
    if (width == 0 or height == 0 or voice_count == 0) return;
    const n: usize = @min(@as(usize, voice_count), view.max_opl_voices);
    paint.printAt(win, x, y, "OPL", theme.style(.spectrum_title));
    const label_w: u16 = 4;
    const inner_w = width -| label_w;
    if (inner_w == 0) return;

    const rows: u16 = if (height >= 2 and n > 9) 2 else 1;
    const per_row = if (rows == 2) (n + 1) / 2 else n;
    const cell_w: u16 = @max(1, inner_w / @as(u16, @intCast(@max(per_row, 1))));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row_i: u16 = if (rows == 2 and i >= per_row) 1 else 0;
        if (row_i >= height) break;
        const col_i = if (row_i == 1) i - per_row else i;
        const cx = x + label_w + @as(u16, @intCast(col_i)) * cell_w;
        const cy = y + row_i;
        const voice = snap.voices[i];
        const chan_type: view.OplChanType = @fromBackingInt(@intCast(voice.chan_type));
        const keyed = voice.keyed;
        const style = if (keyed) theme.style(.voice_key_on) else theme.style(.voice_key_off);
        if (chan_type == .four_op_lo) {
            paint.printAt(win, cx, cy, "   ", style);
            continue;
        }
        if (chan_type == .drum) {
            const name = drum_names[@min(i % 5, drum_names.len - 1)];
            if (keyed) paint.printAt(win, cx, cy, name, style) else paint.printAt(win, cx, cy, "---", style);
            continue;
        }
        if (!keyed) {
            paint.printAt(win, cx, cy, "---", style);
            continue;
        }
        if (pitchFromFnum(voice.fnum, voice.block, &view.standard_fnum_notes, 0)) |p| {
            const tok = noteToken(p.semitone, p.octave);
            paint.printAt(win, cx, cy, &tok, style);
        } else {
            paint.printAt(win, cx, cy, "---", style);
        }
    }

    if (height >= 3 and cell_w >= 2) {
        const bar_h = height - rows;
        const bar_y = y + rows;
        const bar_w = @max(1, cell_w -| 1);
        for (0..n) |ch| {
            if (ch >= levels.len) break;
            const row_i: u16 = if (rows == 2 and ch >= per_row) 1 else 0;
            _ = row_i;
            const col_i = if (rows == 2 and ch >= per_row) ch - per_row else ch;
            const bx = x + label_w + @as(u16, @intCast(col_i)) * cell_w;
            if (rows == 2 and ch >= per_row) continue;
            paint.drawMeterColumn(win, theme, bx, bar_y, bar_h, bar_w, .{ .level = levels[ch] });
        }
    }
}

fn offsetBranch(a: std.mem.Allocator, b: @FieldType(view.EventPayload, "branch")) ![]const u8 {
    const verb = switch (b.kind) {
        .ret => return "Return",
        .jump => "Jump to",
        .call => "Call",
        .loop => "Repeat from",
        .skip => "Skip to",
    };
    if (b.target == view.sequence_pc_none) return a.print("{s} an offset outside the data", .{verb});
    return a.print("{s} {X:0>6}", .{ verb, b.target });
}

// --- tests -------------------------------------------------------------------

test "pitchFromFnum names notes with the source's own tuning" {
    const a2m_notes = [12]u16{ 343, 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647 };
    const d4 = pitchFromFnum(385, 4, &a2m_notes, 0).?;
    try std.testing.expectEqual(@as(u8, 2), d4.semitone);
    try std.testing.expectEqual(@as(u8, 4), d4.octave);
    const lds_c = pitchFromFnum(343, 3, &a2m_notes, 1).?;
    try std.testing.expectEqual(@as(u8, 0), lds_c.semitone);
    try std.testing.expectEqual(@as(u8, 4), lds_c.octave);
    const below = pitchFromFnum(343, 4, &view.standard_fnum_notes, 0).?;
    try std.testing.expectEqual(@as(u8, 11), below.semitone);
    try std.testing.expectEqual(@as(u8, 3), below.octave);
    const above = pitchFromFnum(686, 4, &a2m_notes, 0).?;
    try std.testing.expectEqual(@as(u8, 0), above.semitone);
    try std.testing.expectEqual(@as(u8, 5), above.octave);
}
