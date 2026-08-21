//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const opal = @import("opal");

const fmt = @import("../format.zig");
const chip_adapter = @import("../chip.zig");

pub const visualizer_name = "stream";

const magic = "CTMF";
const instrument_bytes = 16;
const payload_bytes = 11;
const max_instruments = 256;
const midi_channels = 16;
const opl_channels = 9;

const Reg = struct {
    const waveform_select: u16 = 0x01;
    const csw: u16 = 0x08;
    const fnum_lo: u16 = 0xa0;
    const key_block: u16 = 0xb0;
    const rhythm: u16 = 0xbd;
    const feedback: u16 = 0xc0;
    const char_base: u16 = 0x20;
    const level_base: u16 = 0x40;
    const ad_base: u16 = 0x60;
    const sr_base: u16 = 0x80;
    const wave_base: u16 = 0xe0;
    const key_on: u8 = 0x20;
};

const op_offset = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x10, 0x11, 0x12 };

const op_reg_fields = .{
    .{ Reg.char_base, "char_mult" },
    .{ Reg.level_base, "scaling" },
    .{ Reg.ad_base, "attack_decay" },
    .{ Reg.sr_base, "sustain_release" },
    .{ Reg.wave_base, "wave" },
};

/// MIDI note 0..127 -> (block nibble in high 4, semitone in low 4). Creative SBFMDRV table.
const block_note = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b,
    0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b,
    0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b,
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b,
    0x7b, 0x7b, 0x7b, 0x7b, 0x7b, 0x7b, 0x7b, 0x7b,
};

/// F-number for a note index in 1/64ths of a semitone within one octave
/// (12 * 64 == 768 entries). Creative SBFMDRV table, via AdPlug / fmdrv.
const fnum_tbl = [768]u16{
    343, 343, 344, 344, 344, 344, 345, 345, 345, 346, 346, 346,
    347, 347, 347, 348, 348, 348, 349, 349, 349, 349, 350, 350,
    350, 351, 351, 351, 352, 352, 352, 353, 353, 353, 354, 354,
    354, 355, 355, 355, 356, 356, 356, 356, 357, 357, 357, 358,
    358, 358, 359, 359, 359, 360, 360, 360, 361, 361, 361, 362,
    362, 362, 363, 363, 363, 364, 364, 364, 365, 365, 365, 366,
    366, 366, 367, 367, 367, 368, 368, 368, 369, 369, 369, 370,
    370, 370, 371, 371, 371, 372, 372, 372, 373, 373, 373, 374,
    374, 374, 375, 375, 375, 376, 376, 376, 377, 377, 377, 378,
    378, 378, 379, 379, 379, 380, 380, 380, 381, 381, 381, 382,
    382, 382, 383, 383, 384, 384, 384, 385, 385, 385, 386, 386,
    386, 387, 387, 387, 388, 388, 388, 389, 389, 389, 390, 390,
    391, 391, 391, 392, 392, 392, 393, 393, 393, 394, 394, 394,
    395, 395, 395, 396, 396, 397, 397, 397, 398, 398, 398, 399,
    399, 399, 400, 400, 401, 401, 401, 402, 402, 402, 403, 403,
    403, 404, 404, 405, 405, 405, 406, 406, 406, 407, 407, 407,
    408, 408, 409, 409, 409, 410, 410, 410, 411, 411, 412, 412,
    412, 413, 413, 413, 414, 414, 414, 415, 415, 416, 416, 416,
    417, 417, 417, 418, 418, 419, 419, 419, 420, 420, 421, 421,
    421, 422, 422, 422, 423, 423, 424, 424, 424, 425, 425, 425,
    426, 426, 427, 427, 427, 428, 428, 429, 429, 429, 430, 430,
    430, 431, 431, 432, 432, 432, 433, 433, 434, 434, 434, 435,
    435, 436, 436, 436, 437, 437, 438, 438, 438, 439, 439, 440,
    440, 440, 441, 441, 442, 442, 442, 443, 443, 444, 444, 444,
    445, 445, 446, 446, 446, 447, 447, 448, 448, 448, 449, 449,
    450, 450, 450, 451, 451, 452, 452, 452, 453, 453, 454, 454,
    454, 455, 455, 456, 456, 457, 457, 457, 458, 458, 459, 459,
    459, 460, 460, 461, 461, 461, 462, 462, 463, 463, 464, 464,
    464, 465, 465, 466, 466, 467, 467, 467, 468, 468, 469, 469,
    469, 470, 470, 471, 471, 472, 472, 472, 473, 473, 474, 474,
    475, 475, 475, 476, 476, 477, 477, 478, 478, 478, 479, 479,
    480, 480, 481, 481, 481, 482, 482, 483, 483, 484, 484, 485,
    485, 485, 486, 486, 487, 487, 488, 488, 488, 489, 489, 490,
    490, 491, 491, 492, 492, 492, 493, 493, 494, 494, 495, 495,
    496, 496, 496, 497, 497, 498, 498, 499, 499, 500, 500, 501,
    501, 501, 502, 502, 503, 503, 504, 504, 505, 505, 506, 506,
    506, 507, 507, 508, 508, 509, 509, 510, 510, 511, 511, 511,
    512, 512, 513, 513, 514, 514, 515, 515, 516, 516, 517, 517,
    518, 518, 518, 519, 519, 520, 520, 521, 521, 522, 522, 523,
    523, 524, 524, 525, 525, 526, 526, 526, 527, 527, 528, 528,
    529, 529, 530, 530, 531, 531, 532, 532, 533, 533, 534, 534,
    535, 535, 536, 536, 537, 537, 538, 538, 538, 539, 539, 540,
    540, 541, 541, 542, 542, 543, 543, 544, 544, 545, 545, 546,
    546, 547, 547, 548, 548, 549, 549, 550, 550, 551, 551, 552,
    552, 553, 553, 554, 554, 555, 555, 556, 556, 557, 557, 558,
    558, 559, 559, 560, 560, 561, 561, 562, 562, 563, 563, 564,
    564, 565, 565, 566, 566, 567, 567, 568, 568, 569, 569, 570,
    571, 571, 572, 572, 573, 573, 574, 574, 575, 575, 576, 576,
    577, 577, 578, 578, 579, 579, 580, 580, 581, 581, 582, 582,
    583, 584, 584, 585, 585, 586, 586, 587, 587, 588, 588, 589,
    589, 590, 590, 591, 591, 592, 593, 593, 594, 594, 595, 595,
    596, 596, 597, 597, 598, 598, 599, 600, 600, 601, 601, 602,
    602, 603, 603, 604, 604, 605, 606, 606, 607, 607, 608, 608,
    609, 609, 610, 610, 611, 612, 612, 613, 613, 614, 614, 615,
    615, 616, 617, 617, 618, 618, 619, 619, 620, 620, 621, 622,
    622, 623, 623, 624, 624, 625, 626, 626, 627, 627, 628, 628,
    629, 629, 630, 631, 631, 632, 632, 633, 633, 634, 635, 635,
    636, 636, 637, 637, 638, 639, 639, 640, 640, 641, 642, 642,
    643, 643, 644, 644, 645, 646, 646, 647, 647, 648, 649, 649,
    650, 650, 651, 651, 652, 653, 653, 654, 654, 655, 656, 656,
    657, 657, 658, 659, 659, 660, 660, 661, 662, 662, 663, 663,
    664, 665, 665, 666, 666, 667, 668, 668, 669, 669, 670, 671,
    671, 672, 672, 673, 674, 674, 675, 675, 676, 677, 677, 678,
    678, 679, 680, 680, 681, 682, 682, 683, 683, 684, 685, 685,
};

const init_instrument = [_]u8{ 0x01, 0x11, 0x4f, 0x00, 0xf1, 0xf2, 0x53, 0x74, 0x00, 0x00, 0x08 };

const default_drum_patches = [_][payload_bytes]u8{
    .{ 0x00, 0x00, 0x00, 0x00, 0xf8, 0xf8, 0x07, 0x07, 0x00, 0x00, 0x00 },
    .{ 0x0c, 0x0c, 0x00, 0x00, 0xf8, 0xf8, 0x07, 0x07, 0x00, 0x01, 0x00 },
    .{ 0x04, 0x04, 0x00, 0x00, 0xf8, 0xf8, 0x07, 0x07, 0x00, 0x00, 0x00 },
    .{ 0x0c, 0x0c, 0x00, 0x00, 0xf8, 0xf8, 0x05, 0x05, 0x03, 0x03, 0x00 },
    .{ 0x0e, 0x0e, 0x00, 0x00, 0xf8, 0xf8, 0x07, 0x07, 0x03, 0x03, 0x00 },
};

const default_patches = [_][payload_bytes]u8{
    .{ 0x21, 0x21, 0xd1, 0x07, 0xa3, 0xa4, 0x46, 0x25, 0x00, 0x00, 0x0a },
    .{ 0x22, 0x22, 0x0f, 0x0f, 0xf6, 0xf6, 0x95, 0x36, 0x00, 0x00, 0x0a },
    .{ 0xe1, 0xe1, 0x00, 0x00, 0x44, 0x54, 0x24, 0x34, 0x02, 0x02, 0x07 },
    .{ 0xa5, 0xb1, 0xd2, 0x80, 0x81, 0xf1, 0x03, 0x05, 0x00, 0x00, 0x02 },
    .{ 0x71, 0x22, 0xc5, 0x05, 0x6e, 0x8b, 0x17, 0x0e, 0x00, 0x00, 0x02 },
    .{ 0x32, 0x21, 0x16, 0x80, 0x73, 0x75, 0x24, 0x57, 0x00, 0x00, 0x0e },
    .{ 0x01, 0x11, 0x4f, 0x00, 0xf1, 0xd2, 0x53, 0x74, 0x00, 0x00, 0x06 },
    .{ 0x07, 0x12, 0x4f, 0x00, 0xf2, 0xf2, 0x60, 0x72, 0x00, 0x00, 0x08 },
    .{ 0x31, 0xa1, 0x1c, 0x80, 0x51, 0x54, 0x03, 0x67, 0x00, 0x00, 0x0e },
    .{ 0x31, 0xa1, 0x1c, 0x80, 0x41, 0x92, 0x0b, 0x3b, 0x00, 0x00, 0x0e },
    .{ 0x31, 0x16, 0x87, 0x80, 0xa1, 0x7d, 0x11, 0x43, 0x00, 0x00, 0x08 },
    .{ 0x30, 0xb1, 0xc8, 0x80, 0xd5, 0x61, 0x19, 0x1b, 0x00, 0x00, 0x0c },
    .{ 0xf1, 0x21, 0x01, 0x0d, 0x97, 0xf1, 0x17, 0x18, 0x00, 0x00, 0x08 },
    .{ 0x32, 0x16, 0x87, 0x80, 0xa1, 0x7d, 0x10, 0x33, 0x00, 0x00, 0x08 },
    .{ 0x01, 0x12, 0x4f, 0x00, 0x71, 0x52, 0x53, 0x7c, 0x00, 0x00, 0x0a },
    .{ 0x02, 0x03, 0x8d, 0x03, 0xd7, 0xf5, 0x37, 0x18, 0x00, 0x00, 0x04 },
};

const Operator = extern struct {
    char_mult: u8 = 0,
    scaling: u8 = 0,
    attack_decay: u8 = 0,
    sustain_release: u8 = 0,
    wave: u8 = 0,
};

const Instrument = extern struct {
    modulator: Operator = .{},
    carrier: Operator = .{},
    connection: u8 = 0,

    fn fromPayload(p: *const [payload_bytes]u8) Instrument {
        return .{
            .modulator = .{
                .char_mult = p[0],
                .scaling = p[2],
                .attack_decay = p[4],
                .sustain_release = p[6],
                .wave = p[8],
            },
            .carrier = .{
                .char_mult = p[1],
                .scaling = p[3],
                .attack_decay = p[5],
                .sustain_release = p[7],
                .wave = p[9],
            },
            .connection = p[10],
        };
    }
};

const MidiChannel = struct {
    patch: u8 = 0,
    drum: u8 = 0xff,
    pitchbend: i16 = 8192,
    transpose: i16 = 0,
};

const OplVoice = struct {
    note_start: u32 = 0,
    midi_note: i16 = -1,
    midi_channel: i16 = -1,
};

const Header = struct {
    instrument_offset: u16,
    music_offset: u16,
    ticks_per_second: u16,
    title_offset: u16,
    composer_offset: u16,
    num_instruments: u16,
};

const CmfSource = struct {
    sample_rate: u32,
    ticks_per_second: u32,
    frac: u32 = 0,
    music: []const u8,
    instruments: []Instrument,
    inst_count: u16,
    title: ?[]const u8,
    title_embedded: bool,
    artist: ?[]const u8,
    pos: usize = 0,
    prev_command: u8 = 0,
    delay_remaining: u32 = 0,
    note_count: u32 = 0,
    percussive: bool = false,
    midi_drums: bool = false,
    regs: [256]u8 = @splat(0),
    midi: [midi_channels]MidiChannel = @splat(.{}),
    voices: [opl_channels]OplVoice = @splat(.{}),
    note_playing: [midi_channels]u8 = @splat(255),
    note_fix: [midi_channels]bool = @splat(false),

    fn write(self: *CmfSource, chip: fmt.Chip, reg: u16, val: u8) void {
        chip.writeReg(reg, val);
        if (reg < 256) self.regs[@intCast(reg)] = val;
    }

    fn writeInstrument(self: *CmfSource, chip: fmt.Chip, chan: u8, ins: Instrument) void {
        const off = op_offset[chan];
        inline for (op_reg_fields) |pair| {
            self.write(chip, pair[0] + off, @field(ins.modulator, pair[1]));
            self.write(chip, pair[0] + off + 3, @field(ins.carrier, pair[1]));
        }
        self.write(chip, Reg.feedback + chan, ins.connection);
    }

    fn writeInitInstrument(self: *CmfSource, chip: fmt.Chip, chan: u8) void {
        self.writeInstrument(chip, chan, Instrument.fromPayload(&init_instrument));
    }

    fn instrument(self: *const CmfSource, patch: u8) Instrument {
        if (self.instruments.len == 0) return Instrument.fromPayload(&default_patches[0]);
        const idx = patch % self.inst_count;
        return self.instruments[idx];
    }

    fn channelInstrument(self: *const CmfSource, ch: u8) Instrument {
        const drum = self.midi[ch].drum;
        if (drum < default_drum_patches.len) return Instrument.fromPayload(&default_drum_patches[drum]);
        return self.instrument(self.midi[ch].patch);
    }

    fn assignDrumFallbacks(self: *CmfSource) void {
        if (!self.midi_drums) return;
        for (0..default_drum_patches.len) |i| {
            self.midi[11 + i].drum = @intCast(i);
        }
    }

    fn noteFreq(self: *const CmfSource, channel: u8, note: u8) struct { block: u8, fnum: u16 } {
        const bn = block_note[@min(note, 127)];
        var block: i32 = (bn >> 4) & 7;
        // Note index within the octave in 1/64ths of a semitone, as SBFMDRV's
        // calc_block_fnum works. Transpose arrives as the raw controller value
        // and the driver applies a quarter of it. Pitch bend is centred at
        // 8192 with one semitone of range either way.
        var idx: i32 = @as(i32, bn & 0x0f) << 6;
        idx += @divTrunc(@as(i32, self.midi[channel].transpose), 4);
        idx += @divTrunc(@as(i32, self.midi[channel].pitchbend) - 8192, 128);
        if (idx < 0) {
            idx += 768;
            block -= 1;
            if (block < 0) {
                idx = 0;
                block = 0;
            }
        }
        if (idx >= 768) {
            idx -= 768;
            block += 1;
            if (block > 7) {
                idx = 767;
                block = 7;
            }
        }
        return .{ .block = @intCast(block), .fnum = fnum_tbl[@intCast(idx)] };
    }

    fn velocityLevel(carrier_scaling: u8, velocity: u8) u8 {
        const base: u16 = 63 - (carrier_scaling & 0x3f);
        const ksl = carrier_scaling & 0xc0;
        const level: u16 = 63 - (((@as(u16, velocity) | 0x80) * base) >> 8);
        return @truncate(level | ksl);
    }

    fn melodicVoiceCount(self: *const CmfSource) u8 {
        return if (self.percussive) 6 else 9;
    }

    fn pickVoice(self: *CmfSource, chip: fmt.Chip, midi_ch: u8) u8 {
        const n = self.melodicVoiceCount();
        // Tier 1: released voice owned by this channel.
        for (0..n) |i| {
            if (self.voices[i].note_start == 0 and self.voices[i].midi_channel == midi_ch)
                return @intCast(i);
        }
        // Tier 2: never used.
        for (0..n) |i| {
            if (self.voices[i].midi_channel < 0) return @intCast(i);
        }
        // Tier 3: any released voice.
        for (0..n) |i| {
            if (self.voices[i].note_start == 0) return @intCast(i);
        }
        // Tier 4: steal oldest.
        var best: u8 = 0;
        var earliest = self.voices[0].note_start;
        for (1..n) |i| {
            if (self.voices[i].note_start < earliest) {
                earliest = self.voices[i].note_start;
                best = @intCast(i);
            }
        }
        self.write(chip, Reg.key_block + best, self.regs[Reg.key_block + best] & ~Reg.key_on);
        return best;
    }

    fn percChannel(midi_ch: u8) u8 {
        return switch (midi_ch) {
            11 => 6, // bass drum
            12 => 7, // snare
            13 => 8, // tom
            14 => 8, // cymbal
            15 => 7, // hi-hat
            else => 0,
        };
    }

    fn gmKeyToRhythm(note: u8) u8 {
        return switch (note) {
            35, 36 => 11,
            37, 38, 39, 40 => 12,
            42, 44, 46 => 15,
            49, 51, 52, 53, 55, 57, 59, 80, 81 => 14,
            else => 13,
        };
    }

    fn noteOn(self: *CmfSource, chip: fmt.Chip, channel: u8, note: u8, velocity: u8) void {
        var ch = channel;
        if (self.midi_drums and ch == 9) ch = gmKeyToRhythm(note);

        if (ch > 10 and self.percussive) {
            const opl = percChannel(ch);
            const ins = self.channelInstrument(ch);
            self.programPerc(chip, ch, ins);
            const level = velocityLevel(ins.carrier.scaling, velocity);
            var lvl_reg = Reg.level_base + op_offset[opl];
            if (ch == 11) lvl_reg += 3;
            self.write(chip, lvl_reg, level);
            const freq = self.noteFreq(ch, note);
            self.write(chip, Reg.fnum_lo + opl, @truncate(freq.fnum));
            self.write(chip, Reg.key_block + opl, @as(u8, @truncate(freq.block << 2)) | @as(u8, @truncate(freq.fnum >> 8)));
            const bit: u8 = @as(u8, 1) << @intCast(15 - ch);
            const bd = self.regs[Reg.rhythm];
            if (bd & bit != 0) self.write(chip, Reg.rhythm, bd & ~bit);
            self.write(chip, Reg.rhythm, self.regs[Reg.rhythm] | bit);
            self.note_count += 1;
            self.voices[opl].note_start = self.note_count;
            self.voices[opl].midi_channel = ch;
            self.voices[opl].midi_note = note;
            return;
        }

        const voice = self.pickVoice(chip, ch);
        if (self.voices[voice].midi_channel != ch) {
            self.writeInstrument(chip, voice, self.instrument(self.midi[ch].patch));
        }
        self.note_count += 1;
        self.voices[voice].note_start = self.note_count;
        self.voices[voice].midi_channel = ch;
        self.voices[voice].midi_note = note;

        const ins = self.instrument(self.midi[ch].patch);
        const level = velocityLevel(ins.carrier.scaling, velocity);
        self.write(chip, Reg.level_base + op_offset[voice] + 3, level);
        const freq = self.noteFreq(ch, note);
        self.write(chip, Reg.fnum_lo + voice, @truncate(freq.fnum));
        self.write(chip, Reg.key_block + voice, Reg.key_on | @as(u8, @truncate(freq.block << 2)) | @as(u8, @truncate((freq.fnum >> 8) & 3)));
    }

    fn programPerc(self: *CmfSource, chip: fmt.Chip, midi_ch: u8, ins: Instrument) void {
        if (midi_ch == 11) return self.writeInstrument(chip, 6, ins);
        const off: u8 = switch (midi_ch) {
            12 => op_offset[7] + 3,
            13 => op_offset[8],
            14 => op_offset[8] + 3,
            15 => op_offset[7],
            else => return,
        };
        inline for (op_reg_fields) |pair| {
            self.write(chip, pair[0] + off, @field(ins.modulator, pair[1]));
        }
    }

    fn noteOff(self: *CmfSource, chip: fmt.Chip, channel: u8, note: u8) void {
        var ch = channel;
        if (self.midi_drums and ch == 9) ch = gmKeyToRhythm(note);

        if (ch > 10 and self.percussive) {
            const opl = percChannel(ch);
            if (self.voices[opl].midi_note != note) return;
            const bit: u8 = @as(u8, 1) << @intCast(15 - ch);
            self.write(chip, Reg.rhythm, self.regs[Reg.rhythm] & ~bit);
            self.voices[opl].note_start = 0;
            return;
        }

        const n = self.melodicVoiceCount();
        for (0..n) |i| {
            if (self.voices[i].midi_channel == ch and self.voices[i].midi_note == note and self.voices[i].note_start != 0) {
                self.voices[i].note_start = 0;
                self.write(chip, Reg.key_block + @as(u8, @intCast(i)), self.regs[Reg.key_block + i] & ~Reg.key_on);
            }
        }
    }

    fn noteUpdate(self: *CmfSource, chip: fmt.Chip, channel: u8) void {
        if (channel > 10 and self.percussive) {
            const opl = percChannel(channel);
            if (self.voices[opl].midi_note < 0) return;
            const freq = self.noteFreq(channel, @intCast(self.voices[opl].midi_note));
            self.write(chip, Reg.fnum_lo + opl, @truncate(freq.fnum));
            self.write(chip, Reg.key_block + opl, @as(u8, @truncate(freq.block << 2)) | @as(u8, @truncate(freq.fnum >> 8)));
            return;
        }
        const n = self.melodicVoiceCount();
        for (0..n) |i| {
            if (self.voices[i].midi_channel == channel and self.voices[i].note_start > 0) {
                const freq = self.noteFreq(channel, @intCast(self.voices[i].midi_note));
                self.write(chip, Reg.fnum_lo + @as(u8, @intCast(i)), @truncate(freq.fnum));
                self.write(chip, Reg.key_block + @as(u8, @intCast(i)), Reg.key_on | @as(u8, @truncate(freq.block << 2)) | @as(u8, @truncate((freq.fnum >> 8) & 3)));
            }
        }
    }

    fn rhythmMode(self: *CmfSource, chip: fmt.Chip, enable: bool) void {
        for (0..opl_channels) |i| {
            const reg = Reg.key_block + @as(u16, @intCast(i));
            self.write(chip, reg, self.regs[reg] & ~Reg.key_on);
        }
        self.percussive = enable;
        self.write(chip, Reg.csw, 0);
        for (0..opl_channels) |i| {
            self.writeInitInstrument(chip, @intCast(i));
            self.voices[i] = .{};
        }
        for (&self.midi) |*m| {
            m.patch = 0;
            m.drum = 0xff;
        }
        if (enable) self.assignDrumFallbacks();
        self.write(chip, Reg.rhythm, if (enable) 0xe0 else 0xc0);
    }

    /// End-of-track only rewinds the byte cursor, so the next pass would
    /// inherit keyed-on voices, patches, pitch bend, and transpose. Restore
    /// the load-time state instead, as the Creative driver's reset does.
    fn resetLoopState(self: *CmfSource, chip: fmt.Chip) void {
        for (0..opl_channels) |i| {
            const reg = Reg.key_block + @as(u16, @intCast(i));
            self.write(chip, reg, self.regs[reg] & ~Reg.key_on);
        }
        self.midi = @splat(.{});
        self.rhythmMode(chip, self.midi_drums);
        self.note_playing = @splat(255);
        self.note_fix = @splat(false);
    }

    fn readByte(self: *CmfSource) ?u8 {
        if (self.pos >= self.music.len) return null;
        const b = self.music[self.pos];
        self.pos += 1;
        return b;
    }

    fn readVlq(self: *CmfSource) u32 {
        var value: u32 = 0;
        for (0..4) |_| {
            const b = self.readByte() orelse break;
            value = (value << 7) | (b & 0x7f);
            if (b & 0x80 == 0) break;
        }
        return value;
    }

    fn controller(self: *CmfSource, chip: fmt.Chip, channel: u8, ctrl: u8, value: u8) void {
        switch (ctrl) {
            0x63 => {
                const bd = self.regs[Reg.rhythm] & ~@as(u8, 0xc0);
                self.write(chip, Reg.rhythm, bd | (@as(u8, value & 3) << 6));
            },
            0x67 => self.rhythmMode(chip, value != 0),
            0x68 => {
                self.midi[channel].transpose = value;
                self.noteUpdate(chip, channel);
            },
            0x69 => {
                self.midi[channel].transpose = -@as(i16, value);
                self.noteUpdate(chip, channel);
            },
            else => {},
        }
    }

    fn processEvent(self: *CmfSource, chip: fmt.Chip) bool {
        var command = self.readByte() orelse {
            self.pos = 0;
            return true;
        };
        if (command & 0x80 == 0) {
            self.pos -= 1;
            command = self.prev_command;
        } else {
            self.prev_command = command;
        }

        const channel: u8 = command & 0x0f;
        switch (command & 0xf0) {
            0x80 => {
                const note = self.readByte() orelse 0;
                _ = self.readByte();
                self.noteOff(chip, channel, note);
            },
            0x90 => {
                const note = self.readByte() orelse 0;
                var velocity = self.readByte() orelse 0;
                if (velocity != 0) {
                    if (self.note_playing[channel] == note) {
                        velocity = 0;
                        self.note_fix[channel] = true;
                    }
                } else if (self.note_fix[channel]) {
                    velocity = 127;
                    self.note_fix[channel] = false;
                }
                self.note_playing[channel] = if (velocity != 0) note else 255;
                if (velocity != 0) self.noteOn(chip, channel, note, velocity) else self.noteOff(chip, channel, note);
            },
            0xa0 => {
                _ = self.readByte();
                _ = self.readByte();
            },
            0xb0 => {
                const ctrl = self.readByte() orelse 0;
                const value = self.readByte() orelse 0;
                self.controller(chip, channel, ctrl, value);
            },
            0xc0 => {
                const patch = self.readByte() orelse 0;
                const wrapped: u8 = if (self.inst_count > 0) @intCast(patch % self.inst_count) else 0;
                self.midi[channel].patch = wrapped;
                self.midi[channel].drum = 0xff;
                if (!self.percussive or channel < 11) {
                    const n = self.melodicVoiceCount();
                    for (0..n) |i| {
                        if (self.voices[i].note_start == 0 and self.voices[i].midi_channel == channel)
                            self.voices[i].midi_channel = -1;
                    }
                    for (0..n) |i| {
                        if (self.voices[i].note_start > 0 and self.voices[i].midi_channel == channel)
                            self.writeInstrument(chip, @intCast(i), self.instrument(wrapped));
                    }
                } else {
                    self.programPerc(chip, channel, self.instrument(wrapped));
                }
            },
            0xd0 => _ = self.readByte(),
            0xe0 => {
                const lsb = self.readByte() orelse 0;
                const msb = self.readByte() orelse 0;
                self.midi[channel].pitchbend = @intCast((@as(u16, msb) << 7) | lsb);
                self.noteUpdate(chip, channel);
            },
            0xf0 => switch (command) {
                0xf0, 0xf7 => {
                    const len = self.readVlq();
                    self.pos = @min(self.music.len, self.pos + len);
                },
                0xf1 => _ = self.readByte(),
                0xf2 => {
                    _ = self.readByte();
                    _ = self.readByte();
                },
                0xf3 => _ = self.readByte(),
                0xfc => {
                    self.pos = 0;
                    return true;
                },
                0xff => {
                    const event = self.readByte() orelse 0;
                    const len = self.readVlq();
                    if (event == 0x2f) {
                        self.pos = 0;
                        return true;
                    }
                    self.pos = @min(self.music.len, self.pos + len);
                },
                else => {},
            },
            else => {},
        }

        if (self.pos >= self.music.len) {
            self.pos = 0;
            return true;
        }
        return false;
    }

    const max_events_per_step: u32 = 256;

    pub fn step(self: *CmfSource, chip: fmt.Chip) fmt.StepResult {
        if (self.delay_remaining == 0) {
            var done = false;
            var events: u32 = 0;
            while (self.delay_remaining == 0) {
                done = self.processEvent(chip) or done;
                events += 1;
                if (self.pos == 0 and done) {
                    // End of track: next delay is the leading VLQ after rewind.
                    self.resetLoopState(chip);
                    self.prev_command = 0;
                    self.delay_remaining = self.readVlq();
                    return .{ .frames = 0, .done = true };
                }
                self.delay_remaining = self.readVlq();
                if (self.pos == 0 and self.delay_remaining == 0 and done) {
                    self.resetLoopState(chip);
                    return .{ .frames = 0, .done = true };
                }
                if (self.delay_remaining == 0 and events >= max_events_per_step) {
                    return .{ .frames = 0 };
                }
            }
        }

        const wait = self.delay_remaining;
        self.delay_remaining = 0;
        const rate = @max(@as(u32, 1), self.ticks_per_second);
        return .{ .frames = fmt.rescale(wait, rate, self.sample_rate, &self.frac) };
    }

    pub fn info(self: *CmfSource) fmt.TrackInfo {
        return .{
            .title = self.title,
            .title_embedded = self.title_embedded,
            .artist = self.artist,
            .format_name = "CMF",
            .opl3 = false,
            .system = "OPL2",
            .loop = true,
            .visualizer = visualizer_name,
        };
    }

    pub fn deinit(self: *CmfSource, gpa: std.mem.Allocator) void {
        gpa.free(self.music);
        gpa.free(self.instruments);
        if (self.title) |t| gpa.free(t);
        if (self.artist) |a| gpa.free(a);
        gpa.destroy(self);
    }
};

fn readHeader(data: []const u8) error{InvalidCmf}!?Header {
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], magic)) return null;
    if (data.len < 6) return error.InvalidCmf;
    const version = fmt.readU16Le(data, 4);
    if (version != 0x0100 and version != 0x0101) return null;
    if (data.len < 36) return error.InvalidCmf;

    var h = Header{
        .instrument_offset = fmt.readU16Le(data, 6),
        .music_offset = fmt.readU16Le(data, 8),
        .ticks_per_second = fmt.readU16Le(data, 12),
        .title_offset = fmt.readU16Le(data, 14),
        .composer_offset = fmt.readU16Le(data, 16),
        .num_instruments = 0,
    };
    if (h.ticks_per_second == 0) h.ticks_per_second = 96;

    if (version == 0x0100) {
        if (data.len < 37) return error.InvalidCmf;
        h.num_instruments = data[36];
    } else {
        if (data.len < 40) return error.InvalidCmf;
        h.num_instruments = fmt.readU16Le(data, 36);
    }

    if (h.instrument_offset > data.len or h.music_offset >= data.len) return error.InvalidCmf;
    if (h.title_offset >= h.instrument_offset) h.title_offset = 0;
    if (h.composer_offset >= h.instrument_offset) h.composer_offset = 0;
    return h;
}

fn readCString(data: []const u8, offset: u16) []const u8 {
    if (offset == 0 or offset >= data.len) return "";
    return std.mem.sliceTo(data[offset..], 0);
}

fn readCappedVlq(music: []const u8, pos: *usize) u32 {
    var len: u32 = 0;
    var c: u32 = 0;
    while (pos.* < music.len and c < 4) : (c += 1) {
        const b = music[pos.*];
        pos.* += 1;
        len = (len << 7) | (b & 0x7f);
        if (b & 0x80 == 0) break;
    }
    return len;
}

fn detectMidiDrums(music: []const u8) bool {
    var pos: usize = 0;
    var prev: u8 = 0;
    var ch9_note = false;
    var ch9_prog = false;
    var ch9_non_drum = false;

    // Skip leading VLQ delay.
    while (pos < music.len and music[pos] & 0x80 != 0) pos += 1;
    if (pos < music.len) pos += 1;

    while (pos < music.len) {
        var cmd = music[pos];
        pos += 1;
        if (cmd & 0x80 == 0) {
            pos -= 1;
            cmd = prev;
        } else prev = cmd;
        const ch: u8 = cmd & 0x0f;
        switch (cmd & 0xf0) {
            0x80, 0xa0, 0xb0, 0xe0 => pos += 2,
            0x90 => {
                if (pos + 1 >= music.len) break;
                const note = music[pos];
                const vel = music[pos + 1];
                pos += 2;
                if (ch == 9 and vel > 0) {
                    ch9_note = true;
                    if (note < 35 or note > 81) ch9_non_drum = true;
                }
            },
            0xc0 => {
                if (ch == 9) ch9_prog = true;
                pos += 1;
            },
            0xd0 => pos += 1,
            0xf0 => {
                if (cmd == 0xf0 or cmd == 0xf7) {
                    const len = readCappedVlq(music, &pos);
                    pos += len;
                } else if (cmd == 0xff) {
                    if (pos >= music.len) break;
                    const evt = music[pos];
                    pos += 1;
                    const len = readCappedVlq(music, &pos);
                    if (evt == 0x2f) break;
                    pos += len;
                } else if (cmd == 0xfc) break;
            },
            else => {},
        }
        if (pos >= music.len) break;
        while (pos < music.len and music[pos] & 0x80 != 0) pos += 1;
        if (pos < music.len) pos += 1;
    }
    return ch9_note and !ch9_prog and !ch9_non_drum;
}

fn load(
    gpa: std.mem.Allocator,
    data: []const u8,
    ctx: fmt.LoadContext,
) anyerror!?fmt.MusicSource {
    const header = (try readHeader(data)) orelse return null;
    const music_slice = data[header.music_offset..];

    const n_inst = @min(header.num_instruments, max_instruments);
    const instruments = try gpa.alloc(Instrument, if (n_inst == 0) 16 else n_inst);
    errdefer gpa.free(instruments);

    if (n_inst == 0) {
        for (instruments, 0..) |*ins, i| ins.* = Instrument.fromPayload(&default_patches[i]);
    } else {
        const need = @as(usize, header.instrument_offset) + @as(usize, n_inst) * instrument_bytes;
        if (need > data.len) return error.InvalidCmf;
        for (instruments, 0..) |*ins, i| {
            const off = header.instrument_offset + i * instrument_bytes;
            var payload: [payload_bytes]u8 = undefined;
            @memcpy(&payload, data[off .. off + payload_bytes]);
            ins.* = Instrument.fromPayload(&payload);
        }
    }

    const music = try gpa.dupe(u8, music_slice);
    errdefer gpa.free(music);

    const title_s = readCString(data, header.title_offset);
    const artist_s = readCString(data, header.composer_offset);
    const title = if (title_s.len != 0) try gpa.dupe(u8, title_s) else null;
    errdefer if (title) |t| gpa.free(t);
    const artist = if (artist_s.len != 0) try gpa.dupe(u8, artist_s) else null;
    errdefer if (artist) |a| gpa.free(a);

    const src = try gpa.create(CmfSource);
    errdefer gpa.destroy(src);
    src.* = .{
        .sample_rate = ctx.sample_rate,
        .ticks_per_second = header.ticks_per_second,
        .music = music,
        .instruments = instruments,
        .inst_count = if (n_inst == 0) 16 else n_inst,
        .title = title,
        .title_embedded = title != null,
        .artist = artist,
        .midi_drums = detectMidiDrums(music),
    };

    const chip = ctx.chip;
    src.write(chip, Reg.waveform_select, 0x20);
    src.write(chip, 0x05, 0x00);
    src.write(chip, Reg.csw, 0x00);
    for (0..opl_channels) |i| src.writeInitInstrument(chip, @intCast(i));
    src.write(chip, Reg.rhythm, 0xc0);
    if (src.midi_drums) src.rhythmMode(chip, true);
    src.delay_remaining = src.readVlq();
    chip.flush();

    return fmt.MusicSource.init(src);
}

pub const format = fmt.Format{
    .name = "CMF",
    .extensions = &.{".cmf"},
    .visualizer = visualizer_name,
    .load = load,
};

// --- tests -------------------------------------------------------------------

fn makeMinimalCmf(buf: []u8, music: []const u8) []const u8 {
    // v1.1 header, 1 instrument, music at end.
    const inst_off: u16 = 40;
    const mus_off: u16 = inst_off + instrument_bytes;
    @memset(buf, 0);
    @memcpy(buf[0..4], magic);
    buf[4] = 0x01;
    buf[5] = 0x01;
    std.mem.writeInt(u16, buf[6..8], inst_off, .little);
    std.mem.writeInt(u16, buf[8..10], mus_off, .little);
    std.mem.writeInt(u16, buf[10..12], 24, .little); // tpqn
    std.mem.writeInt(u16, buf[12..14], 96, .little); // tps
    std.mem.writeInt(u16, buf[36..38], 1, .little); // 1 instrument
    // One blank instrument at inst_off.
    @memcpy(buf[inst_off .. inst_off + payload_bytes], &init_instrument);
    @memcpy(buf[mus_off .. mus_off + music.len], music);
    return buf[0 .. mus_off + music.len];
}

test "cmf loads and ends on meta end-of-track" {
    const gpa = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // delay 0, note-on ch0 note 60 vel 64, delay 10, note-off, delay 0, meta EOT
    const music = [_]u8{
        0x00, // delay
        0x90, 60, 64, // note on
        0x0a, // delay 10
        0x80, 60, 64, // note off
        0x00,
        0xff, 0x2f, 0x00, // end of track
    };
    const data = makeMinimalCmf(&buf, &music);
    var chip = opal.Opal.init(44100);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = chip_adapter.fromOpal(&chip),
        .ext = ".cmf",
        .name = "t.cmf",
    })).?;
    defer src.deinit(gpa);

    try std.testing.expectEqualStrings("CMF", src.info().format_name);
    const drained = fmt.testDrain(src, chip_adapter.fromOpal(&chip), 64);
    try std.testing.expect(drained.done);
    try std.testing.expect(drained.frames > 0);
}

test "cmf rejects non-ctmf" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try load(gpa, "XXXX" ++ [_]u8{0} ** 40, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".cmf",
    }) == null);
}

test "cmf title from tag offset" {
    const gpa = std.testing.allocator;
    // Build by hand with title between header and instruments.
    var buf: [160]u8 = @splat(0);
    @memcpy(buf[0..4], magic);
    buf[4] = 0x01;
    buf[5] = 0x01;
    const title_off: u16 = 40;
    const inst_off: u16 = 56;
    const mus_off: u16 = inst_off + instrument_bytes;
    std.mem.writeInt(u16, buf[6..8], inst_off, .little);
    std.mem.writeInt(u16, buf[8..10], mus_off, .little);
    std.mem.writeInt(u16, buf[12..14], 96, .little);
    std.mem.writeInt(u16, buf[14..16], title_off, .little);
    std.mem.writeInt(u16, buf[36..38], 1, .little);
    @memcpy(buf[title_off .. title_off + 4], "Song");
    buf[title_off + 4] = 0;
    @memcpy(buf[inst_off .. inst_off + payload_bytes], &init_instrument);
    const music = [_]u8{ 0x00, 0xff, 0x2f, 0x00 };
    @memcpy(buf[mus_off .. mus_off + music.len], &music);

    const src = (try load(gpa, buf[0 .. mus_off + music.len], .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".cmf",
    })).?;
    defer src.deinit(gpa);
    try std.testing.expectEqualStrings("Song", src.info().title.?);
    try std.testing.expect(src.info().title_embedded);
}

test "cmf truncated header is invalid" {
    const gpa = std.testing.allocator;
    const data = magic ++ [_]u8{ 0x00, 0x01, 40, 0, 56, 0 };
    try std.testing.expectError(error.InvalidCmf, load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".cmf",
    }));
}

test "cmf step yields before a long zero-delay event chain" {
    const gpa = std.testing.allocator;
    const n: usize = CmfSource.max_events_per_step + 8;
    var music = try gpa.alloc(u8, n * 4 + 4);
    defer gpa.free(music);
    var p: usize = 0;
    var e: usize = 0;
    while (e < n) : (e += 1) {
        music[p] = 0x00;
        music[p + 1] = 0x80;
        music[p + 2] = 60;
        music[p + 3] = 0;
        p += 4;
    }
    music[p] = 0x01;
    music[p + 1] = 0xff;
    music[p + 2] = 0x2f;
    music[p + 3] = 0x00;
    p += 4;

    var file_buf: [2048]u8 = undefined;
    const data = makeMinimalCmf(&file_buf, music[0..p]);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".cmf",
    })).?;
    defer src.deinit(gpa);

    const first = src.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u64, 0), first.frames);
    try std.testing.expect(!first.done);

    var saw_wait = false;
    var steps: u32 = 0;
    while (steps < 8) : (steps += 1) {
        const r = src.step(fmt.noop_chip);
        if (r.frames > 0) {
            saw_wait = true;
            break;
        }
        try std.testing.expect(!r.done);
    }
    try std.testing.expect(saw_wait);
}

fn effectiveFreq(r: anytype) u32 {
    return @as(u32, r.fnum) << @intCast(r.block);
}

test "cmf pitch bend and transpose shift frequency fractionally" {
    var src = CmfSource{
        .sample_rate = 44100,
        .ticks_per_second = 96,
        .music = &.{},
        .instruments = &.{},
        .inst_count = 1,
        .title = null,
        .title_embedded = false,
        .artist = null,
    };
    const base = src.noteFreq(0, 60);

    // Half deflection of the one-semitone bend range lands between semitones.
    src.midi[0].pitchbend = 8192 + 4096;
    const bent = src.noteFreq(0, 60);
    try std.testing.expectEqual(base.block, bent.block);
    try std.testing.expect(bent.fnum > base.fnum);
    try std.testing.expect(bent.fnum < fnum_tbl[64]);

    // Transpose full deflection is just under half a semitone.
    src.midi[0].pitchbend = 8192;
    src.midi[0].transpose = 127;
    const up = src.noteFreq(0, 60);
    try std.testing.expect(effectiveFreq(up) > effectiveFreq(base));
    try std.testing.expect(effectiveFreq(up) <= effectiveFreq(bent));
    src.midi[0].transpose = -127;
    const down = src.noteFreq(0, 60);
    try std.testing.expect(effectiveFreq(down) < effectiveFreq(base));

    // A full down-bend at the bottom of the range clamps to block 0.
    src.midi[0].transpose = 0;
    src.midi[0].pitchbend = 0;
    const low = src.noteFreq(0, 0);
    try std.testing.expectEqual(@as(u8, 0), low.block);
    try std.testing.expectEqual(fnum_tbl[0], low.fnum);
}

test "cmf loop rewind silences voices and resets channel state" {
    const gpa = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // Note on with no matching note off before end of track.
    const music = [_]u8{
        0x00, 0x90, 60,   64,
        0x0a, 0xff, 0x2f, 0x00,
    };
    const data = makeMinimalCmf(&buf, &music);
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = fmt.noop_chip,
        .ext = ".cmf",
    })).?;
    defer src.deinit(gpa);

    var steps: u32 = 0;
    while (steps < 16) : (steps += 1) {
        if (src.step(fmt.noop_chip).done) break;
    }
    try std.testing.expect(steps < 16);

    const state: *CmfSource = @ptrCast(@alignCast(src.ptr));
    for (0..opl_channels) |i| {
        try std.testing.expect(state.regs[Reg.key_block + i] & Reg.key_on == 0);
    }
    try std.testing.expectEqual(@as(u8, 255), state.note_playing[0]);
}

test "cmf gm channel-9 bass drum uses the fallback percussion patch" {
    const Rec = struct {
        regs: [256]u8 = @splat(0),
        fn write(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg < 256) self.regs[reg] = val;
        }
        fn flush(_: *anyopaque) void {}
        fn chip(self: *@This()) fmt.Chip {
            return .{
                .ptr = self,
                .vtable = &.{ .writeReg = write, .flush = flush },
            };
        }
    };

    const gpa = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const music = [_]u8{
        0x00, 0x99, 36,   64,
        0x0a, 0xff, 0x2f, 0x00,
    };
    const data = makeMinimalCmf(&buf, &music);
    var rec = Rec{};
    const src = (try load(gpa, data, .{
        .sample_rate = 44100,
        .chip = rec.chip(),
        .ext = ".cmf",
        .name = "gm-drums.cmf",
    })).?;
    defer src.deinit(gpa);

    const state: *CmfSource = @ptrCast(@alignCast(src.ptr));
    try std.testing.expect(state.midi_drums);
    _ = src.step(rec.chip());
    try std.testing.expectEqual(@as(u8, 0x00), rec.regs[0x30]);
    try std.testing.expectEqual(@as(u8, 0xf8), rec.regs[0x70]);
}
