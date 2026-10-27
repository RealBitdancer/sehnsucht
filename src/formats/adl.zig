//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const fmt = @import("../format.zig");
const view = @import("../view.zig");

pub const format_name = "ADL";
pub const extensions = &.{".adl"};
pub const visualizer_name = "sequence";
pub const view_caps = view.ViewCaps{ .sequence = true, .instruments = true };

const tick_hz: u32 = 72;
const voices = 9;
const channels = 10;
const control_ch: u8 = 9;
const queue_len = 16;
const stack_len = 4;
const max_ops_per_channel: u32 = 256;
const max_music_tracks = 250;
const v1_tracks: usize = 120;
const v4_tracks: usize = 250;
const v1_programs: u16 = 150;
const v23_programs: u16 = 250;
const v4_programs: u16 = 500;
const v1_first_offset: u16 = 600;
const v23_first_offset: u16 = 1000;
const v4_first_offset: u16 = 2000;
const v1_min_bytes: usize = v1_tracks + v1_first_offset;
const v23_min_bytes: usize = v1_tracks + v23_first_offset;
const v4_min_bytes: usize = v4_tracks * 2 + v4_first_offset;
const driver_xlat: i32 = 191;
const opcode_count = 75;
const instrument_bytes = 11;

const Version = enum(u8) {
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,

    fn tableBytes(self: Version) usize {
        return switch (self) {
            .v1, .v2, .v3 => v1_tracks,
            .v4 => v4_tracks * 2,
        };
    }

    fn programCount(self: Version) u16 {
        return switch (self) {
            .v1 => v1_programs,
            .v2, .v3 => v23_programs,
            .v4 => v4_programs,
        };
    }

    fn jumpIsAbsolute(self: Version) bool {
        return switch (self) {
            .v1 => true,
            .v2, .v3, .v4 => false,
        };
    }

    fn jsrIsAbsolute(self: Version) bool {
        return switch (self) {
            .v1, .v2 => true,
            .v3, .v4 => false,
        };
    }
};

const OpResult = enum { more, wait, wait_no_fx };

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };

const Reg = struct {
    const waveform_select: u16 = 0x01;
    const csw: u16 = 0x08;
    const char_base: u16 = 0x20;
    const level_base: u16 = 0x40;
    const ad_base: u16 = 0x60;
    const sr_base: u16 = 0x80;
    const fnum_lo: u16 = 0xa0;
    const key_block: u16 = 0xb0;
    const feedback: u16 = 0xc0;
    const wave_base: u16 = 0xe0;
    const rhythm: u16 = 0xbd;
    const key_on: u8 = 0x20;
};

const Instrument = extern struct {
    mod_char: u8,
    car_char: u8,
    feedback: u8,
    mod_wave: u8,
    car_wave: u8,
    mod_level: u8,
    car_level: u8,
    mod_ad: u8,
    car_ad: u8,
    mod_sr: u8,
    car_sr: u8,

    comptime {
        if (@sizeOf(Instrument) != instrument_bytes) @compileError("Instrument must be 11 bytes");
    }
};

const Opcode = enum(u8) {
    set_repeat = 0,
    check_repeat = 1,
    setup_program = 2,
    set_note_spacing = 3,
    jump = 4,
    jsr = 5,
    ret = 6,
    set_base_octave = 7,
    rest = 9,
    write_adlib = 10,
    note_and_duration = 11,
    set_base_note = 12,
    secondary_effect = 13,
    stop_other = 14,
    wait_end = 15,
    instrument = 16,
    slide = 17,
    remove_slide = 18,
    set_base_freq = 19,
    vibrato = 21,
    set_priority = 26,
    set_beat = 28,
    wait_beat = 29,
    set_extra1 = 30,
    setup_duration = 32,
    play_note = 33,
    frac_spacing = 36,
    set_tempo = 38,
    remove_secondary = 39,
    chan_tempo = 41,
    set_extra3 = 43,
    set_extra2 = 44,
    change_extra2 = 45,
    am_depth = 46,
    vibrato_depth = 47,
    change_extra1 = 48,
    clear_channel = 51,
    change_note_randomly = 53,
    remove_vibrato = 54,
    pitch_bend = 57,
    reset_tempo = 58,
    nop_59 = 59,
    dur_rand = 60,
    change_tempo = 61,
    set_callback_tables = 63,
    nop_64 = 64,
    rhythm_setup = 65,
    rhythm_play = 66,
    rhythm_off = 67,
    rhythm_level2 = 68,
    change_rhythm_level1 = 69,
    set_rhythm_level1 = 70,
    sound_trigger = 71,
    tempo_reset = 72,
    set_unused = 73,
    _,

    fn isStop(self: Opcode) bool {
        return switch (self) {
            .set_repeat,
            .check_repeat,
            .setup_program,
            .set_note_spacing,
            .jump,
            .jsr,
            .ret,
            .set_base_octave,
            .rest,
            .write_adlib,
            .note_and_duration,
            .set_base_note,
            .secondary_effect,
            .stop_other,
            .wait_end,
            .instrument,
            .slide,
            .remove_slide,
            .set_base_freq,
            .vibrato,
            .set_priority,
            .set_beat,
            .wait_beat,
            .set_extra1,
            .setup_duration,
            .play_note,
            .frac_spacing,
            .set_tempo,
            .remove_secondary,
            .chan_tempo,
            .set_extra3,
            .set_extra2,
            .change_extra2,
            .am_depth,
            .vibrato_depth,
            .change_extra1,
            .clear_channel,
            .change_note_randomly,
            .remove_vibrato,
            .pitch_bend,
            .reset_tempo,
            .nop_59,
            .dur_rand,
            .change_tempo,
            .set_callback_tables,
            .nop_64,
            .rhythm_setup,
            .rhythm_play,
            .rhythm_off,
            .rhythm_level2,
            .change_rhythm_level1,
            .set_rhythm_level1,
            .sound_trigger,
            .tempo_reset,
            .set_unused,
            => false,
            _ => true,
        };
    }

    fn argCount(self: Opcode) u8 {
        const i = @backingInt(self);
        if (i >= arg_count.len) return 0;
        return arg_count[i];
    }

    const arg_count = [opcode_count]u8{
        1, 2, 1, 1, 2, 2, 0, 1,
        0, 1, 2, 2, 1, 5, 1, 1,
        1, 3, 0, 1, 0, 4, 0, 0,
        0, 0, 1, 0, 1, 1, 1, 0,
        1, 1, 0, 0, 1, 0, 1, 0,
        0, 1, 0, 1, 2, 2, 1, 1,
        1, 0, 0, 1, 0, 2, 0, 0,
        0, 1, 0, 0, 1, 1, 0, 2,
        0, 9, 1, 0, 2, 2, 2, 1,
        1, 2, 0,
    };
};

fn startsVoices(sd: []const u8, off: u16) bool {
    if (@as(usize, off) + 2 > sd.len) return false;
    var pos: usize = @as(usize, off) + 2;
    var n: u32 = 0;
    while (pos < sd.len and n < 4096) : (n += 1) {
        const opcode = sd[pos];
        pos += 1;
        if (opcode & 0x80 == 0) {
            if (pos >= sd.len) break;
            pos += 1;
            continue;
        }
        const idx: Opcode = @fromBackingInt(@intCast(@min(opcode & 0x7f, opcode_count - 1)));
        if (idx.isStop()) break;
        const argc = idx.argCount();
        if (pos + argc > sd.len) break;
        if (idx == .setup_program and sd[pos] != 0xff) return true;
        pos += argc;
    }
    return false;
}

fn advanceTimer(timer: *u8, tempo: u8) bool {
    const old = timer.*;
    timer.* +%= tempo;
    return timer.* < old;
}

const Effect = enum { none, slide, vibrato };
const SecEffect = enum { none, modulate };
const RhythmMode = enum { set2, change1, set1 };

const freq_table = [_]u16{
    0x0134, 0x0147, 0x015a, 0x016f, 0x0184, 0x019c, 0x01b4, 0x01ce, 0x01e9,
    0x0207, 0x0225, 0x0246,
};

const callback_table_1 = [_]u8{
    0x50, 0x50, 0x4f, 0x4f, 0x4e, 0x4e, 0x4d, 0x4d, 0x4c, 0x4c, 0x4b, 0x4b, 0x4a, 0x4a, 0x49, 0x49,
    0x48, 0x48, 0x47, 0x47, 0x46, 0x46, 0x45, 0x45, 0x44, 0x44, 0x43, 0x43, 0x42, 0x42, 0x41, 0x41,
    0x40, 0x40, 0x3f, 0x3f, 0x3e, 0x3e, 0x3d, 0x3d, 0x3c, 0x3c, 0x3b, 0x3b, 0x3a, 0x3a, 0x39, 0x39,
    0x38, 0x38, 0x37, 0x37, 0x36, 0x36, 0x35, 0x35, 0x34, 0x34, 0x33, 0x33, 0x32, 0x32, 0x31, 0x31,
    0x30, 0x30, 0x2f, 0x2f, 0x2e, 0x2e, 0x2d, 0x2d, 0x2c, 0x2c, 0x2b, 0x2b, 0x2a, 0x2a, 0x29, 0x29,
    0x28, 0x28, 0x27, 0x27, 0x26, 0x26, 0x25, 0x25, 0x24, 0x24, 0x23, 0x23, 0x22, 0x22, 0x21, 0x21,
    0x20, 0x20, 0x1f, 0x1f, 0x1e, 0x1e, 0x1d, 0x1d, 0x1c, 0x1c, 0x1b, 0x1b, 0x1a, 0x1a, 0x19, 0x19,
    0x18, 0x18, 0x17, 0x17, 0x16, 0x16, 0x15, 0x15, 0x14, 0x14, 0x13, 0x13, 0x12, 0x12, 0x11, 0x11,
    0x10, 0x10,
};

const callback_table_2 = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
    0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f,
    0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x6f,
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f,
};

const callback_table_3 = [_]u8{
    0x40, 0x40, 0x40, 0x3f, 0x3f, 0x3f, 0x3e, 0x3e, 0x3e, 0x3d, 0x3d, 0x3d, 0x3c, 0x3c, 0x3c, 0x3b,
    0x3b, 0x3b, 0x3a, 0x3a, 0x3a, 0x39, 0x39, 0x39, 0x38, 0x38, 0x38, 0x37, 0x37, 0x37, 0x36, 0x36,
    0x36, 0x35, 0x35, 0x35, 0x34, 0x34, 0x34, 0x33, 0x33, 0x33, 0x32, 0x32, 0x32, 0x31, 0x31, 0x31,
    0x30, 0x30, 0x30, 0x2f, 0x2f, 0x2f, 0x2e, 0x2e, 0x2e, 0x2d, 0x2d, 0x2d, 0x2c, 0x2c, 0x2c, 0x2b,
    0x2b, 0x2b, 0x2a, 0x2a, 0x2a, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x27, 0x27, 0x27, 0x26, 0x26,
    0x26, 0x25, 0x25, 0x25, 0x24, 0x24, 0x24, 0x23, 0x23, 0x23, 0x22, 0x22, 0x22, 0x21, 0x21, 0x21,
    0x20, 0x20, 0x20, 0x1f, 0x1f, 0x1f, 0x1e, 0x1e, 0x1e, 0x1d, 0x1d, 0x1d, 0x1c, 0x1c, 0x1c, 0x1b,
    0x1b, 0x1b, 0x1a, 0x1a, 0x1a, 0x19, 0x19, 0x19, 0x18, 0x18, 0x18, 0x17, 0x17, 0x17, 0x16, 0x16,
    0x16, 0x15,
};

const callback_tables = [_][]const u8{
    &callback_table_1,
    &callback_table_2,
    &callback_table_1,
    &callback_table_2,
    &callback_table_3,
    &callback_table_2,
};

const pitch_bend_tables = [14][32]u8{
    .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x22, 0x24,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x09, 0x0a, 0x0c, 0x0d, 0x0e, 0x0f, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17, 0x19, 0x1a, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x24, 0x25, 0x26,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17, 0x18, 0x1a, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x23, 0x25, 0x27, 0x28,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x11, 0x13, 0x15,
        0x16, 0x17, 0x18, 0x19, 0x1b, 0x1d, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x28, 0x2a,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x13, 0x15,
        0x16, 0x17, 0x18, 0x19, 0x1b, 0x1d, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x25, 0x27, 0x29, 0x2b, 0x2d,
    },
    .{
        0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x13, 0x15,
        0x16, 0x17, 0x18, 0x1a, 0x1c, 0x1e, 0x21, 0x24, 0x25, 0x26, 0x27, 0x29, 0x2b, 0x2d, 0x2f, 0x30,
    },
    .{
        0x00, 0x01, 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x13, 0x15, 0x18,
        0x19, 0x1a, 0x1c, 0x1d, 0x1f, 0x21, 0x23, 0x25, 0x26, 0x27, 0x29, 0x2b, 0x2d, 0x2f, 0x30, 0x32,
    },
    .{
        0x00, 0x01, 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x14, 0x17, 0x1a,
        0x19, 0x1a, 0x1c, 0x1e, 0x20, 0x22, 0x25, 0x28, 0x29, 0x2a, 0x2b, 0x2d, 0x2f, 0x31, 0x33, 0x35,
    },
    .{
        0x00, 0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0e, 0x0f, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1a, 0x1b,
        0x1c, 0x1d, 0x1e, 0x20, 0x22, 0x24, 0x26, 0x29, 0x2a, 0x2c, 0x2e, 0x30, 0x32, 0x34, 0x36, 0x39,
    },
    .{
        0x00, 0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0e, 0x0f, 0x10, 0x12, 0x14, 0x16, 0x19, 0x1b, 0x1e,
        0x1f, 0x21, 0x23, 0x25, 0x27, 0x29, 0x2b, 0x2d, 0x2e, 0x2f, 0x31, 0x32, 0x34, 0x36, 0x39, 0x3c,
    },
    .{
        0x00, 0x01, 0x03, 0x05, 0x07, 0x0a, 0x0c, 0x0f, 0x10, 0x11, 0x13, 0x15, 0x17, 0x19, 0x1b, 0x1e,
        0x1f, 0x20, 0x22, 0x24, 0x26, 0x28, 0x2b, 0x2e, 0x2f, 0x30, 0x32, 0x34, 0x36, 0x39, 0x3c, 0x3f,
    },
    .{
        0x00, 0x02, 0x04, 0x06, 0x08, 0x0b, 0x0d, 0x10, 0x11, 0x12, 0x14, 0x16, 0x18, 0x1b, 0x1e, 0x21,
        0x22, 0x23, 0x25, 0x27, 0x29, 0x2c, 0x2f, 0x32, 0x33, 0x34, 0x36, 0x38, 0x3b, 0x34, 0x41, 0x44,
    },
    .{
        0x00, 0x02, 0x04, 0x06, 0x08, 0x0b, 0x0d, 0x11, 0x12, 0x13, 0x15, 0x17, 0x1a, 0x1d, 0x20, 0x23,
        0x24, 0x25, 0x27, 0x29, 0x2c, 0x2f, 0x32, 0x35, 0x36, 0x37, 0x39, 0x3b, 0x3e, 0x41, 0x44, 0x47,
    },
};

const Channel = struct {
    repeating: bool = false,
    op_extra_level2: u8 = 0,
    dataptr: ?u32 = null,
    duration: u8 = 0,
    repeat_counter: u8 = 0,
    base_octave: i8 = 0,
    priority: u8 = 0,
    stack_pos: u8 = 0,
    stack: [stack_len]u32 = @splat(0),
    base_note: i8 = 0,
    slide_tempo: u8 = 0,
    slide_timer: u8 = 0,
    slide_step: i16 = 0,
    vibrato_step: i16 = 0,
    vibrato_step_range: u8 = 0,
    vibrato_steps_countdown: u8 = 0,
    vibrato_num_steps: u8 = 0,
    vibrato_delay: u8 = 0,
    vibrato_tempo: u8 = 0,
    vibrato_timer: u8 = 0,
    vibrato_delay_countdown: u8 = 0,
    op_extra_level1: u8 = 0,
    spacing2: u8 = 0,
    base_freq: u8 = 0,
    tempo: u8 = 0,
    timer: u8 = 0,
    reg_ax: u8 = 0,
    reg_bx: u8 = 0,
    primary: Effect = .none,
    secondary: SecEffect = .none,
    fractional_spacing: u8 = 0,
    op_level1: u8 = 0,
    op_level2: u8 = 0,
    op_extra_level3: u8 = 0,
    two_chan: bool = false,
    unused_a: u8 = 0,
    unused_b: u8 = 0,
    spacing1: u8 = 0,
    duration_randomness: u8 = 0,
    secondary_tempo: u8 = 0,
    secondary_timer: u8 = 0,
    secondary_size: i8 = 0,
    secondary_pos: i8 = 0,
    secondary_regbase: u8 = 0,
    secondary_data: u16 = 0,
    tempo_reset: u8 = 0,
    raw_note: u8 = 0,
    pitch_bend: i8 = 0,
    volume_modifier: u8 = 0,
    instrument_id: u16 = 0xffff,
};

fn pitchClassAndOctave(raw_note: u8, base_note: i8, base_octave: i8) struct { class: u8, octave: u8 } {
    var note: i32 = @as(i32, raw_note & 0x0f) + base_note;
    var octave: i32 = ((@as(i32, raw_note) + base_octave) >> 4) & 0x0f;
    if (note >= 12) {
        octave += @divTrunc(note, 12);
        note = @mod(note, 12);
    } else if (note < 0) {
        const octaves = @divTrunc(-(note + 1), 12) + 1;
        octave -= octaves;
        note += 12 * octaves;
    }
    return .{
        .class = @intCast(note),
        .octave = @intCast(std.math.clamp(octave, 0, 7)),
    };
}

fn soundingMidi(raw_note: u8, base_note: i8, base_octave: i8) u8 {
    const pitched = pitchClassAndOctave(raw_note, base_note, base_octave);
    return pitched.octave * 12 + pitched.class;
}

fn bendValue(bend: i8) u16 {
    return @intCast(8192 + @as(i32, std.math.clamp(bend, -31, 31)) * 256);
}

const QueueEntry = struct {
    data: ?u32 = null,
    id: u8 = 0,
};

const Driver = struct {
    sound_data: []const u8 = &.{},
    version: Version = .v3,
    num_programs: u16 = v23_programs,
    chip: fmt.Chip = fmt.noop_chip,
    cur_channel: u8 = 0,
    cur_reg_off: u8 = 0,
    rnd: u16 = 0x1234,
    beat_divider: u8 = 0,
    beat_div_cnt: u8 = 0,
    callback_timer: u8 = 0xff,
    beat_counter: u8 = 0,
    beat_waiting: u8 = 0,
    op_level_bd: u8 = 0,
    op_level_hh: u8 = 0,
    op_level_sd: u8 = 0,
    op_level_tt: u8 = 0,
    op_level_cy: u8 = 0,
    op_extra1_hh: u8 = 0,
    op_extra2_hh: u8 = 0,
    op_extra1_cy: u8 = 0,
    op_extra2_cy: u8 = 0,
    op_extra2_tt: u8 = 0,
    op_extra1_tt: u8 = 0,
    op_extra1_sd: u8 = 0,
    op_extra2_sd: u8 = 0,
    op_extra1_bd: u8 = 0,
    op_extra2_bd: u8 = 0,
    queue: [queue_len]QueueEntry = @splat(.{}),
    program_start_timeout: u8 = 0,
    queue_start: u8 = 0,
    queue_end: u8 = 0,
    retry_sounds: bool = false,
    channels: [channels]Channel = @splat(.{}),
    vibrato_am_bits: u8 = 0,
    rhythm_bits: u8 = 0,
    tempo: u8 = 0,
    last_instrument: u16 = 0,
    table_ptr1: []const u8 = &.{},
    table_ptr2: []const u8 = &.{},
    sound_trigger: u8 = 0,

    fn write(self: *Driver, reg: u16, val: u8) void {
        self.chip.writeReg(reg, val);
    }

    fn initChannel(self: *Driver, ch: u8) void {
        const extra2 = self.channels[ch].op_extra_level2;
        self.channels[ch] = .{
            .op_extra_level2 = extra2,
            .tempo = 0xff,
            .spacing1 = 1,
        };
    }

    fn reset(self: *Driver, chip: fmt.Chip) void {
        self.chip = chip;
        self.rnd = 0x1234;
        self.vibrato_am_bits = 0;
        self.cur_reg_off = 0;
        self.cur_channel = 0;
        self.rhythm_bits = 0;
        self.tempo = 0;
        self.last_instrument = 0;
        self.sound_trigger = 0;
        self.program_start_timeout = 0;
        self.callback_timer = 0xff;
        self.beat_divider = 0;
        self.beat_div_cnt = 0;
        self.beat_counter = 0;
        self.beat_waiting = 0;
        self.op_level_bd = 0;
        self.op_level_hh = 0;
        self.op_level_sd = 0;
        self.op_level_tt = 0;
        self.op_level_cy = 0;
        self.op_extra1_hh = 0;
        self.op_extra2_hh = 0;
        self.op_extra1_cy = 0;
        self.op_extra2_cy = 0;
        self.op_extra2_tt = 0;
        self.op_extra1_tt = 0;
        self.op_extra1_sd = 0;
        self.op_extra2_sd = 0;
        self.op_extra1_bd = 0;
        self.op_extra2_bd = 0;
        self.table_ptr1 = &.{};
        self.table_ptr2 = &.{};
        self.queue = @splat(.{});
        self.queue_start = 0;
        self.queue_end = 0;
        self.retry_sounds = false;
        self.write(Reg.waveform_select, 0x20);
        self.write(Reg.csw, 0);
        self.write(Reg.rhythm, 0);
        self.initChannel(control_ch);
        var i: u8 = voices;
        while (i > 0) {
            i -= 1;
            self.write(Reg.level_base + op_offset[i], 0x3f);
            self.write(Reg.level_base + 3 + op_offset[i], 0x3f);
            self.initChannel(i);
        }
    }

    fn getProgram(self: *const Driver, id: u16) ?u32 {
        return programOffset(self.sound_data, id);
    }

    fn getInstrument(self: *const Driver, id: u8) ?u32 {
        return self.getProgram(self.num_programs + id);
    }

    fn random(self: *Driver) u16 {
        self.rnd +%= 0x9248;
        const low: u16 = self.rnd & 7;
        self.rnd >>= 3;
        self.rnd |= low << 13;
        return self.rnd;
    }

    fn noteOff(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        if (self.rhythm_bits != 0 and ch >= 6) return;
        self.channels[ch].reg_bx &= ~Reg.key_on;
        self.write(Reg.key_block + ch, self.channels[ch].reg_bx);
    }

    fn initAdlibChannel(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        if (self.rhythm_bits != 0 and ch >= 6) return;
        const off = op_offset[ch];
        self.write(Reg.ad_base + off, 0xff);
        self.write(Reg.ad_base + 3 + off, 0xff);
        self.write(Reg.sr_base + off, 0xff);
        self.write(Reg.sr_base + 3 + off, 0xff);
        self.write(Reg.key_block + ch, 0);
        self.write(Reg.key_block + ch, Reg.key_on);
    }

    fn setupDuration(self: *Driver, duration: u8, ch: u8) void {
        var c = &self.channels[ch];
        if (c.duration_randomness != 0) {
            c.duration = duration +% @as(u8, @truncate(self.random() & c.duration_randomness));
            return;
        }
        if (c.fractional_spacing != 0) {
            c.spacing2 = (duration >> 3) *% c.fractional_spacing;
        }
        c.duration = duration;
    }

    fn setupNote(self: *Driver, raw_note: u8, ch: u8, force_bend: bool) void {
        if (ch >= voices) return;
        var c = &self.channels[ch];
        c.raw_note = raw_note;
        const pitched = pitchClassAndOctave(raw_note, c.base_note, c.base_octave);
        var freq: u16 = freq_table[pitched.class] + c.base_freq;
        if (c.pitch_bend != 0 or force_bend) {
            const index_note: u8 = @intCast(std.math.clamp(@as(i32, raw_note & 0x0f), 0, 11));
            if (c.pitch_bend >= 0) {
                const table = pitch_bend_tables[index_note + 2];
                freq += table[@intCast(std.math.clamp(@as(i32, c.pitch_bend), 0, 31))];
            } else {
                const table = pitch_bend_tables[index_note];
                freq -= table[@intCast(std.math.clamp(-@as(i32, c.pitch_bend), 0, 31))];
            }
        }
        const octave_bits: u8 = pitched.octave << 2;
        c.reg_ax = @truncate(freq);
        c.reg_bx = (c.reg_bx & Reg.key_on) | octave_bits | @as(u8, @truncate((freq >> 8) & 3));
        self.write(Reg.fnum_lo + ch, c.reg_ax);
        self.write(Reg.key_block + ch, c.reg_bx);
    }

    fn opLevel1(self: *const Driver, ch: u8) u8 {
        const c = self.channels[ch];
        var value: u16 = c.op_level1 & 0x3f;
        if (c.two_chan) {
            value += c.op_extra_level1;
            value += c.op_extra_level2;
            var level3: u16 = (c.op_extra_level3 ^ 0x3f);
            level3 *%= c.volume_modifier;
            if (level3 != 0) {
                level3 += 0x3f;
                level3 >>= 8;
            }
            value += level3 ^ 0x3f;
        }
        var out: u8 = if (value > 0x3f) 0x3f else @truncate(value);
        if (c.volume_modifier == 0) out = 0x3f;
        return out | (c.op_level1 & 0xc0);
    }

    fn opLevel2(self: *const Driver, ch: u8) u8 {
        const c = self.channels[ch];
        var value: u16 = c.op_level2 & 0x3f;
        value += c.op_extra_level1;
        value += c.op_extra_level2;
        var level3: u16 = (c.op_extra_level3 ^ 0x3f);
        level3 *%= c.volume_modifier;
        if (level3 != 0) {
            level3 += 0x3f;
            level3 >>= 8;
        }
        value += level3 ^ 0x3f;
        var out: u8 = if (value > 0x3f) 0x3f else @truncate(value);
        if (c.volume_modifier == 0) out = 0x3f;
        return out | (c.op_level2 & 0xc0);
    }

    fn setupInstrument(self: *Driver, reg_off: u8, off: u32, ch: u8) void {
        if (ch >= channels or self.cur_channel >= voices) return;
        const sd = self.sound_data;
        if (off + instrument_bytes > sd.len) return;
        const inst = std.mem.bytesToValue(Instrument, sd[off..][0..instrument_bytes]);
        self.write(Reg.char_base + reg_off, inst.mod_char);
        self.write(Reg.char_base + 3 + reg_off, inst.car_char);
        self.write(Reg.feedback + self.cur_channel, inst.feedback);
        self.channels[ch].two_chan = inst.feedback & 1 != 0;
        self.write(Reg.wave_base + reg_off, inst.mod_wave);
        self.write(Reg.wave_base + 3 + reg_off, inst.car_wave);
        self.channels[ch].op_level1 = inst.mod_level;
        self.channels[ch].op_level2 = inst.car_level;
        self.write(Reg.level_base + reg_off, self.opLevel1(ch));
        self.write(Reg.level_base + 3 + reg_off, self.opLevel2(ch));
        self.write(Reg.ad_base + reg_off, inst.mod_ad);
        self.write(Reg.ad_base + 3 + reg_off, inst.car_ad);
        self.write(Reg.sr_base + reg_off, inst.mod_sr);
        self.write(Reg.sr_base + 3 + reg_off, inst.car_sr);
    }

    fn noteOn(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        var c = &self.channels[ch];
        c.reg_bx |= Reg.key_on;
        self.write(Reg.key_block + ch, c.reg_bx);
        const shift: u4 = @intCast(9 - @min(c.vibrato_step_range, 9));
        const freq: u16 = ((@as(u16, c.reg_bx) << 8) | c.reg_ax) & 0x3ff;
        c.vibrato_step = @intCast((freq >> shift) & 0xff);
        c.vibrato_delay_countdown = c.vibrato_delay;
    }

    fn adjustVolume(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        self.write(Reg.level_base + 3 + op_offset[ch], self.opLevel2(ch));
        if (self.channels[ch].two_chan) {
            self.write(Reg.level_base + op_offset[ch], self.opLevel1(ch));
        }
    }

    fn effectSlide(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        var c = &self.channels[ch];
        if (!advanceTimer(&c.slide_timer, c.slide_tempo)) return;
        var freq: i32 = ((@as(i32, c.reg_bx & 0x03) << 8) | c.reg_ax);
        var octave: u8 = c.reg_bx & 0x1c;
        const note_on: u8 = c.reg_bx & Reg.key_on;
        const step = std.math.clamp(c.slide_step, -0x3ff, 0x3ff);
        freq += step;
        if (step >= 0 and freq >= 734) {
            freq >>= 1;
            if (freq & 0x3ff == 0) freq += 1;
            octave +%= 4;
        } else if (step < 0 and freq < 388) {
            if (freq < 0) freq = 0;
            freq <<= 1;
            if (freq & 0x3ff == 0) freq -= 1;
            octave -%= 4;
        }
        const bits: u32 = @bitCast(freq);
        c.reg_ax = @truncate(bits);
        c.reg_bx = note_on | (octave & 0x1c) | @as(u8, @truncate((bits >> 8) & 3));
        self.write(Reg.fnum_lo + ch, c.reg_ax);
        self.write(Reg.key_block + ch, c.reg_bx);
    }

    fn effectVibrato(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        var c = &self.channels[ch];
        if (c.vibrato_delay_countdown != 0) {
            c.vibrato_delay_countdown -= 1;
            return;
        }
        if (!advanceTimer(&c.vibrato_timer, c.vibrato_tempo)) return;
        c.vibrato_steps_countdown -%= 1;
        if (c.vibrato_steps_countdown == 0) {
            c.vibrato_step = -%c.vibrato_step;
            c.vibrato_steps_countdown = c.vibrato_num_steps;
        }
        var freq: i32 = ((@as(i32, c.reg_bx) << 8) | c.reg_ax) & 0x3ff;
        freq += c.vibrato_step;
        const bits: u32 = @bitCast(freq);
        c.reg_ax = @truncate(bits);
        c.reg_bx = (c.reg_bx & 0xfc) | @as(u8, @truncate(bits >> 8));
        self.write(Reg.fnum_lo + ch, c.reg_ax);
        self.write(Reg.key_block + ch, c.reg_bx);
    }

    fn effectModulate(self: *Driver, ch: u8) void {
        if (ch >= voices) return;
        var c = &self.channels[ch];
        if (!advanceTimer(&c.secondary_timer, c.secondary_tempo)) return;
        c.secondary_pos -%= 1;
        if (c.secondary_pos < 0) c.secondary_pos = c.secondary_size;
        const idx: i32 = @as(i32, c.secondary_data) + c.secondary_pos;
        if (idx < 0 or idx >= self.sound_data.len) return;
        self.write(
            @as(u16, c.secondary_regbase) + self.cur_reg_off,
            self.sound_data[@intCast(idx)],
        );
    }

    fn runEffects(self: *Driver, ch: u8) void {
        switch (self.channels[ch].primary) {
            .none => {},
            .slide => self.effectSlide(ch),
            .vibrato => self.effectVibrato(ch),
        }
        switch (self.channels[ch].secondary) {
            .none => {},
            .modulate => self.effectModulate(ch),
        }
    }

    fn startOnChannel(self: *Driver, ch: u8, dataptr: u32, priority: u8) void {
        self.initChannel(ch);
        self.channels[ch].priority = priority;
        self.channels[ch].dataptr = dataptr;
        self.channels[ch].tempo = 0xff;
        self.channels[ch].timer = 0xff;
        self.channels[ch].duration = 1;
        self.channels[ch].volume_modifier = 0xff;
        self.initAdlibChannel(ch);
        self.program_start_timeout = 2;
    }

    fn startSound(self: *Driver, track_prog: u16) void {
        const off = self.getProgram(track_prog) orelse return;
        if (self.queue_end == self.queue_start and self.queue[self.queue_end].data != null) return;
        self.queue[self.queue_end] = .{ .data = off, .id = @truncate(track_prog) };
        self.queue_end = (self.queue_end + 1) % queue_len;
    }

    fn setupPrograms(self: *Driver) void {
        const entry = self.queue[self.queue_start];
        const ptr = entry.data orelse return;

        var retry = QueueEntry{};
        if (entry.id == 0) self.retry_sounds = true else if (self.retry_sounds) retry = entry;

        self.queue[self.queue_start].data = null;
        self.queue_start = (self.queue_start + 1) % queue_len;

        const sd = self.sound_data;
        if (ptr + 2 > sd.len) return;
        const chan = sd[ptr];
        if (chan > control_ch) return;
        if (chan < control_ch and ptr + 4 > sd.len) return;

        const priority = sd[ptr + 1];
        if (priority >= self.channels[chan].priority) {
            self.startOnChannel(chan, ptr + 2, priority);
            retry = .{};
        }
        if (retry.data != null) self.startSound(retry.id);
    }

    fn execOpcode(self: *Driver, ch: u8, op: Opcode, values: []const u8) OpResult {
        if (op.isStop()) return self.opStop(ch);
        return switch (op) {
            .set_repeat => self.opSetRepeat(ch, values),
            .check_repeat => self.opCheckRepeat(ch, values),
            .setup_program => self.opSetupProgram(ch, values),
            .set_note_spacing => self.opSetNoteSpacing(ch, values),
            .jump => self.opJump(ch, values),
            .jsr => self.opJsr(ch, values),
            .ret => self.opReturn(ch),
            .set_base_octave => self.opSetBaseOctave(ch, values),
            .rest => self.opRest(ch, values),
            .write_adlib => self.opWriteAdlib(values),
            .note_and_duration => self.opNoteAndDuration(ch, values),
            .set_base_note => self.opSetBaseNote(ch, values),
            .secondary_effect => self.opSecondaryEffect(ch, values),
            .stop_other => self.opStopOther(values),
            .wait_end => self.opWaitEnd(ch, values),
            .instrument => self.opInstrument(ch, values),
            .slide => self.opSlide(ch, values),
            .remove_slide => self.opRemoveSlide(ch),
            .set_base_freq => self.opSetBaseFreq(ch, values),
            .vibrato => self.opVibrato(ch, values),
            .set_priority => self.opSetPriority(ch, values),
            .set_beat => self.opSetBeat(values),
            .wait_beat => self.opWaitBeat(ch, values),
            .set_extra1 => self.opSetExtra1(ch, values),
            .setup_duration => self.opSetupDuration(ch, values),
            .play_note => self.opPlayNote(ch, values),
            .frac_spacing => self.opFracSpacing(ch, values),
            .set_tempo => self.opSetTempo(values),
            .remove_secondary => self.opRemoveSecondary(ch),
            .chan_tempo => self.opChanTempo(ch, values),
            .set_extra3 => self.opSetExtra3(ch, values),
            .set_extra2 => self.opSetExtra2(values),
            .change_extra2 => self.opChangeExtra2(values),
            .am_depth => self.opAmDepth(values),
            .vibrato_depth => self.opVibratoDepth(values),
            .change_extra1 => self.opChangeExtra1(ch, values),
            .clear_channel => self.opClearChannel(values),
            .change_note_randomly => self.opChangeNoteRandomly(ch, values),
            .remove_vibrato => self.opRemoveVibrato(ch),
            .pitch_bend => self.opPitchBend(ch, values),
            .reset_tempo => self.opResetTempo(ch),
            .nop_59, .nop_64 => .more,
            .dur_rand => self.opDurRand(ch, values),
            .change_tempo => self.opChangeTempo(ch, values),
            .set_callback_tables => self.opSetCallbackTables(values),
            .rhythm_setup => self.opRhythmSetup(ch, values),
            .rhythm_play => self.opRhythmPlay(values),
            .rhythm_off => self.opRhythmOff(),
            .rhythm_level2 => self.opRhythmLevel2(values),
            .change_rhythm_level1 => self.opChangeRhythmLevel1(values),
            .set_rhythm_level1 => self.opSetRhythmLevel1(values),
            .sound_trigger => self.opSoundTrigger(values),
            .tempo_reset => self.opTempoReset(ch, values),
            .set_unused => self.opSetUnused(ch, values),
            else => self.opStop(ch),
        };
    }

    fn opSetRepeat(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].repeat_counter = values[0];
        return .more;
    }

    fn opCheckRepeat(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].repeat_counter -%= 1;
        if (self.channels[ch].repeat_counter != 0) {
            const add = std.mem.readInt(i16, values[0..2], .little);
            if (self.relPtr(self.channels[ch].dataptr.?, add)) |p| {
                self.channels[ch].dataptr = p;
            }
        }
        return .more;
    }

    fn opSetupProgram(self: *Driver, ch: u8, values: []const u8) OpResult {
        if (values[0] == 0xff) return .more;
        const off = self.getProgram(values[0]) orelse return .more;
        const sd = self.sound_data;
        if (off + 2 > sd.len) return .more;
        const chan = sd[off];
        const priority = sd[off + 1];
        if (chan > control_ch) return .more;
        if (priority >= self.channels[chan].priority) {
            const resume_at = self.channels[ch].dataptr;
            self.startOnChannel(chan, off + 2, priority);
            self.channels[ch].dataptr = resume_at;
        }
        return .more;
    }

    fn opSetNoteSpacing(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].spacing1 = values[0];
        return .more;
    }

    fn opJump(self: *Driver, ch: u8, values: []const u8) OpResult {
        const add = std.mem.readInt(i16, values[0..2], .little);
        const dest = if (self.version.jumpIsAbsolute())
            self.absPtr(add)
        else
            self.relPtr(self.channels[ch].dataptr.?, add);
        if (dest) |p| {
            const from = self.channels[ch].dataptr orelse 0;
            if (add < 0 or p <= from) self.channels[ch].repeating = true;
            self.channels[ch].dataptr = p;
            return .more;
        }
        return self.opStop(ch);
    }

    fn opJsr(self: *Driver, ch: u8, values: []const u8) OpResult {
        const add = std.mem.readInt(i16, values[0..2], .little);
        if (self.channels[ch].stack_pos >= stack_len) return .more;
        const ret = self.channels[ch].dataptr.?;
        self.channels[ch].stack[self.channels[ch].stack_pos] = ret;
        self.channels[ch].stack_pos += 1;
        const dest = if (self.version.jsrIsAbsolute())
            self.absPtr(add)
        else
            self.relPtr(ret, add);
        if (dest) |p| {
            self.channels[ch].dataptr = p;
        } else {
            self.channels[ch].stack_pos -= 1;
        }
        return .more;
    }

    fn opReturn(self: *Driver, ch: u8) OpResult {
        if (self.channels[ch].stack_pos == 0) return self.opStop(ch);
        self.channels[ch].stack_pos -= 1;
        self.channels[ch].dataptr = self.channels[ch].stack[self.channels[ch].stack_pos];
        return .more;
    }

    fn opSetBaseOctave(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].base_octave = @bitCast(values[0]);
        return .more;
    }

    fn opStop(self: *Driver, ch: u8) OpResult {
        self.channels[ch].priority = 0;
        if (ch != control_ch) self.noteOff(ch);
        self.channels[ch].dataptr = null;
        return .wait_no_fx;
    }

    fn opRest(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.setupDuration(values[0], ch);
        self.noteOff(ch);
        return if (values[0] != 0) .wait else .more;
    }

    fn opWriteAdlib(self: *Driver, values: []const u8) OpResult {
        self.write(values[0], values[1]);
        return .more;
    }

    fn opNoteAndDuration(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.setupNote(values[0], ch, false);
        self.setupDuration(values[1], ch);
        return if (values[1] != 0) .wait else .more;
    }

    fn opSetBaseNote(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].base_note = @bitCast(values[0]);
        return .more;
    }

    fn opSecondaryEffect(self: *Driver, ch: u8, values: []const u8) OpResult {
        var c = &self.channels[ch];
        c.secondary_timer = values[0];
        c.secondary_tempo = values[0];
        c.secondary_size = @bitCast(values[1]);
        c.secondary_pos = @bitCast(values[1]);
        c.secondary_regbase = values[2];
        const raw = fmt.readU16Le(values, 3);
        const data: i32 = @as(i32, raw) - driver_xlat;
        if (data < 0 or data + @as(i32, c.secondary_size) >= self.sound_data.len) {
            c.secondary = .none;
            return .more;
        }
        c.secondary_data = @intCast(data);
        c.secondary = .modulate;
        return .more;
    }

    fn opStopOther(self: *Driver, values: []const u8) OpResult {
        if (values[0] > control_ch) return .more;
        const other = values[0];
        self.channels[other].duration = 0;
        self.channels[other].priority = 0;
        self.channels[other].dataptr = null;
        return .more;
    }

    fn opWaitEnd(self: *Driver, ch: u8, values: []const u8) OpResult {
        const off = self.getProgram(values[0]) orelse return .more;
        const chan = self.sound_data[off];
        if (chan > control_ch or self.channels[chan].dataptr == null) return .more;
        if (self.channels[chan].repeating) self.channels[ch].repeating = true;
        self.channels[ch].dataptr = self.channels[ch].dataptr.? - 2;
        return .wait_no_fx;
    }

    fn opInstrument(self: *Driver, ch: u8, values: []const u8) OpResult {
        const off = self.getInstrument(values[0]) orelse return .more;
        self.channels[ch].instrument_id = values[0];
        self.last_instrument = values[0];
        self.setupInstrument(self.cur_reg_off, off, ch);
        return .more;
    }

    fn opSlide(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].slide_tempo = values[0];
        self.channels[ch].slide_step = std.mem.readInt(i16, values[1..3], .big);
        self.channels[ch].primary = .slide;
        self.channels[ch].slide_timer = 0xff;
        return .more;
    }

    fn opRemoveSlide(self: *Driver, ch: u8) OpResult {
        self.channels[ch].primary = .none;
        self.channels[ch].slide_step = 0;
        return .more;
    }

    fn opSetBaseFreq(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].base_freq = values[0];
        return .more;
    }

    fn opVibrato(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].vibrato_tempo = values[0];
        self.channels[ch].vibrato_step_range = values[1];
        self.channels[ch].vibrato_steps_countdown = values[2] +% 1;
        self.channels[ch].vibrato_num_steps = values[2] *% 2;
        self.channels[ch].vibrato_delay = values[3];
        self.channels[ch].primary = .vibrato;
        return .more;
    }

    fn opSetPriority(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].priority = values[0];
        return .more;
    }

    fn opSetBeat(self: *Driver, values: []const u8) OpResult {
        self.beat_divider = values[0] >> 1;
        self.beat_div_cnt = self.beat_divider;
        self.callback_timer = 0xff;
        self.beat_counter = 0;
        self.beat_waiting = 0;
        return .more;
    }

    fn opWaitBeat(self: *Driver, ch: u8, values: []const u8) OpResult {
        if (self.beat_counter & values[0] != 0 and self.beat_waiting != 0) {
            self.beat_waiting = 0;
            return .more;
        }
        if (self.beat_counter & values[0] == 0) self.beat_waiting +%= 1;
        self.channels[ch].dataptr = self.channels[ch].dataptr.? - 2;
        self.channels[ch].duration = 1;
        return .wait_no_fx;
    }

    fn opSetExtra1(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].op_extra_level1 = values[0];
        self.adjustVolume(ch);
        return .more;
    }

    fn opSetupDuration(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.setupDuration(values[0], ch);
        return if (values[0] != 0) .wait else .more;
    }

    fn opPlayNote(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.setupDuration(values[0], ch);
        self.noteOn(ch);
        return if (values[0] != 0) .wait else .more;
    }

    fn opFracSpacing(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].fractional_spacing = values[0] & 7;
        return .more;
    }

    fn opSetTempo(self: *Driver, values: []const u8) OpResult {
        self.tempo = values[0];
        return .more;
    }

    fn opRemoveSecondary(self: *Driver, ch: u8) OpResult {
        self.channels[ch].secondary = .none;
        return .more;
    }

    fn opChanTempo(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].tempo = values[0];
        return .more;
    }

    fn opSetExtra3(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].op_extra_level3 = values[0];
        return .more;
    }

    fn opSetExtra2(self: *Driver, values: []const u8) OpResult {
        if (values[0] > control_ch) return .more;
        const ch = values[0];
        self.channels[ch].op_extra_level2 = values[1];
        self.adjustVolume(ch);
        return .more;
    }

    fn opChangeExtra2(self: *Driver, values: []const u8) OpResult {
        if (values[0] > control_ch) return .more;
        const ch = values[0];
        self.channels[ch].op_extra_level2 +%= values[1];
        self.adjustVolume(ch);
        return .more;
    }

    fn opAmDepth(self: *Driver, values: []const u8) OpResult {
        if (values[0] & 1 != 0) self.vibrato_am_bits |= 0x80 else self.vibrato_am_bits &= 0x7f;
        self.write(Reg.rhythm, self.vibrato_am_bits);
        return .more;
    }

    fn opVibratoDepth(self: *Driver, values: []const u8) OpResult {
        if (values[0] & 1 != 0) self.vibrato_am_bits |= 0x40 else self.vibrato_am_bits &= 0xbf;
        self.write(Reg.rhythm, self.vibrato_am_bits);
        return .more;
    }

    fn opChangeExtra1(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].op_extra_level1 +%= values[0];
        self.adjustVolume(ch);
        return .more;
    }

    fn opClearChannel(self: *Driver, values: []const u8) OpResult {
        if (values[0] > control_ch) return .more;
        const ch = values[0];
        self.channels[ch].duration = 0;
        self.channels[ch].priority = 0;
        self.channels[ch].dataptr = null;
        self.channels[ch].op_extra_level2 = 0;
        if (ch != control_ch) {
            self.channels[ch].reg_bx &= ~Reg.key_on;
            const off = op_offset[ch];
            self.write(Reg.feedback + ch, 0);
            self.write(Reg.level_base + 3 + off, 0x3f);
            self.write(Reg.sr_base + 3 + off, 0xff);
            self.write(Reg.key_block + ch, 0);
        }
        return .more;
    }

    fn opChangeNoteRandomly(self: *Driver, ch: u8, values: []const u8) OpResult {
        if (ch >= voices) return .more;
        const mask = std.mem.readInt(u16, values[0..2], .big);
        var note: u16 = ((@as(u16, self.channels[ch].reg_bx & 0x1f) << 8) | self.channels[ch].reg_ax);
        note +%= mask & self.random();
        note |= @as(u16, self.channels[ch].reg_bx & Reg.key_on) << 8;
        self.write(Reg.fnum_lo + ch, @truncate(note));
        self.write(Reg.key_block + ch, @truncate(note >> 8));
        return .more;
    }

    fn opRemoveVibrato(self: *Driver, ch: u8) OpResult {
        self.channels[ch].primary = .none;
        return .more;
    }

    fn opPitchBend(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].pitch_bend = @bitCast(values[0]);
        self.setupNote(self.channels[ch].raw_note, ch, true);
        return .more;
    }

    fn opResetTempo(self: *Driver, ch: u8) OpResult {
        self.channels[ch].tempo = self.tempo;
        return .more;
    }

    fn opDurRand(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].duration_randomness = values[0];
        return .more;
    }

    fn opChangeTempo(self: *Driver, ch: u8, values: []const u8) OpResult {
        const next: i32 = @as(i32, self.channels[ch].tempo) + @as(i8, @bitCast(values[0]));
        self.channels[ch].tempo = @intCast(std.math.clamp(next, 1, 255));
        return .more;
    }

    fn opSetCallbackTables(self: *Driver, values: []const u8) OpResult {
        const entry = values[1];
        if (@as(usize, entry) + 2 > callback_tables.len) return .more;
        self.table_ptr1 = callback_tables[entry];
        self.table_ptr2 = callback_tables[entry + 1];
        if (values[0] == 2 and self.table_ptr2.len != 0) {
            self.write(Reg.fnum_lo, self.table_ptr2[0]);
        }
        return .more;
    }

    fn opRhythmSetup(self: *Driver, ch: u8, values: []const u8) OpResult {
        const saved_ch = self.cur_channel;
        const saved_off = self.cur_reg_off;
        self.cur_channel = 6;
        self.cur_reg_off = op_offset[6];
        if (self.getInstrument(values[0])) |off| self.setupInstrument(self.cur_reg_off, off, ch);
        self.op_level_bd = self.channels[ch].op_level2;

        self.cur_channel = 7;
        self.cur_reg_off = op_offset[7];
        if (self.getInstrument(values[1])) |off| self.setupInstrument(self.cur_reg_off, off, ch);
        self.op_level_hh = self.channels[ch].op_level1;
        self.op_level_sd = self.channels[ch].op_level2;

        self.cur_channel = 8;
        self.cur_reg_off = op_offset[8];
        if (self.getInstrument(values[2])) |off| self.setupInstrument(self.cur_reg_off, off, ch);
        self.op_level_tt = self.channels[ch].op_level1;
        self.op_level_cy = self.channels[ch].op_level2;

        self.channels[6].reg_bx = values[3] & 0x2f;
        self.write(Reg.key_block + 6, self.channels[6].reg_bx);
        self.write(Reg.fnum_lo + 6, values[4]);
        self.channels[7].reg_bx = values[5] & 0x2f;
        self.write(Reg.key_block + 7, self.channels[7].reg_bx);
        self.write(Reg.fnum_lo + 7, values[6]);
        self.channels[8].reg_bx = values[7] & 0x2f;
        self.write(Reg.key_block + 8, self.channels[8].reg_bx);
        self.write(Reg.fnum_lo + 8, values[8]);
        self.rhythm_bits = 0x20;
        self.cur_reg_off = saved_off;
        self.cur_channel = saved_ch;
        return .more;
    }

    fn opRhythmPlay(self: *Driver, values: []const u8) OpResult {
        self.write(Reg.rhythm, (self.rhythm_bits & ~(values[0] & 0x1f)) | 0x20);
        self.rhythm_bits |= values[0];
        self.write(Reg.rhythm, self.vibrato_am_bits | 0x20 | self.rhythm_bits);
        return .more;
    }

    fn opRhythmOff(self: *Driver) OpResult {
        self.rhythm_bits = 0;
        self.write(Reg.rhythm, self.vibrato_am_bits);
        return .more;
    }

    fn rhythmLevel(self: *Driver, v: u8, extra1: *u8, extra2: *u8, level: u8, reg: u16, mode: RhythmMode) void {
        switch (mode) {
            .set2 => {
                extra2.* = v;
                self.write(reg, @intCast(std.math.clamp(@as(i32, v) + level + extra1.* + extra2.*, 0, 0x3f)));
            },
            .change1 => {
                extra1.* = @intCast(std.math.clamp(@as(i32, v) + level + extra1.* + extra2.*, 0, 0x3f));
                self.write(reg, extra1.*);
            },
            .set1 => {
                extra1.* = v;
                self.write(reg, @intCast(std.math.clamp(@as(i32, v) + level + extra2.*, 0, 0x3f)));
            },
        }
    }

    fn applyRhythmOps(self: *Driver, ops: u8, v: u8, mode: RhythmMode) void {
        if (ops & 1 != 0) self.rhythmLevel(v, &self.op_extra1_hh, &self.op_extra2_hh, self.op_level_hh, Reg.level_base + op_offset[7], mode);
        if (ops & 2 != 0) self.rhythmLevel(v, &self.op_extra1_cy, &self.op_extra2_cy, self.op_level_cy, Reg.level_base + 3 + op_offset[8], mode);
        if (ops & 4 != 0) self.rhythmLevel(v, &self.op_extra1_tt, &self.op_extra2_tt, self.op_level_tt, Reg.level_base + op_offset[8], mode);
        if (ops & 8 != 0) self.rhythmLevel(v, &self.op_extra1_sd, &self.op_extra2_sd, self.op_level_sd, Reg.level_base + 3 + op_offset[7], mode);
        if (ops & 16 != 0) self.rhythmLevel(v, &self.op_extra1_bd, &self.op_extra2_bd, self.op_level_bd, Reg.level_base + 3 + op_offset[6], mode);
    }

    fn opRhythmLevel2(self: *Driver, values: []const u8) OpResult {
        self.applyRhythmOps(values[0], values[1], .set2);
        return .more;
    }

    fn opChangeRhythmLevel1(self: *Driver, values: []const u8) OpResult {
        self.applyRhythmOps(values[0], values[1], .change1);
        return .more;
    }

    fn opSetRhythmLevel1(self: *Driver, values: []const u8) OpResult {
        self.applyRhythmOps(values[0], values[1], .set1);
        return .more;
    }

    fn opSoundTrigger(self: *Driver, values: []const u8) OpResult {
        self.sound_trigger = values[0];
        return .more;
    }

    fn opTempoReset(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].tempo_reset = values[0];
        return .more;
    }

    fn opSetUnused(self: *Driver, ch: u8, values: []const u8) OpResult {
        self.channels[ch].unused_a = values[0];
        self.channels[ch].unused_b = values[1];
        return .more;
    }

    fn relPtr(self: *const Driver, from: u32, add: i16) ?u32 {
        const dest: i64 = @as(i64, from) + add;
        if (dest < 0 or dest > self.sound_data.len) return null;
        return @intCast(dest);
    }

    fn absPtr(self: *const Driver, add: i16) ?u32 {
        const dest: i64 = @as(i64, add) - driver_xlat;
        if (dest < 0 or dest > self.sound_data.len) return null;
        return @intCast(dest);
    }

    fn executePrograms(self: *Driver) void {
        var ch: u8 = channels;
        while (ch > 0) {
            ch -= 1;
            const cidx = ch;
            self.cur_channel = cidx;
            var c = &self.channels[cidx];
            if (c.dataptr == null) continue;
            self.cur_reg_off = if (cidx == control_ch) 0 else op_offset[cidx];
            if (c.tempo_reset != 0) c.tempo = self.tempo;

            var result: OpResult = .wait;
            if (advanceTimer(&c.timer, c.tempo)) {
                c.duration -%= 1;
                if (c.duration != 0) {
                    if (c.duration == c.spacing2) self.noteOff(cidx);
                    if (c.duration == c.spacing1 and cidx != control_ch) self.noteOff(cidx);
                } else {
                    result = .more;
                }
            }

            var ops: u32 = 0;
            while (result == .more and c.dataptr != null) {
                ops += 1;
                if (ops > max_ops_per_channel) break;
                var pos = c.dataptr.?;
                var opcode: u8 = 0xff;
                if (pos < self.sound_data.len) {
                    opcode = self.sound_data[pos];
                    pos += 1;
                }
                c.dataptr = pos;
                if (opcode & 0x80 != 0) {
                    const idx: Opcode = @fromBackingInt(@intCast(@min(opcode & 0x7f, opcode_count - 1)));
                    const n = idx.argCount();
                    if (pos + n > self.sound_data.len) {
                        result = self.opStop(cidx);
                        break;
                    }
                    const values = self.sound_data[pos..][0..n];
                    c.dataptr = pos + n;
                    result = self.execOpcode(cidx, idx, values);
                } else {
                    if (pos >= self.sound_data.len) {
                        result = self.opStop(cidx);
                        break;
                    }
                    const duration = self.sound_data[pos];
                    c.dataptr = pos + 1;
                    self.setupNote(opcode, cidx, false);
                    self.noteOn(cidx);
                    self.setupDuration(duration, cidx);
                    result = if (duration != 0) .wait else .more;
                }
            }
            if (result == .wait) self.runEffects(cidx);
        }
    }

    fn callback(self: *Driver) void {
        if (self.program_start_timeout != 0) {
            self.program_start_timeout -= 1;
        } else {
            self.setupPrograms();
        }
        self.executePrograms();
        if (advanceTimer(&self.callback_timer, self.tempo)) {
            self.beat_div_cnt -%= 1;
            if (self.beat_div_cnt == 0) {
                self.beat_div_cnt = self.beat_divider;
                self.beat_counter +%= 1;
            }
        }
    }

    fn anyPlaying(self: *const Driver) bool {
        for (&self.channels) |c| {
            if (c.dataptr != null) return true;
        }
        return false;
    }

    fn anyAdvancing(self: *const Driver) bool {
        for (&self.channels) |c| {
            if (c.dataptr != null and !c.repeating) return true;
        }
        return false;
    }
};

const AdlSource = struct {
    sample_rate: u32,
    frac: u32 = 0,
    version: Version,
    sound_data: []const u8,
    track_entries: [v4_tracks * 2]u8 = @splat(0xff),
    music_ids: [max_music_tracks]u16 = @splat(0),
    music_count: u16,
    music_index: u16,
    title: ?[]const u8 = null,
    title_stem: ?[]const u8 = null,
    measured_frames: u64 = 0,
    duration_cache: [max_music_tracks]u64 = @splat(0),
    had_activity: bool = false,
    idle: u8 = 0,
    tick: u32 = 0,
    driver: Driver = .{},

    fn programFor(self: *const AdlSource, table_index: u16) ?u16 {
        const nprog = self.version.programCount();
        if (self.version == .v4) {
            const id = fmt.readU16Le(&self.track_entries, @as(usize, table_index) * 2);
            if (id == 0xffff or id >= nprog) return null;
            return id;
        }
        const id = self.track_entries[table_index];
        if (id == 0xff or id >= nprog) return null;
        return id;
    }

    fn begin(self: *AdlSource, chip: fmt.Chip) void {
        self.driver.sound_data = self.sound_data;
        self.driver.version = self.version;
        self.driver.num_programs = self.version.programCount();
        self.driver.reset(chip);
        const table_index = self.music_ids[self.music_index];
        if (self.programFor(table_index)) |prog| {
            self.driver.startSound(prog);
        }
        self.frac = 0;
        self.had_activity = false;
        self.idle = 0;
        self.tick = 0;
    }

    fn probeDuration(self: *const AdlSource) ?u64 {
        var probe = self.*;
        probe.title = null;
        probe.title_stem = null;
        probe.frac = 0;
        probe.had_activity = false;
        probe.idle = 0;
        probe.tick = 0;
        probe.driver = .{};
        probe.measured_frames = 0;
        probe.begin(fmt.noop_chip);
        return fmt.measureByStepping(fmt.MusicSource.init(&probe, visualizer_name), fmt.noop_chip, self.sample_rate);
    }

    fn seedDuration(self: *AdlSource) void {
        const idx = self.music_index;
        if (self.duration_cache[idx] == 0) {
            self.duration_cache[idx] = self.probeDuration() orelse 0;
        }
        self.measured_frames = self.duration_cache[idx];
    }

    pub fn selectArchiveTrack(
        self: *AdlSource,
        gpa: std.mem.Allocator,
        index: u32,
        chip: fmt.Chip,
    ) !void {
        if (self.music_count == 0) return;
        const idx: u16 = @intCast(@min(index, @as(u32, self.music_count) - 1));
        var new_title: ?[]u8 = null;
        errdefer if (new_title) |t| gpa.free(t);
        if (self.title_stem) |stem| {
            new_title = try gpa.print("{s} track {d}/{d}", .{
                stem,
                idx + 1,
                self.music_count,
            });
        }
        if (self.title) |t| gpa.free(t);
        self.title = new_title;
        new_title = null;
        self.music_index = idx;
        self.driver = .{};
        self.seedDuration();
        self.begin(chip);
    }

    pub fn durationFrames(self: *AdlSource) u64 {
        return self.measured_frames;
    }

    pub fn step(self: *AdlSource, chip: fmt.Chip) fmt.StepResult {
        self.driver.chip = chip;
        self.driver.callback();
        if (self.driver.anyAdvancing()) {
            self.had_activity = true;
            self.idle = 0;
            self.tick +%= 1;
            return .{ .frames = fmt.rescale(1, tick_hz, self.sample_rate, &self.frac) };
        }
        if (self.had_activity) {
            self.begin(chip);
            return .{ .frames = 0, .done = true };
        }
        self.idle +%= 1;
        if (self.idle >= 8) {
            self.begin(chip);
            return .{ .frames = 0, .done = true };
        }
        self.tick +%= 1;
        return .{ .frames = fmt.rescale(1, tick_hz, self.sample_rate, &self.frac) };
    }

    pub fn info(self: *AdlSource) fmt.TrackInfo {
        return .{
            .title = self.title,
            .format_name = "ADL",
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .archive_track_count = self.music_count,
            .archive_track_index = self.music_index,
        };
    }

    pub fn playhead(self: *AdlSource) view.Playhead {
        return .{
            .tick = self.tick,
            .tempo = self.driver.tempo,
            .last_instrument = self.driver.last_instrument,
            .flags = .{ .has_tick = true, .has_tempo = true },
        };
    }

    pub fn sequenceState(self: *AdlSource) view.SequenceStateBank {
        var bank = view.SequenceStateBank{ .channels = channels };
        for (0..channels) |i| {
            const ch = self.driver.channels[i];
            const keyed = i != control_ch and ch.reg_bx & Reg.key_on != 0;
            bank.slots[i] = .{
                .program = ch.instrument_id,
                .note = soundingMidi(ch.raw_note, ch.base_note, ch.base_octave),
                .keyed = keyed,
                .bend = bendValue(ch.pitch_bend),
                .opl_voice = if (i == control_ch) 0xff else @intCast(i),
                .pc = ch.dataptr orelse view.sequence_pc_none,
                .duration = ch.duration,
                .chan_tempo = ch.tempo,
                .priority = ch.priority,
                .stack = ch.stack_pos,
                .fx = .{
                    .slide = ch.primary == .slide,
                    .vibrato = ch.primary == .vibrato,
                    .modulate = ch.secondary == .modulate,
                },
            };
        }
        return bank;
    }

    pub fn sequenceView(self: *AdlSource) view.SequenceView {
        return .{
            .ctx = self,
            .kind = .voice_programs,
            .track_count = channels,
            .channel_count = channels,
            .tick_rate = tick_hz,
            .length_ticks = 0,
            .track = adlTrack,
            .programAt = adlProgramAt,
            .bytecodeWindow = adlBytecodeWindow,
            .bytecodePage = adlBytecodePage,
        };
    }

    pub fn instrumentBank(self: *AdlSource) view.InstrumentBank {
        return .{
            .ctx = self,
            .count = adlInstrumentCount(self),
            .get = adlInstrument,
        };
    }

    pub fn deinit(self: *AdlSource, gpa: std.mem.Allocator) void {
        gpa.free(self.sound_data);
        if (self.title) |t| gpa.free(t);
        if (self.title_stem) |t| gpa.free(t);
        gpa.destroy(self);
    }
};

fn adlTrack(_: *anyopaque, index: u16) view.SequenceTrack {
    if (index >= channels) return .{};
    return .{
        .name = if (index == control_ch) "ctrl" else "",
        .channel = @intCast(index),
        .kind = if (index == control_ch) .control else .melodic,
        .in_use = true,
    };
}

fn programOffset(sd: []const u8, id: u16) ?u32 {
    if (@as(u32, id) * 2 + 1 >= sd.len) return null;
    const off = fmt.readU16Le(sd, @as(usize, id) * 2);
    if (off == 0 or off >= sd.len) return null;
    return off;
}

fn adlProgramAt(ptr: *anyopaque, program: u16) []const u8 {
    const self: *AdlSource = @ptrCast(@alignCast(ptr));
    const off = programOffset(self.sound_data, program) orelse return &.{};
    return self.sound_data[off..];
}

fn branchTarget(sd: []const u8, after: usize, operand: i16, absolute: bool) u32 {
    const dest: i64 = if (absolute) @as(i64, operand) - driver_xlat else @as(i64, @intCast(after)) + operand;
    return if (dest < 0 or dest > sd.len) view.sequence_pc_none else @intCast(dest);
}

fn adlDecodeOne(sd: []const u8, version: Version, pos: *usize, chan: u16) ?view.SequenceEvent {
    if (pos.* >= sd.len) return null;
    const start = pos.*;
    const opcode = sd[pos.*];
    pos.* += 1;
    var ev = view.SequenceEvent{
        .tick = @intCast(start),
        .instr_index = @intCast(start),
        .track = chan,
        .channel = @intCast(@min(chan, 255)),
    };
    if (opcode & 0x80 == 0) {
        if (pos.* >= sd.len) {
            ev.kind = .end;
            return ev;
        }
        const duration = sd[pos.*];
        pos.* += 1;
        ev.kind = .duration_note;
        ev.payload = .{ .note = .{ .note = soundingMidi(opcode, 0, 0), .velocity = 127, .duration_ticks = duration } };
        return ev;
    }
    const raw = opcode & 0x7f;
    const idx: Opcode = @fromBackingInt(@min(raw, opcode_count - 1));
    const argc = idx.argCount();
    if (pos.* + argc > sd.len) {
        pos.* = sd.len;
        ev.kind = .end;
        return ev;
    }
    if (idx.isStop()) {
        ev.kind = .end;
        return ev;
    }
    const values = sd[pos.*..][0..argc];
    pos.* += argc;
    switch (idx) {
        .jump, .jsr, .check_repeat => {
            ev.kind = .jump;
            const absolute = switch (idx) {
                .jump => version.jumpIsAbsolute(),
                .jsr => version.jsrIsAbsolute(),
                else => false,
            };
            ev.payload = .{ .branch = .{
                .target = branchTarget(sd, pos.*, std.mem.readInt(i16, values[0..2], .little), absolute),
                .kind = switch (idx) {
                    .jsr => .call,
                    .check_repeat => .loop,
                    else => .jump,
                },
            } };
        },
        .ret => {
            ev.kind = .jump;
            ev.payload = .{ .branch = .{ .kind = .ret } };
        },
        .instrument => {
            ev.kind = .program;
            ev.payload = .{ .program = if (argc >= 1) values[0] else 0 };
        },
        .setup_program => {
            ev.kind = .start_program;
            ev.payload = .{ .start_program = if (argc >= 1) values[0] else 0 };
        },
        .set_tempo, .chan_tempo => {
            ev.kind = .tempo;
            ev.payload = .{ .tempo = if (argc >= 1) values[0] else 0 };
        },
        .pitch_bend => {
            ev.kind = .pitch_bend;
            const bend: i8 = if (argc >= 1) @bitCast(values[0]) else 0;
            ev.payload = .{ .pitch_bend = bendValue(bend) };
        },
        .rest => {
            ev.kind = .note_off;
            ev.payload = .{ .note = .{
                .note = 0,
                .velocity = 0,
                .duration_ticks = if (argc >= 1) values[0] else 0,
            } };
        },
        .play_note => {
            ev.kind = .duration_note;
            ev.payload = .{ .note = .{
                .note = 0,
                .velocity = 0,
                .duration_ticks = if (argc >= 1) values[0] else 0,
            } };
        },
        .note_and_duration => {
            ev.kind = .duration_note;
            ev.payload = .{ .note = .{
                .note = if (argc >= 1) soundingMidi(values[0], 0, 0) else 0,
                .velocity = 127,
                .duration_ticks = if (argc >= 2) values[1] else 0,
            } };
        },
        else => {
            ev.kind = .control;
            ev.payload = .{ .control = .{ .cc = raw, .value = if (argc >= 1) values[0] else 0 } };
        },
    }
    return ev;
}

fn adlBytecodeWindow(ptr: *anyopaque, chan: u16, from: u32, dest: []view.SequenceEvent) view.EventRange {
    return adlBytecodePage(ptr, chan, from, 0, dest);
}

fn adlBytecodePage(ptr: *anyopaque, chan: u16, from: u32, skip: u32, dest: []view.SequenceEvent) view.EventRange {
    const self: *AdlSource = @ptrCast(@alignCast(ptr));
    if (chan >= channels or from == view.sequence_pc_none) return .{};
    const sd = self.sound_data;
    if (from >= sd.len) return .{};
    var pos: usize = from;
    var written: u16 = 0;
    var total: u32 = 0;
    while (pos < sd.len) {
        const ev = adlDecodeOne(sd, self.version, &pos, chan) orelse break;
        total += 1;
        if (total > skip and written < dest.len) {
            dest[written] = ev;
            written += 1;
        }
        if (ev.kind == .end) break;
    }
    return .{ .written = written, .total_in_range = total };
}

fn instrumentLimit(self: *const AdlSource) u16 {
    return @min(256, self.version.programCount());
}

fn instrumentOffset(self: *const AdlSource, id: u16) ?u32 {
    if (id >= instrumentLimit(self)) return null;
    return programOffset(self.sound_data, self.version.programCount() + id);
}

fn adlInstrumentCount(self: *const AdlSource) u16 {
    var count: u16 = 0;
    for (0..instrumentLimit(self)) |id| {
        if (instrumentOffset(self, @intCast(id)) != null) count = @intCast(id + 1);
    }
    return count;
}

fn adlInstrument(ptr: *anyopaque, index: u16) view.InstrumentInfo {
    const self: *AdlSource = @ptrCast(@alignCast(ptr));
    const off = instrumentOffset(self, index) orelse return .{};
    const sd = self.sound_data;
    if (off + instrument_bytes > sd.len) return .{};
    const inst = std.mem.bytesToValue(Instrument, sd[off..][0..instrument_bytes]);
    return .{
        .patch = .{ .opl_2op = .{
            .ops = .{
                fmt.operatorParams(inst.mod_char, inst.mod_level, inst.mod_ad, inst.mod_sr, inst.mod_wave),
                fmt.operatorParams(inst.car_char, inst.car_level, inst.car_ad, inst.car_sr, inst.car_wave),
                .{},
                .{},
            },
            .op_count = 2,
            .feedback = @truncate((inst.feedback >> 1) & 7),
            .additive = inst.feedback & 1 != 0,
        } },
    };
}

fn detectVersion(data: []const u8) ?Version {
    if (data.len < v1_min_bytes) return null;

    var v4 = true;
    for (0..@min(data.len, Version.v4.tableBytes()) / 2) |i| {
        const w = fmt.readU16Le(data, i * 2);
        if (w >= v4_programs and w < 0xffff) {
            v4 = false;
            break;
        }
    }

    if (v4) {
        if (data.len < v4_min_bytes) return null;
        const sd = data[Version.v4.tableBytes()..];
        for (0..v4_programs) |p| {
            const w = fmt.readU16Le(sd, p * 2);
            if (w > 0 and w < v4_first_offset) return null;
        }
        return .v4;
    }

    const sd = data[Version.v1.tableBytes()..];
    var v1 = false;
    for (0..v1_programs) |p| {
        const w = fmt.readU16Le(sd, p * 2);
        if (w > 0 and w < v1_first_offset) return null;
        if (w > 0 and w < v23_first_offset) v1 = true;
    }
    if (v1) return .v1;
    if (data.len < v23_min_bytes) return null;
    for (v1_programs..v23_programs) |p| {
        const w = fmt.readU16Le(sd, p * 2);
        if (w > 0 and w < v23_first_offset) return null;
    }
    return .v3;
}

fn collectMusic(
    version: Version,
    data: []const u8,
    music_ids: *[max_music_tracks]u16,
) u16 {
    const table_len: usize = if (version == .v4) v4_tracks else v1_tracks;
    const sd_off = version.tableBytes();
    const nprog = version.programCount();
    const sd = data[sd_off..];
    var count: u16 = 0;
    var fallback_n: u16 = 0;
    var fallback: [max_music_tracks]u16 = undefined;

    for (0..table_len) |i| {
        const prog_id: u16 = if (version == .v4)
            fmt.readU16Le(data, i * 2)
        else
            data[i];
        const empty = if (version == .v4) @as(u16, 0xffff) else 0xff;
        if (prog_id == empty or prog_id >= nprog) continue;
        const off = fmt.readU16Le(sd, @as(usize, prog_id) * 2);
        if (off == 0 or off == 0xffff or @as(usize, off) + 1 >= sd.len) continue;
        const chan = sd[off];
        const prio = sd[off + 1];
        if (fallback_n < max_music_tracks) {
            fallback[fallback_n] = @intCast(i);
            fallback_n += 1;
        }
        if (chan == control_ch and prio < 50 and startsVoices(sd, off) and count < max_music_tracks) {
            music_ids[count] = @intCast(i);
            count += 1;
        }
    }
    if (count == 0) {
        @memcpy(music_ids[0..fallback_n], fallback[0..fallback_n]);
        return fallback_n;
    }
    return count;
}

pub fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const version = detectVersion(data) orelse return null;
    var music_ids: [max_music_tracks]u16 = @splat(0);
    const music_count = collectMusic(version, data, &music_ids);
    if (music_count == 0) return error.InvalidAdl;

    const table_len = version.tableBytes();
    const copy = try gpa.dupe(u8, data[table_len..]);
    errdefer gpa.free(copy);

    const idx: u16 = @intCast(@min(ctx.track_index, music_count - 1));
    var title: ?[]u8 = null;
    errdefer if (title) |t| gpa.free(t);
    var title_stem: ?[]u8 = null;
    errdefer if (title_stem) |t| gpa.free(t);
    if (music_count > 1) {
        const base = try fmt.dupeDisplayBasename(gpa, ctx.name);
        defer gpa.free(base);
        title_stem = try gpa.dupe(u8, fmt.stemOf(base));
        title = try gpa.print("{s} track {d}/{d}", .{
            title_stem.?,
            idx + 1,
            music_count,
        });
    }

    const src = try gpa.create(AdlSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .version = version,
        .sound_data = copy,
        .music_count = music_count,
        .music_index = idx,
        .title = title,
        .title_stem = title_stem,
    };
    @memcpy(src.track_entries[0..table_len], data[0..table_len]);
    @memcpy(src.music_ids[0..music_count], music_ids[0..music_count]);
    src.begin(ctx.chip);
    ctx.chip.flush();
    src.seedDuration();
    return fmt.MusicSource.init(src, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

fn putU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

fn makeV1(buf: []u8) []u8 {
    @memset(buf, 0);
    @memset(buf[0..v1_tracks], 0xff);
    buf[0] = 0;
    buf[1] = 1;
    buf[2] = 2;
    const sd = v1_tracks;
    putU16(buf, sd + 0 * 2, v1_first_offset);
    putU16(buf, sd + 1 * 2, v1_first_offset);
    putU16(buf, sd + 2 * 2, 620);
    putU16(buf, sd + 3 * 2, 640);
    putU16(buf, sd + v1_programs * 2, 660);

    const stop = [_]u8{ control_ch, 10, 0xae, 0, 0xaf, 0, 0xb3, 0, 0xb3, 1, 0x88 };
    @memcpy(buf[sd + v1_first_offset ..][0..stop.len], &stop);
    const song = [_]u8{ control_ch, 4, 0x82, 3, 0x89, 4, 0x88 };
    @memcpy(buf[sd + 620 ..][0..song.len], &song);
    const voice = [_]u8{ 0, 16, 0x90, 0, 0x30, 4, 0x88 };
    @memcpy(buf[sd + 640 ..][0..voice.len], &voice);
    @memset(buf[sd + 660 ..][0..instrument_bytes], 0x20);
    buf[sd + 660 + 5] = 0x10;
    buf[sd + 660 + 6] = 0x10;
    putU16(buf, sd + 40 * 2, 0xffff);
    buf[5] = 40;
    return buf[0 .. sd + 671];
}

fn makeLoopingV1(buf: []u8) []u8 {
    const data = makeV1(buf);
    const sd = v1_tracks;
    const loop = [_]u8{ 0, 16, 0x30, 4, 0x84, 0x41, 0x03 };
    @memcpy(buf[sd + 640 ..][0..loop.len], &loop);
    return data;
}

fn makeTwoSongV1(buf: []u8) []u8 {
    _ = makeV1(buf);
    const sd = v1_tracks;
    buf[3] = 4;
    putU16(buf, sd + 4 * 2, 680);
    const song2 = [_]u8{ control_ch, 4, 0x82, 3, 0x89, 16, 0x88 };
    @memcpy(buf[sd + 680 ..][0..song2.len], &song2);
    return buf[0 .. sd + 680 + song2.len];
}

const Rec = struct {
    writes: u32 = 0,
    fn write(ptr: *anyopaque, _: u16, _: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.writes += 1;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

test "adl rejects non-westwood bytes" {
    const gpa = std.testing.allocator;
    const ctx = fmt.LoadContext{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".adl", .name = "x.adl" };
    try std.testing.expect(fmt.isPlayablePath("tune.adl"));
    try std.testing.expect(try load(gpa, "not an adl", ctx) == null);
    try std.testing.expect(try load(gpa, &@as([100]u8, @splat(0)), ctx) == null);
}

test "adl loads a song, skips mute slots, and ends" {
    const gpa = std.testing.allocator;
    var buf: [800]u8 = undefined;
    const data = makeV1(&buf);
    try std.testing.expectEqual(Version.v1, detectVersion(data).?);

    var rec = Rec{};
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".adl",
        .name = "song.adl",
    })).?;
    defer src.deinit(gpa);

    const inf = src.info();
    try std.testing.expectEqualStrings("ADL", inf.format_name);
    try std.testing.expectEqualStrings("sequence", inf.visualizer);
    const sv = src.views().sequence.?;
    try std.testing.expectEqual(view.SequenceKind.voice_programs, sv.kind);
    try std.testing.expectEqual(@as(u16, channels), sv.track_count);
    try std.testing.expect(sv.programAt.?(sv.ctx, 0).len > 0);
    try std.testing.expect(src.views().instruments.?.count >= 1);
    try std.testing.expect(inf.loop);
    try std.testing.expectEqual(@as(u32, 1), inf.archive_track_count);
    try std.testing.expectEqual(@as(u32, 0), inf.archive_track_index);
    try std.testing.expect(inf.title == null);

    const drained = fmt.testDrain(src, rec.chip(), 400);
    try std.testing.expect(drained.done);
    try std.testing.expect(drained.frames > 0);
    try std.testing.expect(rec.writes > 0);
}

test "adl backward jump is a song boundary" {
    const gpa = std.testing.allocator;
    var buf: [800]u8 = undefined;
    const data = makeLoopingV1(&buf);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".adl",
        .name = "loop.adl",
    })).?;
    defer src.deinit(gpa);

    const drained = fmt.testDrain(src, fmt.noop_chip, 400);
    try std.testing.expect(drained.done);
    try std.testing.expect(drained.frames > 0);
}

test "adl selectArchiveTrack retargets in place" {
    const gpa = std.testing.allocator;
    var buf: [900]u8 = undefined;
    const data = makeTwoSongV1(&buf);
    var rec = Rec{};
    const src = (try fmt.load(gpa, "dune.adl", data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
    })) orelse return error.TestUnexpectedResult;
    defer src.deinit(gpa);

    try std.testing.expect(src.vtable.selectArchiveTrack != null);
    try std.testing.expect(src.duration_override == null);
    const inf0 = src.info();
    try std.testing.expectEqual(@as(u32, 2), inf0.archive_track_count);
    try std.testing.expectEqual(@as(u32, 0), inf0.archive_track_index);
    try std.testing.expectEqualStrings("dune track 1/2", inf0.title.?);
    const dur0 = src.durationFrames().?;
    try std.testing.expect(dur0 > 0);

    try std.testing.expect(try src.selectArchiveTrack(gpa, 1, rec.chip()));
    const inf1 = src.info();
    try std.testing.expectEqual(@as(u32, 1), inf1.archive_track_index);
    try std.testing.expectEqualStrings("dune track 2/2", inf1.title.?);
    const dur1 = src.durationFrames().?;
    try std.testing.expect(dur1 > dur0);

    try std.testing.expect(try src.selectArchiveTrack(gpa, 99, rec.chip()));
    try std.testing.expectEqual(@as(u32, 1), src.info().archive_track_index);
    try std.testing.expectEqualStrings("dune track 2/2", src.info().title.?);

    const adl: *AdlSource = @ptrCast(@alignCast(src.ptr));
    adl.driver.channels[0].op_extra_level2 = 9;
    try std.testing.expect(try src.selectArchiveTrack(gpa, 0, rec.chip()));
    try std.testing.expectEqual(@as(u8, 0), adl.driver.channels[0].op_extra_level2);
}

const RegRec = struct {
    regs: [0x200]u8 = @splat(0),
    fn write(ptr: *anyopaque, reg: u16, val: u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (reg < self.regs.len) self.regs[reg] = val;
    }
    fn flush(_: *anyopaque) void {}
    fn chip(self: *@This()) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

test "adl rhythm setup levels come from the executing channel" {
    var sd: [8 + instrument_bytes]u8 = @splat(0);
    for (0..3) |i| std.mem.writeInt(u16, sd[i * 2 ..][0..2], 8, .little);
    sd[8 + 2] = 0x01;
    sd[8 + 5] = 0x10;
    sd[8 + 6] = 0x08;
    var rec = RegRec{};
    var driver = Driver{ .sound_data = &sd, .chip = rec.chip(), .num_programs = 0 };
    driver.channels[control_ch].volume_modifier = 0xff;
    _ = driver.opRhythmSetup(control_ch, &@as([9]u8, @splat(0)));
    try std.testing.expect(rec.regs[Reg.level_base + 3 + op_offset[6]] != 0x3f);
    try std.testing.expectEqual(@as(u8, 0x01), rec.regs[Reg.feedback + 8]);
    try std.testing.expectEqual(@as(u8, 0x08), driver.op_level_cy);
    try std.testing.expect(driver.channels[control_ch].two_chan);
}

test "adl hostile modulation size and high program offsets do not panic" {
    var driver = Driver{};
    driver.channels[0].secondary_pos = -128;
    driver.channels[0].secondary_size = -128;
    driver.channels[0].secondary_tempo = 0xff;
    driver.channels[0].secondary_timer = 0xff;
    driver.effectModulate(0);
    try std.testing.expectEqual(@as(i8, 127), driver.channels[0].secondary_pos);

    const sd = try std.testing.allocator.alloc(u8, 0x10002);
    defer std.testing.allocator.free(sd);
    @memset(sd, 0);
    _ = startsVoices(sd, 0xfffe);
}

test "adl setup_program on the caller's own channel resets it and keeps the caller running" {
    var sd: [16]u8 = @splat(0);
    std.mem.writeInt(u16, sd[0..2], 8, .little);
    sd[8] = 0;
    sd[9] = 1;
    var rec = RegRec{};
    var driver = Driver{ .sound_data = &sd, .chip = rec.chip(), .num_programs = 1 };
    driver.channels[0].dataptr = 12;
    driver.channels[0].priority = 0;
    _ = driver.opSetupProgram(0, &.{0});
    try std.testing.expectEqual(@as(?u32, 12), driver.channels[0].dataptr);
    try std.testing.expectEqual(@as(u8, 1), driver.channels[0].priority);
}

test "adl v1 instrument bank ends at the instrument table" {
    const gpa = std.testing.allocator;
    var buf: [800]u8 = undefined;
    const data = makeV1(&buf);
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".adl", .name = "song.adl" })).?;
    defer src.deinit(gpa);
    const bank = src.views().instruments.?;
    try std.testing.expectEqual(@as(u16, 1), bank.count);
    try std.testing.expect(bank.get(bank.ctx, v1_programs + 1).patch == .empty);
}

test "adl jumps publish their destination offset" {
    const gpa = std.testing.allocator;
    var buf: [800]u8 = undefined;
    const data = makeLoopingV1(&buf);
    const src = (try load(gpa, data, .{ .sample_rate = 44100, .chip = fmt.noop_chip, .ext = ".adl", .name = "loop.adl" })).?;
    defer src.deinit(gpa);
    const sv = src.views().sequence.?;
    var dest: [4]view.SequenceEvent = undefined;
    const range = sv.bytecodeWindow.?(sv.ctx, 0, 642, &dest);
    try std.testing.expect(range.written >= 2);
    try std.testing.expectEqual(@as(u32, 642), dest[1].payload.branch.target);
    try std.testing.expect(dest[1].payload.branch.kind == .jump);
}

test "adl branches resolve relative and absolute operands and read as offsets" {
    const common = @import("../visualizers/common.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sv = view.SequenceView{ .ctx = undefined, .kind = .voice_programs, .track_count = 10, .channel_count = 10, .tick_rate = 1, .length_ticks = 0, .track = undefined };
    const Kind = @FieldType(@FieldType(view.EventPayload, "branch"), "kind");
    const Want = struct { kind: Kind, target: u32, text: []const u8 };
    const v3 = [_]u8{ 0x84, 0xfd, 0xff, 0x85, 0x02, 0x00, 0x81, 0xf7, 0xff, 0x86 };
    const wants = [_]Want{
        .{ .kind = .jump, .target = 0, .text = "Jump to 000000" },
        .{ .kind = .call, .target = 8, .text = "Call 000008" },
        .{ .kind = .loop, .target = 0, .text = "Repeat from 000000" },
        .{ .kind = .ret, .target = 0, .text = "Return" },
    };
    var pos: usize = 0;
    for (wants) |want| {
        const ev = adlDecodeOne(&v3, .v3, &pos, 0).?;
        try std.testing.expectEqual(want.kind, ev.payload.branch.kind);
        try std.testing.expectEqual(want.target, ev.payload.branch.target);
        try std.testing.expectEqualStrings(want.text, try common.describeSequenceEvent(arena.allocator(), sv, ev));
    }
    const v2 = [_]u8{ 0x85, 0xc2, 0x00, 0x86, 0x84, 0x00, 0x10 };
    pos = 0;
    try std.testing.expectEqual(@as(u32, 3), adlDecodeOne(&v2, .v2, &pos, 0).?.payload.branch.target);
    pos = 4;
    const outside = adlDecodeOne(&v2, .v2, &pos, 0).?;
    try std.testing.expectEqual(view.sequence_pc_none, outside.payload.branch.target);
    try std.testing.expectEqualStrings("Jump to an offset outside the data", try common.describeSequenceEvent(arena.allocator(), sv, outside));
}

test "adl only the global and channel tempo opcodes read as tempo" {
    const common = @import("../visualizers/common.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sv = view.SequenceView{ .ctx = undefined, .kind = .voice_programs, .track_count = 10, .channel_count = 10, .tick_rate = 1, .length_ticks = 0, .track = undefined };
    const code = [_]u8{ 0xa6, 0xb9, 0xa9, 0x40, 0xba, 0xbd, 0xf8, 0xc8, 0x01 };
    const wants = [_][]const u8{ "Tempo 185", "Tempo 64", "Control 58 = 0", "Control 61 = 248", "Control 72 = 1" };
    var pos: usize = 0;
    for (wants) |want| {
        const ev = adlDecodeOne(&code, .v3, &pos, 0).?;
        try std.testing.expectEqualStrings(want, try common.describeSequenceEvent(arena.allocator(), sv, ev));
    }
}

test "adl stops, clamped opcodes, and truncated operands end the window" {
    const common = @import("../visualizers/common.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sv = view.SequenceView{ .ctx = undefined, .kind = .voice_programs, .track_count = 10, .channel_count = 10, .tick_rate = 1, .length_ticks = 0, .track = undefined };
    const programs = [_][]const u8{
        &.{ 0x30, 4, 0x88, 0x30, 4 },
        &.{ 0x30, 4, 0x94, 0x30, 4 },
        &.{ 0x30, 4, 0xcb, 0x30, 4 },
        &.{ 0x30, 4, 0xff, 0x30, 4 },
        &.{ 0x30, 4, 0x30 },
        &.{ 0x30, 4, 0x84, 0x30 },
        &.{ 0x30, 4, 0xc1, 0x00, 0x30, 4 },
    };
    for (programs) |program| {
        var src = AdlSource{ .sample_rate = 44100, .version = .v3, .sound_data = program, .music_count = 1, .music_index = 0 };
        var dest: [8]view.SequenceEvent = undefined;
        const range = adlBytecodePage(&src, 0, 0, 0, &dest);
        try std.testing.expectEqual(@as(u16, 2), range.written);
        try std.testing.expectEqual(@as(u32, 2), range.total_in_range);
        try std.testing.expectEqual(view.SequenceEventKind.end, dest[1].kind);
        try std.testing.expectEqualStrings("End", try common.describeSequenceEvent(arena.allocator(), sv, dest[1]));
    }
}

test "adl pitch bends publish the centred 14-bit range" {
    const code = [_]u8{ 0xb9, 0x00, 0xb9, 0x01, 0xb9, 0xf7, 0xb9, 0x7f, 0xb9, 0x80 };
    const wants = [_]u16{ 8192, 8448, 5888, 16128, 256 };
    var pos: usize = 0;
    for (wants) |want| {
        try std.testing.expectEqual(want, adlDecodeOne(&code, .v3, &pos, 0).?.payload.pitch_bend);
    }
}

test "adl channel state publishes the live bend and no voice for the control channel" {
    const program = [_]u8{ 0xb9, 0x01, 0x30, 4, 0x88, 0xb9, 0x80, 0x30, 4, 0x88 };
    var src = AdlSource{ .sample_rate = 44100, .version = .v3, .sound_data = &program, .music_count = 1, .music_index = 0 };
    src.driver.sound_data = &program;
    src.driver.startOnChannel(0, 0, 1);
    src.driver.startOnChannel(1, 5, 1);
    src.driver.executePrograms();
    const state = src.sequenceState();
    try std.testing.expectEqual(@as(u16, 8448), state.slots[0].bend);
    try std.testing.expectEqual(@as(u16, 256), state.slots[1].bend);
    try std.testing.expectEqual(@as(u16, 8192), state.slots[2].bend);
    for (state.slots[0..voices], 0..) |slot, i| try std.testing.expectEqual(@as(u8, @intCast(i)), slot.opl_voice);
    try std.testing.expectEqual(@as(u8, 0xff), state.slots[control_ch].opl_voice);
}
