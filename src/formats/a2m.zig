//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const fmt = @import("../format.zig");
const cp437 = @import("../cp437.zig");
const view = @import("../view.zig");

pub const format_name = "A2M";
pub const extensions = &.{ ".a2m", ".a2t" };
pub const visualizer_name = "tracker";
pub const view_caps = view.ViewCaps{ .pattern = true, .order = true, .instruments = true };

pub fn labelForPath(path: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(fmt.extensionOf(path), ".a2t")) "A2T" else format_name;
}

const max_channels = 20;
const max_instruments = 255;
const order_count = 128;
const macro_bytes = 3831;
const pitch_macro_bytes = 521;
const modern_pattern_bytes = max_channels * 256 * 6;
const columns = [_]view.ColumnId{ .note, .instrument, .effect, .effect2 };
const frequencies = [_]u16{ 343, 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647 };
const voice_order = [_]u16{ 3, 0, 4, 1, 5, 2, 6, 7, 8, 0x103, 0x100, 0x104, 0x101, 0x105, 0x102, 0x106, 0x107, 0x108 };
const operator_offsets = [_]u8{ 0, 1, 2, 8, 9, 10, 16, 17, 18 };

const Text = struct {
    bytes: [126]u8 = undefined,
    len: u8 = 0,

    fn parse(data: []const u8) Text {
        var text: Text = .{};
        if (data.len == 0) return text;
        const count = @min(@as(usize, data[0]), data.len - 1);
        text.len = @intCast(cp437.decode(&text.bytes, data[1..][0..count]).len);
        return text;
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Patch = struct {
    registers: [11]u8 = @splat(0),
    panning: u8 = 0,
    fine_tune: i8 = 0,
    percussion: u8 = 0,

    fn parse(data: []const u8) Patch {
        return .{
            .registers = data[0..11].*,
            .panning = if (data[11] <= 2) data[11] else 0,
            .fine_tune = @bitCast(data[12]),
            .percussion = if (data.len == 14) data[13] else 0,
        };
    }

    fn operator(self: Patch, index: usize) view.OperatorParams {
        const r = self.registers;
        return fmt.operatorParams(r[index], r[index + 2], r[index + 4], r[index + 6], r[index + 8]);
    }

    fn info(self: Patch) view.OplPatch {
        return .{
            .ops = .{ self.operator(0), self.operator(1), .{}, .{} },
            .feedback = @truncate(self.registers[10] >> 1),
            .additive = self.registers[10] & 1 != 0,
            .fine_tune = self.fine_tune,
            .panning = self.panning,
            .perc_voice = self.percussion,
        };
    }
};

const Event = struct {
    note: u8 = 0,
    instrument: u8 = 0,
    effects: [2]view.Effect = .{ .{}, .{} },
};

const EffectPhase = enum { settings, fine, tick };

const EffectCode = enum(u8) {
    arpeggio = 0,
    slide_up,
    slide_down,
    portamento,
    vibrato,
    portamento_volume,
    vibrato_volume,
    fine_slide_up,
    fine_slide_down,
    modulator_volume,
    volume_slide,
    jump,
    volume,
    pattern_break,
    tempo,
    speed,
    portamento_fine_volume,
    vibrato_fine_volume,
    carrier_volume,
    waveform,
    fine_volume,
    retrigger,
    tremolo,
    tremor,
    arpeggio_volume,
    arpeggio_fine_volume,
    multi_retrigger,
    slide_up_volume,
    slide_down_volume,
    fine_slide_up_volume,
    fine_slide_down_volume,
    slide_up_fine_volume,
    slide_down_fine_volume,
    fine_slide_up_fine_volume,
    fine_slide_down_fine_volume,
    extended,
    extended2,
    global_volume,
    arpeggio_table,
    vibrato_table,
    force_volume,
    extended3,
    extra_fine_arpeggio,
    extra_fine_vibrato,
    extra_fine_tremolo,
    waveform_table,
    global_slide_up,
    global_slide_down,
    _,
};

const RunningEffect = struct {
    code: ?EffectCode = null,
    param: u8 = 0,

    fn active(self: RunningEffect) bool {
        return self.code != null or self.param != 0;
    }

    fn within(self: RunningEffect, codes: []const EffectCode) bool {
        const code = self.code orelse return false;
        return std.mem.findScalar(EffectCode, codes, code) != null;
    }
};

const Song = struct {
    metadata: []u8,
    patterns: []u8,
    version: u8,
    tiny: bool,
    instrument_count: u8,
    pattern_count: u8,
    channels: u8,
    rows: u16,
    tempo: u8,
    tempo_fine_tune: i16 = 0,
    rows_per_beat: u8 = 4,
    speed: u8,
    flags: u8,
    macro_speed: u16,
    four_op: u6,
    title: Text,
    artist: Text,
    instrument_names: [max_instruments]Text,
    pattern_names: [128]Text,

    fn modern(self: *const Song) bool {
        return self.version >= 9;
    }

    fn orders(self: *const Song) *const [order_count]u8 {
        const offset: usize = if (self.modern()) 0x11281d else 0x2d42;
        return self.metadata[offset..][0..order_count];
    }

    fn instrument(self: *const Song, index: u8) Patch {
        if (index == 0 or index > self.instrument_count) return .{};
        const base: usize = if (self.modern()) 0x2b2b else 0x2090;
        const stride: usize = if (self.modern()) 14 else 13;
        return Patch.parse(self.metadata[base + (index - @as(usize, 1)) * stride ..][0..stride]);
    }

    fn macro(self: *const Song, index: u8) []const u8 {
        if (!self.modern() or index == 0) return &.{};
        return self.metadata[0x391d + (index - @as(usize, 1)) * macro_bytes ..][0..macro_bytes];
    }

    fn pitchMacro(self: *const Song, index: u8, kind: view.MacroKind) []const u8 {
        if (!self.modern() or index == 0) return &.{};
        const data = self.metadata[0xf2126 + (index - @as(usize, 1)) * pitch_macro_bytes ..][0..pitch_macro_bytes];
        return switch (kind) {
            .arpeggio => data[0..260],
            .vibrato => data[260..],
            .fmreg => &.{},
        };
    }

    fn disabledColumns(self: *const Song, index: u8) u32 {
        if (self.version < 11 or index == 0) return 0;
        const start = 0x113e3a + (index - @as(usize, 1)) * 28;
        var mask: u32 = 0;
        for (self.metadata[start..][0..28], 0..) |disabled, bit| {
            if (disabled != 0) mask |= @as(u32, 1) << @intCast(bit);
        }
        return mask;
    }

    fn locks(self: *const Song, channel: usize) u8 {
        if (self.version >= 10) return self.metadata[0x1128a6 + channel];
        return (if (self.flags & 2 != 0) @as(u8, 0x10) else 0) | (if (self.flags & 4 != 0) @as(u8, 0x20) else 0);
    }

    fn patternSpan(self: *const Song) u16 {
        var span: u16 = self.pattern_count;
        for (self.orders()) |entry| {
            if (entry < 128) span = @max(span, @as(u16, entry) + 1);
        }
        return span;
    }

    fn event(self: *const Song, pattern: u8, row: u16, channel: usize) Event {
        if (pattern >= self.pattern_count or row >= self.rows or channel >= self.channels) return .{};
        const stride: usize = if (self.modern()) 6 else 4;
        const offset = if (self.version < 5)
            ((@as(usize, pattern) * 64 + row) * 9 + channel) * stride
        else
            ((@as(usize, pattern) * (if (self.modern()) @as(usize, 20) else 18) + channel) * (if (self.modern()) @as(usize, 256) else 64) + row) * stride;
        const data = self.patterns[offset..][0..stride];
        var result: Event = .{
            .note = data[0],
            .instrument = data[1],
            .effects = .{ .{ .cmd = data[2], .param = data[3] }, .{} },
        };
        if (self.modern()) result.effects[1] = .{ .cmd = data[4], .param = data[5] };
        return result;
    }

    fn deinit(self: *Song, gpa: std.mem.Allocator) void {
        gpa.free(self.metadata);
        gpa.free(self.patterns);
    }
};

const CompressionError = error{InvalidA2mCompression};

fn unpack(version: u8, source: []const u8, dest: []u8) !usize {
    return switch (version) {
        1, 5 => sixpack(source, dest),
        2, 6 => lzw(source, dest),
        3, 7 => lzss(source, dest),
        4, 8 => blk: {
            if (source.len > dest.len) return error.InvalidA2mCompression;
            @memcpy(dest[0..source.len], source);
            break :blk source.len;
        },
        9...11 => aplib(source, dest),
        12...14 => lzh(source, dest),
        else => error.UnsupportedA2mVersion,
    };
}

const Input = struct {
    bytes: []const u8,
    pos: usize = 0,
    tag: u8 = 0,
    remaining: u4 = 0,

    fn byte(self: *Input) CompressionError!u8 {
        if (self.pos == self.bytes.len) return error.InvalidA2mCompression;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn bit(self: *Input) CompressionError!u1 {
        if (self.remaining == 0) {
            self.tag = try self.byte();
            self.remaining = 8;
        }
        const value: u1 = @truncate(self.tag >> 7);
        self.tag <<= 1;
        self.remaining -= 1;
        return value;
    }

    fn bits(self: *Input, count: u5) CompressionError!u16 {
        var value: u16 = 0;
        for (0..count) |_| value = (value << 1) | try self.bit();
        return value;
    }

    fn gamma(self: *Input) CompressionError!usize {
        var value: usize = 1;
        for (0..24) |_| {
            value = (value << 1) | try self.bit();
            if (try self.bit() == 0) return value;
        }
        return error.InvalidA2mCompression;
    }
};

fn lzss(source: []const u8, dest: []u8) CompressionError!usize {
    var input: Input = .{ .bytes = source };
    var output: Output = .{ .bytes = dest };
    var history: [4096]u8 = @splat(0);
    var head: u12 = 4096 - 18;
    while (input.pos < source.len) {
        var flags = try input.byte();
        for (0..8) |_| {
            if (input.pos == source.len) return output.len;
            if (flags & 1 != 0) {
                const value = try input.byte();
                try output.byte(value);
                history[head] = value;
                head +%= 1;
            } else {
                const low = try input.byte();
                const high = try input.byte();
                var offset: u12 = @as(u12, high & 0xf0) << 4 | low;
                for (0..@as(usize, high & 15) + 3) |_| {
                    const value = history[offset];
                    try output.byte(value);
                    history[head] = value;
                    head +%= 1;
                    offset +%= 1;
                }
            }
            flags >>= 1;
        }
    }
    return output.len;
}

fn lzw(source: []const u8, dest: []u8) CompressionError!usize {
    var output: Output = .{ .bytes = dest };
    var prefixes: [8192]u16 = undefined;
    var suffixes: [8192]u8 = undefined;
    var stack: [8192]u8 = undefined;
    var bit_position: usize = 0;
    var width: u4 = 9;
    var next: u16 = 258;
    var previous: ?u16 = null;
    var first: u8 = 0;
    while (true) {
        if (width > source.len * 8 - bit_position) return error.InvalidA2mCompression;
        var code: u16 = 0;
        for (0..width) |bit| {
            code |= @as(u16, (source[bit_position / 8] >> @as(u3, @intCast(bit_position % 8))) & 1) << @intCast(bit);
            bit_position += 1;
        }
        if (code == 257) return output.len;
        if (code == 256) {
            width = 9;
            next = 258;
            previous = null;
            continue;
        }
        if (code > next or (previous == null and code >= 256)) return error.InvalidA2mCompression;
        const current = code;
        var length: usize = 0;
        if (code == next) {
            stack[length] = first;
            length += 1;
            code = previous orelse return error.InvalidA2mCompression;
        }
        while (code >= 258) {
            if (code >= next or code >= prefixes.len or length == stack.len) return error.InvalidA2mCompression;
            stack[length] = suffixes[code];
            length += 1;
            code = prefixes[code];
        }
        if (code >= 256) return error.InvalidA2mCompression;
        first = @intCast(code);
        try output.byte(first);
        while (length > 0) {
            length -= 1;
            try output.byte(stack[length]);
        }
        if (previous) |prefix| {
            if (next >= prefixes.len) return error.InvalidA2mCompression;
            prefixes[next] = prefix;
            suffixes[next] = first;
            next += 1;
            if (next == @as(u16, 1) << width and width < 13) width += 1;
        }
        previous = current;
    }
}

const Output = struct {
    bytes: []u8,
    len: usize = 0,

    fn byte(self: *Output, value: u8) CompressionError!void {
        if (self.len == self.bytes.len) return error.InvalidA2mCompression;
        self.bytes[self.len] = value;
        self.len += 1;
    }

    fn copy(self: *Output, distance: usize, count: usize) CompressionError!void {
        if (distance == 0 or distance > self.len or count > self.bytes.len - self.len)
            return error.InvalidA2mCompression;
        for (0..count) |_| {
            self.bytes[self.len] = self.bytes[self.len - distance];
            self.len += 1;
        }
    }
};

fn aplib(source: []const u8, dest: []u8) CompressionError!usize {
    var input: Input = .{ .bytes = source };
    var output: Output = .{ .bytes = dest };
    try output.byte(try input.byte());
    var last_distance: usize = 0;
    while (true) {
        if (try input.bit() == 0) {
            try output.byte(try input.byte());
        } else if (try input.bit() == 0) {
            const high = try input.gamma();
            if (high == 2) {
                try output.copy(last_distance, try input.gamma());
            } else {
                const distance = ((high - 3) << 8) | try input.byte();
                var length = try input.gamma();
                if (distance < 128) length += 2;
                if (distance >= 1280) length += 1;
                if (distance >= 32000) length += 1;
                try output.copy(distance, length);
                last_distance = distance;
            }
        } else if (try input.bit() == 0) {
            const pair = try input.byte();
            const distance = pair >> 1;
            if (distance == 0) return output.len;
            try output.copy(distance, 2 + @as(usize, pair & 1));
            last_distance = distance;
        } else {
            const distance = try input.bits(4);
            if (distance == 0) try output.byte(0) else try output.copy(distance, 1);
        }
    }
}

const Huffman = struct {
    counts: [17]u16 = @splat(0),
    first: [17]u32 = @splat(0),
    offsets: [17]u16 = @splat(0),
    symbols: [511]u16 = undefined,
    single: ?u16 = null,

    fn init(lengths: []const u8) CompressionError!Huffman {
        var tree: Huffman = .{};
        for (lengths) |length| {
            if (length > 16) return error.InvalidA2mCompression;
            if (length != 0) tree.counts[length] += 1;
        }
        var slots: i32 = 1;
        var offset: u16 = 0;
        for (1..17) |length| {
            slots = slots * 2 - tree.counts[length];
            if (slots < 0) return error.InvalidA2mCompression;
            tree.first[length] = (tree.first[length - 1] + tree.counts[length - 1]) * 2;
            tree.offsets[length] = offset;
            for (lengths, 0..) |n, symbol| {
                if (n == length) {
                    tree.symbols[offset] = @intCast(symbol);
                    offset += 1;
                }
            }
        }
        if (slots != 0) return error.InvalidA2mCompression;
        return tree;
    }

    fn read(self: *const Huffman, input: *Input) CompressionError!u16 {
        if (self.single) |value| return value;
        var code: u32 = 0;
        for (1..17) |length| {
            code = (code << 1) | try input.bit();
            const first = self.first[length];
            if (code >= first and code - first < self.counts[length])
                return self.symbols[self.offsets[length] + code - first];
        }
        return error.InvalidA2mCompression;
    }
};

fn lengthTree(input: *Input, count: usize, width: u5, skip: ?usize) CompressionError!Huffman {
    const used = try input.bits(width);
    if (used > count) return error.InvalidA2mCompression;
    if (used == 0) {
        const value = try input.bits(width);
        if (value >= count) return error.InvalidA2mCompression;
        return .{ .single = value };
    }
    var lengths: [19]u8 = @splat(0);
    var index: usize = 0;
    while (index < used) {
        var length: u16 = try input.bits(3);
        if (length == 7) {
            while (try input.bit() != 0) {
                length += 1;
                if (length > 16) return error.InvalidA2mCompression;
            }
        }
        lengths[index] = @intCast(length);
        index += 1;
        if (skip != null and index == skip.?) {
            index += try input.bits(2);
            if (index > used) return error.InvalidA2mCompression;
        }
    }
    return Huffman.init(lengths[0..count]);
}

fn literalTree(input: *Input, lengths_tree: *const Huffman) CompressionError!Huffman {
    const used = try input.bits(16);
    if (used > 511) return error.InvalidA2mCompression;
    if (used == 0) {
        const value = try input.bits(16);
        if (value >= 511) return error.InvalidA2mCompression;
        return .{ .single = value };
    }
    var lengths: [511]u8 = @splat(0);
    var index: usize = 0;
    while (index < used) {
        const symbol = try lengths_tree.read(input);
        if (symbol <= 2) {
            const run: usize = switch (symbol) {
                0 => 1,
                1 => 3 + @as(usize, try input.bits(4)),
                2 => 20 + @as(usize, try input.bits(16)),
                else => unreachable,
            };
            if (run > used - index) return error.InvalidA2mCompression;
            index += run;
        } else {
            lengths[index] = @intCast(symbol - 2);
            index += 1;
        }
    }
    return Huffman.init(&lengths);
}

fn lzh(source: []const u8, dest: []u8) CompressionError!usize {
    if (source.len < 5 or source[0] != 0) return error.InvalidA2mCompression;
    const size = std.mem.readInt(u32, source[1..5], .little);
    if (size > dest.len) return error.InvalidA2mCompression;
    var input: Input = .{ .bytes = source[5..] };
    var output: Output = .{ .bytes = dest[0..size] };
    var remaining: u16 = 0;
    var literals: Huffman = undefined;
    var distances: Huffman = undefined;
    while (output.len < size) {
        if (remaining == 0) {
            remaining = try input.bits(16);
            if (remaining == 0) return error.InvalidA2mCompression;
            const lengths = try lengthTree(&input, 19, 15, 3);
            literals = try literalTree(&input, &lengths);
            distances = try lengthTree(&input, 15, 14, null);
        }
        remaining -= 1;
        const symbol = try literals.read(&input);
        if (symbol < 256) {
            try output.byte(@intCast(symbol));
        } else {
            const code = try distances.read(&input);
            const offset: usize = if (code == 0) 0 else (@as(usize, 1) << @intCast(code - 1)) + try input.bits(@intCast(code - 1));
            try output.copy(offset + 1, symbol - 254);
        }
    }
    return output.len;
}

const SixpackInput = struct {
    bytes: []const u8,
    pos: usize = 0,
    word: u16 = 0,
    remaining: u5 = 0,

    fn bit(self: *SixpackInput) CompressionError!u1 {
        if (self.remaining == 0) {
            if (self.bytes.len - self.pos < 2) return error.InvalidA2mCompression;
            self.word = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
            self.pos += 2;
            self.remaining = 16;
        }
        const value: u1 = @truncate(self.word >> 15);
        self.word <<= 1;
        self.remaining -= 1;
        return value;
    }
};

const SixpackTree = struct {
    const symbols = 257 + 6 * 253;
    const max_weight = 2000;
    const Node = struct {
        children: [2]u16 = .{ 0, 0 },
        parent: u16 = 0,
        weight: u16 = 1,
    };

    nodes: [symbols * 2]Node = @splat(.{}),

    fn init() SixpackTree {
        var self: SixpackTree = .{};
        for (1..symbols) |i| {
            self.nodes[i].children = .{ @intCast(i * 2), @intCast(i * 2 + 1) };
            self.nodes[i * 2].parent = @intCast(i);
            self.nodes[i * 2 + 1].parent = @intCast(i);
        }
        return self;
    }

    fn repair(self: *SixpackTree, start: u16) void {
        var node = start;
        while (node != 0) : (node = self.nodes[node].parent) {
            const children = self.nodes[node].children;
            self.nodes[node].weight = self.nodes[children[0]].weight +% self.nodes[children[1]].weight;
        }
        if (self.nodes[1].weight == max_weight) {
            for (self.nodes[1..]) |*entry| entry.weight /= 2;
        }
    }

    fn update(self: *SixpackTree, leaf: u16) void {
        self.nodes[leaf].weight +%= 1;
        if (self.nodes[leaf].parent == 1) return;
        self.repair(self.nodes[leaf].parent);
        var node = leaf;
        while (self.nodes[node].parent > 1) {
            const parent = self.nodes[node].parent;
            const grandparent = self.nodes[parent].parent;
            const uncle_side: usize = @intFromBool(self.nodes[grandparent].children[0] == parent);
            const uncle = self.nodes[grandparent].children[uncle_side];
            if (self.nodes[node].weight > self.nodes[uncle].weight) {
                const side: usize = @intFromBool(self.nodes[parent].children[1] == node);
                self.nodes[parent].children[side] = uncle;
                self.nodes[grandparent].children[uncle_side] = node;
                self.nodes[node].parent = grandparent;
                self.nodes[uncle].parent = parent;
                self.repair(parent);
            }
            node = parent;
        }
    }

    fn read(self: *SixpackTree, input: *SixpackInput) CompressionError!u16 {
        var node: u16 = 1;
        while (node < symbols) node = self.nodes[node].children[try input.bit()];
        self.update(node);
        return node - symbols;
    }
};

fn sixpack(source: []const u8, dest: []u8) CompressionError!usize {
    var input: SixpackInput = .{ .bytes = source };
    var output: Output = .{ .bytes = dest };
    var tree = SixpackTree.init();
    while (true) {
        const symbol = try tree.read(&input);
        if (symbol < 256) {
            try output.byte(@intCast(symbol));
        } else if (symbol == 256) {
            return output.len;
        } else {
            const group = (symbol - 257) / 253;
            const length = (symbol - 257) % 253 + 3;
            const width = group * 2 + 4;
            var distance: usize = length;
            for (0..group) |i| distance += @as(usize, 1) << @intCast(i * 2 + 4);
            for (0..width) |i| distance += @as(usize, try input.bit()) << @intCast(i);
            try output.copy(distance, length);
        }
    }
}

fn metadataSize(version: u8) usize {
    return switch (version) {
        1...4 => 0x2dc4,
        5...8 => 0x2dc5,
        9 => 0x1128a5,
        10 => 0x1128ba,
        11 => 0x115a1e,
        12, 13 => 0x115e9f,
        14 => 0x115ea2,
        else => 0,
    };
}

fn parse(gpa: std.mem.Allocator, data: []const u8) !?Song {
    const tiny = std.ascii.startsWithIgnoreCase(data, "_A2tiny_module_");
    if (!tiny and !std.ascii.startsWithIgnoreCase(data, "_A2module_")) return null;
    const version_offset: usize = if (tiny) 19 else 14;
    if (data.len < version_offset + 2) return error.InvalidA2m;
    const version = data[version_offset];
    if (version == 0 or version > 14) return error.UnsupportedA2mVersion;
    const count = data[version_offset + 1];
    const modern = version >= 9;
    const group_count: usize = if (version < 5) 4 else if (modern) 16 else 8;
    const group_patterns: usize = if (version < 5) 16 else 8;
    if (count == 0 or count > group_count * group_patterns) return error.InvalidA2m;
    const metadata_blocks: usize = if (!tiny) 1 else if (version >= 11) 5 else if (modern) 4 else 2;
    const lengths_offset: usize = if (!tiny) 16 else switch (version) {
        1...4 => 23,
        5...8 => 24,
        9 => 29,
        else => 50,
    };
    const length_size: usize = if (modern) 4 else 2;
    var offset = lengths_offset + (group_count + metadata_blocks) * length_size;
    if (offset > data.len) return error.InvalidA2m;
    var lengths: [21]usize = @splat(0);
    for (lengths[0 .. group_count + metadata_blocks], 0..) |*length, i| {
        const field = data[lengths_offset + i * length_size ..];
        length.* = if (modern) std.mem.readInt(u32, field[0..4], .little) else std.mem.readInt(u16, field[0..2], .little);
    }
    const groups = @divCeil(count, group_patterns);
    var payload_end = offset;
    for (lengths[0 .. metadata_blocks + groups]) |length| {
        if (length > data.len - payload_end) return error.InvalidA2m;
        payload_end += length;
    }
    const stored_crc = std.mem.readInt(u32, data[version_offset - 4 ..][0..4], .little);
    if (checksum(data[offset..payload_end], data[lengths_offset..offset], length_size) != stored_crc) return error.InvalidA2mChecksum;
    const metadata = try gpa.alloc(u8, metadataSize(version));
    errdefer gpa.free(metadata);
    var instrument_count: u8 = if (modern) 255 else 250;
    if (tiny) {
        @memset(metadata, 0);
        instrument_count = try tinyMetadata(version, data, lengths[0..metadata_blocks], &offset, metadata);
    } else if (try unpackBlock(version, data, &offset, lengths[0], metadata) != metadata.len) return error.InvalidA2m;
    const order_offset: usize = if (modern) 0x11281d else 0x2d42;
    const tempo = metadata[order_offset + 128];
    const speed = metadata[order_offset + 129];
    const flags = if (version >= 5) metadata[order_offset + 130] else 0;
    const channels: u8 = if (modern) metadata[order_offset + 133] else if (version < 5) 9 else 18;
    const rows: u16 = if (modern) std.mem.readInt(u16, metadata[order_offset + 131 ..][0..2], .little) else 64;
    if (tempo == 0 or speed == 0 or channels == 0 or channels > max_channels or rows == 0 or rows > 256) return error.InvalidA2m;
    const pattern_size: usize = if (modern) modern_pattern_bytes else if (version < 5) 64 * 9 * 4 else 18 * 64 * 4;
    const patterns = try gpa.alloc(u8, groups * group_patterns * pattern_size);
    errdefer gpa.free(patterns);
    @memset(patterns, 0);
    for (lengths[metadata_blocks .. metadata_blocks + groups], 0..) |length, i| {
        const dest = patterns[i * group_patterns * pattern_size ..][0 .. group_patterns * pattern_size];
        const size = try unpackBlock(version, data, &offset, length, dest);
        const used = @min(group_patterns, count - i * group_patterns);
        if (size < used * pattern_size or size % pattern_size != 0) return error.InvalidA2m;
    }
    var song: Song = .{
        .metadata = metadata,
        .patterns = patterns,
        .version = version,
        .tiny = tiny,
        .instrument_count = instrument_count,
        .pattern_count = count,
        .channels = channels,
        .rows = rows,
        .tempo = tempo,
        .tempo_fine_tune = if (version >= 14) std.mem.readInt(i16, metadata[0x115ea0..][0..2], .little) else 0,
        .rows_per_beat = if (version >= 14) @max(1, metadata[0x115e9f]) else 4,
        .speed = speed,
        .flags = flags,
        .macro_speed = if (modern) @max(1, std.mem.readInt(u16, metadata[order_offset + 134 ..][0..2], .little)) else 1,
        .four_op = if (version >= 10) @truncate(metadata[order_offset + 136]) else 0,
        .title = Text.parse(metadata[0..43]),
        .artist = Text.parse(metadata[43..86]),
        .instrument_names = @splat(.{}),
        .pattern_names = @splat(.{}),
    };
    const name_size: usize = if (modern) 43 else 33;
    for (song.instrument_names[0..song.instrument_count], 0..) |*name, i| name.* = Text.parse(metadata[86 + i * name_size ..][0..name_size]);
    if (version >= 11) {
        for (&song.pattern_names, 0..) |*name, i| name.* = Text.parse(metadata[0x1128ba + i * 43 ..][0..43]);
    }
    return song;
}

fn checksum(payload: []const u8, lengths: []const u8, length_size: usize) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(payload);
    var offset: usize = 0;
    while (offset < lengths.len) : (offset += length_size) crc.update(lengths[offset..][0..2]);
    return ~crc.final();
}

fn unpackBlock(version: u8, data: []const u8, offset: *usize, length: usize, dest: []u8) !usize {
    if (length > data.len - offset.*) return error.InvalidA2m;
    const block = data[offset.*..][0..length];
    offset.* += length;
    return if (length == 0) 0 else try unpack(version, block, dest);
}

fn tinyMetadata(version: u8, data: []const u8, lengths: []const usize, offset: *usize, metadata: []u8) !u8 {
    const modern = version >= 9;
    const order_offset: usize = if (modern) 0x11281d else 0x2d42;
    metadata[order_offset + 128] = data[21];
    metadata[order_offset + 129] = data[22];
    if (version >= 5) metadata[order_offset + 130] = data[23];
    if (modern) @memcpy(metadata[order_offset + 131 ..][0..5], data[24..29]);
    if (version >= 10) @memcpy(metadata[order_offset + 136 ..][0..21], data[29..50]);

    const prefix: usize = if (version >= 14) 0x484 else if (version >= 12) 0x481 else 0;
    const stride: usize = if (modern) 14 else 13;
    const limit: usize = if (modern) 255 else 250;
    var instruments: [0x484 + 255 * 14]u8 = undefined;
    const size = try unpackBlock(version, data, offset, lengths[0], instruments[0 .. prefix + limit * stride]);
    if (size < prefix or (size - prefix) % stride != 0) return error.InvalidA2m;
    const count: u8 = @intCast((size - prefix) / stride);
    const instrument_offset: usize = if (modern) 0x2b2b else 0x2090;
    @memcpy(metadata[instrument_offset..][0 .. size - prefix], instruments[prefix..size]);
    if (version >= 12) {
        const start: usize = if (version >= 14) 3 else 0;
        @memcpy(metadata[0x115a1e..][0..0x481], instruments[start..prefix]);
    }
    if (version >= 14) @memcpy(metadata[0x115e9f..][0..3], instruments[0..3]);

    const macro_blocks = [_]struct { offset: usize, stride: usize }{
        .{ .offset = 0x391d, .stride = macro_bytes },
        .{ .offset = 0xf2126, .stride = pitch_macro_bytes },
        .{ .offset = 0x113e3a, .stride = 28 },
    };
    for (lengths[1 .. lengths.len - 1], 0..) |length, i| {
        const block = macro_blocks[i];
        const decoded = try unpackBlock(version, data, offset, length, metadata[block.offset..][0 .. 255 * block.stride]);
        if (decoded % block.stride != 0) return error.InvalidA2m;
    }
    const orders = metadata[order_offset..][0..128];
    @memset(orders, 0x80);
    if (try unpackBlock(version, data, offset, lengths[lengths.len - 1], orders) == 0) return error.InvalidA2m;
    return count;
}

const MacroCursor = struct {
    position: u8 = 0,
    shown: u8 = 0,
    remaining: u16 = 0,
};

const Track = struct {
    instrument: u8 = 0,
    patch: Patch = .{},
    note: u8 = 0,
    keyed: bool = false,
    pitch: i32 = 0,
    target: i32 = 0,
    tone_speed: u8 = 0,
    volume: [2]u8 = .{ 0, 0 },
    peak: [2]u8 = .{ 63, 63 },
    panning: u8 = 0,
    volume_lock: bool = false,
    peak_lock: bool = false,
    pan_lock: bool = false,
    four_op_lock: bool = false,
    slide_type: u2 = 0,
    legacy_carrier_adsr: bool = false,
    effects: [2]view.Effect = .{ .{}, .{} },
    memory: [2][@typeInfo(EffectCode).@"enum".field_names.len]u8 = @splat(@splat(0)),
    vibrato_phase: [2]u16 = .{ 0, 0 },
    tremolo_phase: [2]u16 = .{ 0, 0 },
    arpeggio_phase: [2]u2 = .{ 0, 0 },
    vibrato_offset: [2]i32 = .{ 0, 0 },
    tremolo_attenuation: [2]i16 = .{ 0, 0 },
    arpeggio_shift: [2]u8 = .{ 0, 0 },
    running: [2]RunningEffect = @splat(.{}),
    last_effect: [2]RunningEffect = @splat(.{}),
    loop_row: u16 = 0,
    loop_counts: [256]u8 = @splat(0),
    retrigger_portamento: bool = false,
    retrigger_count: [2]u8 = .{ 0, 0 },
    macro_keyoff_loop: bool = false,
    released: bool = false,
    fm: MacroCursor = .{},
    arpeggio: MacroCursor = .{},
    vibrato: MacroCursor = .{},
    arpeggio_table: u8 = 0,
    vibrato_table: u8 = 0,
    vibrato_delay: u16 = 0,
    macro_note: ?u8 = null,
    macro_vibrato: i16 = 0,
    delayed: ?u8 = null,
    pitch_offset: i32 = 0,
    attenuation: i16 = 0,
    written_pitch: ?i32 = null,
    written_key: bool = false,
};

const Source = struct {
    song: Song,
    sample_rate: u32,
    tracks: [max_channels]Track = @splat(.{}),
    order: u8 = 0,
    pattern: u8 = 0,
    row: u16 = 0,
    tick: u16 = 0,
    macro_tick: u16 = 0,
    elapsed_ticks: u32 = 0,
    tempo: u16,
    tempo_fine_tune: i16 = 0,
    speed: u16,
    global_volume: u8 = 63,
    depth: u8 = 0,
    rhythm_keys: u5 = 0,
    fraction: u32 = 0,
    last_rate: u32 = 0,
    last_instrument: u8 = 0,
    initialized: bool = false,
    boundary: bool = false,
    visited: std.bit_set.Static(128) = .empty,
    next_order: ?u8 = null,
    next_row: ?u16 = null,
    repeat_row: ?u16 = null,
    row_delay: u16 = 0,
    wave_parameter: u8 = 0,
    shown: view.Playhead = .{},
    registers: [512]u8 = @splat(0),
    written_registers: std.bit_set.Static(512) = .empty,

    fn writeRegister(self: *Source, chip: fmt.Chip, reg: u16, value: u8) void {
        if (self.written_registers.isSet(reg) and self.registers[reg] == value) return;
        self.written_registers.set(reg);
        self.registers[reg] = value;
        chip.writeReg(reg, value);
    }

    fn percussion(self: *const Source) bool {
        return self.song.flags & 0x40 != 0 or self.song.channels > 18;
    }

    fn voice(self: *const Source, channel: usize) u16 {
        if (self.percussion()) {
            if (channel >= 15) return ([_]u16{ 6, 7, 8, 8, 7 })[channel - 15];
            if (channel >= 6 and channel <= 8) return 0x100 + @as(u16, @intCast(channel));
        }
        return voice_order[channel];
    }

    fn paired(self: *const Source, channel: usize) bool {
        const local = channel % 9;
        if (channel >= 18 or local >= 6) return false;
        const bit: u3 = @intCast(channel / 9 * 3 + local / 2);
        return self.song.four_op & (@as(u6, 1) << bit) != 0;
    }

    fn operatorOffset(self: *const Source, channel: usize, op: usize) ?u16 {
        const v = self.voice(channel);
        if (self.percussion() and channel >= 16) {
            const active: usize = if (channel == 16 or channel == 18) 1 else 0;
            if (op != active) return null;
        }
        return (v & 0x100) + operator_offsets[v & 0xff] + @as(u16, @intCast(op * 3));
    }

    fn writePatch(self: *Source, chip: fmt.Chip, channel: usize) void {
        const track = &self.tracks[channel];
        for (0..2) |op| {
            const offset = self.operatorOffset(channel, op) orelse continue;
            for ([_]u16{ 0x20, 0x60, 0x80, 0xe0 }, [_]usize{ 0, 4, 6, 8 }) |base, index| {
                self.writeRegister(chip, base + offset, track.patch.registers[index + op]);
            }
        }
        const pan: u8 = switch (track.panning) {
            1 => 0x10,
            2 => 0x20,
            else => 0x30,
        };
        self.writeRegister(chip, 0xc0 + self.voice(channel), (track.patch.registers[10] & 0x0f) | (if (self.song.version >= 5) pan else 0));
        self.writeVolume(chip, channel, 0);
    }

    fn audible(self: *const Source, channel: usize, op: usize) bool {
        const track = &self.tracks[channel];
        if (self.paired(channel)) {
            const local = channel % 9;
            const high = channel - local % 2;
            const algorithm: u2 = @as(u2, @truncate(self.tracks[high].patch.registers[10] & 1)) * 2 + @as(u2, @truncate(self.tracks[high + 1].patch.registers[10] & 1));
            return if (local % 2 == 0) op == 1 or (algorithm == 3 and op == 0) else (algorithm & 1 != 0 and op == 0) or (algorithm == 2 and op == 1);
        }
        return op == 1 or track.patch.registers[10] & 1 != 0 or (self.percussion() and channel >= 16);
    }

    fn writeVolume(self: *Source, chip: fmt.Chip, channel: usize, attenuation: i16) void {
        const track = &self.tracks[channel];
        for (0..2) |op| {
            const offset = self.operatorOffset(channel, op) orelse continue;
            var volume: i32 = track.volume[op];
            if (self.audible(channel, op)) volume = @divTrunc(@max(0, volume - attenuation) * self.global_volume, 63);
            const level: u8 = @intCast(63 - std.math.clamp(volume, 0, 63));
            self.writeRegister(chip, 0x40 + offset, (track.patch.registers[2 + op] & 0xc0) | level);
        }
    }

    fn frequency(note: u8, fine: i8) i32 {
        if (note == 0) return 0;
        const n = @min(note, 96) - 1;
        return @as(i32, frequencies[n % 12]) + @as(i32, n / 12) * 344 + fine;
    }

    fn writePitch(self: *Source, chip: fmt.Chip, channel: usize, pitch: i32) void {
        if (self.paired(channel) and channel % 9 % 2 == 0) return;
        const value = std.math.clamp(pitch, 0, 7 * 344 + 686);
        const track = &self.tracks[channel];
        if (track.written_pitch == value and track.written_key == track.keyed) return;
        track.written_pitch = value;
        track.written_key = track.keyed;
        const block: u16 = @intCast(@min(@divTrunc(@max(0, value - 343), 344), 7));
        const fnum: u16 = @intCast(value - @as(i32, block) * 344);
        const voice_offset = self.voice(channel);
        self.writeRegister(chip, 0xa0 + voice_offset, @truncate(fnum));
        self.writeRegister(chip, 0xb0 + voice_offset, @as(u8, @intCast((fnum >> 8) | (block << 2))) | (if (self.tracks[channel].keyed) @as(u8, 0x20) else 0));
    }

    fn key(self: *Source, chip: fmt.Chip, channel: usize, on: bool) void {
        self.tracks[channel].keyed = on;
        if (self.percussion() and channel >= 15) {
            const mask: u5 = @as(u5, 16) >> @intCast(channel - 15);
            if (on) self.rhythm_keys |= mask else self.rhythm_keys &= ~mask;
            self.writeRegister(chip, 0xbd, self.depth | 0x20 | self.rhythm_keys);
        }
        self.writePitch(chip, channel, self.tracks[channel].pitch);
    }

    fn retriggerNote(self: *Source, chip: fmt.Chip, channel: usize) void {
        const track = &self.tracks[channel];
        if (!track.keyed) return;
        track.pitch = frequency(track.note, track.patch.fine_tune);
        for (track.effects) |effect| {
            if (effect.cmd == @backingInt(EffectCode.extended2) and (effect.param >> 4 == 4 or effect.param >> 4 == 5))
                track.pitch += @as(i32, effect.param & 15) * @as(i32, if (effect.param >> 4 == 4) 1 else -1);
        }
        self.key(chip, channel, false);
        self.key(chip, channel, true);
    }

    fn begin(self: *Source, chip: fmt.Chip) void {
        self.last_instrument = 0;
        self.writeRegister(chip, 0x105, @intFromBool(self.song.version >= 5));
        self.writeRegister(chip, 0x104, self.song.four_op);
        self.writeRegister(chip, 1, 0x20);
        self.writeRegister(chip, 8, 0x40);
        self.depth = ((self.song.flags & 8) << 4) | ((self.song.flags & 16) << 2);
        self.writeRegister(chip, 0xbd, self.depth | (if (self.percussion()) @as(u8, 0x20) else 0));
        for (0..18) |i| self.writeRegister(chip, 0xb0 + @as(u16, @intCast(i / 9 * 256 + i % 9)), 0);
        for (self.tracks[0..self.song.channels], 0..) |*track, i| {
            const locks = self.song.locks(i);
            track.* = .{
                .panning = if (locks & 3 <= 2) locks & 3 else 0,
                .volume_lock = self.song.flags & 2 != 0 and locks & 16 != 0,
                .peak_lock = self.song.flags & 4 != 0 and locks & 32 != 0,
                .pan_lock = self.song.flags & 32 != 0,
                .four_op_lock = locks & 64 != 0,
                .slide_type = @truncate(locks >> 2),
            };
        }
        self.selectOrder(0);
        self.initialized = true;
        chip.flush();
    }

    fn selectOrder(self: *Source, requested: u8) void {
        var index = requested;
        var followed: std.bit_set.Static(128) = .empty;
        while (index < order_count) {
            if (followed.isSet(index)) break;
            followed.set(index);
            const entry = self.song.orders()[index];
            if (entry < 128) {
                self.order = index;
                self.pattern = entry;
                if (self.visited.isSet(index)) {
                    self.boundary = true;
                    if (index == 0 and self.song.flags & 1 != 0) self.speed = self.song.speed;
                }
                self.visited.set(index);
                return;
            }
            index = entry & 0x7f;
        }
        self.boundary = true;
    }

    fn triggerNote(self: *Source, chip: fmt.Chip, channel: usize, event: Event, slide: bool, keep_macros: bool) void {
        const track = &self.tracks[channel];
        if (event.instrument != 0 and event.instrument <= self.song.instrument_count) {
            const changed = track.instrument != event.instrument;
            if (changed and !track.released) track.macro_keyoff_loop = false;
            track.released = false;
            track.instrument = event.instrument;
            self.last_instrument = event.instrument;
            const stored = self.song.instrument(event.instrument);
            track.peak = .{ 63 - (stored.registers[2] & 63), 63 - (stored.registers[3] & 63) };
            if (!track.volume_lock or changed) track.volume = track.peak;
            if (changed) {
                track.patch = stored;
                if (!track.pan_lock) track.panning = stored.panning;
                self.writePatch(chip, channel);
            }
        }
        if (event.note == 255) {
            self.key(chip, channel, false);
            self.releaseMacros(channel);
        } else if (event.note != 0 and track.instrument != 0) {
            const value = if (event.note > 0x90) event.note - 0x90 else event.note;
            if (value > 96) return;
            track.note = value;
            track.vibrato_offset = .{ 0, 0 };
            track.tremolo_attenuation = .{ 0, 0 };
            track.target = frequency(value, track.patch.fine_tune);
            if (!slide or !track.keyed) {
                self.key(chip, channel, false);
                track.pitch = track.target;
                self.key(chip, channel, true);
            } else if (track.retrigger_portamento) {
                self.key(chip, channel, false);
                self.key(chip, channel, true);
            }
            if (!keep_macros) self.restartMacros(channel);
        }
    }

    fn restartMacros(self: *Source, channel: usize) void {
        const track = &self.tracks[channel];
        const data = self.song.macro(track.instrument);
        track.fm = .{};
        track.arpeggio = .{};
        track.vibrato = .{};
        track.macro_note = null;
        track.macro_vibrato = 0;
        if (data.len == 0) return;
        track.fm.position = @intFromBool(data[0] != 0);
        track.arpeggio_table = data[4];
        track.vibrato_table = data[5];
        self.restartPitchMacros(channel);
    }

    fn restartPitchMacros(self: *Source, channel: usize) void {
        const track = &self.tracks[channel];
        const arp = self.song.pitchMacro(track.arpeggio_table, .arpeggio);
        const vib = self.song.pitchMacro(track.vibrato_table, .vibrato);
        track.arpeggio = .{ .position = @intFromBool(arp.len != 0 and arp[0] != 0), .remaining = 1 };
        track.vibrato = .{ .position = @intFromBool(vib.len != 0 and vib[0] != 0), .remaining = 1 };
        track.vibrato_delay = if (vib.len != 0) vib[2] else 0;
    }

    fn releaseMacros(self: *Source, channel: usize) void {
        const track = &self.tracks[channel];
        const fm = self.song.macro(track.instrument);
        const arp = self.song.pitchMacro(track.arpeggio_table, .arpeggio);
        const vib = self.song.pitchMacro(track.vibrato_table, .vibrato);
        if (fm.len != 0 and fm[3] != 0) track.fm = .{ .position = fm[3] };
        if (arp.len != 0 and arp[4] != 0) track.arpeggio = .{ .position = arp[4], .remaining = 1 };
        if (vib.len != 0 and vib[5] != 0) {
            track.pitch = slidePitch(track.pitch, track.macro_vibrato);
            track.macro_vibrato = 0;
            track.vibrato = .{ .position = vib[5], .remaining = 1 };
            track.vibrato_delay = 0;
        }
    }

    fn isRetrigger(cmd: u8) bool {
        return cmd == @backingInt(EffectCode.retrigger) or cmd == @backingInt(EffectCode.multi_retrigger);
    }

    fn isArpeggio(effect: view.Effect) bool {
        return switch (@as(EffectCode, @fromBackingInt(effect.cmd))) {
            .arpeggio => effect.param != 0,
            .extra_fine_arpeggio, .arpeggio_volume, .arpeggio_fine_volume => true,
            else => false,
        };
    }

    fn slidePhase(fine: bool) EffectPhase {
        return if (fine) .fine else .tick;
    }

    fn hasEffect(track: *const Track, code: EffectCode, param: ?u8) bool {
        for (track.effects) |effect| {
            if (effect.cmd == @backingInt(code) and (param == null or effect.param == param.?)) return true;
        }
        return false;
    }

    fn family(code: EffectCode) []const EffectCode {
        return switch (code) {
            .portamento => &.{.portamento},
            .vibrato, .extra_fine_vibrato => &.{ .vibrato, .extra_fine_vibrato },
            .tremolo, .extra_fine_tremolo => &.{ .tremolo, .extra_fine_tremolo },
            .portamento_volume, .portamento_fine_volume => &.{ .portamento_volume, .portamento_fine_volume },
            .vibrato_volume, .vibrato_fine_volume => &.{ .vibrato_volume, .vibrato_fine_volume },
            .arpeggio_volume, .arpeggio_fine_volume => &.{ .arpeggio_volume, .arpeggio_fine_volume },
            .slide_up_volume,
            .slide_down_volume,
            .fine_slide_up_volume,
            .fine_slide_down_volume,
            .slide_up_fine_volume,
            .slide_down_fine_volume,
            .fine_slide_up_fine_volume,
            .fine_slide_down_fine_volume,
            => &.{ .slide_up_volume, .slide_down_volume, .fine_slide_up_volume, .fine_slide_down_volume, .slide_up_fine_volume, .slide_down_fine_volume, .fine_slide_up_fine_volume, .fine_slide_down_fine_volume },
            else => &.{},
        };
    }

    fn continueEffect(track: *Track, column: usize, effect: view.Effect, pitched: bool) view.Effect {
        const running = &track.running[column];
        const last = track.last_effect[column];
        const code: EffectCode = @fromBackingInt(effect.cmd);
        const group = family(code);
        var param: u8 = @intCast(effect.param);
        switch (code) {
            .arpeggio, .retrigger => if (param == 0) return effect,
            .multi_retrigger => if (param >> 4 == 0) return effect,
            .tremor => if (param >> 4 == 0 or param & 15 == 0) return effect,
            .extended2 => if (param >> 4 < 2 or param >> 4 == 4 or param >> 4 == 5) return effect,
            .portamento => if (!pitched and last.code != .portamento) return .{},
            .slide_up, .slide_down, .fine_slide_up, .fine_slide_down, .volume_slide, .fine_volume, .global_slide_up, .global_slide_down, .extra_fine_arpeggio => {},
            else => if (group.len == 0) return effect,
        }
        if (isArpeggio(effect) and track.note == 0 and !pitched) {
            running.* = .{};
            return .{};
        }
        if (param == 0 and group.len != 0) {
            const previous = if (code == .vibrato_volume or code == .vibrato_fine_volume) running.param else last.param;
            if (last.within(group) and previous != 0) {
                param = previous;
            } else switch (code) {
                .portamento, .vibrato, .extra_fine_vibrato, .tremolo, .extra_fine_tremolo => {},
                else => return .{},
            }
        }
        if (isRetrigger(effect.cmd) and !last.within(&.{ .retrigger, .multi_retrigger })) track.retrigger_count[column] = 1;
        if (code == .portamento) track.tone_speed = param;
        running.* = .{ .code = code, .param = param };
        return .{ .cmd = effect.cmd, .param = param };
    }

    fn processRow(self: *Source, chip: fmt.Chip) void {
        self.next_order = null;
        self.next_row = null;
        self.repeat_row = null;
        self.row_delay = 0;
        for (0..self.song.channels) |channel| {
            const track = &self.tracks[channel];
            const event = self.song.event(self.pattern, self.row, channel);
            track.effects = event.effects;
            if (self.song.version < 5) {
                self.translateLegacyEffect(channel);
            } else if (self.song.version < 9 and track.effects[0].cmd == 22) {
                const p = track.effects[0].param;
                track.effects[0] = .{ .cmd = @backingInt(EffectCode.extended2), .param = if (p >> 4 != 0) 0x40 | (p >> 4) else 0x50 | (p & 15) };
            }
            const value = if (event.note > 0x90 and event.note != 255) event.note - 0x90 else event.note;
            const pitched = value >= 1 and value <= 96;
            track.delayed = null;
            for (&track.effects, &track.running, &track.last_effect, 0..) |*effect, *running, *last, column| {
                if (running.active()) last.* = running.*;
                running.code = null;
                const cmd: EffectCode = @fromBackingInt(@intCast(effect.cmd));
                if (cmd != .vibrato and cmd != .vibrato_volume and cmd != .vibrato_fine_volume and cmd != .extra_fine_vibrato) track.vibrato_phase[column] = 0;
                if (cmd != .tremolo and cmd != .extra_fine_tremolo) track.tremolo_phase[column] = 0;
                if (!isRetrigger(effect.cmd)) track.retrigger_count[column] = 0;
                if (!(cmd == .arpeggio and effect.param != 0) and cmd != .extra_fine_arpeggio) {
                    track.arpeggio_phase[column] = 1;
                    track.arpeggio_shift[column] = 0;
                }
                if (isArpeggio(effect.*) and (event.note != 0 or !last.within(&.{ .arpeggio, .extra_fine_arpeggio, .arpeggio_volume, .arpeggio_fine_volume }))) {
                    track.arpeggio_phase[column] = 0;
                    track.arpeggio_shift[column] = 0;
                }
                const blank = effect.cmd == 0 and effect.param == 0;
                effect.* = continueEffect(track, column, effect.*, pitched);
                if (blank) running.* = .{};
                if (effect.cmd < track.memory[column].len and effect.param != 0) track.memory[column][effect.cmd] = @intCast(effect.param);
            }
            var delayed = false;
            for (track.effects) |effect| {
                if (effect.cmd == @backingInt(EffectCode.extended2) and effect.param >> 4 == 2 and effect.param & 15 != 0) delayed = true;
            }
            if (delayed) {
                track.delayed = event.note;
                self.triggerNote(chip, channel, .{ .instrument = event.instrument }, false, true);
            } else {
                const slide = hasEffect(track, .portamento, null) or hasEffect(track, .portamento_volume, null) or hasEffect(track, .portamento_fine_volume, null);
                self.triggerNote(chip, channel, event, slide, hasEffect(track, .extended, 0xff));
            }
        }
    }

    fn translateLegacyEffect(self: *Source, channel: usize) void {
        const track = &self.tracks[channel];
        const effect = &track.effects[0];
        const mapping = [_]EffectCode{ .arpeggio, .slide_up, .slide_down, .fine_slide_up, .fine_slide_down, .portamento, .portamento_volume, .vibrato, .vibrato_volume, .volume, .volume, .pattern_break, .jump, .speed, .tempo, .extended };
        const original = effect.cmd;
        if (original >= mapping.len) return;
        effect.cmd = @backingInt(mapping[original]);
        if (original == 9) {
            const p = effect.param;
            effect.* = if (p >> 4 != 0)
                .{ .cmd = @backingInt(EffectCode.carrier_volume), .param = 3 + (p >> 4) * 4 }
            else if (p & 15 != 0)
                .{ .cmd = @backingInt(EffectCode.modulator_volume), .param = 3 + (p & 15) * 4 }
            else
                .{};
        } else if (original == 15) {
            const value: u8 = @intCast(effect.param & 15);
            switch (effect.param >> 4) {
                0, 1 => {},
                2 => effect.* = .{ .cmd = @backingInt(EffectCode.waveform), .param = if (value < 4) (@as(u16, value) << 4) | 15 else 0xf0 | (value & 3) },
                3, 4 => effect.* = .{ .cmd = @backingInt(if (effect.param >> 4 == 3) EffectCode.fine_slide_up else .fine_slide_down), .param = value },
                5...8 => {
                    const group = effect.param >> 4;
                    effect.* = .{ .cmd = @backingInt(if (group < 7) EffectCode.volume_slide else .fine_volume), .param = if (group % 2 == 1) @as(u16, value) << 4 else value };
                },
                9 => effect.* = .{ .cmd = @backingInt(EffectCode.retrigger), .param = value + 1 },
                10...13 => effect.param = ((effect.param >> 4) - 8 + @as(u16, if (track.legacy_carrier_adsr) 4 else 0)) * 16 + value,
                14 => effect.param = 0xa0 | value,
                15 => {
                    const commands = [_]u8{ 0xf0, 0xf2, 0xf3, 0xf4, 0xf5, 0, 0, 0xf7, 0xf6, 0xf8 };
                    if (value == 5 or value == 6) track.legacy_carrier_adsr = value == 5;
                    if (value >= commands.len or value == 5 or value == 6) effect.* = .{} else effect.param = commands[value];
                },
                else => unreachable,
            }
        }
    }

    fn volumeSlots(self: *const Source, channel: usize) [2]bool {
        return switch (self.tracks[channel].slide_type) {
            0 => .{ self.audible(channel, 0), self.audible(channel, 1) },
            1 => .{ false, true },
            2 => .{ true, false },
            3 => .{ true, true },
        };
    }

    fn changeVolume(self: *Source, channel: usize, delta: i16) void {
        const track = &self.tracks[channel];
        const enabled = self.volumeSlots(channel);
        for (enabled, 0..) |apply, op| {
            if (apply) {
                const maximum: i16 = if (track.peak_lock) track.peak[op] else 63;
                track.volume[op] = @intCast(std.math.clamp(@as(i16, track.volume[op]) + delta, 0, maximum));
            }
        }
    }

    fn volumeSlide(self: *Source, channel: usize, parameter: u8) void {
        const up: i16 = parameter >> 4;
        self.changeVolume(channel, if (up != 0) up else -@as(i16, parameter & 15));
    }

    fn setVolume(self: *Source, channel: usize, volume: u8, force: bool) void {
        const track = &self.tracks[channel];
        const value = @min(volume, 63);
        const scale = self.song.flags & 0x80 != 0 or track.four_op_lock;
        for (0..2) |op| {
            if (force and op == 0) {
                track.volume[op] = @intCast((@as(u16, track.peak[op]) * value + 31) / 63);
            } else if (self.audible(channel, op)) {
                track.volume[op] = if (scale) @intCast((@as(u16, track.peak[op]) * value + 31) / 63) else value;
            }
        }
        if (track.four_op_lock and self.paired(channel)) {
            const partner = if (channel % 9 % 2 == 0) channel + 1 else channel - 1;
            for (0..2) |op| {
                if (self.audible(partner, op)) self.tracks[partner].volume[op] = @intCast((@as(u16, self.tracks[partner].peak[op]) * value + 31) / 63);
            }
        }
    }

    fn portamento(track: *Track) void {
        if (track.pitch < track.target) track.pitch = @min(track.target, track.pitch + track.tone_speed);
        if (track.pitch > track.target) track.pitch = @max(track.target, track.pitch - track.tone_speed);
    }

    fn slidePitch(pitch: i32, delta: i32) i32 {
        return if (delta < 0) @max(frequencies[0], pitch + delta) else @min(7 * 344 + 686, pitch + delta);
    }

    fn modulation(self: *const Source, phase: u16) i16 {
        const table = [_]i16{ 0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253, 255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24 };
        if (self.wave_parameter == 0) return table[phase % 32] * @as(i16, if (phase / 32 % 2 == 0) 1 else -1);
        const size: u16 = if (self.wave_parameter < 0xf0) 32 else @as(u16, 32) << @intCast((self.wave_parameter - 0xf0) / 4);
        const maximum: u16 = if (self.wave_parameter < 0xf0) self.wave_parameter else 255;
        const position = phase % size;
        const triangle = @min(position, size - position);
        const value: i16 = @intCast(@as(u32, triangle) * maximum * 2 / size);
        return if (phase / size % 2 == 0) value else -value;
    }

    fn vibratoEffect(self: *Source, channel: usize, column: usize, parameter: u8, advance: bool) void {
        const track = &self.tracks[channel];
        const factor: u16 = if (self.wave_parameter < 0xf0) 1 else @as(u16, self.wave_parameter & 3) + 1;
        if (advance) track.vibrato_phase[column] +%= @as(u16, parameter >> 4) * factor;
        track.vibrato_offset[column] = -@divTrunc(@as(i32, self.modulation(track.vibrato_phase[column])) * (parameter & 15), 128);
    }

    fn tremoloEffect(self: *Source, channel: usize, column: usize, parameter: u8, advance: bool) void {
        const track = &self.tracks[channel];
        const factor: u16 = if (self.wave_parameter < 0xf0) 1 else @as(u16, self.wave_parameter & 3) + 1;
        if (advance) track.tremolo_phase[column] +%= @as(u16, parameter >> 4) * factor;
        track.tremolo_attenuation[column] = @intCast(@divTrunc(@as(i32, self.modulation(track.tremolo_phase[column])) * (parameter & 15), 128));
    }

    fn arpeggioEffect(self: *Source, channel: usize, column: usize, parameter: u8, advance: bool) void {
        const track = &self.tracks[channel];
        if (parameter == 0 or track.note == 0) return;
        if (advance) {
            track.arpeggio_shift[column] = switch (track.arpeggio_phase[column]) {
                1 => parameter >> 4,
                2 => parameter & 15,
                else => 0,
            };
            track.arpeggio_phase[column] = (track.arpeggio_phase[column] + 1) % 3;
        }
        track.pitch_offset += frequency(@min(96, track.note + track.arpeggio_shift[column]), track.patch.fine_tune) - frequency(track.note, track.patch.fine_tune);
    }

    fn extended(self: *Source, chip: fmt.Chip, channel: usize, column: usize, parameter: u8) void {
        const track = &self.tracks[channel];
        const value = parameter & 15;
        const group = parameter >> 4;
        switch (group) {
            0, 1 => {
                const mask: u8 = if (group == 0) 0x80 else 0x40;
                self.depth = (self.depth & ~mask) | (if (value & 1 != 0) mask else 0);
                self.writeRegister(chip, 0xbd, self.depth | self.rhythm_keys | (if (self.percussion()) @as(u8, 0x20) else 0));
            },
            2...9 => {
                const op: usize = (group - 2) / 4;
                const field = (group - 2) % 4;
                const index: usize = 4 + op + @as(usize, field / 2) * 2;
                const mask: u8 = if (field % 2 == 0) 0xf0 else 0x0f;
                const shift: u3 = if (field % 2 == 0) 4 else 0;
                track.patch.registers[index] = (track.patch.registers[index] & ~mask) | (value << shift);
                self.writePatch(chip, channel);
            },
            10 => {
                track.patch.registers[10] = (track.patch.registers[10] & 1) | ((value & 7) << 1);
                self.writePatch(chip, channel);
            },
            11 => {
                track.panning = @min(value, 2);
                self.writePatch(chip, channel);
            },
            12, 13 => {
                if (column == 1 and track.effects[0].cmd == @backingInt(EffectCode.extended) and track.effects[0].param >> 4 == 12) return;
                if (value == 0) {
                    track.loop_row = self.row;
                } else {
                    const remaining = &track.loop_counts[self.row];
                    if (remaining.* == 255) return;
                    if (remaining.* == 0) remaining.* = value + 1;
                    remaining.* -= 1;
                    if (remaining.* != 0) self.repeat_row = track.loop_row else if (group == 12) remaining.* = 255;
                }
            },
            14 => switch (value) {
                0, 1 => track.macro_keyoff_loop = value == 1,
                2, 3 => track.retrigger_portamento = value == 3,
                4 => {
                    self.key(chip, channel, false);
                    self.key(chip, channel, true);
                },
                5, 6 => track.four_op_lock = value == 6,
                else => {},
            },
            15 => switch (value) {
                0 => {
                    @memset(track.patch.registers[4..8], 0xff);
                    track.volume = .{ 0, 0 };
                    self.key(chip, channel, false);
                    self.releaseMacros(channel);
                    track.instrument = 0;
                    track.released = true;
                    self.writePatch(chip, channel);
                },
                1 => track.volume = track.peak,
                2, 3 => track.volume_lock = value == 2,
                4, 5 => track.peak_lock = value == 4,
                6 => track.slide_type = if (hasEffect(track, .extended, 0xf7)) 3 else 2,
                7 => track.slide_type = if (hasEffect(track, .extended, 0xf6)) 3 else 1,
                8 => track.slide_type = 0,
                9, 10 => track.pan_lock = value == 9,
                11 => {
                    track.vibrato_phase = .{ 0, 0 };
                    track.vibrato_offset = .{ 0, 0 };
                },
                12 => {
                    track.tremolo_phase = .{ 0, 0 };
                    track.tremolo_attenuation = .{ 0, 0 };
                },
                else => {},
            },
            else => unreachable,
        }
    }

    fn extended3(self: *Source, chip: fmt.Chip, channel: usize, parameter: u8) void {
        const track = &self.tracks[channel];
        const group = parameter >> 4;
        const value = parameter & 15;
        if (group == 0) {
            track.patch.registers[10] = (track.patch.registers[10] & ~@as(u8, 1)) | (value & 1);
        } else if (group <= 12) {
            const op: usize = (group - 1) / 6;
            const field = (group - 1) % 6;
            const index: usize = op + (if (field == 1) @as(usize, 2) else 0);
            const mask: u8 = switch (field) {
                0 => 15,
                1 => 0xc0,
                2 => 0x80,
                3 => 0x40,
                4 => 0x10,
                5 => 0x20,
                else => unreachable,
            };
            const shift: u3 = switch (field) {
                0 => 0,
                1 => 6,
                2 => 7,
                3 => 6,
                4 => 4,
                5 => 5,
                else => unreachable,
            };
            track.patch.registers[index] = (track.patch.registers[index] & ~mask) | ((value << shift) & mask);
        }
        self.writePatch(chip, channel);
    }

    fn applyEffect(self: *Source, chip: fmt.Chip, channel: usize, column: usize, phase: EffectPhase) void {
        const track = &self.tracks[channel];
        const effect = track.effects[column];
        const code: EffectCode = @fromBackingInt(@intCast(effect.cmd));
        const parameter: u8 = @intCast(effect.param);
        const first = self.tick == 0;
        const settings = phase == .settings;
        const per_tick = phase == .tick;
        const fine_vibrato = hasEffect(track, .extended, 0xfd);
        const fine_tremolo = hasEffect(track, .extended, 0xfe);
        const memory = track.memory[column];
        switch (code) {
            .arpeggio => if (per_tick) self.arpeggioEffect(channel, column, parameter, true),
            .slide_up => {
                if (per_tick) track.pitch = slidePitch(track.pitch, parameter);
            },
            .slide_down => {
                if (per_tick) track.pitch = slidePitch(track.pitch, -@as(i32, parameter));
            },
            .portamento => {
                if (per_tick) portamento(track);
            },
            .vibrato => {
                if (per_tick) self.vibratoEffect(channel, column, parameter, !fine_vibrato or first);
            },
            .portamento_volume, .portamento_fine_volume => {
                if (per_tick) portamento(track);
                if (phase == slidePhase(code == .portamento_fine_volume)) self.volumeSlide(channel, parameter);
            },
            .vibrato_volume, .vibrato_fine_volume => {
                if (per_tick) self.vibratoEffect(channel, column, memory[@backingInt(EffectCode.vibrato)], !fine_vibrato or first);
                if (phase == slidePhase(code == .vibrato_fine_volume)) self.volumeSlide(channel, parameter);
            },
            .fine_slide_up => {
                if (phase == .fine) track.pitch = slidePitch(track.pitch, parameter);
            },
            .fine_slide_down => {
                if (phase == .fine) track.pitch = slidePitch(track.pitch, -@as(i32, parameter));
            },
            .modulator_volume => {
                if (settings) track.volume[0] = @min(parameter, 63);
            },
            .carrier_volume => {
                if (settings) track.volume[1] = @min(parameter, 63);
            },
            .volume_slide => if (per_tick) self.volumeSlide(channel, parameter),
            .fine_volume => {
                if (phase == .fine) self.volumeSlide(channel, parameter);
            },
            .jump => {
                if (settings) self.next_order = parameter;
            },
            .volume, .force_volume => {
                if (settings) self.setVolume(channel, parameter, code == .force_volume);
            },
            .pattern_break => {
                if (settings) self.next_row = parameter;
            },
            .tempo => {
                if (settings and parameter != 0) self.tempo = parameter;
            },
            .speed => {
                if (settings and parameter != 0) self.speed = parameter;
            },
            .waveform => if (settings) {
                if (parameter >> 4 <= 7) track.patch.registers[9] = parameter >> 4;
                if (parameter & 15 <= 7) track.patch.registers[8] = parameter & 15;
                self.writePatch(chip, channel);
            },
            .retrigger => if (per_tick and parameter != 0) {
                if (track.retrigger_count[column] >= parameter) {
                    track.retrigger_count[column] = 0;
                    self.retriggerNote(chip, channel);
                    self.restartMacros(channel);
                } else track.retrigger_count[column] += 1;
            },
            .tremolo => {
                if (per_tick) self.tremoloEffect(channel, column, parameter, !fine_tremolo or first);
            },
            .tremor => if (per_tick) {
                const on: u16 = @max(1, parameter >> 4);
                const off: u16 = @max(1, parameter & 15);
                if (self.tick % (on + off) >= on) track.attenuation = 63;
            },
            .arpeggio_volume, .arpeggio_fine_volume => {
                if (per_tick) self.arpeggioEffect(channel, column, memory[0], true);
                if (phase == slidePhase(code == .arpeggio_fine_volume)) self.volumeSlide(channel, parameter);
            },
            .multi_retrigger => if (per_tick and parameter >> 4 != 0) {
                if (track.retrigger_count[column] < parameter >> 4) {
                    track.retrigger_count[column] += 1;
                    return;
                }
                track.retrigger_count[column] = 0;
                const mode = parameter & 15;
                if (mode >= 1 and mode <= 5) self.changeVolume(channel, -(@as(i16, 1) << @intCast(mode - 1)));
                if (mode >= 9 and mode <= 13) self.changeVolume(channel, @as(i16, 1) << @intCast(mode - 9));
                if (mode == 6 or mode == 7 or mode == 14 or mode == 15) {
                    const enabled = self.volumeSlots(channel);
                    for (enabled, 0..) |apply, op| {
                        if (apply) track.volume[op] = @intCast(@min(63, switch (mode) {
                            6 => @as(u16, track.volume[op]) * 2 / 3,
                            7 => @as(u16, track.volume[op]) / 2,
                            14 => @as(u16, track.volume[op]) * 3 / 2,
                            15 => @as(u16, track.volume[op]) * 2,
                            else => unreachable,
                        }));
                    }
                }
                self.retriggerNote(chip, channel);
                self.restartMacros(channel);
            },
            .slide_up_volume,
            .slide_down_volume,
            .fine_slide_up_volume,
            .fine_slide_down_volume,
            .slide_up_fine_volume,
            .slide_down_fine_volume,
            .fine_slide_up_fine_volume,
            .fine_slide_down_fine_volume,
            => {
                const fine_pitch = code == .fine_slide_up_volume or code == .fine_slide_down_volume or code == .fine_slide_up_fine_volume or code == .fine_slide_down_fine_volume;
                const fine_volume = @backingInt(code) >= @backingInt(EffectCode.slide_up_fine_volume);
                const down = (@backingInt(code) - @backingInt(EffectCode.slide_up_volume)) % 2 != 0;
                const pitch_code: EffectCode = if (fine_pitch) (if (down) .fine_slide_down else .fine_slide_up) else (if (down) .slide_down else .slide_up);
                if (phase == slidePhase(fine_pitch)) track.pitch = slidePitch(track.pitch, @as(i32, memory[@backingInt(pitch_code)]) * @as(i32, if (down) -1 else 1));
                if (phase == slidePhase(fine_volume)) self.volumeSlide(channel, parameter);
            },
            .extended => {
                if (settings) self.extended(chip, channel, column, parameter);
            },
            .extended2 => {
                const value = parameter & 15;
                const group = parameter >> 4;
                switch (group) {
                    0 => {
                        if (settings) self.row_delay = value;
                    },
                    1 => {
                        if (settings) self.row_delay = @as(u16, value) * self.speed;
                    },
                    3 => {
                        if (per_tick and self.tick == value) self.key(chip, channel, false);
                    },
                    2 => if (per_tick and self.tick == value) {
                        if (track.delayed) |note| self.triggerNote(chip, channel, .{ .note = note }, false, false);
                        track.delayed = null;
                    },
                    4, 5 => {
                        if (phase == .fine) track.pitch += @as(i32, value) * @as(i32, if (group == 4) 1 else -1);
                    },
                    6...11 => {
                        const apply = if (group < 8) per_tick else if (group < 10) phase == .fine else per_tick and self.elapsed_ticks % 4 == 0;
                        if (apply) self.global_volume = @intCast(std.math.clamp(@as(i16, self.global_volume) + @as(i16, value) * @as(i16, if (group % 2 == 0) 1 else -1), 0, 63));
                    },
                    12, 13 => {
                        if (per_tick and self.elapsed_ticks % 4 == 0) self.changeVolume(channel, @as(i16, value) * @as(i16, if (group == 12) 1 else -1));
                    },
                    14, 15 => {
                        if (per_tick and self.elapsed_ticks % 4 == 0) track.pitch = slidePitch(track.pitch, @as(i32, value) * @as(i32, if (group == 14) 1 else -1));
                    },
                    else => unreachable,
                }
            },
            .global_volume => {
                if (settings) self.global_volume = @min(parameter, 63);
            },
            .arpeggio_table, .vibrato_table => if (settings) {
                if (code == .arpeggio_table) track.arpeggio_table = parameter else track.vibrato_table = parameter;
                if (!hasEffect(track, .extended, 0xff)) self.restartPitchMacros(channel);
            },
            .extended3 => {
                if (settings) self.extended3(chip, channel, parameter);
            },
            .extra_fine_arpeggio => if (per_tick) self.arpeggioEffect(channel, column, parameter, self.elapsed_ticks % 4 == 0),
            .extra_fine_vibrato => {
                if (per_tick) self.vibratoEffect(channel, column, parameter, self.tick % 4 == 0);
            },
            .extra_fine_tremolo => {
                if (per_tick) self.tremoloEffect(channel, column, parameter, self.tick % 4 == 0);
            },
            .waveform_table => {
                if (settings) self.wave_parameter = parameter;
            },
            .global_slide_up, .global_slide_down => {
                if (column == 0 and (track.effects[1].cmd == @backingInt(EffectCode.global_slide_up) or track.effects[1].cmd == @backingInt(EffectCode.global_slide_down))) return;
                const apply = if (fine_vibrato) phase == .fine else per_tick and (!fine_tremolo or self.tick % 4 == 0);
                if (apply) {
                    const delta = @as(i32, parameter) * @as(i32, if (code == .global_slide_up) 1 else -1);
                    if (hasEffect(track, .extended, 0xe7)) {
                        self.tempo_fine_tune = @intCast(std.math.clamp(@as(i32, self.tempo_fine_tune) + delta, -32768, 32767));
                    } else {
                        for (self.tracks[channel..self.song.channels], channel..) |*target, index| {
                            if (index != channel and (hasEffect(target, .global_slide_up, null) or hasEffect(target, .global_slide_down, null))) break;
                            target.pitch = slidePitch(target.pitch, delta);
                        }
                    }
                }
            },
            else => {},
        }
        track.pitch = std.math.clamp(track.pitch, 0, 7 * 344 + 686);
    }

    fn advanceMacro(cursor: *MacroCursor, length: u8, loop_start: u8, loop_length: u8, keyoff: u8, keyed: bool, release_loop: bool) void {
        const next: u16 = @as(u16, cursor.position) + 1;
        const loop_end = @as(u16, loop_start) + loop_length;
        if (!keyed and keyoff != 0 and release_loop and next > length) {
            cursor.position = if (keyoff <= length) keyoff else 0;
        } else if (keyed and loop_start != 0 and loop_start <= length and loop_length != 0 and next >= loop_end) {
            cursor.position = loop_start;
        } else if (next > length or (keyed and keyoff != 0 and next >= keyoff)) {
            cursor.position = 0;
        } else {
            cursor.position = @intCast(next);
        }
    }

    fn applyFmMacro(self: *Source, chip: fmt.Chip, channel: usize) void {
        const track = &self.tracks[channel];
        const data = self.song.macro(track.instrument);
        if (data.len == 0 or track.fm.position == 0) return;
        if (track.fm.remaining != 0) {
            track.fm.remaining -= 1;
            return;
        }
        if (track.fm.position > data[0]) {
            track.fm.position = 0;
            return;
        }
        const record = data[6 + (track.fm.position - @as(usize, 1)) * 15 ..][0..15];
        track.fm.shown = track.fm.position;
        if (record[14] != 0) {
            const disabled = self.song.disabledColumns(track.instrument);
            for (0..2) |op| {
                const indexes = [_]usize{ 4, 4, 6, 6, 8, 2, 2, 0, 0, 0, 0, 0 };
                const masks = [_]u8{ 0xf0, 0x0f, 0xf0, 0x0f, 7, 63, 0xc0, 15, 0x80, 0x40, 0x10, 0x20 };
                for (indexes, masks, 0..) |index, mask, field| {
                    if (disabled & (@as(u32, 1) << @intCast(op * 12 + field)) != 0) continue;
                    track.patch.registers[index + op] = (track.patch.registers[index + op] & ~mask) | (record[index + op] & mask);
                }
                if (disabled & (@as(u32, 1) << @intCast(op * 12 + 5)) == 0) track.volume[op] = record[2 + op] & 63;
            }
            if (disabled & (1 << 24) == 0) track.patch.registers[10] = (track.patch.registers[10] & ~@as(u8, 1)) | (record[10] & 1);
            if (disabled & (1 << 25) == 0) track.patch.registers[10] = (track.patch.registers[10] & ~@as(u8, 14)) | (record[10] & 14);
            if (self.song.version >= 11 and record[10] & 0x80 != 0) self.retriggerNote(chip, channel);
            if (disabled & (1 << 26) == 0) track.pitch = slidePitch(track.pitch, std.mem.readInt(i16, record[11..13], .little));
            if (disabled & (1 << 27) == 0 and !track.pan_lock and record[13] <= 2) track.panning = record[13];
            self.writePatch(chip, channel);
        }
        track.fm.remaining = @as(u16, @max(1, record[14])) - 1;
        advanceMacro(&track.fm, data[0], data[1], data[2], data[3], track.keyed, track.macro_keyoff_loop);
    }

    fn applyPitchMacros(self: *Source, channel: usize) void {
        const track = &self.tracks[channel];
        const arp = self.song.pitchMacro(track.arpeggio_table, .arpeggio);
        if (arp.len != 0 and track.arpeggio.position != 0) {
            if (track.arpeggio.remaining != 0) {
                track.arpeggio.remaining -= 1;
            } else if (track.arpeggio.position <= arp[0]) {
                track.arpeggio.shown = track.arpeggio.position;
                const value = arp[4 + @as(usize, track.arpeggio.position)];
                track.macro_note = @intCast(@min(96, if (value > 128) value - @as(u16, 128) else @as(u16, track.note) + value));
                track.arpeggio.remaining = @as(u16, @max(1, arp[1])) - 1;
                advanceMacro(&track.arpeggio, arp[0], arp[2], arp[3], arp[4], track.keyed, track.macro_keyoff_loop);
            } else track.arpeggio.position = 0;
        }
        const vib = self.song.pitchMacro(track.vibrato_table, .vibrato);
        if (track.vibrato_delay != 0) {
            track.vibrato_delay -= 1;
        } else if (vib.len != 0 and track.vibrato.position != 0) {
            if (track.vibrato.remaining != 0) {
                track.vibrato.remaining -= 1;
            } else if (track.vibrato.position <= vib[0]) {
                track.vibrato.shown = track.vibrato.position;
                track.macro_vibrato = @as(i8, @bitCast(vib[5 + @as(usize, track.vibrato.position)]));
                track.vibrato.remaining = @as(u16, @max(1, vib[1])) - 1;
                advanceMacro(&track.vibrato, vib[0], vib[3], vib[4], vib[5], track.keyed, track.macro_keyoff_loop);
            } else track.vibrato.position = 0;
        }
    }

    fn advanceRow(self: *Source) void {
        if (self.next_order != null or self.next_row != null) {
            const next: u8 = self.next_order orelse self.order + 1;
            self.selectOrder(next);
            self.row = @min(self.next_row orelse 0, self.song.rows - 1);
        } else if (self.repeat_row) |row| {
            self.row = row;
            return;
        } else if (self.row + 1 < self.song.rows) {
            self.row += 1;
            return;
        } else {
            self.selectOrder(self.order + 1);
            self.row = 0;
        }
        for (&self.tracks) |*track| {
            track.loop_row = 0;
            track.loop_counts = @splat(0);
        }
    }

    pub fn step(self: *Source, chip: fmt.Chip) fmt.StepResult {
        if (!self.initialized) self.begin(chip);
        if (self.boundary) {
            self.boundary = false;
            self.visited = .empty;
            self.visited.set(self.order);
            self.elapsed_ticks = 0;
            return .{ .frames = 0, .done = true };
        }
        if (self.macro_tick == 0) {
            if (self.tick == 0) {
                self.processRow(chip);
                for (0..self.song.channels) |channel| {
                    for (0..2) |column| self.applyEffect(chip, channel, column, .settings);
                    for (0..2) |column| self.applyEffect(chip, channel, column, .fine);
                }
            }
            for (0..self.song.channels) |channel| {
                self.tracks[channel].pitch_offset = 0;
                self.tracks[channel].attenuation = 0;
                for (0..2) |column| self.applyEffect(chip, channel, column, .tick);
            }
        }
        for (0..self.song.channels) |channel| {
            self.applyFmMacro(chip, channel);
            self.applyPitchMacros(channel);
            const track = &self.tracks[channel];
            var pitch = track.pitch + track.pitch_offset;
            if (track.macro_note) |value| pitch += frequency(value, track.patch.fine_tune) - frequency(track.note, track.patch.fine_tune);
            self.writePitch(chip, channel, slidePitch(pitch, track.macro_vibrato + track.vibrato_offset[0] + track.vibrato_offset[1]));
            self.writeVolume(chip, channel, track.attenuation + track.tremolo_attenuation[0] + track.tremolo_attenuation[1]);
        }
        const tempo: u32 = @intCast(std.math.clamp(@as(i32, self.tempo) + self.tempo_fine_tune, 1, 65535));
        self.shown = .{
            .order = self.order,
            .pattern = self.pattern,
            .row = self.row,
            .speed = self.speed,
            .tempo = @intCast(tempo),
            .bpm = @intCast(@min(65535, tempo * 60 / (@as(u32, self.speed) * self.song.rows_per_beat))),
            .tick = self.elapsed_ticks,
            .last_instrument = self.last_instrument,
            .macro_speedup = self.song.macro_speed,
            .global_volume = self.global_volume,
            .flags = .{ .has_order = true, .has_pattern = true, .has_row = true, .has_speed = true, .has_tempo = true, .has_bpm = true, .has_tick = true, .has_macro_speedup = true, .has_global_volume = true },
        };
        const rate = tempo * self.song.macro_speed;
        if (self.last_rate != 0 and rate != self.last_rate) self.fraction = @intCast(@as(u64, self.fraction) * rate / self.last_rate);
        self.last_rate = rate;
        const frames = fmt.rescale(1, rate, self.sample_rate, &self.fraction);
        self.macro_tick += 1;
        if (self.macro_tick == self.song.macro_speed) {
            self.macro_tick = 0;
            self.elapsed_ticks +%= 1;
            self.tick += 1;
            if (self.tick >= self.speed + self.row_delay) {
                self.tick = 0;
                self.advanceRow();
            }
        }
        return .{ .frames = frames };
    }

    pub fn info(self: *Source) fmt.TrackInfo {
        return .{
            .format_name = if (self.song.tiny) "A2T" else format_name,
            .title = if (self.song.title.len == 0) null else self.song.title.slice(),
            .title_embedded = self.song.title.len != 0,
            .artist = if (self.song.artist.len == 0) null else self.song.artist.slice(),
            .opl3 = self.song.version >= 5,
            .system = if (self.song.version >= 5) "OPL3" else "OPL2",
            .loop = true,
        };
    }

    pub fn playhead(self: *Source) view.Playhead {
        return self.shown;
    }

    pub fn channelState(self: *Source) view.ChannelStateBank {
        var state: view.ChannelStateBank = .{ .channels = self.song.channels };
        for (self.tracks[0..self.song.channels], state.slots[0..self.song.channels]) |track, *slot| {
            slot.* = .{
                .instrument = if (track.instrument == 0) view.instrument_none else track.instrument,
                .note_code = track.note,
                .keyed = track.keyed,
                .vol_mod = track.volume[0],
                .vol_car = track.volume[1],
                .panning = track.panning,
                .fmreg_pos = track.fm.shown,
                .fmreg_duration = @intCast(@min(track.fm.remaining, 255)),
                .arpg_pos = track.arpeggio.shown,
                .arpg_count = @intCast(@min(track.arpeggio.remaining, 255)),
                .arpg_table = track.arpeggio_table,
                .vib_pos = track.vibrato.shown,
                .vib_delay = @intCast(@min(track.vibrato_delay, 255)),
                .vib_table = track.vibrato_table,
                .volume_lock = track.volume_lock,
                .vol4op_lock = track.four_op_lock,
                .pan_lock = track.pan_lock,
                .peak_lock = track.peak_lock,
                .effects = track.effects,
            };
        }
        return state;
    }

    pub fn patternView(self: *Source) view.PatternView {
        return .{
            .ctx = self,
            .grid = .shared_pattern,
            .occupancy = .independent,
            .columns = if (self.song.modern()) &columns else columns[0..3],
            .effect_style = .letter_param,
            .cell_template = .{ .width = if (self.song.modern()) 15 else 11 },
            .channels = self.song.channels,
            .rows_per_pattern = self.song.rows,
            .num_patterns = self.song.patternSpan(),
            .fnum_notes = &frequencies,
            .cell = viewCell,
            .channelInfo = viewChannel,
            .effectLexicon = effectDescription,
            .patternName = patternName,
        };
    }

    pub fn orderView(self: *Source) view.OrderView {
        return .{ .ctx = self, .len = order_count, .kind = .shared_index, .entry = orderEntry };
    }

    pub fn instrumentBank(self: *Source) view.InstrumentBank {
        return .{ .ctx = self, .count = @as(u16, self.song.instrument_count) + 1, .get = instrumentInfo, .macroStep = macroStep };
    }

    fn viewCell(ptr: *anyopaque, pattern: u16, row: u16, channel: u16) view.Cell {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (pattern >= self.song.pattern_count) return .{};
        const event = self.song.event(@intCast(pattern), row, channel);
        const value = if (event.note > 0x90 and event.note != 255) event.note - 0x90 else event.note;
        return .{
            .note = if (event.note == 255) .off else if (value >= 1 and value <= 96)
                .{ .pitch = .{ .semitone = (value - 1) % 12, .octave = (value - 1) / 12, .fixed = event.note > 0x90 } }
            else
                .none,
            .instrument = if (event.instrument == 0) null else event.instrument,
            .effects = event.effects,
        };
    }

    fn viewChannel(ptr: *anyopaque, channel: u16) view.ChannelInfo {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (channel >= self.song.channels) return .{ .present = false };
        const paired_channel = self.paired(channel);
        const high = channel % 9 % 2 == 0;
        const physical = self.voice(channel);
        return .{
            .kind = if (self.percussion() and channel >= 15) .drum else .fm,
            .opl_voice = @intCast((physical >> 8) * 9 + (physical & 0xff)),
            .four_op_pair = if (paired_channel) @intCast(if (high) channel + 1 else channel - 1) else null,
            .four_op_role = if (paired_channel) (if (high) .hi else .lo) else .none,
        };
    }

    fn patternName(ptr: *anyopaque, index: u16) []const u8 {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (index >= self.song.pattern_count) return "";
        return self.song.pattern_names[index].slice();
    }

    fn orderEntry(ptr: *anyopaque, index: u16) view.OrderEntry {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (index >= order_count) return .{ .kind = .end };
        const entry = self.song.orders()[index];
        if (entry >= 128) return .{ .kind = .jump, .jump_to = entry & 0x7f };
        return .{ .kind = .pattern, .pattern = entry };
    }

    fn instrumentInfo(ptr: *anyopaque, index: u16) view.InstrumentInfo {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (index == 0 or index > self.song.instrument_count) return .{};
        const number: u8 = @intCast(index);
        var result: view.InstrumentInfo = .{
            .name = self.song.instrument_names[index - 1].slice(),
            .patch = .{ .opl_2op = self.song.instrument(number).info() },
        };
        const fm = self.song.macro(number);
        if (fm.len != 0) {
            result.macros = .{
                .fmreg_len = fm[0],
                .fmreg_loop_begin = fm[1],
                .fmreg_loop_length = fm[2],
                .fmreg_keyoff = fm[3],
                .arpeggio_table = fm[4],
                .vibrato_table = fm[5],
                .dis_fmreg_cols = self.song.disabledColumns(number),
            };
            const arp = self.song.pitchMacro(fm[4], .arpeggio);
            const vib = self.song.pitchMacro(fm[5], .vibrato);
            if (arp.len != 0) {
                result.macros.arpeggio_len = arp[0];
                result.macros.arpeggio_speed = arp[1];
                result.macros.arpeggio_loop_begin = arp[2];
                result.macros.arpeggio_loop_length = arp[3];
                result.macros.arpeggio_keyoff = arp[4];
            }
            if (vib.len != 0) {
                result.macros.vibrato_len = vib[0];
                result.macros.vibrato_speed = vib[1];
                result.macros.vibrato_delay = vib[2];
                result.macros.vibrato_loop_begin = vib[3];
                result.macros.vibrato_loop_length = vib[4];
                result.macros.vibrato_keyoff = vib[5];
            }
        }
        return result;
    }

    fn macroStep(ptr: *anyopaque, index: u16, kind: view.MacroKind, step_index: u16) view.MacroStep {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (index == 0 or index > self.song.instrument_count) return .{};
        const fm = self.song.macro(@intCast(index));
        if (fm.len == 0) return .{};
        if (kind == .fmreg) {
            if (step_index >= fm[0]) return .{};
            const record = fm[6 + @as(usize, step_index) * 15 ..][0..15];
            var patch: Patch = .{ .registers = record[0..11].* };
            patch.registers[2] ^= 63;
            patch.registers[3] ^= 63;
            return .{
                .empty = false,
                .duration = record[14],
                .panning = record[13],
                .freq_slide = std.mem.readInt(i16, record[11..13], .little),
                .flags = record[10] & 0x80,
                .ops = .{ patch.operator(0), patch.operator(1) },
                .feedback = @truncate(record[10] >> 1),
                .additive = record[10] & 1 != 0,
            };
        }
        const data = self.song.pitchMacro(if (kind == .arpeggio) fm[4] else fm[5], kind);
        if (data.len == 0 or step_index >= data[0]) return .{};
        return if (kind == .arpeggio)
            .{ .empty = false, .arp_note = data[5 + @as(usize, step_index)] }
        else
            .{ .empty = false, .vib_delta = @bitCast(data[6 + @as(usize, step_index)]) };
    }

    fn effectDescription(ptr: *anyopaque, code: u8, _: u16) view.EffectDesc {
        const self: *Source = @ptrCast(@alignCast(ptr));
        if (self.song.version < 5) {
            const legacy_names = [_][]const u8{ "arpeggio", "pitch up", "pitch down", "fine pitch up", "fine pitch down", "portamento", "portamento + volume", "vibrato", "vibrato + volume", "operator intensity", "instrument volume", "pattern break", "order jump", "speed", "tempo", "extended" };
            if (code >= legacy_names.len) return .{};
            return .{ .letter = "0123456789ABCDEF"[code], .text = legacy_names[code] };
        }
        if (self.song.version < 9 and code == 22) return .{ .letter = 'M', .text = "manual fine tune (up x, else down y)" };
        const names = [_][]const u8{
            "arpeggio",            "pitch up",               "pitch down",               "portamento",             "vibrato",                  "portamento + volume",         "vibrato + volume",
            "fine pitch up",       "fine pitch down",        "modulator volume",         "volume slide",           "order jump",               "instrument volume",           "pattern break",
            "tempo",               "speed",                  "portamento + fine volume", "vibrato + fine volume",  "carrier volume",           "waveform",                    "fine volume",
            "retrigger",           "tremolo",                "tremor",                   "arpeggio + volume",      "arpeggio + fine volume",   "retrigger + volume",          "pitch up + volume",
            "pitch down + volume", "fine pitch up + volume", "fine pitch down + volume", "pitch up + fine volume", "pitch down + fine volume", "fine pitch up + fine volume", "fine pitch down + fine volume",
            "extended",            "extended 2",             "global volume",            "arpeggio table",         "vibrato table",            "force volume",                "operator settings",
            "extra fine arpeggio", "extra fine vibrato",     "extra fine tremolo",       "modulation table",       "global pitch up",          "global pitch down",
        };
        const letters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ&%!@=#$~^`><";
        if (code >= names.len) return .{};
        return .{ .letter = letters[code], .text = names[code] };
    }

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        self.song.deinit(gpa);
        gpa.destroy(self);
    }
};

pub fn load(gpa: std.mem.Allocator, data: []const u8, ctx: fmt.LoadContext) anyerror!?fmt.MusicSource {
    var song = (try parse(gpa, data)) orelse return null;
    errdefer song.deinit(gpa);
    const source = try gpa.create(Source);
    source.* = .{ .song = song, .sample_rate = ctx.sample_rate, .tempo = song.tempo, .tempo_fine_tune = song.tempo_fine_tune, .speed = song.speed };
    return fmt.MusicSource.init(source, visualizer_name);
}

pub const format = fmt.Format.init(@This());

// --- tests -------------------------------------------------------------------

const TestModule = struct {
    version: u8,
    metadata: []u8,
    patterns: []u8,

    fn init(version: u8) !TestModule {
        const gpa = std.testing.allocator;
        const metadata = try gpa.alloc(u8, metadataSize(version));
        errdefer gpa.free(metadata);
        @memset(metadata, 0);
        const pattern_size: usize = if (version >= 9) modern_pattern_bytes else if (version < 5) 64 * 9 * 4 else 18 * 64 * 4;
        const patterns = try gpa.alloc(u8, pattern_size);
        @memset(patterns, 0);
        const orders: usize = if (version >= 9) 0x11281d else 0x2d42;
        @memset(metadata[orders..][0..128], 0x80);
        metadata[orders] = 0;
        metadata[orders + 128] = 50;
        metadata[orders + 129] = 1;
        if (version >= 9) {
            std.mem.writeInt(u16, metadata[orders + 131 ..][0..2], 4, .little);
            metadata[orders + 133] = 1;
            std.mem.writeInt(u16, metadata[orders + 134 ..][0..2], 1, .little);
        }
        const instrument: usize = if (version >= 9) 0x2b2b else 0x2090;
        @memcpy(metadata[instrument..][0..11], &[_]u8{ 0x21, 0x21, 20, 0, 0xf3, 0xf3, 0x77, 0x77, 0, 0, 0 });
        return .{ .version = version, .metadata = metadata, .patterns = patterns };
    }

    fn deinit(self: TestModule) void {
        std.testing.allocator.free(self.metadata);
        std.testing.allocator.free(self.patterns);
    }

    fn event(self: TestModule, row: usize, channel: usize, value: []const u8) void {
        const offset = if (self.version >= 9) (channel * 256 + row) * 6 else if (self.version < 5) (row * 9 + channel) * 4 else (channel * 64 + row) * 4;
        @memcpy(self.patterns[offset..][0..value.len], value);
    }

    fn encode(self: TestModule) ![]u8 {
        const gpa = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        const header: usize = if (self.version >= 9) 84 else if (self.version < 5) 26 else 34;
        try bytes.appendNTimes(gpa, 0, header);
        @memcpy(bytes.items[0..10], "_A2module_");
        bytes.items[14] = self.version;
        bytes.items[15] = 1;
        for ([_][]const u8{ self.metadata, self.patterns }, 0..) |block, i| {
            const size = try pack(&bytes, self.version, block);
            if (self.version >= 9)
                std.mem.writeInt(u32, bytes.items[16 + i * 4 ..][0..4], @intCast(size), .little)
            else
                std.mem.writeInt(u16, bytes.items[16 + i * 2 ..][0..2], @intCast(size), .little);
        }
        std.mem.writeInt(u32, bytes.items[10..14], checksum(bytes.items[header..], bytes.items[16..header], if (self.version >= 9) 4 else 2), .little);
        return bytes.toOwnedSlice(gpa);
    }

    fn encodeTiny(self: TestModule) ![]u8 {
        const gpa = std.testing.allocator;
        const modern = self.version >= 9;
        const prefix: usize = if (self.version >= 14) 0x484 else if (self.version >= 12) 0x481 else 0;
        const stride: usize = if (modern) 14 else 13;
        var instruments: [0x484 + 14]u8 = @splat(0);
        if (self.version >= 12) {
            const start: usize = if (self.version >= 14) 3 else 0;
            @memcpy(instruments[start..prefix], self.metadata[0x115a1e..][0..0x481]);
        }
        if (self.version >= 14) @memcpy(instruments[0..3], self.metadata[0x115e9f..][0..3]);
        const instrument_offset: usize = if (modern) 0x2b2b else 0x2090;
        @memcpy(instruments[prefix..][0..stride], self.metadata[instrument_offset..][0..stride]);
        const orders: usize = if (modern) 0x11281d else 0x2d42;
        var blocks: [6][]const u8 = undefined;
        blocks[0] = instruments[0 .. prefix + stride];
        var count: usize = 1;
        if (modern) {
            blocks[1] = self.metadata[0x391d..][0..3831];
            blocks[2] = self.metadata[0xf2126..][0..521];
            count = 3;
        }
        if (self.version >= 11) {
            blocks[count] = self.metadata[0x113e3a..][0..28];
            count += 1;
        }
        blocks[count] = self.metadata[orders..][0..127];
        blocks[count + 1] = self.patterns;
        count += 2;

        const lengths_offset: usize = if (self.version < 5) 23 else if (!modern) 24 else if (self.version == 9) 29 else 50;
        const length_size: usize = if (modern) 4 else 2;
        const slots: usize = if (self.version < 5) 6 else if (!modern) 10 else if (self.version < 11) 20 else 21;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.appendNTimes(gpa, 0, lengths_offset + slots * length_size);
        @memcpy(bytes.items[0..15], "_A2tiny_module_");
        bytes.items[19] = self.version;
        bytes.items[20] = 1;
        @memcpy(bytes.items[21..23], self.metadata[orders + 128 ..][0..2]);
        if (self.version >= 5) bytes.items[23] = self.metadata[orders + 130];
        if (modern) @memcpy(bytes.items[24..29], self.metadata[orders + 131 ..][0..5]);
        if (self.version >= 10) @memcpy(bytes.items[29..50], self.metadata[orders + 136 ..][0..21]);
        for (blocks[0..count], 0..) |block, i| {
            const size = try pack(&bytes, self.version, block);
            const field = bytes.items[lengths_offset + i * length_size ..];
            if (modern)
                std.mem.writeInt(u32, field[0..4], @intCast(size), .little)
            else
                std.mem.writeInt(u16, field[0..2], @intCast(size), .little);
        }
        const header = lengths_offset + slots * length_size;
        std.mem.writeInt(u32, bytes.items[15..19], checksum(bytes.items[header..], bytes.items[lengths_offset..header], length_size), .little);
        return bytes.toOwnedSlice(gpa);
    }

    fn pack(bytes: *std.ArrayList(u8), version: u8, block: []const u8) !usize {
        const gpa = std.testing.allocator;
        if (block.len == 0) return 0;
        const start = bytes.items.len;
        if (version >= 12) {
            try bytes.append(gpa, 0);
            const size = std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(block.len)));
            try bytes.appendSlice(gpa, &size);
            var mask: u8 = 0;
            var tag: usize = 0;
            var cursor: usize = 0;
            while (cursor < block.len) {
                const value = block[cursor];
                var end = cursor + 1;
                while (end < block.len and end - cursor < 65535 and block[end] == value) : (end += 1) {}
                const fields = [_]u16{ @intCast(end - cursor), 0, 0, 0, value, 0, 0 };
                const widths = [_]u5{ 16, 15, 15, 16, 16, 14, 14 };
                for (fields, widths) |field, width| {
                    var left = width;
                    while (left > 0) {
                        left -= 1;
                        try bit(bytes, &tag, &mask, field & (@as(u16, 1) << @intCast(left)) != 0);
                    }
                }
                cursor = end;
            }
        } else if (version >= 9) {
            try bytes.append(gpa, block[0]);
            var mask: u8 = 0;
            var tag: usize = 0;
            for (block[1..]) |value| {
                try bit(bytes, &tag, &mask, false);
                try bytes.append(gpa, value);
            }
            for ([_]bool{ true, true, false }) |value| try bit(bytes, &tag, &mask, value);
            try bytes.append(gpa, 0);
        } else {
            try bytes.appendSlice(gpa, block);
        }
        return bytes.items.len - start;
    }

    fn bit(bytes: *std.ArrayList(u8), tag: *usize, mask: *u8, value: bool) !void {
        if (mask.* == 0) {
            tag.* = bytes.items.len;
            try bytes.append(std.testing.allocator, 0);
            mask.* = 128;
        }
        if (value) bytes.items[tag.*] |= mask.*;
        mask.* >>= 1;
    }

    fn source(self: TestModule) !fmt.MusicSource {
        const bytes = try self.encode();
        defer std.testing.allocator.free(bytes);
        return (try load(std.testing.allocator, bytes, test_context)).?;
    }
};

const test_context: fmt.LoadContext = .{ .sample_rate = 48000, .chip = fmt.noop_chip, .ext = ".a2m", .name = "test.a2m" };

const TestChip = struct {
    registers: [512]u8 = @splat(0),
    writes: [512]u32 = @splat(0),

    fn write(ptr: *anyopaque, reg: u16, value: u8) void {
        const self: *TestChip = @ptrCast(@alignCast(ptr));
        self.registers[reg] = value;
        self.writes[reg] += 1;
    }

    fn flush(_: *anyopaque) void {}

    fn chip(self: *TestChip) fmt.Chip {
        return .{ .ptr = self, .vtable = &.{ .writeReg = write, .flush = flush } };
    }
};

test "a2m retains metadata and patterns after the input is freed" {
    var module = try TestModule.init(11);
    defer module.deinit();
    @memcpy(module.metadata[0..5], &[_]u8{ 4, 'T', 0x81, 'n', 'e' });
    @memcpy(module.metadata[86..91], "\x04Bell");
    module.event(0, 0, &.{ 49, 1, 1, 4, 12, 32 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    @memset(module.metadata, 0);
    @memset(module.patterns, 0);
    try std.testing.expectEqualStrings("Tüne", source.info().title.?);
    const views = source.views();
    const pattern = views.pattern.?;
    const cell = pattern.cell(pattern.ctx, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 4), cell.note.pitch.octave);
    try std.testing.expectEqual(@as(u16, 32), cell.effects[1].param);
    const bank = views.instruments.?;
    try std.testing.expectEqualStrings("Bell", bank.get(bank.ctx, cell.instrument.?).name);
    var chip: TestChip = .{};
    try std.testing.expectEqual(@as(u64, 960), source.step(chip.chip()).frames);
    try std.testing.expectEqual(@as(u8, 0x5b), chip.registers[0xa3]);
    try std.testing.expectEqual(@as(u8, 31), chip.registers[0x4b]);
    try std.testing.expectEqual(cell.instrument.?, source.playhead().?.last_instrument);
    try std.testing.expectEqual(@as(?u8, 3), pattern.channelInfo.?(pattern.ctx, 0).opl_voice);
    try std.testing.expectEqualStrings("", bank.get(bank.ctx, 0).name);
}

test "a2m rejects incomplete compressed patterns and invalid dimensions" {
    var module = try TestModule.init(11);
    defer module.deinit();
    const bytes = try module.encode();
    defer std.testing.allocator.free(bytes);
    std.mem.writeInt(u32, bytes[20..24], 4, .little);
    const payload_end = 84 + std.mem.readInt(u32, bytes[16..20], .little) + 4;
    std.mem.writeInt(u32, bytes[10..14], checksum(bytes[84..payload_end], bytes[16..84], 4), .little);
    try std.testing.expectError(error.InvalidA2mCompression, parse(std.testing.allocator, bytes));
    module.metadata[0x11281d + 133] = 21;
    const invalid = try module.encode();
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(error.InvalidA2m, parse(std.testing.allocator, invalid));
}

test "a2m pattern loops repeat rows before reporting a song boundary" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.event(0, 0, &.{ 49, 1, 35, 0xc0, 0, 0 });
    module.event(2, 0, &.{ 0, 0, 35, 0xc2, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    for ([_]u16{ 0, 1, 2, 0, 1, 2, 0, 1, 2, 3 }) |row| {
        try std.testing.expect(!source.step(fmt.noop_chip).done);
        try std.testing.expectEqual(row, source.playhead().?.row);
    }
    try std.testing.expect(source.step(fmt.noop_chip).done);
    try std.testing.expect(!source.step(fmt.noop_chip).done);
    try std.testing.expectEqual(@as(u16, 0), source.playhead().?.row);
}

test "a2m four operator pairs use the low voice for pitch and key state" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 133] = 2;
    module.metadata[0x11281d + 136] = 1;
    module.event(0, 0, &.{ 1, 1, 0, 0, 0, 0 });
    module.event(0, 1, &.{ 2, 1, 0, 0, 0, 0 });
    module.event(1, 1, &.{ 255, 0, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 1), chip.registers[0x104]);
    try std.testing.expectEqual(@as(u8, 0x6b), chip.registers[0xa0]);
    try std.testing.expectEqual(@as(u8, 0x21), chip.registers[0xb0]);
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0xb3]);
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 1), chip.registers[0xb0]);
    const pattern = source.views().pattern.?;
    try std.testing.expectEqual(@as(?u8, 1), pattern.channelInfo.?(pattern.ctx, 0).four_op_pair);
}

test "a2t owns compact instruments and exposes playable tracker data across versions" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("A2T", fmt.displayLabelForPath("tune.A2T").?);
    for ([_]u8{ 4, 8, 9, 10, 11, 12, 13, 14 }) |version| {
        var module = try TestModule.init(version);
        defer module.deinit();
        module.event(0, 0, if (version >= 9) &.{ 49, 1, 0, 0, 12, 32 } else &.{ 49, 1, 0, 0 });
        if (version == 14) {
            module.metadata[0x115e9f] = 6;
            std.mem.writeInt(i16, module.metadata[0x115ea0..][0..2], -2, .little);
        }
        const source = blk: {
            const bytes = try module.encodeTiny();
            defer gpa.free(bytes);
            break :blk (try load(gpa, bytes, .{ .sample_rate = 48000, .chip = fmt.noop_chip, .ext = ".a2t" })).?;
        };
        defer source.deinit(gpa);
        @memset(module.metadata, 0);
        @memset(module.patterns, 0);
        try std.testing.expectEqualStrings("A2T", source.info().format_name);
        try std.testing.expect(source.info().title == null);
        try std.testing.expect(source.info().artist == null);
        const views = source.views();
        const bank = views.instruments.?;
        try std.testing.expectEqual(@as(u16, 2), bank.count);
        try std.testing.expectEqualStrings("", bank.get(bank.ctx, 1).name);
        const pattern = views.pattern.?;
        const cell = pattern.cell(pattern.ctx, 0, 0, 0);
        try std.testing.expectEqual(@as(u8, 4), cell.note.pitch.octave);
        try std.testing.expectEqual(@as(u16, 1), cell.instrument.?);
        if (version >= 9) try std.testing.expectEqual(@as(u16, 32), cell.effects[1].param);
        const orders = views.order.?;
        try std.testing.expect(orders.entry(orders.ctx, 127).kind == .jump);
        var chip: TestChip = .{};
        try std.testing.expectEqual(@as(u64, if (version == 14) 1000 else 960), source.step(chip.chip()).frames);
        try std.testing.expect(chip.registers[0xb3] & 0x20 != 0);
        try std.testing.expectEqual(@as(u16, if (version == 14) 48 else 50), source.playhead().?.tempo);
        if (version == 14) try std.testing.expectEqual(@as(u16, 480), source.playhead().?.bpm);
    }
}

test "a2t retains macros track locks and four operator pairing" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 10, 11, 12, 13, 14 }) |version| {
        var module = try TestModule.init(version);
        defer module.deinit();
        module.metadata[0x11281d + 130] = 2;
        module.metadata[0x11281d + 133] = 2;
        const multiplier: u16 = if (version == 12) 259 else 3;
        std.mem.writeInt(u16, module.metadata[0x11281d + 134 ..][0..2], multiplier, .little);
        module.metadata[0x11281d + 136] = 1;
        module.metadata[0x1128a6] = 0x11;
        @memcpy(module.metadata[0x391d..][0..6], &[_]u8{ 1, 1, 1, 0, 1, 1 });
        std.mem.writeInt(i16, module.metadata[0x391d + 17 ..][0..2], -3, .little);
        module.metadata[0x391d + 20] = 2;
        @memcpy(module.metadata[0xf2126..][0..6], &[_]u8{ 1, 2, 0, 0, 0, 7 });
        @memcpy(module.metadata[0xf2126 + 260 ..][0..7], &[_]u8{ 1, 2, 3, 0, 0, 0, 254 });
        if (version >= 11) module.metadata[0x113e3a + 3] = 1;
        module.event(0, 0, &.{ 49, 1, 0, 0, 0, 0 });
        module.event(0, 1, &.{ 49, 1, 0, 0, 0, 0 });
        const bytes = try module.encodeTiny();
        defer gpa.free(bytes);
        const source = (try load(gpa, bytes, test_context)).?;
        defer source.deinit(gpa);
        const bank = source.views().instruments.?;
        const instrument = bank.get(bank.ctx, 1);
        try std.testing.expectEqual(@as(u16, 1), instrument.macros.fmreg_len);
        try std.testing.expectEqual(@as(u32, if (version >= 11) 8 else 0), instrument.macros.dis_fmreg_cols);
        try std.testing.expectEqual(@as(i16, -3), bank.macroStep.?(bank.ctx, 1, .fmreg, 0).freq_slide);
        try std.testing.expectEqual(@as(u8, 7), bank.macroStep.?(bank.ctx, 1, .arpeggio, 0).arp_note);
        try std.testing.expectEqual(@as(i8, -2), bank.macroStep.?(bank.ctx, 1, .vibrato, 0).vib_delta);
        var chip: TestChip = .{};
        try std.testing.expectEqual(@as(u64, 960 / multiplier), source.step(chip.chip()).frames);
        try std.testing.expectEqual(@as(u8, 1), chip.registers[0x104]);
        try std.testing.expectEqual(multiplier, source.playhead().?.macro_speedup);
        try std.testing.expect(source.channelState().?.slots[0].volume_lock);
        const pattern = source.views().pattern.?;
        try std.testing.expectEqual(@as(?u8, 1), pattern.channelInfo.?(pattern.ctx, 0).four_op_pair);
    }
}

test "a2m and a2t checksums reject damaged payloads and cover unused length words" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 4, 8, 9, 14 }) |version| {
        var module = try TestModule.init(version);
        defer module.deinit();
        for ([_]bool{ false, true }) |tiny| {
            const encoded = if (tiny) try module.encodeTiny() else try module.encode();
            defer gpa.free(encoded);
            const data = try gpa.alloc(u8, encoded.len + 3);
            defer gpa.free(data);
            @memcpy(data[0..encoded.len], encoded);
            @memset(data[encoded.len..], 0xa5);
            const header: usize = if (tiny) switch (version) {
                4 => 35,
                8 => 44,
                9 => 109,
                else => 134,
            } else if (version < 5) 26 else if (version < 9) 34 else 84;
            if (version >= 9) @memset(data[header - 2 .. header], 0xff);
            const source = (try load(gpa, data, test_context)).?;
            source.deinit(gpa);
            data[encoded.len - 1] ^= 1;
            try std.testing.expectError(error.InvalidA2mChecksum, load(gpa, data, test_context));
            data[encoded.len - 1] ^= 1;
            const unused_length = header - @as(usize, if (version >= 9) 4 else 2);
            data[unused_length] ^= 1;
            try std.testing.expectError(error.InvalidA2mChecksum, load(gpa, data, test_context));
            data[unused_length] ^= 1;
            const crc_offset: usize = if (tiny) 15 else 10;
            @memset(data[crc_offset..][0..4], 0);
            try std.testing.expectError(error.InvalidA2mChecksum, load(gpa, data, test_context));
        }
    }
}

test "a2t rejects truncated blocks partial instruments and invalid playback dimensions" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 4, 14 }) |version| {
        var module = try TestModule.init(version);
        defer module.deinit();
        const bytes = try module.encodeTiny();
        defer gpa.free(bytes);
        for ([_]usize{ 15, 20, 22, bytes.len - 1 }) |length| {
            try std.testing.expectError(error.InvalidA2m, parse(gpa, bytes[0..length]));
        }
        bytes[19] = 15;
        try std.testing.expectError(error.UnsupportedA2mVersion, parse(gpa, bytes));
        bytes[19] = version;
        bytes[21] = 0;
        try std.testing.expectError(error.InvalidA2m, parse(gpa, bytes));
        bytes[21] = 50;
        if (version == 4) {
            std.mem.writeInt(u16, bytes[23..25], 12, .little);
            std.mem.writeInt(u32, bytes[15..19], checksum(bytes[35 .. bytes.len - 1], bytes[23..35], 2), .little);
            try std.testing.expectError(error.InvalidA2m, parse(gpa, bytes));
        } else {
            bytes[26] = 21;
            try std.testing.expectError(error.InvalidA2m, parse(gpa, bytes));
            bytes[26] = 1;
            std.mem.writeInt(u16, bytes[24..26], 257, .little);
            try std.testing.expectError(error.InvalidA2m, parse(gpa, bytes));
        }
    }
}

test "aPLib decodes literals and overlapping matches" {
    var dest: [5]u8 = undefined;
    const source = [_]u8{ 'A', 0x6c, 'B', 5, 0 };
    try std.testing.expectEqual(5, try aplib(&source, &dest));
    try std.testing.expectEqualStrings("ABABA", &dest);
    try std.testing.expectError(error.InvalidA2mCompression, aplib(&source, dest[0..4]));
    try std.testing.expectError(error.InvalidA2mCompression, aplib(source[0..4], &dest));
}

test "sixpack leaves the root weight alone once a leaf hangs from the root" {
    var tree = SixpackTree.init();
    const leaf: u16 = SixpackTree.symbols + 'A';
    var updates: usize = 0;
    while (tree.nodes[leaf].parent != 1 and updates < 4000) : (updates += 1) tree.update(leaf);
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[leaf].parent);
    const root = tree.nodes[1].weight;
    tree.update(leaf);
    try std.testing.expectEqual(root, tree.nodes[1].weight);
}

test "a2m orders naming an unsaved pattern play empty rows and then follow the jump" {
    var module = try TestModule.init(11);
    defer module.deinit();
    const orders = module.metadata[0x11281d..][0..3];
    @memcpy(orders, &[_]u8{ 0, 1, 0x80 });
    module.event(0, 0, &.{ 49, 1, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    for (0..4) |_| try std.testing.expect(!source.step(fmt.noop_chip).done);
    for (0..4) |row| {
        try std.testing.expect(!source.step(fmt.noop_chip).done);
        const at = source.playhead().?;
        try std.testing.expectEqual(@as(u16, 1), at.order);
        try std.testing.expectEqual(@as(u16, 1), at.pattern);
        try std.testing.expectEqual(@as(u16, @intCast(row)), at.row);
    }
    try std.testing.expect(source.step(fmt.noop_chip).done);
    _ = source.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u16, 0), source.playhead().?.order);
}

test "a2m volume slides run on the row tick as well" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.event(0, 0, &.{ 49, 1, 10, 0x01, 0, 0 });
    module.event(1, 0, &.{ 0, 0, 10, 0x01, 0, 0 });
    module.event(2, 0, &.{ 0, 0, 10, 0x01, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    for (0..3) |_| _ = source.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 60), source.channelState().?.slots[0].vol_car);

    const Case = struct { cells: [2][6]u8, mod: u8, car: u8 };
    const cases = [_]Case{
        .{ .cells = .{ .{ 49, 1, 10, 0x03, 12, 32 }, @splat(0) }, .mod = 43, .car = 29 },
        .{ .cells = .{ .{ 49, 1, 12, 32, 10, 0x03 }, @splat(0) }, .mod = 43, .car = 29 },
        .{ .cells = .{ .{ 49, 1, 10, 0x03, 35, 0xf6 }, @splat(0) }, .mod = 40, .car = 63 },
        .{ .cells = .{ .{ 49, 1, 35, 0xf6, 10, 0x03 }, @splat(0) }, .mod = 40, .car = 63 },
        .{ .cells = .{ .{ 49, 1, 18, 62, 0, 0 }, .{ 0, 0, 10, 0x30, 20, 0x02 } }, .mod = 43, .car = 63 },
        .{ .cells = .{ .{ 49, 1, 18, 62, 0, 0 }, .{ 0, 0, 20, 0x02, 10, 0x30 } }, .mod = 43, .car = 63 },
    };
    for (cases) |case| {
        var rows = try TestModule.init(11);
        defer rows.deinit();
        for (case.cells, 0..) |cell, row| rows.event(row, 0, &cell);
        const played = try rows.source();
        defer played.deinit(std.testing.allocator);
        for (case.cells) |_| _ = played.step(fmt.noop_chip);
        const slot = played.channelState().?.slots[0];
        try std.testing.expectEqual(case.mod, slot.vol_mod);
        try std.testing.expectEqual(case.car, slot.vol_car);
    }

    var global = try TestModule.init(11);
    defer global.deinit();
    global.metadata[0x11281d + 133] = 2;
    global.event(0, 0, &.{ 49, 1, 36, 0x73, 0, 0 });
    global.event(0, 1, &.{ 0, 0, 37, 40, 0, 0 });
    const both = try global.source();
    defer both.deinit(std.testing.allocator);
    _ = both.step(fmt.noop_chip);
    try std.testing.expectEqual(@as(u8, 37), both.playhead().?.global_volume);
}

test "a2m legacy 9xy sets only the named operator" {
    for ([_]u8{ 0x03, 0x30 }) |param| {
        var module = try TestModule.init(4);
        defer module.deinit();
        module.event(0, 0, &.{ 49, 1, 9, param });
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        _ = source.step(fmt.noop_chip);
        const slot = source.channelState().?.slots[0];
        try std.testing.expectEqual(@as(u8, if (param == 0x03) 15 else 43), slot.vol_mod);
        try std.testing.expectEqual(@as(u8, if (param == 0x03) 63 else 15), slot.vol_car);
    }
}

test "a2m v5 to v8 manual slide fine-tunes up by x or down by y" {
    var plain = try TestModule.init(8);
    defer plain.deinit();
    plain.event(0, 0, &.{ 51, 1, 0, 0 });
    const reference = try plain.source();
    defer reference.deinit(std.testing.allocator);
    var base: TestChip = .{};
    _ = reference.step(base.chip());
    const pattern = reference.views().pattern.?;
    const voice: u16 = pattern.channelInfo.?(pattern.ctx, 0).opl_voice.?;
    const fnum = 0xa0 + voice / 9 * 0x100 + voice % 9;
    for ([_]u8{ 0x03, 0x30 }) |param| {
        var module = try TestModule.init(8);
        defer module.deinit();
        module.event(0, 0, &.{ 51, 1, 22, param });
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        var chip: TestChip = .{};
        _ = source.step(chip.chip());
        const expected = if (param == 0x03) base.registers[fnum] - 3 else base.registers[fnum] + 3;
        try std.testing.expectEqual(expected, chip.registers[fnum]);
    }
}

test "a2m songs before version 10 take their volume lock from the common flags" {
    var module = try TestModule.init(8);
    defer module.deinit();
    module.metadata[0x2d42 + 130] = 0x02;
    module.event(0, 0, &.{ 49, 1, 12, 20 });
    module.event(1, 0, &.{ 51, 1, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    _ = source.step(fmt.noop_chip);
    _ = source.step(fmt.noop_chip);
    const slot = source.channelState().?.slots[0];
    try std.testing.expect(slot.volume_lock);
    try std.testing.expectEqual(@as(u8, 20), slot.vol_car);
}

test "a2m retrigger fires every parameter plus one ticks across rows" {
    const KeyEdges = struct {
        on: bool = false,
        edges: u32 = 0,
        fn write(ptr: *anyopaque, reg: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (reg != 0xb3) return;
            const now = value & 0x20 != 0;
            if (now and !self.on) self.edges += 1;
            self.on = now;
        }
        fn flush(_: *anyopaque) void {}
    };
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 129] = 6;
    module.event(0, 0, &.{ 49, 1, 21, 3, 0, 0 });
    module.event(1, 0, &.{ 0, 0, 21, 3, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var keys: KeyEdges = .{};
    const chip: fmt.Chip = .{ .ptr = &keys, .vtable = &.{ .writeReg = KeyEdges.write, .flush = KeyEdges.flush } };
    for (0..12) |_| _ = source.step(chip);
    try std.testing.expectEqual(@as(u32, 4), keys.edges);

    var legacy = try TestModule.init(4);
    defer legacy.deinit();
    legacy.event(0, 0, &.{ 49, 1, 15, 0x90 });
    const old = try legacy.source();
    defer old.deinit(std.testing.allocator);
    var old_keys: KeyEdges = .{};
    const old_chip: fmt.Chip = .{ .ptr = &old_keys, .vtable = &.{ .writeReg = KeyEdges.write, .flush = KeyEdges.flush } };
    _ = old.step(old_chip);
    try std.testing.expectEqual(@as(u32, 2), old_keys.edges);

    for ([_][6]u8{ @splat(0), .{ 0, 0, 19, 0, 0, 0 } }) |between| {
        var gap = try TestModule.init(11);
        defer gap.deinit();
        gap.metadata[0x11281d + 129] = 6;
        gap.event(0, 0, &.{ 49, 1, 21, 4, 0, 0 });
        gap.event(2, 0, &between);
        gap.event(3, 0, &.{ 0, 0, 21, 4, 0, 0 });
        const resumed = try gap.source();
        defer resumed.deinit(std.testing.allocator);
        var gap_keys: KeyEdges = .{};
        const gap_chip: fmt.Chip = .{ .ptr = &gap_keys, .vtable = &.{ .writeReg = KeyEdges.write, .flush = KeyEdges.flush } };
        for (0..22) |_| _ = resumed.step(gap_chip);
        try std.testing.expectEqual(@as(u32, 2), gap_keys.edges);
        _ = resumed.step(gap_chip);
        try std.testing.expectEqual(@as(u32, 3), gap_keys.edges);
    }
}

test "a2m retrigger restarts the note at its own pitch and leaves a released note silent" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 129] = 6;
    module.event(0, 0, &.{ 49, 1, 2, 0xf0, 21, 5 });
    module.event(1, 0, &.{ 255, 0, 0, 0, 21, 2 });
    module.event(2, 0, &.{ 49, 1, 36, 0x41, 21, 1 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    for (0..5) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0x57), chip.registers[0xa3]);
    try std.testing.expectEqual(@as(u8, 0x31), chip.registers[0xb3]);
    _ = source.step(chip.chip());
    for (0..6) |_| {
        _ = source.step(chip.chip());
        try std.testing.expectEqual(@as(u8, 0), chip.registers[0xb3] & 0x20);
    }
    for (0..3) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0x58), chip.registers[0xa3]);
    try std.testing.expectEqual(@as(u8, 0x31), chip.registers[0xb3]);

    var macro = try TestModule.init(11);
    defer macro.deinit();
    macro.metadata[0x391d] = 2;
    @memcpy(macro.metadata[0x391d + 6 ..][0..15], &[_]u8{ 0x21, 0x21, 63, 63, 0xf3, 0xf3, 0x77, 0x77, 0, 0, 0, 100, 0, 0, 1 });
    @memcpy(macro.metadata[0x391d + 21 ..][0..15], &[_]u8{ 0x21, 0x21, 63, 63, 0xf3, 0xf3, 0x77, 0x77, 0, 0, 0x80, 10, 0, 0, 1 });
    macro.event(0, 0, &.{ 49, 1, 0, 0, 0, 0 });
    const stepped = try macro.source();
    defer stepped.deinit(std.testing.allocator);
    var macro_chip: TestChip = .{};
    _ = stepped.step(macro_chip.chip());
    try std.testing.expectEqual(@as(u8, 0xbb), macro_chip.registers[0xa3]);
    _ = stepped.step(macro_chip.chip());
    try std.testing.expectEqual(@as(u8, 0x61), macro_chip.registers[0xa3]);
}

test "a2m ZF0 silences the note until an instrument number reloads it" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 130] = 0x02;
    module.metadata[0x1128a6] = 0x10;
    module.event(0, 0, &.{ 49, 1, 0, 0, 0, 0 });
    module.event(1, 0, &.{ 0, 0, 35, 0xf0, 0, 0 });
    module.event(2, 0, &.{ 51, 0, 0, 0, 0, 0 });
    module.event(3, 0, &.{ 49, 1, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    for (0..2) |_| _ = source.step(chip.chip());
    for ([_]u16{ 0x48, 0x4b }) |reg| try std.testing.expectEqual(@as(u8, 63), chip.registers[reg]);
    for ([_]u16{ 0x68, 0x6b, 0x88, 0x8b }) |reg| try std.testing.expectEqual(@as(u8, 0xff), chip.registers[reg]);
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0xb3] & 0x20);
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0xb3] & 0x20);
    _ = source.step(chip.chip());
    try std.testing.expect(chip.registers[0xb3] & 0x20 != 0);
    try std.testing.expectEqual(@as(u8, 0xf3), chip.registers[0x6b]);
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0x4b]);
}

test "a2m fm macro steps with zero duration take a sub-tick and change nothing" {
    var module = try TestModule.init(11);
    defer module.deinit();
    const record = [_]u8{ 0x21, 0x21, 63, 63, 0xe2, 0xe2, 0x77, 0x77, 0, 0, 0, 0, 0, 0, 1 };
    module.metadata[0x391d] = 3;
    @memcpy(module.metadata[0x391d + 6 ..][0..15], &record);
    @memcpy(module.metadata[0x391d + 36 ..][0..15], &record);
    module.event(0, 0, &.{ 49, 1, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0xe2), chip.registers[0x6b]);
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 2), source.channelState().?.slots[0].fmreg_pos);
    try std.testing.expectEqual(@as(u8, 0xe2), chip.registers[0x6b]);
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0x4b]);
}

test "a2m notes without an instrument number keep the current volume" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.event(0, 0, &.{ 49, 1, 12, 32, 0, 0 });
    module.event(1, 0, &.{ 51, 0, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    for (0..2) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 32), source.channelState().?.slots[0].vol_car);
    try std.testing.expectEqual(@as(u8, 31), chip.registers[0x4b]);
}

test "a2m vibrato and tremolo restart their phase after a row without them" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 129] = 6;
    module.event(0, 0, &.{ 49, 1, 4, 0x68, 22, 0x68 });
    module.event(2, 0, &.{ 0, 0, 4, 0x68, 22, 0x68 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    _ = source.step(chip.chip());
    const first = [_]u8{ chip.registers[0xa3], chip.registers[0xb3], chip.registers[0x4b] };
    for (0..12) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(first, [_]u8{ chip.registers[0xa3], chip.registers[0xb3], chip.registers[0x4b] });
}

test "a2m downward slides and vibrato stop at C-0" {
    const Case = struct { cell: [6]u8, steps: usize };
    for ([_]Case{
        .{ .cell = .{ 13, 1, 2, 0xff, 0, 0 }, .steps = 3 },
        .{ .cell = .{ 1, 1, 4, 0xf8, 0, 0 }, .steps = 1 },
    }) |case| {
        var module = try TestModule.init(11);
        defer module.deinit();
        module.metadata[0x11281d + 129] = 6;
        module.event(0, 0, &case.cell);
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        var chip: TestChip = .{};
        for (0..case.steps) |_| _ = source.step(chip.chip());
        try std.testing.expectEqual(@as(u8, 0x57), chip.registers[0xa3]);
        try std.testing.expectEqual(@as(u8, 0x21), chip.registers[0xb3]);
    }

    var tuned = try TestModule.init(11);
    defer tuned.deinit();
    tuned.metadata[0x2b2b + 12] = @bitCast(@as(i8, -10));
    tuned.event(0, 0, &.{ 1, 1, 0, 0, 0, 0 });
    const source = try tuned.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0x4d), chip.registers[0xa3]);
}

test "a2m keeps the macro key-off loop only across ZF0's reload" {
    for ([_]bool{ true, false }) |release| {
        var module = try TestModule.init(11);
        defer module.deinit();
        if (release) module.event(0, 0, &.{ 49, 1, 35, 0xe1, 0, 0 }) else module.event(0, 0, &.{ 0, 0, 35, 0xe1, 0, 0 });
        if (release) module.event(1, 0, &.{ 0, 0, 35, 0xf0, 0, 0 });
        module.event(2, 0, &.{ 49, 1, 0, 0, 0, 0 });
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        for (0..3) |_| _ = source.step(fmt.noop_chip);
        const state: *Source = @ptrCast(@alignCast(source.ptr));
        try std.testing.expectEqual(release, state.tracks[0].macro_keyoff_loop);
    }
}

test "a2m notes repeating the current instrument keep the patch and panning set by effects" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.event(0, 0, &.{ 49, 1, 35, 0xb1, 19, 0x21 });
    module.event(1, 0, &.{ 51, 1, 12, 32, 0, 0 });
    module.event(2, 0, &.{ 49, 1, 0, 0, 0, 0 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    for (0..2) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0x10), chip.registers[0xc3]);
    try std.testing.expectEqual(@as(u8, 1), chip.registers[0xe8]);
    try std.testing.expectEqual(@as(u8, 2), chip.registers[0xeb]);
    try std.testing.expectEqual(@as(u8, 31), chip.registers[0x4b]);
    _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0x10), chip.registers[0xc3]);
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0x4b]);
    try std.testing.expectEqual(@as(u8, 1), source.channelState().?.slots[0].panning);
}

test "a2m delayed notes keep the volume set on their row" {
    var module = try TestModule.init(11);
    defer module.deinit();
    module.metadata[0x11281d + 129] = 6;
    module.event(0, 0, &.{ 49, 1, 36, 0x22, 12, 32 });
    const source = try module.source();
    defer source.deinit(std.testing.allocator);
    var chip: TestChip = .{};
    for (0..2) |_| _ = source.step(chip.chip());
    try std.testing.expectEqual(@as(u8, 0), chip.registers[0xb3] & 0x20);
    _ = source.step(chip.chip());
    try std.testing.expect(chip.registers[0xb3] & 0x20 != 0);
    try std.testing.expectEqual(@as(u8, 31), chip.registers[0x4b]);
    try std.testing.expectEqual(@as(u8, 32), source.channelState().?.slots[0].vol_car);
}

test "a2m arpeggio continues its cycle across consecutive arpeggio rows" {
    const Case = struct { cells: [2][6]u8, fnum: [10]u8 };
    for ([_]Case{
        .{ .cells = .{ .{ 49, 1, 0, 0x47, 0, 0 }, .{ 0, 0, 0, 0x47, 0, 0 } }, .fnum = .{ 0x57, 0xb0, 0x02, 0x57, 0xb0, 0x02, 0x57, 0xb0, 0x02, 0x57 } },
        .{ .cells = .{ .{ 49, 1, 0, 0x47, 0, 0 }, .{ 0, 0, 24, 0x01, 0, 0 } }, .fnum = .{ 0x57, 0xb0, 0x02, 0x57, 0xb0, 0xb0, 0x02, 0x57, 0xb0, 0x02 } },
        .{ .cells = .{ .{ 49, 1, 42, 0x47, 0, 0 }, .{ 0, 0, 42, 0x47, 0, 0 } }, .fnum = .{ 0x57, 0x57, 0x57, 0x57, 0xb0, 0xb0, 0xb0, 0xb0, 0x02, 0x02 } },
    }) |case| {
        var module = try TestModule.init(11);
        defer module.deinit();
        module.metadata[0x11281d + 129] = 5;
        for (case.cells, 0..) |cell, row| module.event(row, 0, &cell);
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        var chip: TestChip = .{};
        for (case.fnum) |expected| {
            _ = source.step(chip.chip());
            try std.testing.expectEqual(expected, chip.registers[0xa3]);
        }
    }

    const waveform = [_]u8{ 0, 0, 19, 0, 0, 0 };
    const Gap = struct { between: [2][6]u8, fnum: [5]u8 };
    for ([_]Gap{
        .{ .between = @splat(@splat(0)), .fnum = .{ 0xb0, 0x02, 0x57, 0xb0, 0x02 } },
        .{ .between = .{ @splat(0), waveform }, .fnum = .{ 0xb0, 0x02, 0x57, 0xb0, 0x02 } },
        .{ .between = .{ waveform, @splat(0) }, .fnum = .{ 0x57, 0xb0, 0x02, 0x57, 0xb0 } },
    }) |case| {
        var gap = try TestModule.init(11);
        defer gap.deinit();
        gap.metadata[0x11281d + 129] = 5;
        gap.event(0, 0, &.{ 49, 1, 0, 0x47, 0, 0 });
        for (case.between, 1..) |cell, row| gap.event(row, 0, &cell);
        gap.event(3, 0, &.{ 0, 0, 0, 0x47, 0, 0 });
        const source = try gap.source();
        defer source.deinit(std.testing.allocator);
        var chip: TestChip = .{};
        for (0..15) |_| _ = source.step(chip.chip());
        for (case.fnum) |expected| {
            _ = source.step(chip.chip());
            try std.testing.expectEqual(expected, chip.registers[0xa3]);
        }
    }
}

test "a2m zero parameters reuse only the last continuing effect of the same family" {
    const Case = struct { cells: [3][6]u8, fnum: u8, car: u8 };
    for ([_]Case{
        .{ .cells = .{ .{ 49, 1, 5, 0x02, 0, 0 }, .{ 51, 0, 3, 0x10, 0, 0 }, .{ 0, 0, 5, 0, 0, 0 } }, .fnum = 0x67, .car = 61 },
        .{ .cells = .{ .{ 49, 1, 5, 0x02, 0, 0 }, .{ 0, 0, 5, 0, 0, 0 }, @splat(0) }, .fnum = 0x57, .car = 59 },
        .{ .cells = .{ .{ 49, 1, 4, 0x83, 0, 0 }, .{ 0, 0, 8, 0x02, 0, 0 }, .{ 0, 0, 4, 0, 0, 0 } }, .fnum = 0xad, .car = 63 },
        .{ .cells = .{ .{ 49, 1, 43, 0x83, 0, 0 }, .{ 0, 0, 4, 0, 0, 0 }, @splat(0) }, .fnum = 0xaa, .car = 63 },
    }) |case| {
        var module = try TestModule.init(11);
        defer module.deinit();
        for (case.cells, 0..) |cell, row| module.event(row, 0, &cell);
        const source = try module.source();
        defer source.deinit(std.testing.allocator);
        var chip: TestChip = .{};
        for (case.cells) |_| _ = source.step(chip.chip());
        try std.testing.expectEqual(case.fnum, chip.registers[0xa3]);
        try std.testing.expectEqual(case.car, source.channelState().?.slots[0].vol_car);
    }
}
