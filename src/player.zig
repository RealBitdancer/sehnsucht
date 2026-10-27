//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;

const AudioEngine = @import("audioengine.zig").AudioEngine;
const Bridge = @import("bridge.zig").Bridge;
const format = @import("format.zig");
const view = @import("view.zig");
const visualizer = @import("visualizer.zig");

pub const Loaded = struct {
    src: format.MusicSource,
    track: format.TrackInfo,
    views: view.SourceViews,
    display_name: []const u8,
    system: []const u8,
};

fn chipLabel(track: format.TrackInfo) []const u8 {
    if (track.system) |s| {
        for ([_][]const u8{ "Dual OPL2", "OPL3", "OPL2" }) |label| {
            if (std.mem.eql(u8, s, label)) return label;
        }
    }
    return if (track.opl3) "OPL3" else "OPL2";
}

pub fn assembleTrack(
    gpa: std.mem.Allocator,
    engine: *AudioEngine,
    path: []const u8,
    raw: []const u8,
    companions: format.Companions,
    tick_rate_hz: u32,
    track_index: u32,
) !Loaded {
    const src = try engine.load(gpa, path, raw, companions, tick_rate_hz, track_index);
    errdefer src.deinit(gpa);
    const track = src.info();
    const viz = visualizer.find(track.visualizer) orelse return error.UnknownVisualizer;
    const views = src.views();
    if (!view.ViewCaps.subsetOf(viz.requires, views.caps())) {
        return error.MissingVisualizerData;
    }
    return .{
        .src = src,
        .track = track,
        .views = views,
        .display_name = track.title orelse format.basenameOf(path),
        .system = chipLabel(track),
    };
}

pub const TrackInput = struct {
    path: []u8,
    bytes: []u8,
    sibling: ?[]u8 = null,
    sibling2: ?[]u8 = null,
    sibling_is_alt: bool = false,
    resources: []format.Resource = &.{},

    pub fn init(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, from: format.Companions) !TrackInput {
        var input: TrackInput = .{ .path = try gpa.dupe(u8, path), .bytes = &.{} };
        errdefer input.deinit(gpa);
        input.bytes = try gpa.dupe(u8, bytes);
        if (from.sibling) |s| input.sibling = try gpa.dupe(u8, s);
        if (from.sibling2) |s| input.sibling2 = try gpa.dupe(u8, s);
        input.sibling_is_alt = from.sibling_is_alt;
        const resources = try gpa.alloc(format.Resource, from.resources.len);
        var copied: usize = 0;
        errdefer {
            for (resources[0..copied]) |r| {
                gpa.free(r.name);
                gpa.free(r.data);
            }
            gpa.free(resources);
        }
        for (from.resources, resources) |src, *dst| {
            const name = try gpa.dupe(u8, src.name);
            errdefer gpa.free(name);
            dst.* = .{ .name = name, .data = try gpa.dupe(u8, src.data) };
            copied += 1;
        }
        input.resources = resources;
        return input;
    }

    pub fn deinit(self: TrackInput, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.bytes);
        if (self.sibling) |s| gpa.free(s);
        if (self.sibling2) |s| gpa.free(s);
        for (self.resources) |r| {
            gpa.free(r.name);
            gpa.free(r.data);
        }
        gpa.free(self.resources);
    }

    fn companions(self: *const TrackInput) format.Companions {
        return .{
            .sibling = self.sibling,
            .sibling2 = self.sibling2,
            .sibling_is_alt = self.sibling_is_alt,
            .resources = self.resources,
        };
    }
};

pub const Direction = enum(i2) {
    next = 1,
    prev = -1,
};

fn buildOrder(order: []usize, shuffle: bool, current: usize, rng: std.Random) usize {
    for (order, 0..) |*slot, i| slot.* = i;
    if (!shuffle) return if (current < order.len) current else 0;
    if (order.len == 0) return 0;
    rng.shuffle(usize, order);
    const cur_pos = std.mem.findScalar(usize, order, current) orelse 0;
    std.mem.swap(usize, &order[0], &order[cur_pos]);
    return 0;
}

fn reshuffleWrap(order: []usize, rng: std.Random, dir: Direction, current: usize) usize {
    for (order, 0..) |*slot, i| slot.* = i;
    if (order.len < 2) return 0;
    rng.shuffle(usize, order);
    const pos: usize = if (dir == .next) 0 else order.len - 1;
    const other: usize = if (dir == .next) order.len - 1 else 0;
    if (order[pos] == current) std.mem.swap(usize, &order[pos], &order[other]);
    return pos;
}

fn seedRng(io: Io) std.Random.DefaultPrng {
    var seed: [8]u8 = undefined;
    io.random(&seed);
    return .init(std.mem.readInt(u64, &seed, .little));
}

const OwnedPlaylist = struct {
    entries: []const []const u8,
    titles: []const ?[]const u8,
    rates: []const u32,
    themes: []const ?u8,
    name: []const u8,
    order: []usize,
    played: []bool,
    unplayable: []bool,

    fn build(
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        titles: []const ?[]const u8,
        rates: []const u32,
        themes: []const ?u8,
        list_name: []const u8,
    ) !OwnedPlaylist {
        const new_entries = try gpa.alloc([]const u8, paths.len);
        errdefer gpa.free(new_entries);
        var i: usize = 0;
        errdefer for (new_entries[0..i]) |e| gpa.free(e);
        while (i < paths.len) : (i += 1) {
            new_entries[i] = try gpa.dupe(u8, paths[i]);
        }
        const new_titles = try gpa.alloc(?[]const u8, paths.len);
        errdefer gpa.free(new_titles);
        var j: usize = 0;
        errdefer for (new_titles[0..j]) |t| if (t) |s| gpa.free(s);
        while (j < paths.len) : (j += 1) {
            const source: ?[]const u8 = if (j < titles.len) titles[j] else null;
            new_titles[j] = if (source) |t| try gpa.dupe(u8, t) else null;
        }
        const new_rates = try gpa.alloc(u32, paths.len);
        errdefer gpa.free(new_rates);
        for (new_rates, 0..) |*slot, k| {
            slot.* = if (k < rates.len) rates[k] else 0;
        }
        const new_themes = try gpa.alloc(?u8, paths.len);
        errdefer gpa.free(new_themes);
        for (new_themes, 0..) |*slot, k| {
            slot.* = if (k < themes.len) themes[k] else null;
        }
        const new_name: []const u8 = if (list_name.len > 0)
            try gpa.dupe(u8, list_name)
        else
            "";
        errdefer gpa.free(new_name);
        const new_order = try gpa.alloc(usize, paths.len);
        errdefer gpa.free(new_order);
        const new_played = try gpa.alloc(bool, paths.len);
        errdefer gpa.free(new_played);
        const new_unplayable = try gpa.alloc(bool, paths.len);
        @memset(new_played, false);
        @memset(new_unplayable, false);
        return .{
            .entries = new_entries,
            .titles = new_titles,
            .rates = new_rates,
            .themes = new_themes,
            .name = new_name,
            .order = new_order,
            .played = new_played,
            .unplayable = new_unplayable,
        };
    }
};

pub const Player = struct {
    gpa: std.mem.Allocator,
    io: Io,
    engine: *AudioEngine,
    bridge: *Bridge,
    entries: []const []const u8,
    titles: []const ?[]const u8 = &.{},
    rates: []const u32 = &.{},
    themes: []const ?u8 = &.{},
    name: []const u8 = "",
    owns_entries: bool = false,
    index: usize,
    order: []usize = &.{},
    order_pos: usize = 0,
    played: []bool = &.{},
    unplayable: []bool = &.{},
    shuffle: bool = false,
    loop_all: bool = false,
    tick_rate_hz: u32,
    live_rate_hz: u32 = 0,
    track_index: u32,
    src: ?format.MusicSource,
    input: ?TrackInput = null,
    detached_path: ?[]u8 = null,

    pub const Config = struct {
        entries: []const []const u8,
        titles: []const ?[]const u8 = &.{},
        rates: []const u32 = &.{},
        themes: []const ?u8 = &.{},
        name: []const u8 = "",
        tick_rate_hz: u32 = 0,
        track_index: u32 = 0,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        engine: *AudioEngine,
        bridge: *Bridge,
        config: Config,
    ) !Player {
        var self = Player{
            .gpa = gpa,
            .io = io,
            .engine = engine,
            .bridge = bridge,
            .entries = config.entries,
            .titles = config.titles,
            .rates = config.rates,
            .themes = config.themes,
            .name = config.name,
            .index = 0,
            .tick_rate_hz = config.tick_rate_hz,
            .track_index = config.track_index,
            .src = null,
        };
        errdefer self.deinit();
        try self.ensureOrder();
        try self.resetFlags(&self.played);
        try self.resetFlags(&self.unplayable);
        return self;
    }

    pub fn multi(self: *const Player) bool {
        return self.entries.len > 1;
    }

    pub fn isDetached(self: *const Player) bool {
        return self.detached_path != null;
    }

    pub fn clearDetached(self: *Player) void {
        if (self.detached_path) |p| self.gpa.free(p);
        self.detached_path = null;
    }

    fn deinitEntries(self: *Player) void {
        if (!self.owns_entries) return;
        for (self.entries) |e| self.gpa.free(e);
        self.gpa.free(self.entries);
        self.entries = &.{};
        for (self.titles) |t| if (t) |s| self.gpa.free(s);
        self.gpa.free(self.titles);
        self.titles = &.{};
        self.gpa.free(self.rates);
        self.rates = &.{};
        self.gpa.free(self.themes);
        self.themes = &.{};
        self.gpa.free(self.name);
        self.name = "";
        self.owns_entries = false;
    }

    pub fn themeForIndex(self: *const Player, idx: usize) ?u8 {
        return if (idx < self.themes.len) self.themes[idx] else null;
    }

    pub fn rateForIndex(self: *const Player, idx: usize) u32 {
        if (self.live_rate_hz != 0) return self.live_rate_hz;
        if (self.tick_rate_hz != 0) return self.tick_rate_hz;
        if (idx < self.rates.len and self.rates[idx] != 0) return self.rates[idx];
        return 0;
    }

    fn deinitOrder(self: *Player) void {
        self.gpa.free(self.order);
        self.order = &.{};
        self.order_pos = 0;
    }

    fn freeFlags(self: *Player, flags: *[]bool) void {
        self.gpa.free(flags.*);
        flags.* = &.{};
    }

    pub fn deinitSource(self: *Player) void {
        if (self.src) |s| {
            self.engine.source = null;
            s.deinit(self.gpa);
        }
        self.src = null;
        if (self.input) |input| input.deinit(self.gpa);
        self.input = null;
    }

    pub fn keepInput(self: *Player, path: []const u8, bytes: []const u8, from: format.Companions) !void {
        const input = try TrackInput.init(self.gpa, path, bytes, from);
        if (self.input) |old| old.deinit(self.gpa);
        self.input = input;
    }

    /// A rebuilt source is returned and must replace the old one wherever it is shown.
    pub fn seek(self: *Player, frames: u64) !?format.MusicSource {
        const src = self.src orelse return null;
        const input = if (self.input) |*kept| kept else return null;
        const duration = src.durationFrames() orelse return null;
        const target = @min(frames, duration -| 1);
        const was_started = self.engine.started;
        self.engine.stop();
        errdefer if (was_started) self.engine.start() catch {};
        const ended = self.bridge.halt_at_songend.load(.acquire) and self.bridge.loop_count.load(.acquire) > 0;
        const parked = ended and self.bridge.paused.load(.acquire) and !self.engine.park_after_wait;
        const fresh = self.engine.load(self.gpa, input.path, input.bytes, input.companions(), src.getTickRate() orelse 0, self.track_index) catch |err| {
            self.engine.source = src;
            return err;
        };
        errdefer {
            self.engine.source = src;
            fresh.deinit(self.gpa);
        }
        self.engine.source = fresh;
        self.bridge.branch_request.store(std.math.maxInt(u32), .release);
        self.bridge.position_frames.store(0, .release);
        if (ended) self.bridge.loop_count.store(0, .release);
        self.engine.skip(target);
        self.engine.publishState();
        if (parked) self.bridge.paused.store(false, .release);
        if (was_started) try self.engine.start();
        self.src = fresh;
        src.deinit(self.gpa);
        return fresh;
    }

    pub fn retargetArchiveTrack(self: *Player, index: u32) !bool {
        const existing = self.src orelse return false;
        if (existing.vtable.selectArchiveTrack == null) return false;
        self.engine.stop();
        errdefer if (self.src != null) self.engine.start() catch {};
        if (!try self.engine.selectArchiveTrack(self.gpa, index)) {
            try self.engine.start();
            return false;
        }
        const src = self.engine.source.?;
        self.src = src;
        self.track_index = src.info().archive_track_index;
        self.bridge.resetTrackState();
        self.bridge.paused.store(false, .release);
        try self.engine.start();
        return true;
    }

    pub fn deinit(self: *Player) void {
        self.deinitSource();
        self.clearDetached();
        self.deinitEntries();
        self.deinitOrder();
        self.freeFlags(&self.played);
        self.freeFlags(&self.unplayable);
    }

    fn resetFlags(self: *Player, flags: *[]bool) !void {
        if (flags.len != self.entries.len) {
            self.freeFlags(flags);
            if (self.entries.len == 0) return;
            flags.* = try self.gpa.alloc(bool, self.entries.len);
        }
        @memset(flags.*, false);
    }

    pub fn markPlayed(self: *Player, idx: usize) void {
        if (idx < self.played.len) self.played[idx] = true;
    }

    pub fn markUnplayable(self: *Player, idx: usize) void {
        if (idx < self.unplayable.len) self.unplayable[idx] = true;
    }

    pub fn clearUnplayable(self: *Player, idx: usize) void {
        if (idx < self.unplayable.len) self.unplayable[idx] = false;
    }

    fn isUnplayable(self: *const Player, idx: usize) bool {
        return idx < self.unplayable.len and self.unplayable[idx];
    }

    fn hasPlayable(self: *const Player) bool {
        if (self.entries.len == 0) return false;
        if (self.unplayable.len != self.entries.len) return true;
        for (self.unplayable) |dead| {
            if (!dead) return true;
        }
        return false;
    }

    pub fn ensureOrder(self: *Player) !void {
        const n = self.entries.len;
        if (self.order.len == n) return;
        self.deinitOrder();
        if (n == 0) return;
        self.order = try self.gpa.alloc(usize, n);
        self.rebuildOrder();
    }

    fn rebuildOrder(self: *Player) void {
        if (self.order.len == 0) return;
        var prng = seedRng(self.io);
        self.order_pos = buildOrder(self.order, self.shuffle, self.index, prng.random());
    }

    pub fn toggleShuffle(self: *Player) !void {
        if (!self.multi()) return;
        try self.ensureOrder();
        self.shuffle = !self.shuffle;
        self.rebuildOrder();
    }

    pub fn toggleLoop(self: *Player) void {
        if (!self.multi()) return;
        self.loop_all = !self.loop_all;
    }

    fn playPos(self: *const Player) usize {
        if (self.order.len == 0) return self.index;
        return std.mem.findScalar(usize, self.order, self.index) orelse self.order_pos;
    }

    pub fn canStep(self: *const Player, dir: Direction) bool {
        if (self.entries.len < 2) return false;
        if (!self.hasPlayable()) return false;
        if (self.loop_all) return true;
        const pos = self.playPos();
        var ahead: usize = 0;
        var behind: usize = 0;
        if (self.order.len == self.entries.len) {
            for (self.order, 0..) |idx, slot| {
                if (self.isUnplayable(idx)) continue;
                if (slot > pos) ahead += 1;
                if (slot < pos) behind += 1;
            }
        } else {
            const n = self.entries.len;
            ahead = if (pos < n) n - pos - 1 else 0;
            behind = pos;
        }
        return switch (dir) {
            .prev => behind > 0,
            .next => ahead > 0,
        };
    }

    pub fn stepOrder(self: *Player, dir: Direction) !?usize {
        try self.ensureOrder();
        const n = self.order.len;
        if (n == 0) return null;
        self.order_pos = self.playPos();
        var pos: i64 = @intCast(self.order_pos);
        var candidates: usize = n;
        while (candidates > 0) : (candidates -= 1) {
            pos += @backingInt(dir);
            if (pos < 0 or pos >= @as(i64, @intCast(n))) {
                if (!self.loop_all) return null;
                if (self.shuffle) {
                    var prng = seedRng(self.io);
                    self.order_pos = reshuffleWrap(self.order, prng.random(), dir, self.index);
                    if (!self.isUnplayable(self.order[self.order_pos])) {
                        return self.order[self.order_pos];
                    }
                    pos = @intCast(self.order_pos);
                    continue;
                }
                pos = @mod(pos, @as(i64, @intCast(n)));
            }
            const idx = self.order[@intCast(pos)];
            if (!self.isUnplayable(idx)) {
                self.order_pos = @intCast(pos);
                return idx;
            }
        }
        return null;
    }

    pub fn replaceEntries(
        self: *Player,
        paths: []const []const u8,
        titles: []const ?[]const u8,
        rates: []const u32,
        themes: []const ?u8,
        list_name: []const u8,
    ) !void {
        if (paths.len == 0) return error.EmptyPlaylist;
        const built = try OwnedPlaylist.build(self.gpa, paths, titles, rates, themes, list_name);
        self.deinitEntries();
        self.deinitOrder();
        self.freeFlags(&self.played);
        self.freeFlags(&self.unplayable);
        self.entries = built.entries;
        self.titles = built.titles;
        self.rates = built.rates;
        self.themes = built.themes;
        self.name = built.name;
        self.owns_entries = true;
        self.index = 0;
        self.order = built.order;
        self.rebuildOrder();
        self.played = built.played;
        self.unplayable = built.unplayable;
    }
};

// --- tests -------------------------------------------------------------------

test "stepOrder and canStep pass over unplayable entries" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf", "d.dro" };
    var p = Player{
        .gpa = gpa,
        .io = io,
        .engine = undefined,
        .bridge = undefined,
        .entries = &entries,
        .index = 0,
        .tick_rate_hz = 0,
        .track_index = 0,
        .src = null,
    };
    defer p.deinit();
    try p.ensureOrder();
    try p.resetFlags(&p.unplayable);

    p.markUnplayable(1);
    try std.testing.expectEqual(@as(?usize, 2), try p.stepOrder(.next));
    p.index = 2;
    try std.testing.expect(p.canStep(.prev));
    try std.testing.expect(p.canStep(.next));

    try std.testing.expectEqual(@as(?usize, 0), try p.stepOrder(.prev));

    p.index = 2;
    p.markUnplayable(0);
    p.markUnplayable(3);
    try std.testing.expectEqual(@as(?usize, null), try p.stepOrder(.next));
    try std.testing.expectEqual(@as(?usize, null), try p.stepOrder(.prev));
    try std.testing.expect(!p.canStep(.next));
    try std.testing.expect(!p.canStep(.prev));

    p.loop_all = true;
    try std.testing.expectEqual(@as(?usize, 2), try p.stepOrder(.next));
    try std.testing.expect(p.canStep(.next));

    p.markUnplayable(2);
    try std.testing.expectEqual(@as(?usize, null), try p.stepOrder(.next));
    try std.testing.expect(!p.canStep(.next));
    try std.testing.expect(!p.canStep(.prev));
}

test "canStep advertises only steps stepOrder can take in shuffle mode" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf", "d.dro" };
    var p = Player{
        .gpa = gpa,
        .io = io,
        .engine = undefined,
        .bridge = undefined,
        .entries = &entries,
        .index = 0,
        .tick_rate_hz = 0,
        .track_index = 0,
        .src = null,
    };
    defer p.deinit();
    try p.ensureOrder();
    try p.resetFlags(&p.unplayable);
    p.shuffle = true;

    try std.testing.expect(p.canStep(.next));
    try std.testing.expect(!p.canStep(.prev));
    try std.testing.expectEqual(@as(?usize, null), try p.stepOrder(.prev));

    p.index = entries.len - 1;
    try std.testing.expect(p.canStep(.prev));
    try std.testing.expect(!p.canStep(.next));
    try std.testing.expectEqual(@as(?usize, null), try p.stepOrder(.next));
}

fn stepOrderOomBody(gpa: std.mem.Allocator, io: Io) !void {
    const entries = [_][]const u8{ "a.hsc", "b.vgm" };
    var p = Player{
        .gpa = gpa,
        .io = io,
        .engine = undefined,
        .bridge = undefined,
        .entries = &entries,
        .index = 0,
        .tick_rate_hz = 0,
        .track_index = 0,
        .src = null,
    };
    defer p.deinit();
    try std.testing.expectEqual(@as(?usize, 1), try p.stepOrder(.next));
}

test "stepOrder propagates allocation failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        stepOrderOomBody,
        .{threaded.io()},
    );
}

fn replaceEntriesOomBody(gpa: std.mem.Allocator, io: Io) !void {
    var p = Player{
        .gpa = gpa,
        .io = io,
        .engine = undefined,
        .bridge = undefined,
        .entries = &.{},
        .index = 0,
        .tick_rate_hz = 0,
        .track_index = 0,
        .src = null,
    };
    defer p.deinit();
    try p.replaceEntries(
        &[_][]const u8{ "a.hsc", "b.vgm" },
        &[_]?[]const u8{ "A", null },
        &.{},
        &.{},
        "First List",
    );
    p.markPlayed(1);
    if (p.replaceEntries(
        &[_][]const u8{ "c.imf", "d.dro", "e.hsc" },
        &[_]?[]const u8{ null, "D", null },
        &.{},
        &.{},
        "Second List",
    )) |_| {
        try std.testing.expectEqual(@as(usize, 3), p.entries.len);
        try std.testing.expectEqualStrings("c.imf", p.entries[0]);
        try std.testing.expectEqualStrings("D", p.titles[1].?);
        try std.testing.expectEqualStrings("Second List", p.name);
        try std.testing.expectEqual(@as(usize, 3), p.order.len);
        try std.testing.expectEqual(@as(usize, 3), p.played.len);
        try std.testing.expectEqual(@as(usize, 3), p.unplayable.len);
    } else |err| {
        try std.testing.expectEqual(@as(usize, 2), p.entries.len);
        try std.testing.expectEqualStrings("a.hsc", p.entries[0]);
        try std.testing.expectEqualStrings("b.vgm", p.entries[1]);
        try std.testing.expectEqualStrings("A", p.titles[0].?);
        try std.testing.expect(p.titles[1] == null);
        try std.testing.expectEqualStrings("First List", p.name);
        try std.testing.expectEqual(@as(usize, 2), p.order.len);
        try std.testing.expectEqual(@as(usize, 2), p.played.len);
        try std.testing.expect(p.played[1]);
        try std.testing.expectEqual(@as(usize, 2), p.unplayable.len);
        return err;
    }
}

test "seek rebuilds the decoder from the kept input and runs it ahead to the target" {
    const gpa = std.testing.allocator;
    const opal = @import("opal");
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var data: [4 + 64 * 4]u8 = undefined;
    @memcpy(data[0..4], &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    for (0..64) |i| @memcpy(data[4 + i * 4 ..][0..4], &[_]u8{ 0xa0, @intCast(i + 1), 0x10, 0x00 });

    var br = Bridge{};
    var engine = AudioEngine{ .bridge = &br, .device = undefined, .chip = opal.Opal.init(44100) };
    var p = Player{
        .gpa = gpa,
        .io = threaded.io(),
        .engine = &engine,
        .bridge = &br,
        .entries = &.{},
        .index = 0,
        .tick_rate_hz = 0,
        .track_index = 0,
        .src = null,
    };
    defer p.deinit();
    p.src = try engine.load(gpa, "song.imf", &data, .{}, 0, 0);
    engine.source = p.src;
    try p.keepInput("song.imf", &data, .{});

    const duration = p.src.?.durationFrames().?;
    const target = duration / 3;
    const first = p.src.?;
    const rebuilt = (try p.seek(target)).?;
    try std.testing.expect(rebuilt.ptr != first.ptr);
    try std.testing.expectEqual(rebuilt.ptr, p.src.?.ptr);
    try std.testing.expectEqual(rebuilt.ptr, engine.source.?.ptr);
    try std.testing.expectEqual(target, br.position_frames.load(.acquire));
    const fnum = engine.chip.chan[0].f_number & 0xff;
    try std.testing.expect(fnum > 1);

    _ = try p.seek(duration * 2);
    try std.testing.expectEqual(duration - 1, br.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u16, 64), engine.chip.chan[0].f_number & 0xff);
    _ = try p.seek(target);
    try std.testing.expectEqual(target, br.position_frames.load(.acquire));
    try std.testing.expectEqual(fnum, engine.chip.chan[0].f_number & 0xff);

    p.src.?.setTickRate(700);
    br.position_frames.store(12345, .release);
    const fast_target = p.src.?.durationFrames().? / 2;
    _ = try p.seek(fast_target);
    var ref_br = Bridge{};
    var ref = AudioEngine{ .bridge = &ref_br, .device = undefined, .chip = opal.Opal.init(44100) };
    const ref_src = try ref.load(gpa, "song.imf", &data, .{}, 700, 0);
    defer ref_src.deinit(gpa);
    ref.source = ref_src;
    ref.skip(fast_target);
    try std.testing.expectEqual(fast_target, br.position_frames.load(.acquire));
    try std.testing.expectEqual(ref.chip.chan[0].f_number & 0xff, engine.chip.chan[0].f_number & 0xff);

    br.halt_at_songend.store(true, .release);
    br.loop_count.store(1, .release);
    br.paused.store(true, .release);
    br.branch_request.store(3, .release);
    _ = try p.seek(target);
    try std.testing.expectEqual(@as(u32, 0), br.loop_count.load(.acquire));
    try std.testing.expect(!br.paused.load(.acquire));
    try std.testing.expectEqual(std.math.maxInt(u32), br.branch_request.load(.acquire));

    br.loop_count.store(1, .release);
    br.paused.store(true, .release);
    engine.park_after_wait = true;
    _ = try p.seek(target);
    try std.testing.expectEqual(@as(u32, 0), br.loop_count.load(.acquire));
    try std.testing.expect(br.paused.load(.acquire));
}

test "capability check rejects tracker without a pattern view" {
    const Dummy = struct {
        pub fn step(_: *@This(), _: format.Chip) format.StepResult {
            return .{ .frames = 1 };
        }
        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "test", .visualizer = "tracker" };
        }
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    var src_state = Dummy{};
    const src = format.MusicSource.init(&src_state, "tracker");
    const viz = visualizer.find("tracker").?;
    try std.testing.expect(!view.ViewCaps.subsetOf(viz.requires, src.views().caps()));
    try std.testing.expect(visualizer.find("nope") == null);
    const stream = visualizer.find("stream").?;
    try std.testing.expect(view.ViewCaps.subsetOf(stream.requires, src.views().caps()));
    const sequence = visualizer.find("sequence").?;
    try std.testing.expect(!view.ViewCaps.subsetOf(sequence.requires, src.views().caps()));
}

test "chip label keeps Dual OPL2 and ignores GD3 system names" {
    try std.testing.expectEqualStrings("Dual OPL2", chipLabel(.{
        .format_name = "DRO2",
        .visualizer = "stream",
        .system = "Dual OPL2",
    }));
    try std.testing.expectEqualStrings("OPL2", chipLabel(.{
        .format_name = "VGM",
        .visualizer = "stream",
        .system = "MSX",
    }));
    try std.testing.expectEqualStrings("OPL3", chipLabel(.{
        .format_name = "VGM",
        .visualizer = "stream",
        .opl3 = true,
        .system = "IBM PC",
    }));
}

test "replaceEntries keeps the old list intact on allocation failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        replaceEntriesOomBody,
        .{threaded.io()},
    );
}

test "buildOrder without shuffle is identity starting at current" {
    var order = [_]usize{ 0, 0, 0, 0 };
    var prng = std.Random.DefaultPrng.init(1);
    const start = buildOrder(&order, false, 2, prng.random());
    try std.testing.expectEqual(@as(usize, 2), start);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, &order);
}

test "reshuffleWrap covers every track and never opens with the current one" {
    var order = [_]usize{ 0, 0, 0, 0, 0 };
    var prng = std.Random.DefaultPrng.init(7);
    for (0..20) |_| {
        const pos = reshuffleWrap(&order, prng.random(), .next, 2);
        try std.testing.expectEqual(@as(usize, 0), pos);
        try std.testing.expect(order[0] != 2);
        var seen: [5]bool = @splat(false);
        for (order) |idx| {
            try std.testing.expect(idx < 5);
            try std.testing.expect(!seen[idx]);
            seen[idx] = true;
        }
        const prev_pos = reshuffleWrap(&order, prng.random(), .prev, 4);
        try std.testing.expectEqual(@as(usize, 4), prev_pos);
        try std.testing.expect(order[4] != 4);
    }
}

test "buildOrder shuffle keeps current first and covers every track" {
    var order = [_]usize{ 0, 0, 0, 0, 0 };
    var prng = std.Random.DefaultPrng.init(42);
    const start = buildOrder(&order, true, 3, prng.random());
    try std.testing.expectEqual(@as(usize, 0), start);
    try std.testing.expectEqual(@as(usize, 3), order[0]);
    var seen: [5]bool = @splat(false);
    for (order) |idx| {
        try std.testing.expect(idx < 5);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}
