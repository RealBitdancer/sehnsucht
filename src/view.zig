//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const max_pattern_channels: usize = 32;
pub const max_effect_columns: usize = 2;
pub const max_opl_voices: usize = 36;
pub const max_active_voices: usize = 64;
pub const write_log_cap: usize = 32;

pub const ViewCaps = packed struct(u8) {
    pattern: bool = false,
    order: bool = false,
    instruments: bool = false,
    sequence: bool = false,
    dump: bool = false,
    _reserved: u3 = 0,

    pub fn subsetOf(need: ViewCaps, have: ViewCaps) bool {
        inline for (@typeInfo(ViewCaps).@"struct".field_names) |field_name| {
            if (field_name.len != 0 and field_name[0] == '_') continue;
            if (@field(need, field_name) and !@field(have, field_name)) return false;
        }
        return true;
    }
};

pub const SourceViews = struct {
    pattern: ?PatternView = null,
    order: ?OrderView = null,
    instruments: ?InstrumentBank = null,
    sequence: ?SequenceView = null,
    dump: ?DumpView = null,

    pub fn caps(self: SourceViews) ViewCaps {
        var out: ViewCaps = .{};
        inline for (@typeInfo(SourceViews).@"struct".field_names) |field_name| {
            if (@hasField(ViewCaps, field_name)) {
                @field(out, field_name) = @field(self, field_name) != null;
            }
        }
        return out;
    }
};

pub fn SeqLock(comptime T: type) type {
    comptime {
        rejectPointers(T);
    }
    return struct {
        seq: std.atomic.Value(u32) = .init(0),
        data: [@sizeOf(T)]std.atomic.Value(u8) = @splat(.init(0)),
        const max_retries: u32 = 128;

        pub fn write(self: *@This(), value: T) void {
            _ = self.seq.fetchAdd(1, .acq_rel);
            for (&self.data, std.mem.asBytes(&value)) |*byte, source| byte.store(source, .release);
            _ = self.seq.fetchAdd(1, .release);
        }

        pub fn read(self: *const @This()) T {
            var tries: u32 = 0;
            while (tries < max_retries) {
                var spins: u32 = 0;
                var a = self.seq.load(.acquire);
                while (a & 1 != 0) {
                    if (spins == 1_000_000) return std.mem.zeroes(T);
                    spins += 1;
                    std.atomic.spinLoopHint();
                    a = self.seq.load(.acquire);
                }
                var copy: T = undefined;
                for (std.mem.asBytes(&copy), &self.data) |*byte, *source| byte.* = source.load(.acquire);
                const b = self.seq.load(.acquire);
                if (a == b) return copy;
                tries += 1;
            }
            return std.mem.zeroes(T);
        }
    };
}

fn rejectPointers(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("SeqLock T cannot hold pointers"),
        .@"struct" => |s| {
            inline for (s.field_types) |field_type| rejectPointers(field_type);
        },
        .array => |a| rejectPointers(a.child),
        .optional => |o| rejectPointers(o.child),
        .@"union" => |u| {
            inline for (u.field_types) |field_type| rejectPointers(field_type);
        },
        else => {},
    }
}

pub const GridKind = enum {
    shared_pattern,
    per_channel_stream,
};

pub const Occupancy = enum {
    independent,
    packed_event,
};

pub const ColumnId = enum { note, instrument, volume, effect, effect2, extra };
pub const EffectStyle = enum { raw_hex, nibble, letter_param, decimal };
pub const DigitStyle = enum { hex, decimal };

pub const CellTemplate = struct {
    width: u16,
    note_w: u8 = 3,
    inst_w: u8 = 2,
    vol_w: u8 = 2,
    fx_w: u8 = 3,
    extra_w: u8 = 1,
};

pub const Note = union(enum) {
    none,
    pitch: struct { semitone: u8, octave: u8, fixed: bool = false },
    off,
    cut,
    rest,
    hold,
};

pub const CellExtra = union(enum) {
    none,
    retrigger,
    delay: u8,
    pitch: i8,
};

pub const Effect = struct {
    cmd: u8 = 0,
    param: u16 = 0,
};

pub const Cell = struct {
    note: Note = .none,
    instrument: ?u16 = null,
    volume: ?u8 = null,
    effects: [max_effect_columns]Effect = .{ .{}, .{} },
    extra: CellExtra = .none,
};

pub const FourOpRole = enum { none, hi, lo };

pub const ChannelInfo = struct {
    name: []const u8 = "",
    kind: enum { fm, pcm, drum, control } = .fm,
    opl_voice: ?u8 = null,
    four_op_pair: ?u8 = null,
    four_op_role: FourOpRole = .none,
    present: bool = true,
    muted: bool = false,
    pan: u8 = 128,
};

pub const EffectDesc = struct {
    letter: ?u8 = null,
    text: []const u8 = "",
};

pub const standard_fnum_notes = [12]u16{ 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647, 686 };

pub const PatternView = struct {
    ctx: *anyopaque,
    grid: GridKind,
    occupancy: Occupancy,
    columns: []const ColumnId,
    effect_style: EffectStyle,
    inst_digits: DigitStyle = .hex,
    vol_digits: DigitStyle = .hex,
    cell_template: CellTemplate,
    channels: u16,
    rows_per_pattern: u16,
    num_patterns: u16,
    mixed_pcm: bool = false,
    riff_count: u16 = 0,
    rate_text: []const u8 = "",
    fnum_notes: *const [12]u16 = &standard_fnum_notes,
    fnum_octave_offset: i8 = 0,
    riffName: ?*const fn (ctx: *anyopaque, riff_id: u16) []const u8 = null,
    cell: *const fn (ctx: *anyopaque, pattern: u16, row: u16, chan: u16) Cell,
    channelInfo: ?*const fn (ctx: *anyopaque, chan: u16) ChannelInfo = null,
    effectLexicon: ?*const fn (ctx: *anyopaque, cmd: u8, param: u16) EffectDesc = null,
    patternName: ?*const fn (ctx: *anyopaque, pattern: u16) []const u8 = null,
};

pub const OrderKind = enum {
    shared_index,
    per_channel,
    per_channel_index,
};

pub const OrderEntry = struct {
    kind: enum { pattern, jump, skip, end },
    pattern: u16 = 0,
    jump_to: u16 = 0,
};

pub const ChannelRef = struct {
    start: u32 = 0,
    pattern: u16 = 0,
    transpose: i8 = 0,
    target: enum { note, instrument } = .note,
};

pub const OrderView = struct {
    ctx: *anyopaque,
    len: u16,
    kind: OrderKind,
    restart: ?u16 = null,
    entry: *const fn (ctx: *anyopaque, index: u16) OrderEntry,
    channelRef: ?*const fn (ctx: *anyopaque, index: u16, chan: u16) ChannelRef = null,
};

pub const InstrumentKind = enum { empty, opl_2op, opl_4op, midi, sample };

pub const OperatorParams = struct {
    tremolo: bool = false,
    vibrato: bool = false,
    sustaining: bool = false,
    ksr: bool = false,
    mult: u4 = 0,
    ksl: u2 = 0,
    level: u6 = 0,
    attack: u4 = 0,
    decay: u4 = 0,
    sustain: u4 = 0,
    release: u4 = 0,
    wave: u3 = 0,
};

pub const OplPatch = struct {
    ops: [4]OperatorParams = @splat(.{}),
    op_count: u8 = 2,
    feedback: u3 = 0,
    feedback2: u3 = 0,
    algorithm: u8 = 0,
    additive: bool = false,
    perc_voice: u8 = 0,
    fine_tune: i8 = 0,
    panning: u8 = 0,
    carrier_first: bool = false,
};

pub const MidiPatch = struct {
    program: u8 = 0,
};

pub const SamplePatch = struct {
    bytes: u32 = 0,
    c2spd: u32 = 0,
    default_volume: u8 = 0,
    loop_start: u32 = 0,
    loop_end: u32 = 0,
    loop_on: bool = false,
    filename: []const u8 = "",
    panning: u8 = 0,
};

pub const MacroHeaders = struct {
    fmreg_len: u8 = 0,
    fmreg_loop_begin: u8 = 0,
    fmreg_loop_length: u8 = 0,
    fmreg_keyoff: u8 = 0,
    arpeggio_len: u8 = 0,
    arpeggio_speed: u8 = 0,
    arpeggio_table: u8 = 0,
    arpeggio_loop_begin: u8 = 0,
    arpeggio_loop_length: u8 = 0,
    arpeggio_keyoff: u8 = 0,
    vibrato_len: u8 = 0,
    vibrato_speed: u8 = 0,
    vibrato_delay: u8 = 0,
    vibrato_table: u8 = 0,
    vibrato_loop_begin: u8 = 0,
    vibrato_loop_length: u8 = 0,
    vibrato_keyoff: u8 = 0,
    dis_fmreg_cols: u32 = 0,
};

pub const InstrumentPatch = union(InstrumentKind) {
    empty,
    opl_2op: OplPatch,
    opl_4op: OplPatch,
    midi: MidiPatch,
    sample: SamplePatch,
};

pub const InstrumentInfo = struct {
    name: []const u8 = "",
    patch: InstrumentPatch = .empty,
    macros: MacroHeaders = .{},

    pub fn opl(self: InstrumentInfo) OplPatch {
        return switch (self.patch) {
            inline .opl_2op, .opl_4op => |p| p,
            else => .{},
        };
    }

    pub fn hasMacros(self: InstrumentInfo) bool {
        return self.macros.fmreg_len != 0 or self.macros.arpeggio_len != 0 or self.macros.vibrato_len != 0;
    }

    pub fn macroRows(self: InstrumentInfo) u16 {
        return @max(@as(u16, self.macros.fmreg_len), @max(@as(u16, self.macros.arpeggio_len), @as(u16, self.macros.vibrato_len)));
    }

    pub fn macroLen(self: InstrumentInfo, kind: MacroKind) u16 {
        return switch (kind) {
            .fmreg => self.macros.fmreg_len,
            .arpeggio => self.macros.arpeggio_len,
            .vibrato => self.macros.vibrato_len,
        };
    }
};

pub const MacroKind = enum { fmreg, arpeggio, vibrato };

pub const MacroStep = struct {
    empty: bool = true,
    duration: u8 = 0,
    panning: u8 = 0,
    freq_slide: i16 = 0,
    flags: u8 = 0,
    ops: [2]OperatorParams = @splat(.{}),
    feedback: u3 = 0,
    additive: bool = false,
    arp_note: u8 = 0,
    vib_delta: i8 = 0,
    disabled: bool = false,
};

pub const InstrumentBank = struct {
    ctx: *anyopaque,
    count: u16,
    get: *const fn (ctx: *anyopaque, index: u16) InstrumentInfo,
    macroStep: ?*const fn (ctx: *anyopaque, index: u16, kind: MacroKind, step: u16) MacroStep = null,
};

pub const instrument_none: u16 = std.math.maxInt(u16);

pub const ChannelState = struct {
    instrument: u16 = instrument_none,
    note_code: u8 = 0,
    keyed: bool = false,
    vol_mod: u8 = 0,
    vol_car: u8 = 0,
    panning: u8 = 0,
    fmreg_pos: u8 = 0,
    fmreg_duration: u8 = 0,
    arpg_pos: u8 = 0,
    arpg_count: u8 = 0,
    arpg_table: u8 = 0,
    vib_pos: u8 = 0,
    vib_delay: u8 = 0,
    vib_table: u8 = 0,
    volume_lock: bool = false,
    vol4op_lock: bool = false,
    pan_lock: bool = false,
    peak_lock: bool = false,
    effects: [2]Effect = .{ .{}, .{} },
    cursor0: u16 = 0,
    cursor1: u16 = 0,
    cursor2: u16 = 0,
};

comptime {
    if (@sizeOf(ChannelState) > 40) @compileError("ChannelState grew past the 40-byte budget");
}

pub const ChannelStateBank = struct {
    channels: u16 = 0,
    slots: [max_pattern_channels]ChannelState = @splat(.{}),
};

pub const SequenceKind = enum {
    linear_midi,
    voice_programs,
    event_stream,
};

pub const SequenceTrack = struct {
    name: []const u8 = "",
    channel: u8 = 0,
    program: u16 = 0,
    kind: enum { melodic, drum, pcm, control } = .melodic,
    in_use: bool = true,
};

pub const SequenceEventKind = enum(u8) {
    note_on,
    note_off,
    duration_note,
    pitch_bend,
    control,
    program,
    tempo,
    aftertouch,
    jump,
    label,
    start_program,
    sysex,
    wait,
    end,
};

pub const EventPayload = union(enum) {
    none,
    note: struct { note: u8, velocity: u8, duration_ticks: ?u32 = null },
    pitch_bend: u16,
    control: struct { cc: u8, value: u16 },
    program: u16,
    tempo: u32,
    aftertouch: u8,
    jump: u32,
    branch: struct { target: u32 = 0, kind: enum { jump, call, ret, loop, skip }, repeats: u16 = 0 },
    label: u16,
    start_program: u16,
    sysex_ref: u16,
    wait: u32,
};

pub const sequence_unassigned: u16 = std.math.maxInt(u16);
pub const sequence_pc_none: u32 = std.math.maxInt(u32);

pub const SequenceEvent = struct {
    tick: u32 = 0,
    instr_index: u32 = 0,
    track: u16 = 0,
    channel: u8 = 0,
    kind: SequenceEventKind = .note_on,
    payload: EventPayload = .none,
};

pub const EventRange = struct {
    written: u16 = 0,
    total_in_range: u32 = 0,
};

pub const SequenceBranch = struct { label: u16 = 0, tick: u32 = 0 };

pub const SequenceMarker = struct {
    position: u32 = 0,
    event: SequenceEvent = .{},
};

pub const SequenceView = struct {
    ctx: *anyopaque,
    kind: SequenceKind,
    position_unit: enum { tick, event_index } = .tick,
    track_count: u16,
    channel_count: u16,
    tick_rate: u32,
    length_ticks: u32,
    track: *const fn (ctx: *anyopaque, index: u16) SequenceTrack,
    eventLexicon: ?*const fn (ctx: *anyopaque, ev: SequenceEvent) EffectDesc = null,
    eventsInRange: ?*const fn (
        ctx: *anyopaque,
        tick0: u32,
        tick1: u32,
        dest: []SequenceEvent,
    ) EventRange = null,
    programAt: ?*const fn (ctx: *anyopaque, program: u16) []const u8 = null,
    bytecodePage: ?*const fn (ctx: *anyopaque, chan: u16, from: u32, skip: u32, dest: []SequenceEvent) EventRange = null,
    bytecodeWindow: ?*const fn (ctx: *anyopaque, chan: u16, from: u32, dest: []SequenceEvent) EventRange = null,
    eventAt: ?*const fn (ctx: *anyopaque, index: u32) SequenceEvent = null,
    labelTable: ?*const fn (ctx: *anyopaque, label: u16) u32 = null,
    event_count: u32 = 0,
    branch_count: u16 = 0,
    branchAt: ?*const fn (ctx: *anyopaque, index: u16) SequenceBranch = null,
    marker_count: u32 = 0,
    markerAt: ?*const fn (ctx: *anyopaque, index: u32) SequenceMarker = null,
};

pub const SequenceFx = packed struct(u8) {
    slide: bool = false,
    vibrato: bool = false,
    modulate: bool = false,
    _pad: u5 = 0,
};

pub const SequenceChannelState = struct {
    program: u16 = 0,
    note: u8 = 0,
    keyed: bool = false,
    bend: u16 = 0,
    transpose: i8 = 0,
    opl_voice: u8 = 0xff,
    pc: u32 = sequence_pc_none,
    duration: u8 = 0,
    chan_tempo: u8 = 0,
    priority: u8 = 0,
    stack: u8 = 0,
    fx: SequenceFx = .{},
};

pub const SequenceStateBank = struct {
    channels: u16 = 0,
    slots: [max_pattern_channels]SequenceChannelState = @splat(.{}),
    voice_count: u16 = 0,
    voices: [max_active_voices]ActiveVoice = @splat(.{}),
};

pub const ActiveVoice = struct {
    channel: u16 = 0,
    program: u16 = 0,
    note: u8 = 0,
    velocity: u8 = 0,
    opl_voice: u8 = 0xff,
    kind: enum { fm, drum, pcm } = .fm,
    keyed: bool = false,
    level: u8 = 0,
};

pub const PatternCursor = struct {
    active: bool = false,
    order: u16 = 0,
    pattern: u16 = 0,
    row: u16 = 0,
};

pub const PatternCursorBank = struct {
    channels: u16 = 0,
    slots: [max_pattern_channels]PatternCursor = @splat(.{}),
};

pub const ChipKind = enum { opl2, dual_opl2, opl3, dual_opl3 };

pub const LoopMark = struct {
    unit: enum { byte, sample, write },
    offset: u32,
};

pub const DumpView = struct {
    chip: ChipKind = .opl2,
    write_count: u32 = 0,
    loop: ?LoopMark = null,
    clock_ym3812: u32 = 0,
    clock_ym3526: u32 = 0,
    clock_y8950: u32 = 0,
    clock_ymf262: u32 = 0,
    adpcm_voices: u2 = 0,
    header_tick: u32 = 0,
    pit_divisor: u32 = 0,
};

pub const PlayheadFlags = packed struct(u16) {
    has_order: bool = false,
    has_row: bool = false,
    has_pattern: bool = false,
    has_speed: bool = false,
    has_tempo: bool = false,
    has_bpm: bool = false,
    has_pit: bool = false,
    has_tick: bool = false,
    has_macro_speedup: bool = false,
    has_global_volume: bool = false,
    _reserved: u6 = 0,
};

pub const Playhead = struct {
    order: u16 = 0,
    row: u16 = 0,
    pattern: u16 = 0,
    speed: u16 = 0,
    tempo: u16 = 0,
    pit: u16 = 0,
    bpm: u16 = 0,
    macro_speedup: u16 = 0,
    last_instrument: u16 = 0,
    global_volume: u8 = 0,
    fade_out_volume: u8 = 0,
    tick: u32 = 0,
    flags: PlayheadFlags = .{},
};

pub const OplChanType = enum(u8) { melody, four_op_hi, four_op_lo, drum };

pub const OplVoiceSnap = packed struct(u32) {
    keyed: bool = false,
    fnum: u10 = 0,
    block: u3 = 0,
    pan: u2 = 0,
    chan_type: u2 = 0,
    _pad: u14 = 0,
};

pub const ChipSnapshot = struct {
    new_bit: bool = false,
    second_new_bit: bool = false,
    voices: [max_opl_voices]OplVoiceSnap = @splat(.{}),
};

pub const PcmVoice = struct {
    present: bool = false,
    playing: bool = false,
    repeat: bool = false,
    external: bool = false,
    muted: bool = false,
    position: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
    rate: u32 = 0,
    volume: u8 = 0,
    level: u8 = 0,
};

pub const PcmState = struct {
    voices: [2]PcmVoice = @splat(.{}),
};

pub const RegWrite = packed struct(u32) {
    reg: u16 = 0,
    val: u8 = 0,
    _pad: u8 = 0,
};

pub fn visibleVoiceCount(dump: ?DumpView, opl3: bool, system: ?[]const u8) u8 {
    if (dump) |d| {
        return switch (d.chip) {
            .opl2 => 9,
            .dual_opl2, .opl3 => 18,
            .dual_opl3 => 36,
        };
    }
    if (system) |s| {
        if (std.mem.eql(u8, s, "Dual OPL2") or std.mem.eql(u8, s, "OPL3")) return 18;
        if (std.mem.eql(u8, s, "OPL2")) return 9;
    }
    return if (opl3) 18 else 9;
}

pub fn packedEventIsInstrumentSet(cell: Cell) bool {
    return cell.note == .none and cell.instrument != null and cell.effects[0].cmd == 0 and cell.extra == .none;
}

pub fn packedEventIsPitched(cell: Cell) bool {
    return switch (cell.note) {
        .pitch, .off, .cut, .rest, .hold => true,
        .none => false,
    };
}

// --- tests -------------------------------------------------------------------

test "ViewCaps.subsetOf requires every needed flag" {
    const have = ViewCaps{ .pattern = true, .order = true };
    try std.testing.expect(ViewCaps.subsetOf(.{ .pattern = true }, have));
    try std.testing.expect(!ViewCaps.subsetOf(.{ .pattern = true, .instruments = true }, have));
    try std.testing.expect(ViewCaps.subsetOf(.{}, have));
}

test "SeqLock concurrent writer does not mix generations" {
    const Payload = struct { a: u32 = 0, b: u32 = 0 };
    const Ctx = struct {
        lock: SeqLock(Payload) = .{},
        stop: std.atomic.Value(bool) = .init(false),
        mixed: std.atomic.Value(bool) = .init(false),
    };
    var ctx = Ctx{};
    const writer_fn = struct {
        fn run(c: *Ctx) void {
            var gen: u32 = 1;
            while (!c.stop.load(.acquire)) {
                c.lock.write(.{ .a = gen, .b = gen });
                gen +%= 1;
            }
        }
    }.run;
    const reader_fn = struct {
        fn run(c: *Ctx) void {
            var i: u32 = 0;
            while (i < 50_000) : (i += 1) {
                const p = c.lock.read();
                if (p.a != p.b) c.mixed.store(true, .release);
            }
        }
    }.run;
    const w = try std.Thread.spawn(.{}, writer_fn, .{&ctx});
    defer {
        ctx.stop.store(true, .release);
        w.join();
    }
    const r = try std.Thread.spawn(.{}, reader_fn, .{&ctx});
    r.join();
    try std.testing.expect(!ctx.mixed.load(.acquire));
}
