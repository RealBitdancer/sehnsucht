//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const max_input_bytes: usize = 16 * 1024 * 1024;

pub const tick_rates = [_]u32{ 280, 560, 700 };

pub const TrackInfo = struct {
    title: ?[]const u8 = null,
    title_embedded: bool = false,
    artist: ?[]const u8 = null,
    game: ?[]const u8 = null,
    system: ?[]const u8 = null,
    format_name: []const u8,
    visualizer: []const u8,
    opl3: bool = false,
    loop: bool = false,
    rate_adjustable: bool = false,
    archive_track_count: u32 = 0,
    archive_track_index: u32 = 0,
};

pub const StepResult = struct {
    frames: u64,
    done: bool = false,
};

pub const TrackerPos = packed struct(u64) {
    order_pos: u8 = 0,
    row: u8 = 0,
    pattern: u8 = 0,
    speed: u8 = 0,
    last_instrument: u8 = 0,
    _reserved: u24 = 0,
};

pub const TrackerCell = struct {
    pub const Kind = enum { empty, note, note_off, set_instrument, effect_only };
    kind: Kind,
    semitone: u8 = 0,
    octave: u8 = 0,
    arg: u8 = 0,
};

pub const OperatorParams = struct {
    tremolo: bool,
    vibrato: bool,
    sustaining: bool,
    ksr: bool,
    mult: u4,
    ksl: u2,
    level: u6,
    attack: u4,
    decay: u4,
    sustain: u4,
    release: u4,
    wave: u3,
};

pub const InstrumentInfo = struct {
    modulator: OperatorParams,
    carrier: OperatorParams,
    feedback: u3,
    additive: bool,
};

pub fn operatorParams(char: u8, level: u8, ad: u8, sr: u8, wave: u8) OperatorParams {
    return .{
        .tremolo = char & 0x80 != 0,
        .vibrato = char & 0x40 != 0,
        .sustaining = char & 0x20 != 0,
        .ksr = char & 0x10 != 0,
        .mult = @truncate(char & 0x0f),
        .ksl = @truncate(level >> 6),
        .level = @truncate(level & 0x3f),
        .attack = @truncate(ad >> 4),
        .decay = @truncate(ad & 0x0f),
        .sustain = @truncate(sr >> 4),
        .release = @truncate(sr & 0x0f),
        .wave = @truncate(wave & 0x07),
    };
}

pub const TrackerView = struct {
    ctx: *anyopaque,
    channels: u8,
    rows_per_pattern: u8,
    num_patterns: u8,
    order: []const u8,
    cell: *const fn (ctx: *anyopaque, pattern: u8, row: u8, chan: u8) TrackerCell,
    instrument: *const fn (ctx: *anyopaque, index: u8) InstrumentInfo,
};

pub const MusicSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Set by `load` for decoders that cannot derive a length from the file.
    duration_override: ?u64 = null,

    pub fn init(ptr: anytype) MusicSource {
        const pointer = @typeInfo(@TypeOf(ptr)).pointer;
        comptime {
            if (pointer.size != .one or pointer.is_const) {
                @compileError("MusicSource.init requires a mutable single-item pointer");
            }
        }
        const T = pointer.child;
        return .{ .ptr = ptr, .vtable = &SourceAdapter(T).vtable };
    }

    pub const VTable = struct {
        step: *const fn (ptr: *anyopaque, chip: Chip) StepResult,
        info: *const fn (ptr: *anyopaque) TrackInfo,
        deinit: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) void,
        pos: ?*const fn (ptr: *anyopaque) TrackerPos = null,
        trackerView: ?*const fn (ptr: *anyopaque) TrackerView = null,
        getTickRate: ?*const fn (ptr: *anyopaque) u32 = null,
        setTickRate: ?*const fn (ptr: *anyopaque, hz: u32) void = null,
        durationFrames: ?*const fn (ptr: *anyopaque) u64 = null,
    };

    pub fn step(self: MusicSource, chip: Chip) StepResult {
        return self.vtable.step(self.ptr, chip);
    }

    pub fn info(self: MusicSource) TrackInfo {
        return self.vtable.info(self.ptr);
    }

    pub fn deinit(self: MusicSource, gpa: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }

    pub fn pos(self: MusicSource) ?TrackerPos {
        const f = self.vtable.pos orelse return null;
        return f(self.ptr);
    }

    pub fn trackerView(self: MusicSource) ?TrackerView {
        const f = self.vtable.trackerView orelse return null;
        return f(self.ptr);
    }

    pub fn getTickRate(self: MusicSource) ?u32 {
        const f = self.vtable.getTickRate orelse return null;
        return f(self.ptr);
    }

    pub fn setTickRate(self: MusicSource, hz: u32) void {
        const f = self.vtable.setTickRate orelse return;
        f(self.ptr, hz);
    }

    pub fn durationFrames(self: MusicSource) ?u64 {
        if (self.duration_override) |frames| return frames;
        const f = self.vtable.durationFrames orelse return null;
        const frames = f(self.ptr);
        return if (frames == 0) null else frames;
    }

    pub fn cycleTickRate(self: MusicSource) ?u32 {
        if (self.vtable.getTickRate == null or self.vtable.setTickRate == null) return null;
        const cur = self.getTickRate().?;
        const idx = std.mem.indexOfScalar(u32, &tick_rates, cur) orelse 0;
        const next = tick_rates[(idx + 1) % tick_rates.len];
        self.setTickRate(next);
        return next;
    }
};

fn SourceAdapter(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "step")) @compileError(@typeName(T) ++ " must provide step");
        if (!@hasDecl(T, "info")) @compileError(@typeName(T) ++ " must provide info");
        if (!@hasDecl(T, "deinit")) @compileError(@typeName(T) ++ " must provide deinit");
    }
    return struct {
        fn cast(ptr: *anyopaque) *T {
            return @ptrCast(@alignCast(ptr));
        }

        fn step(ptr: *anyopaque, chip: Chip) StepResult {
            return T.step(cast(ptr), chip);
        }

        fn info(ptr: *anyopaque) TrackInfo {
            return T.info(cast(ptr));
        }

        fn deinit(ptr: *anyopaque, gpa: std.mem.Allocator) void {
            T.deinit(cast(ptr), gpa);
        }

        fn pos(ptr: *anyopaque) TrackerPos {
            return T.pos(cast(ptr));
        }

        fn trackerView(ptr: *anyopaque) TrackerView {
            return T.trackerView(cast(ptr));
        }

        fn getTickRate(ptr: *anyopaque) u32 {
            return T.getTickRate(cast(ptr));
        }

        fn setTickRate(ptr: *anyopaque, hz: u32) void {
            T.setTickRate(cast(ptr), hz);
        }

        fn durationFrames(ptr: *anyopaque) u64 {
            return T.durationFrames(cast(ptr));
        }

        const vtable = MusicSource.VTable{
            .step = step,
            .info = info,
            .deinit = deinit,
            .pos = if (@hasDecl(T, "pos")) pos else null,
            .trackerView = if (@hasDecl(T, "trackerView")) trackerView else null,
            .getTickRate = if (@hasDecl(T, "getTickRate")) getTickRate else null,
            .setTickRate = if (@hasDecl(T, "setTickRate")) setTickRate else null,
            .durationFrames = if (@hasDecl(T, "durationFrames")) durationFrames else null,
        };
    };
}

pub const Chip = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeReg: *const fn (ptr: *anyopaque, reg: u16, val: u8) void,
        flush: *const fn (ptr: *anyopaque) void,
    };

    pub fn writeReg(self: Chip, reg: u16, val: u8) void {
        self.vtable.writeReg(self.ptr, reg, val);
    }

    pub fn flush(self: Chip) void {
        self.vtable.flush(self.ptr);
    }
};

var noop_chip_ctx: u8 = 0;
fn noopWriteReg(_: *anyopaque, _: u16, _: u8) void {}
fn noopFlush(_: *anyopaque) void {}
const noop_chip_vtable = Chip.VTable{ .writeReg = noopWriteReg, .flush = noopFlush };

/// A chip that discards every write, for stepping a source purely to measure
/// its length: frames depend on the decoder's timing, never on chip state.
pub const noop_chip = Chip{ .ptr = &noop_chip_ctx, .vtable = &noop_chip_vtable };

/// Companion file bytes gathered by the loader before `load` runs.
/// `sibling_is_alt` reports that the primary companion was missing and the
/// bytes in `sibling` came from `sibling_alt_path` instead.
pub const Companions = struct {
    sibling: ?[]const u8 = null,
    sibling2: ?[]const u8 = null,
    sibling_is_alt: bool = false,
};

pub const LoadContext = struct {
    sample_rate: u32,
    chip: Chip,
    tick_rate_hz: u32 = 0,
    track_index: u32 = 0,
    sibling: ?[]const u8 = null,
    sibling2: ?[]const u8 = null,
    sibling_is_alt: bool = false,
    ext: []const u8 = "",
    name: []const u8 = "",
};

pub const Format = struct {
    name: []const u8,
    extensions: []const []const u8,
    visualizer: []const u8,
    matches_path: ?*const fn (path: []const u8) bool = null,
    label_for_path: ?*const fn (path: []const u8) []const u8 = null,
    sibling_path: ?*const fn (gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 = null,
    /// Fallback for `sibling_path`: fetched when the primary companion cannot
    /// be read. `LoadContext.sibling_is_alt` tells the decoder which one won.
    sibling_alt_path: ?*const fn (gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 = null,
    /// A second companion resolved the same way, for formats that need two
    /// side files. Read tolerantly: absence reaches `load` as a null
    /// `LoadContext.sibling2`, and the decoder decides whether that is fatal.
    sibling2_path: ?*const fn (gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 = null,
    /// Input and context slices are borrowed for the call. Return null to
    /// decline the input, an error after claiming it, or an owned source.
    load: *const fn (
        gpa: std.mem.Allocator,
        data: []const u8,
        ctx: LoadContext,
    ) anyerror!?MusicSource,
};

pub const formats = @import("registry.zig").formats;

pub fn extensionOf(path: []const u8) []const u8 {
    const base = basenameOf(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base[base.len..];
    return base[dot..];
}

pub fn hasExtension(path: []const u8, exts: []const []const u8) bool {
    const ext = extensionOf(path);
    for (exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

inline fn claims(f: Format, path: []const u8) bool {
    return hasExtension(path, f.extensions) or
        if (f.matches_path) |matches| matches(path) else false;
}

/// These helpers also run on URLs and on playlist entries authored
/// on another OS, so both `/` and `\` must separate components
/// no matter what the host filesystem thinks.
pub const basenameOf = std.fs.path.basenameWindows;

pub fn stemOf(name: []const u8) []const u8 {
    const ext = extensionOf(name);
    if (ext.len == name.len) return name;
    return name[0 .. name.len - ext.len];
}

pub fn dirnameOf(path: []const u8) []const u8 {
    return std.fs.path.dirnameWindows(path) orelse ".";
}

pub fn isWindowsDriveRoot(path: []const u8) bool {
    if (path.len < 2 or path[1] != ':') return false;
    if (path.len == 2) return true;
    if (path.len == 3 and (path[2] == '\\' or path[2] == '/')) return true;
    return false;
}

pub fn joinDir(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0 or (dir.len == 1 and dir[0] == '.')) return try gpa.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, dir, '\\') != null or (dir.len >= 2 and dir[1] == ':'))
        '\\'
    else
        '/';
    if (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\') {
        return try std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, name });
    }
    return try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ dir, sep, name });
}

pub fn dupeDisplayBasename(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const buf = try gpa.dupe(u8, basenameOf(path));
    errdefer gpa.free(buf);
    const decoded = std.Uri.percentDecodeInPlace(buf);
    return if (decoded.len == buf.len) buf else try gpa.realloc(buf, decoded.len);
}

pub fn readU16Le(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .little);
}

pub fn readU32Le(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .little);
}

pub fn rescale(count: u64, from_rate: u32, to_rate: u32, frac: *u32) u64 {
    const num = count * to_rate + frac.*;
    frac.* = @intCast(num % from_rate);
    return num / from_rate;
}

const measure_frame_cap_secs: u64 = 30 * 60;
const measure_stall_cap: u32 = 1 << 20;
// The probe runs on the UI thread. The frame cap alone still admits tens of
// millions of decoder steps from a file that yields one frame per step, so a
// total step cap keeps a pathological file from pinning the event loop.
// A 30-minute tracker at 700 Hz needs ~1.3M steps; 4M leaves headroom.
// Overrunning it costs only the progress bar, never the track.
const measure_step_cap: u32 = 1 << 22;

fn measureByStepping(src: MusicSource, chip: Chip, sample_rate: u32) ?u64 {
    const frame_cap: u64 = @as(u64, sample_rate) * measure_frame_cap_secs;
    var frames: u64 = 0;
    var stall: u32 = 0;
    var steps: u32 = 0;
    while (frames < frame_cap) {
        const r = src.step(chip);
        if (r.frames == 0) {
            stall += 1;
            if (stall >= measure_stall_cap) return null;
        } else {
            stall = 0;
            frames += r.frames;
        }
        if (r.done) return if (frames == 0) null else frames;
        steps += 1;
        if (steps >= measure_step_cap) return null;
    }
    return null;
}

/// Sources without a native duration are loaded again on `noop_chip` and
/// stepped to their first song boundary. Each load must be independent.
pub fn load(
    gpa: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    ctx: LoadContext,
) !?MusicSource {
    for (formats) |f| {
        if (!claims(f, path)) continue;
        var fctx = ctx;
        fctx.ext = extensionOf(path);
        fctx.name = basenameOf(path);
        const src = (try f.load(gpa, data, fctx)) orelse continue;
        errdefer src.deinit(gpa);
        if (src.durationFrames() != null) return src;

        var measure_ctx = fctx;
        measure_ctx.chip = noop_chip;
        // The real source already loaded. A failed probe costs the progress bar,
        // never the track.
        const probe = (f.load(gpa, data, measure_ctx) catch null) orelse return src;
        const measured = measureByStepping(probe, noop_chip, ctx.sample_rate);
        probe.deinit(gpa);
        var out = src;
        out.duration_override = measured;
        return out;
    }
    return null;
}

pub fn isPlayablePath(path: []const u8) bool {
    for (formats) |f| {
        if (claims(f, path)) return true;
    }
    return false;
}

pub fn companionPath(
    comptime field: []const u8,
    gpa: std.mem.Allocator,
    path: []const u8,
) !?[]u8 {
    for (formats) |f| {
        if (!claims(f, path)) continue;
        const resolve = @field(f, field) orelse return null;
        return resolve(gpa, path);
    }
    return null;
}

pub fn displayLabelForPath(path: []const u8) ?[]const u8 {
    for (formats) |f| {
        if (!claims(f, path)) continue;
        if (f.label_for_path) |l| return l(path);
        return f.name;
    }
    return null;
}

pub const DrainResult = struct {
    frames: u64 = 0,
    writes: usize = 0,
    done: bool = false,
};

pub fn testDrain(src: MusicSource, chip: Chip, max_steps: usize) DrainResult {
    var out = DrainResult{};
    var steps: usize = 0;
    while (!out.done and steps < max_steps) : (steps += 1) {
        const r = src.step(chip);
        out.done = r.done;
        if (r.frames == 0 and !out.done) out.writes += 1 else out.frames += r.frames;
    }
    return out;
}

// --- tests -------------------------------------------------------------------

const PathCase = struct {
    path: []const u8,
    base: []const u8,
    dir: []const u8,
    ext: []const u8,
};

fn expectPathCase(c: PathCase) !void {
    try std.testing.expectEqualStrings(c.base, basenameOf(c.path));
    try std.testing.expectEqualStrings(c.dir, dirnameOf(c.path));
    try std.testing.expectEqualStrings(c.ext, extensionOf(c.path));
}

test "path helpers split on both separators, on paths and on URLs" {
    const cases = [_]PathCase{
        .{ .path = "tune.hsc", .base = "tune.hsc", .dir = ".", .ext = ".hsc" },
        .{ .path = "music/tune.hsc", .base = "tune.hsc", .dir = "music", .ext = ".hsc" },
        .{ .path = "music\\tune.hsc", .base = "tune.hsc", .dir = "music", .ext = ".hsc" },
        .{ .path = "/usr/share/tune.hsc", .base = "tune.hsc", .dir = "/usr/share", .ext = ".hsc" },
        .{ .path = "/tune.hsc", .base = "tune.hsc", .dir = "/", .ext = ".hsc" },
        .{ .path = "C:\\music\\tune.hsc", .base = "tune.hsc", .dir = "C:\\music", .ext = ".hsc" },
        .{ .path = "C:\\tune.hsc", .base = "tune.hsc", .dir = "C:\\", .ext = ".hsc" },
        .{ .path = "game/AUDIOHED", .base = "AUDIOHED", .dir = "game", .ext = "" },
        .{ .path = "game/AUDIOT.WL6", .base = "AUDIOT.WL6", .dir = "game", .ext = ".WL6" },
        .{ .path = "a.b.c", .base = "a.b.c", .dir = ".", .ext = ".c" },
        .{ .path = "dir.x/file", .base = "file", .dir = "dir.x", .ext = "" },
        .{ .path = "", .base = "", .dir = ".", .ext = "" },
    };
    for (cases) |c| try expectPathCase(c);
}

test "path helpers leave URL components intact" {
    const cases = [_]PathCase{
        .{
            .path = "https://modland.com/pub/tune.dro",
            .base = "tune.dro",
            .dir = "https://modland.com/pub",
            .ext = ".dro",
        },
        .{
            .path = "https://modland.com/tune.dro",
            .base = "tune.dro",
            .dir = "https://modland.com",
            .ext = ".dro",
        },
        .{
            .path = "https://modland.com/Ad%20Lib/dune%201.dro",
            .base = "dune%201.dro",
            .dir = "https://modland.com/Ad%20Lib",
            .ext = ".dro",
        },
    };
    for (cases) |c| try expectPathCase(c);
}

test "a leading dot is an extension, not a hidden-file marker" {
    try std.testing.expectEqualStrings(".hsc", extensionOf(".hsc"));
    try std.testing.expectEqualStrings(".hsc", stemOf(".hsc"));
    try std.testing.expectEqualStrings("tune", stemOf("tune.hsc"));
    try std.testing.expectEqualStrings("a.b", stemOf("a.b.c"));
    try std.testing.expect(isPlayablePath(".hsc"));
}

test "UNC and drive-relative edges follow the Windows component rules" {
    try std.testing.expectEqualStrings("tune.hsc", basenameOf("\\\\server\\share\\tune.hsc"));
    try std.testing.expectEqualStrings("\\\\server\\share\\", dirnameOf("\\\\server\\share\\tune.hsc"));
    try std.testing.expectEqualStrings("//server/share/", dirnameOf("//server/share/tune.hsc"));

    try std.testing.expectEqualStrings("tune.hsc", basenameOf("C:tune.hsc"));
    try std.testing.expectEqualStrings("C:", dirnameOf("C:tune.hsc"));

    try std.testing.expectEqualStrings("b", basenameOf("a/b/"));
    try std.testing.expectEqualStrings(".", dirnameOf("C:\\"));
    try std.testing.expectEqualStrings(".", dirnameOf("/"));
}

test "joinDir absorbs the trailing separator a UNC dirname carries" {
    const gpa = std.testing.allocator;
    const joined = try joinDir(gpa, dirnameOf("\\\\server\\share\\AUDIOHED.WL6"), "AUDIOT.WL6");
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("\\\\server\\share\\AUDIOT.WL6", joined);
}
