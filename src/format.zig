//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub const view = @import("view.zig");

pub const max_input_bytes: usize = 16 * 1024 * 1024;

pub const tick_rates = [_]u32{ 280, 560, 700 };

pub const TrackInfo = struct {
    title: ?[]const u8 = null,
    title_embedded: bool = false,
    artist: ?[]const u8 = null,
    game: ?[]const u8 = null,
    system: ?[]const u8 = null,
    format_name: []const u8,
    visualizer: []const u8 = "",
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

pub const OperatorParams = view.OperatorParams;

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

pub const hsc_columns = [_]view.ColumnId{ .note, .effect };
pub const hsc_cell_template = view.CellTemplate{ .width = 8, .note_w = 3, .fx_w = 2 };

pub const MusicSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Set by `load` for decoders that cannot derive a length from the file.
    duration_override: ?u64 = null,
    visualizer: []const u8 = "",

    pub fn init(ptr: anytype, visualizer: []const u8) MusicSource {
        const pointer = @typeInfo(@TypeOf(ptr)).pointer;
        comptime {
            if (pointer.size != .one or pointer.attrs.@"const") {
                @compileError("MusicSource.init requires a mutable single-item pointer");
            }
        }
        const T = pointer.child;
        return .{ .ptr = ptr, .vtable = &SourceAdapter(T).vtable, .visualizer = visualizer };
    }

    pub const VTable = struct {
        step: *const fn (ptr: *anyopaque, chip: Chip) StepResult,
        branch: ?*const fn (ptr: *anyopaque, label: u16, chip: Chip) bool = null,
        renderPcm: ?*const fn (ptr: *anyopaque, stereo: []i32) void = null,
        pcmState: ?*const fn (ptr: *anyopaque) view.PcmState = null,
        info: *const fn (ptr: *anyopaque) TrackInfo,
        deinit: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) void,
        patternView: ?*const fn (ptr: *anyopaque) view.PatternView = null,
        orderView: ?*const fn (ptr: *anyopaque) view.OrderView = null,
        instrumentBank: ?*const fn (ptr: *anyopaque) view.InstrumentBank = null,
        sequenceView: ?*const fn (ptr: *anyopaque) view.SequenceView = null,
        dumpView: ?*const fn (ptr: *anyopaque) view.DumpView = null,
        playhead: ?*const fn (ptr: *anyopaque) view.Playhead = null,
        sequenceState: ?*const fn (ptr: *anyopaque) view.SequenceStateBank = null,
        channelState: ?*const fn (ptr: *anyopaque) view.ChannelStateBank = null,
        patternCursors: ?*const fn (ptr: *anyopaque) view.PatternCursorBank = null,
        getTickRate: ?*const fn (ptr: *anyopaque) u32 = null,
        setTickRate: ?*const fn (ptr: *anyopaque, hz: u32) void = null,
        durationFrames: ?*const fn (ptr: *anyopaque) u64 = null,
        selectArchiveTrack: ?*const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            index: u32,
            chip: Chip,
        ) anyerror!void = null,
    };

    pub fn step(self: MusicSource, chip: Chip) StepResult {
        return self.vtable.step(self.ptr, chip);
    }

    pub fn branch(self: MusicSource, label: u16, chip: Chip) bool {
        const f = self.vtable.branch orelse return false;
        return f(self.ptr, label, chip);
    }

    pub fn renderPcm(self: MusicSource, stereo: []i32) void {
        @memset(stereo, 0);
        if (self.vtable.renderPcm) |render| render(self.ptr, stereo);
    }

    pub fn pcmState(self: MusicSource) view.PcmState {
        const get = self.vtable.pcmState orelse return .{};
        return get(self.ptr);
    }

    pub fn patternCursors(self: MusicSource) view.PatternCursorBank {
        const get = self.vtable.patternCursors orelse return .{};
        return get(self.ptr);
    }

    pub fn info(self: MusicSource) TrackInfo {
        var track = self.vtable.info(self.ptr);
        track.visualizer = self.visualizer;
        return track;
    }

    pub fn deinit(self: MusicSource, gpa: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }

    pub fn views(self: MusicSource) view.SourceViews {
        return .{
            .pattern = if (self.vtable.patternView) |f| f(self.ptr) else null,
            .order = if (self.vtable.orderView) |f| f(self.ptr) else null,
            .instruments = if (self.vtable.instrumentBank) |f| f(self.ptr) else null,
            .sequence = if (self.vtable.sequenceView) |f| f(self.ptr) else null,
            .dump = if (self.vtable.dumpView) |f| f(self.ptr) else null,
        };
    }

    pub fn playhead(self: MusicSource) ?view.Playhead {
        const f = self.vtable.playhead orelse return null;
        return f(self.ptr);
    }

    pub fn sequenceState(self: MusicSource) ?view.SequenceStateBank {
        const f = self.vtable.sequenceState orelse return null;
        return f(self.ptr);
    }

    pub fn channelState(self: MusicSource) ?view.ChannelStateBank {
        const f = self.vtable.channelState orelse return null;
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

    pub fn selectArchiveTrack(
        self: MusicSource,
        gpa: std.mem.Allocator,
        index: u32,
        chip: Chip,
    ) !bool {
        const f = self.vtable.selectArchiveTrack orelse return false;
        try f(self.ptr, gpa, index, chip);
        return true;
    }

    pub fn cycleTickRate(self: MusicSource) ?u32 {
        if (self.vtable.getTickRate == null or self.vtable.setTickRate == null) return null;
        const cur = self.getTickRate().?;
        const idx = std.mem.findScalar(u32, &tick_rates, cur) orelse 0;
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

        fn branch(ptr: *anyopaque, label: u16, chip: Chip) bool {
            return T.branch(cast(ptr), label, chip);
        }

        fn renderPcm(ptr: *anyopaque, stereo: []i32) void {
            T.renderPcm(cast(ptr), stereo);
        }

        fn pcmState(ptr: *anyopaque) view.PcmState {
            return T.pcmState(cast(ptr));
        }

        fn patternCursors(ptr: *anyopaque) view.PatternCursorBank {
            return T.patternCursors(cast(ptr));
        }

        fn info(ptr: *anyopaque) TrackInfo {
            return T.info(cast(ptr));
        }

        fn deinit(ptr: *anyopaque, gpa: std.mem.Allocator) void {
            T.deinit(cast(ptr), gpa);
        }

        fn patternView(ptr: *anyopaque) view.PatternView {
            return T.patternView(cast(ptr));
        }

        fn orderView(ptr: *anyopaque) view.OrderView {
            return T.orderView(cast(ptr));
        }

        fn instrumentBank(ptr: *anyopaque) view.InstrumentBank {
            return T.instrumentBank(cast(ptr));
        }

        fn sequenceView(ptr: *anyopaque) view.SequenceView {
            return T.sequenceView(cast(ptr));
        }

        fn dumpView(ptr: *anyopaque) view.DumpView {
            return T.dumpView(cast(ptr));
        }

        fn playheadFn(ptr: *anyopaque) view.Playhead {
            return T.playhead(cast(ptr));
        }

        fn sequenceStateFn(ptr: *anyopaque) view.SequenceStateBank {
            return T.sequenceState(cast(ptr));
        }

        fn channelStateFn(ptr: *anyopaque) view.ChannelStateBank {
            return T.channelState(cast(ptr));
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

        fn selectArchiveTrack(
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            index: u32,
            chip: Chip,
        ) anyerror!void {
            return T.selectArchiveTrack(cast(ptr), gpa, index, chip);
        }

        const vtable = MusicSource.VTable{
            .step = step,
            .branch = if (@hasDecl(T, "branch")) branch else null,
            .renderPcm = if (@hasDecl(T, "renderPcm")) renderPcm else null,
            .pcmState = if (@hasDecl(T, "pcmState")) pcmState else null,
            .patternCursors = if (@hasDecl(T, "patternCursors")) patternCursors else null,
            .info = info,
            .deinit = deinit,
            .patternView = if (@hasDecl(T, "patternView")) patternView else null,
            .orderView = if (@hasDecl(T, "orderView")) orderView else null,
            .instrumentBank = if (@hasDecl(T, "instrumentBank")) instrumentBank else null,
            .sequenceView = if (@hasDecl(T, "sequenceView")) sequenceView else null,
            .dumpView = if (@hasDecl(T, "dumpView")) dumpView else null,
            .playhead = if (@hasDecl(T, "playhead")) playheadFn else null,
            .sequenceState = if (@hasDecl(T, "sequenceState")) sequenceStateFn else null,
            .channelState = if (@hasDecl(T, "channelState")) channelStateFn else null,
            .getTickRate = if (@hasDecl(T, "getTickRate")) getTickRate else null,
            .setTickRate = if (@hasDecl(T, "setTickRate")) setTickRate else null,
            .durationFrames = if (@hasDecl(T, "durationFrames")) durationFrames else null,
            .selectArchiveTrack = if (@hasDecl(T, "selectArchiveTrack")) selectArchiveTrack else null,
        };
    };
}

pub const Chip = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeReg: *const fn (ptr: *anyopaque, reg: u16, val: u8) void,
        flush: *const fn (ptr: *anyopaque) void,
        traceReg: ?*const fn (ptr: *anyopaque, reg: u16, val: u8) void = null,
    };

    pub fn writeReg(self: Chip, reg: u16, val: u8) void {
        self.vtable.writeReg(self.ptr, reg, val);
    }

    pub fn flush(self: Chip) void {
        self.vtable.flush(self.ptr);
    }

    pub fn traceReg(self: Chip, reg: u16, val: u8) void {
        if (self.vtable.traceReg) |trace| trace(self.ptr, reg, val);
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
/// bytes in `sibling` came from `CompanionPaths.sibling_alt` instead.
pub const Companions = struct {
    sibling: ?[]const u8 = null,
    sibling2: ?[]const u8 = null,
    sibling_is_alt: bool = false,
    resources: []const Resource = &.{},
};

pub const Resource = struct {
    name: []const u8,
    data: []const u8,
};

pub const ResourceRequest = struct {
    name: []const u8,
    paths: [][]u8,
    required: bool = true,

    pub fn init(gpa: std.mem.Allocator, path: []const u8, name: []const u8, candidates: []const []const u8) !ResourceRequest {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |p| gpa.free(p);
            paths.deinit(gpa);
        }
        for (candidates) |candidate| {
            const joined = try joinDir(gpa, dirnameOf(path), candidate);
            errdefer gpa.free(joined);
            try paths.append(gpa, joined);
        }
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        return .{ .name = owned_name, .paths = try paths.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: ResourceRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.paths) |path| gpa.free(path);
        gpa.free(self.paths);
    }
};

/// Paths a format wants fetched alongside the main file. One resolver returns
/// this struct, so a later archive format can fill the slots it needs without
/// new `Format` function-pointer fields.
pub const CompanionPaths = struct {
    sibling: ?[]u8 = null,
    sibling_alt: ?[]u8 = null,
    sibling2: ?[]u8 = null,

    pub fn deinit(self: CompanionPaths, gpa: std.mem.Allocator) void {
        if (self.sibling) |s| gpa.free(s);
        if (self.sibling_alt) |s| gpa.free(s);
        if (self.sibling2) |s| gpa.free(s);
    }
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
    resources: []const Resource = &.{},

    pub fn resource(self: LoadContext, name: []const u8) ?[]const u8 {
        for (self.resources) |res| if (std.mem.eql(u8, res.name, name)) return res.data;
        return null;
    }
};

pub const Format = struct {
    name: []const u8,
    extensions: []const []const u8,
    visualizer: []const u8,
    view_caps: view.ViewCaps = .{},
    matches_path: ?*const fn (path: []const u8) bool = null,
    label_for_path: ?*const fn (path: []const u8) []const u8 = null,
    companions: ?*const fn (gpa: std.mem.Allocator, path: []const u8) anyerror!CompanionPaths = null,
    resource_requests: ?*const fn (gpa: std.mem.Allocator, path: []const u8, data: []const u8) anyerror![]ResourceRequest = null,
    /// Input and context slices are borrowed for the call. Return null to
    /// decline the input, an error after claiming it, or an owned source.
    load: *const fn (
        gpa: std.mem.Allocator,
        data: []const u8,
        ctx: LoadContext,
    ) anyerror!?MusicSource,

    pub fn init(comptime T: type) Format {
        comptime {
            if (!@hasDecl(T, "format_name")) @compileError(@typeName(T) ++ " must provide format_name");
            if (!@hasDecl(T, "extensions")) @compileError(@typeName(T) ++ " must provide extensions");
            if (!@hasDecl(T, "visualizer_name")) @compileError(@typeName(T) ++ " must provide visualizer_name");
            if (!@hasDecl(T, "view_caps")) @compileError(@typeName(T) ++ " must provide view_caps");
            if (!@hasDecl(T, "load")) @compileError(@typeName(T) ++ " must provide load");
        }
        return .{
            .name = T.format_name,
            .extensions = T.extensions,
            .visualizer = T.visualizer_name,
            .view_caps = T.view_caps,
            .matches_path = if (@hasDecl(T, "matchesPath")) T.matchesPath else null,
            .label_for_path = if (@hasDecl(T, "labelForPath")) T.labelForPath else null,
            .companions = if (@hasDecl(T, "companions")) T.companions else null,
            .resource_requests = if (@hasDecl(T, "resourceRequests")) T.resourceRequests else null,
            .load = T.load,
        };
    }
};

pub const formats = @import("registry.zig").formats;

pub fn extensionOf(path: []const u8) []const u8 {
    const base = basenameOf(path);
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return base[base.len..];
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
pub const basenameOf = std.Io.Dir.path.basenameWindows;

pub fn stemOf(name: []const u8) []const u8 {
    const ext = extensionOf(name);
    if (ext.len == name.len) return name;
    return name[0 .. name.len - ext.len];
}

pub fn dirnameOf(path: []const u8) []const u8 {
    return std.Io.Dir.path.dirnameWindows(path) orelse ".";
}

pub fn isWindowsDriveRoot(path: []const u8) bool {
    if (path.len < 2 or path[1] != ':') return false;
    if (path.len == 2) return true;
    if (path.len == 3 and (path[2] == '\\' or path[2] == '/')) return true;
    return false;
}

pub fn joinDir(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0 or (dir.len == 1 and dir[0] == '.')) return try gpa.dupe(u8, name);
    const sep: u8 = if (std.mem.findScalar(u8, dir, '\\') != null or (dir.len >= 2 and dir[1] == ':'))
        '\\'
    else
        '/';
    if (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\') {
        return try gpa.print("{s}{s}", .{ dir, name });
    }
    return try gpa.print("{s}{c}{s}", .{ dir, sep, name });
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

pub fn measureByStepping(src: MusicSource, chip: Chip, sample_rate: u32) ?u64 {
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
        var src = (try f.load(gpa, data, fctx)) orelse continue;
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

pub fn resolveCompanions(gpa: std.mem.Allocator, path: []const u8) !CompanionPaths {
    for (formats) |f| {
        if (!claims(f, path)) continue;
        const resolve = f.companions orelse return .{};
        return resolve(gpa, path);
    }
    return .{};
}

pub fn resourceRequests(gpa: std.mem.Allocator, path: []const u8, data: []const u8) ![]ResourceRequest {
    var requests: std.ArrayList(ResourceRequest) = .empty;
    errdefer {
        for (requests.items) |request| request.deinit(gpa);
        requests.deinit(gpa);
    }
    for (formats) |f| {
        if (!claims(f, path)) continue;
        const discover = f.resource_requests orelse continue;
        const found = try discover(gpa, path, data);
        defer gpa.free(found);
        requests.appendSlice(gpa, found) catch |err| {
            for (found) |request| request.deinit(gpa);
            return err;
        };
    }
    return requests.toOwnedSlice(gpa);
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
    const Counting = struct {
        inner: Chip,
        writes: usize = 0,

        fn writeReg(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.writes += 1;
            self.inner.writeReg(reg, val);
        }

        fn flush(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.flush();
        }

        fn traceReg(ptr: *anyopaque, reg: u16, val: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.traceReg(reg, val);
        }
    };
    var counting: Counting = .{ .inner = chip };
    const counted: Chip = .{ .ptr = &counting, .vtable = &.{ .writeReg = Counting.writeReg, .flush = Counting.flush, .traceReg = Counting.traceReg } };
    var out = DrainResult{};
    var steps: usize = 0;
    while (!out.done and steps < max_steps) : (steps += 1) {
        const r = src.step(counted);
        out.done = r.done;
        out.frames += r.frames;
    }
    out.writes = counting.writes;
    return out;
}

// --- tests -------------------------------------------------------------------

test "companions belong to the first format that claims a path" {
    const gpa = std.testing.allocator;
    const paths = try resolveCompanions(gpa, "AUDIO.RAD");
    defer paths.deinit(gpa);
    try std.testing.expect(paths.sibling == null and paths.sibling2 == null);
    const audiot = try resolveCompanions(gpa, "AUDIOT.WL6");
    defer audiot.deinit(gpa);
    try std.testing.expect(audiot.sibling != null);
}

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
