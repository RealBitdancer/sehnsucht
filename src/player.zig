//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;

const AudioEngine = @import("audioengine.zig").AudioEngine;
const Bridge = @import("bridge.zig").Bridge;
const format = @import("format.zig");

pub const Loaded = struct {
    src: format.MusicSource,
    track: format.TrackInfo,
    view: ?format.TrackerView,
    display_name: []const u8,
    system: []const u8,
};

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
    const track = src.info();
    const view = src.trackerView();
    if (std.mem.eql(u8, track.visualizer, "tracker") and view == null) {
        src.deinit(gpa);
        return error.MissingTrackerView;
    }
    return .{
        .src = src,
        .track = track,
        .view = view,
        .display_name = track.title orelse format.basenameOf(path),
        .system = if (track.opl3) "OPL3" else "OPL2",
    };
}

pub const Direction = enum(i2) {
    next = 1,
    prev = -1,
};

fn buildOrder(order: []usize, shuffle: bool, current: usize, rng: std.Random) usize {
    for (order, 0..) |*slot, i| slot.* = i;
    if (!shuffle) return if (current < order.len) current else 0;
    if (order.len == 0) return 0;
    rng.shuffle(usize, order);
    const cur_pos = std.mem.indexOfScalar(usize, order, current) orelse 0;
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
    name: []const u8,
    order: []usize,
    played: []bool,
    unplayable: []bool,

    fn build(
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        titles: []const ?[]const u8,
        rates: []const u32,
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
    track_index: u32,
    src: ?format.MusicSource,
    detached_path: ?[]u8 = null,

    pub const Config = struct {
        entries: []const []const u8,
        titles: []const ?[]const u8 = &.{},
        rates: []const u32 = &.{},
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
        self.gpa.free(self.name);
        self.name = "";
        self.owns_entries = false;
    }

    pub fn rateForIndex(self: *const Player, idx: usize) u32 {
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
        return std.mem.indexOfScalar(usize, self.order, self.index) orelse self.order_pos;
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
        if (self.shuffle and ahead > 0) {
            return true;
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
            pos += @intFromEnum(dir);
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
        list_name: []const u8,
    ) !void {
        if (paths.len == 0) return error.EmptyPlaylist;
        const built = try OwnedPlaylist.build(self.gpa, paths, titles, rates, list_name);
        self.deinitEntries();
        self.deinitOrder();
        self.freeFlags(&self.played);
        self.freeFlags(&self.unplayable);
        self.entries = built.entries;
        self.titles = built.titles;
        self.rates = built.rates;
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
        "First List",
    );
    p.markPlayed(1);
    if (p.replaceEntries(
        &[_][]const u8{ "c.imf", "d.dro", "e.hsc" },
        &[_]?[]const u8{ null, "D", null },
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
        var seen = [_]bool{false} ** 5;
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
    var seen = [_]bool{false} ** 5;
    for (order) |idx| {
        try std.testing.expect(idx < 5);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}
