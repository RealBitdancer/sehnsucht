//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;

const AudioEngine = @import("audioengine.zig").AudioEngine;
const Bridge = @import("bridge.zig").Bridge;
const format = @import("format.zig");
const loaderr = @import("loaderr.zig");
const Player = @import("player.zig").Player;
const Direction = @import("player.zig").Direction;
const Loaded = @import("player.zig").Loaded;
const assembleTrack = @import("player.zig").assembleTrack;
const remote = @import("remote.zig");
const ui = @import("ui.zig");

/// Substitute selection after a failed load walks the play order in the
/// job's direction, so a shuffle pass or a backward skip scans the entries
/// the user would have heard next, not raw file indices.
fn nextCandidate(
    order: []const usize,
    tried: []const bool,
    unplayable: []const bool,
    from: usize,
    dir: Direction,
) ?usize {
    const n = order.len;
    if (n == 0) return null;
    var pos = std.mem.indexOfScalar(usize, order, from) orelse 0;
    var steps: usize = 0;
    while (steps < n) : (steps += 1) {
        pos = switch (dir) {
            .next => (pos + 1) % n,
            .prev => (pos + n - 1) % n,
        };
        const idx = order[pos];
        const dead = idx < unplayable.len and unplayable[idx];
        if (idx < tried.len and !tried[idx] and !dead) return idx;
    }
    return null;
}

pub const FetchState = struct {
    req_path: ?[]const u8 = null,
    req_sibling_path: ?[]const u8 = null,
    req_sibling_alt_path: ?[]const u8 = null,
    req_sibling2_path: ?[]const u8 = null,
    req_seq: std.atomic.Value(u64) = .init(0),
    abort: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),
    wake: std.atomic.Value(u32) = .init(0),
    done_seq: std.atomic.Value(u64) = .init(0),
    result: anyerror![]u8 = error.NoResult,
    sibling: ?[]u8 = null,
    sibling2: ?[]u8 = null,
    sibling_is_alt: bool = false,
};

/// A `detached` job carries its own path and an empty `tried` list, so a
/// failure falls straight through `advance` to `exhaust` instead of scanning
/// the playlist for a substitute.
const LoadPurpose = enum { startup, advance, jump, replay, detached };

const LoadJob = struct {
    purpose: LoadPurpose,
    dir: Direction,
    idx: usize,
    seq: u64,
    path: []u8,
    sibling_path: ?[]u8,
    sibling_alt_path: ?[]u8,
    sibling2_path: ?[]u8,
    tried: []bool,
    engine_intact: bool = true,
    model_detached: bool = false,
    on_done: enum { proceed, skip, discard } = .proceed,
};

pub const PollResult = enum { none, startup_failed };

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: Io,
    state: FetchState = .{},
    seq: u64 = 0,
    job: ?LoadJob = null,
    queued: ?Queued = null,
    startup_show_playlist: bool = false,
    startup_errors: []?anyerror = &.{},

    /// `path` is owned while queued and handed to `beginDetached` on release.
    const Queued = struct { purpose: LoadPurpose, idx: usize, dir: Direction, path: ?[]u8 = null };

    fn dropQueued(self: *Loader) void {
        if (self.queued) |q| if (q.path) |p| self.gpa.free(p);
        self.queued = null;
    }

    pub fn fetchWorker(gpa: std.mem.Allocator, io: Io, st: *FetchState) void {
        var last: u64 = 0;
        while (st.running.load(.acquire)) {
            const wake = st.wake.load(.acquire);
            const seq = st.req_seq.load(.acquire);
            if (seq == last) {
                io.futexWait(u32, &st.wake.raw, wake) catch break;
                continue;
            }
            last = seq;
            st.result = fetchEntry(gpa, io, st);
            st.done_seq.store(seq, .release);
        }
    }

    // Companions read here stay in `st` even when a later read fails: `poll`
    // takes and frees them no matter how `result` came out.
    fn fetchEntry(gpa: std.mem.Allocator, io: Io, st: *FetchState) anyerror![]u8 {
        const bytes = try remote.readPathAlloc(gpa, io, st.req_path.?, &st.abort);
        errdefer gpa.free(bytes);
        if (st.req_sibling_path) |p| {
            st.sibling = remote.readPathAlloc(gpa, io, p, &st.abort) catch |err| blk: {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                const alt = st.req_sibling_alt_path orelse return err;
                st.sibling_is_alt = true;
                break :blk try remote.readPathAlloc(gpa, io, alt, &st.abort);
            };
        }
        if (st.req_sibling2_path) |p| {
            st.sibling2 = remote.readPathAlloc(gpa, io, p, &st.abort) catch |err| blk: {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                // The decoder decides whether a missing second companion is
                // fatal, so absence travels as null rather than a load error.
                break :blk null;
            };
        }
        return bytes;
    }

    fn wakeWorker(self: *Loader) void {
        _ = self.state.wake.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.state.wake.raw, 1);
    }

    fn publishFetch(self: *Loader, seq: u64, job: *const LoadJob) void {
        self.state.req_path = job.path;
        self.state.req_sibling_path = job.sibling_path;
        self.state.req_sibling_alt_path = job.sibling_alt_path;
        self.state.req_sibling2_path = job.sibling2_path;
        self.state.sibling = null;
        self.state.sibling2 = null;
        self.state.sibling_is_alt = false;
        self.state.req_seq.store(seq, .release);
        self.wakeWorker();
    }

    fn startJob(self: *Loader, player: *Player, model: *ui.Model, job: LoadJob) void {
        switch (job.purpose) {
            .advance, .jump => player.track_index = 0,
            .startup, .replay, .detached => {},
        }
        player.engine.stop();
        self.seq += 1;
        self.job = job;
        const started = &self.job.?;
        started.seq = self.seq;
        self.publishFetch(started.seq, started);
        model.loading = true;
    }

    pub fn shutdown(self: *Loader) void {
        self.state.abort.store(true, .release);
        self.state.running.store(false, .release);
        self.wakeWorker();
    }

    pub fn busy(self: *const Loader) bool {
        return self.job != null;
    }

    pub fn sameAdvance(self: *const Loader, dir: Direction) bool {
        const job = self.job orelse return false;
        return job.purpose == .advance and job.dir == dir and job.on_done == .proceed;
    }

    pub fn request(
        self: *Loader,
        player: *Player,
        model: *ui.Model,
        purpose: LoadPurpose,
        idx: usize,
        dir: Direction,
    ) !void {
        if (self.job) |*job| {
            job.on_done = .discard;
            self.state.abort.store(true, .release);
            self.dropQueued();
            self.queued = .{ .purpose = purpose, .idx = idx, .dir = dir };
            return;
        }
        try self.begin(player, model, purpose, idx, dir);
    }

    /// Play a path that is not a playlist entry. The read happens on the fetch
    /// worker like any other, so a remote file cannot block or freeze the UI.
    pub fn requestDetached(
        self: *Loader,
        player: *Player,
        model: *ui.Model,
        path: []const u8,
    ) !void {
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        if (self.job) |*job| {
            job.on_done = .discard;
            self.state.abort.store(true, .release);
            self.dropQueued();
            self.queued = .{ .purpose = .detached, .idx = 0, .dir = .next, .path = owned };
            return;
        }
        try self.beginDetached(player, model, owned);
    }

    fn beginDetached(self: *Loader, player: *Player, model: *ui.Model, owned_path: []u8) !void {
        errdefer self.gpa.free(owned_path);
        const same_file = if (player.detached_path) |cur|
            std.mem.eql(u8, cur, owned_path)
        else
            false;
        if (!same_file) player.track_index = 0;
        const tried = try self.gpa.alloc(bool, 0);
        errdefer self.gpa.free(tried);
        const sibling = try format.companionPath("sibling_path", self.gpa, owned_path);
        errdefer if (sibling) |s| self.gpa.free(s);
        const sibling_alt = try format.companionPath("sibling_alt_path", self.gpa, owned_path);
        errdefer if (sibling_alt) |s| self.gpa.free(s);
        const sibling2 = try format.companionPath("sibling2_path", self.gpa, owned_path);
        self.startJob(player, model, .{
            .purpose = .detached,
            .dir = .next,
            .idx = 0,
            .seq = 0,
            .path = owned_path,
            .sibling_path = sibling,
            .sibling_alt_path = sibling_alt,
            .sibling2_path = sibling2,
            .tried = tried,
        });
    }

    pub fn skipCurrent(self: *Loader) void {
        if (self.job) |*job| {
            if (job.on_done == .proceed) job.on_done = .skip;
            self.state.abort.store(true, .release);
        }
    }

    fn begin(
        self: *Loader,
        player: *Player,
        model: *ui.Model,
        purpose: LoadPurpose,
        idx: usize,
        dir: Direction,
    ) !void {
        const n = player.entries.len;
        if (n == 0 or idx >= n) {
            if (player.src != null) try player.engine.start();
            return;
        }
        const tried = try self.gpa.alloc(bool, n);
        errdefer self.gpa.free(tried);
        @memset(tried, false);
        tried[idx] = true;
        const path = try self.gpa.dupe(u8, player.entries[idx]);
        errdefer self.gpa.free(path);
        const sibling = try format.companionPath("sibling_path", self.gpa, path);
        errdefer if (sibling) |s| self.gpa.free(s);
        const sibling_alt = try format.companionPath("sibling_alt_path", self.gpa, path);
        errdefer if (sibling_alt) |s| self.gpa.free(s);
        const sibling2 = try format.companionPath("sibling2_path", self.gpa, path);
        self.startJob(player, model, .{
            .purpose = purpose,
            .dir = dir,
            .idx = idx,
            .seq = 0,
            .path = path,
            .sibling_path = sibling,
            .sibling_alt_path = sibling_alt,
            .sibling2_path = sibling2,
            .tried = tried,
        });
    }

    fn stripEngineIfIntact(job: *LoadJob, player: *Player) void {
        if (!job.engine_intact) return;
        player.engine.source = null;
        player.deinitSource();
        player.clearDetached();
        job.engine_intact = false;
    }

    fn commitLoadedTrack(
        self: *Loader,
        bridge: *Bridge,
        model: *ui.Model,
        player: *Player,
        job: *LoadJob,
        loaded: Loaded,
        detached_path: *?[]u8,
    ) !void {
        if (job.purpose == .detached) {
            player.detached_path = detached_path.*;
            detached_path.* = null;
        } else {
            player.index = job.idx;
            player.clearUnplayable(player.index);
        }

        player.bridge.resetTrackState();
        player.engine.source = loaded.src;
        player.src = loaded.src;

        if (job.purpose != .detached) {
            try player.ensureOrder();
            player.order_pos = std.mem.indexOfScalar(
                usize,
                player.order,
                player.index,
            ) orelse player.order_pos;
            player.markPlayed(player.index);
        }

        try player.engine.start();
        try model.setTrack(.{
            .info = loaded.track,
            .filename = loaded.display_name,
            .view = loaded.view,
            .source = loaded.src,
            .system = loaded.system,
        });

        if (job.purpose == .detached) {
            model.playlist_index = player.index;
            model.playlist_playing = false;
            bridge.paused.store(false, .release);
            return;
        }

        const follow = cursorFollowsPlayback(model);
        model.playlist_index = player.index;
        model.playlist_playing = true;
        if (follow) model.playlist_list.nav.syncTo(player.index, player.entries.len);
        if (job.purpose == .replay) bridge.paused.store(false, .release);
        if (job.purpose == .startup and !self.startup_show_playlist) {
            model.menu_view = .visualize;
            model.menu = .visualize;
        }
    }

    pub fn poll(self: *Loader, bridge: *Bridge, model: *ui.Model, player: *Player) !PollResult {
        const job = if (self.job) |*j| j else return .none;
        if (self.state.done_seq.load(.acquire) != job.seq) return .none;
        self.state.req_path = null;
        self.state.req_sibling_path = null;
        self.state.req_sibling_alt_path = null;
        self.state.req_sibling2_path = null;
        self.state.abort.store(false, .release);
        const res = self.state.result;
        self.state.result = error.NoResult;
        const sibling = self.state.sibling;
        self.state.sibling = null;
        defer if (sibling) |s| self.gpa.free(s);
        const sibling2 = self.state.sibling2;
        self.state.sibling2 = null;
        defer if (sibling2) |s| self.gpa.free(s);
        const sibling_is_alt = self.state.sibling_is_alt;
        self.state.sibling_is_alt = false;

        switch (job.on_done) {
            .discard => {
                if (res) |bytes| self.gpa.free(bytes) else |_| {}
                const q = self.queued;
                self.queued = null;
                self.finish(model);
                if (q) |req| {
                    if (req.path) |p| {
                        try self.beginDetached(player, model, p);
                    } else {
                        try self.begin(player, model, req.purpose, req.idx, req.dir);
                    }
                }
                return .none;
            },
            .skip => {
                if (res) |bytes| self.gpa.free(bytes) else |_| {}
                job.on_done = .proceed;
                return self.advance(bridge, model, player, null);
            },
            .proceed => {},
        }

        if (res) |bytes| {
            defer self.gpa.free(bytes);
            var detached_path = if (job.purpose == .detached)
                try self.gpa.dupe(u8, job.path)
            else
                null;
            defer if (detached_path) |path| self.gpa.free(path);
            stripEngineIfIntact(job, player);
            const loaded = assembleTrack(
                self.gpa,
                player.engine,
                job.path,
                bytes,
                .{ .sibling = sibling, .sibling2 = sibling2, .sibling_is_alt = sibling_is_alt },
                if (job.purpose == .detached) player.tick_rate_hz else player.rateForIndex(job.idx),
                player.track_index,
            ) catch |err| {
                if (!job.model_detached) {
                    model.clearTrack();
                    job.model_detached = true;
                }
                return self.advance(bridge, model, player, err);
            };
            self.commitLoadedTrack(bridge, model, player, job, loaded, &detached_path) catch |err| {
                // The old source is already gone and the new one may be
                // published, so unwind to the no-track state and let the scan
                // continue: erroring out of poll would end the session with
                // the model still pointing at the freed old track. setTrack
                // mutates nothing on failure, and nothing after it can fail,
                // so the model never holds the source freed here.
                player.engine.stop();
                player.engine.source = null;
                player.src = null;
                player.clearDetached();
                loaded.src.deinit(self.gpa);
                if (!job.model_detached) {
                    model.clearTrack();
                    job.model_detached = true;
                }
                return self.advance(bridge, model, player, err);
            };
            self.finish(model);
            return .none;
        } else |err| {
            if (err == error.Canceled) {
                return self.advance(bridge, model, player, null);
            }
            return self.advance(bridge, model, player, err);
        }
    }

    fn advance(
        self: *Loader,
        bridge: *Bridge,
        model: *ui.Model,
        player: *Player,
        err: ?anyerror,
    ) !PollResult {
        const job = &self.job.?;
        if (err) |e| {
            // A detached job's idx addresses nothing: marking would condemn
            // whichever playlist entry happens to sit at index 0.
            if (job.purpose != .detached) player.markUnplayable(job.idx);
            if (job.purpose == .startup and job.idx < self.startup_errors.len) {
                self.startup_errors[job.idx] = e;
            }
            model.noticeSkip(job.path, loaderr.loadErrorLabel(e));
        }
        const n = player.entries.len;
        if (n > 0) {
            if (nextCandidate(player.order, job.tried, player.unplayable, job.idx, job.dir)) |ni| {
                const new_path = try self.gpa.dupe(u8, player.entries[ni]);
                errdefer self.gpa.free(new_path);
                const new_sibling = try format.companionPath("sibling_path", self.gpa, new_path);
                errdefer if (new_sibling) |s| self.gpa.free(s);
                const new_sibling_alt = try format.companionPath("sibling_alt_path", self.gpa, new_path);
                errdefer if (new_sibling_alt) |s| self.gpa.free(s);
                const new_sibling2 = try format.companionPath("sibling2_path", self.gpa, new_path);
                self.gpa.free(job.path);
                job.path = new_path;
                if (job.sibling_path) |s| self.gpa.free(s);
                job.sibling_path = new_sibling;
                if (job.sibling_alt_path) |s| self.gpa.free(s);
                job.sibling_alt_path = new_sibling_alt;
                if (job.sibling2_path) |s| self.gpa.free(s);
                job.sibling2_path = new_sibling2;
                job.tried[ni] = true;
                job.idx = ni;
                self.seq += 1;
                job.seq = self.seq;
                self.publishFetch(job.seq, job);
                return .none;
            }
        }
        return self.exhaust(bridge, model, player);
    }

    fn exhaust(self: *Loader, bridge: *Bridge, model: *ui.Model, player: *Player) !PollResult {
        const job = self.job.?;
        const was_startup = job.purpose == .startup;
        const intact = job.engine_intact;
        self.finish(model);
        if (was_startup and player.src == null) return .startup_failed;
        if (intact) {
            if (player.src != null) try player.engine.start();
        } else {
            parkIdle(bridge, model, player);
        }
        return .none;
    }

    fn finish(self: *Loader, model: *ui.Model) void {
        if (self.job) |*job| {
            self.freeJobFields(job);
            self.job = null;
        }
        model.loading = false;
    }

    fn freeJobFields(self: *Loader, job: *LoadJob) void {
        self.gpa.free(job.path);
        if (job.sibling_path) |s| self.gpa.free(s);
        if (job.sibling_alt_path) |s| self.gpa.free(s);
        if (job.sibling2_path) |s| self.gpa.free(s);
        self.gpa.free(job.tried);
    }

    pub fn deinit(self: *Loader) void {
        self.dropQueued();
        if (self.job) |*job| {
            if (self.state.done_seq.load(.acquire) == job.seq) {
                if (self.state.result) |bytes| self.gpa.free(bytes) else |_| {}
                if (self.state.sibling) |s| self.gpa.free(s);
                if (self.state.sibling2) |s| self.gpa.free(s);
            }
            self.freeJobFields(job);
            self.job = null;
        }
    }
};

fn cursorFollowsPlayback(model: *const ui.Model) bool {
    return model.playlist_playing and
        model.playlist_list.nav.cursor == model.playlist_index;
}

fn parkIdle(bridge: *Bridge, model: *ui.Model, player: *Player) void {
    bridge.resetTrackState();
    bridge.paused.store(false, .release);
    const follow = cursorFollowsPlayback(model);
    model.playlist_count = player.entries.len;
    model.playlist_index = player.index;
    model.playlist_entries = player.entries;
    model.playlist_titles = player.titles;
    model.playlist_name = player.name;
    model.playlist_played = player.played;
    model.playlist_unplayable = player.unplayable;
    model.playlist_playing = false;
    model.clearTrack();
    if (follow) model.playlist_list.nav.syncTo(player.index, player.entries.len);
}

// --- tests -------------------------------------------------------------------

test "cursor follows playback only while it sits on the playing row" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try ui.Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    m.playlist_index = 3;
    m.playlist_playing = true;
    m.playlist_list.nav.cursor = 3;
    try std.testing.expect(cursorFollowsPlayback(&m));

    m.playlist_list.nav.cursor = 7;
    try std.testing.expect(!cursorFollowsPlayback(&m));

    m.playlist_list.nav.cursor = 3;
    m.playlist_playing = false;
    try std.testing.expect(!cursorFollowsPlayback(&m));
}

test "nextCandidate follows the play order and skips tried and dead entries" {
    const tried = [_]bool{ true, false, true, false };
    const dead = [_]bool{ false, false, false, true };
    const identity = [_]usize{ 0, 1, 2, 3 };
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 0, .next));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 2, .next));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 2, .prev));
    // Shuffled order 2, 3, 1, 0: after 2 comes 3 (dead), then 1.
    const shuffled = [_]usize{ 2, 3, 1, 0 };
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&shuffled, &tried, &dead, 2, .next));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&shuffled, &tried, &dead, 0, .prev));
    const all_tried = [_]bool{ true, true, true, false };
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&identity, &all_tried, &dead, 1, .next));
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&.{}, &tried, &dead, 1, .next));
}

const LoaderHarness = struct {
    bridge: Bridge = .{},
    engine: AudioEngine = undefined,
    player: Player = undefined,
    model: ui.Model = undefined,

    fn init(self: *LoaderHarness, io: Io, entries: []const []const u8) !void {
        // No device is ever started here, so the harness never touches either.
        self.engine = .{
            .bridge = &self.bridge,
            .sample_rate = 44100,
            .device = undefined,
            .chip = undefined,
        };
        self.player = try Player.init(std.testing.allocator, io, &self.engine, &self.bridge, .{
            .entries = entries,
        });
        self.model = try ui.Model.init(std.testing.allocator, &self.bridge, .{
            .info = .{ .format_name = "-", .visualizer = "stream" },
            .filename = "",
        });
    }

    fn deinit(self: *LoaderHarness) void {
        self.model.deinit();
        self.player.deinit();
    }
};

fn completeFetch(loader: *Loader, res: anyerror![]u8) void {
    loader.state.result = res;
    loader.state.done_seq.store(loader.job.?.seq, .release);
}

fn requestOomBody(gpa: std.mem.Allocator, io: Io) !void {
    const entries = [_][]const u8{ "a.imf", "b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = gpa, .io = io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expect(loader.busy());
}

test "Loader request propagates allocation failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        requestOomBody,
        .{threaded.io()},
    );
}

test "Loader scans every entry then reports startup failure when all fetches fail" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf", "http://x/c.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var startup_errors = [_]?anyerror{null} ** entries.len;
    var loader = Loader{ .gpa = std.testing.allocator, .io = io, .startup_errors = &startup_errors };
    defer loader.deinit();

    try loader.request(&h.player, &h.model, .startup, 0, .next);
    var result: PollResult = .none;
    var guard: usize = 0;
    while (loader.busy() and guard < 32) : (guard += 1) {
        completeFetch(&loader, error.HttpRequestFailed);
        result = try loader.poll(&h.bridge, &h.model, &h.player);
        if (result != .none) break;
    }

    try std.testing.expectEqual(PollResult.startup_failed, result);
    try std.testing.expect(!loader.busy());
    try std.testing.expect(!h.model.loading);
    for (0..entries.len) |i| {
        try std.testing.expect(h.player.unplayable[i]);
        try std.testing.expectEqual(@as(?anyerror, error.HttpRequestFailed), startup_errors[i]);
    }
}

test "Loader clears archive track index when loading a different file" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "a.imf", "b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    h.player.track_index = 5;
    try loader.request(&h.player, &h.model, .jump, 1, .next);
    try std.testing.expectEqual(@as(u32, 0), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 3;
    try loader.request(&h.player, &h.model, .advance, 0, .next);
    try std.testing.expectEqual(@as(u32, 0), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 7;
    try loader.request(&h.player, &h.model, .replay, 0, .next);
    try std.testing.expectEqual(@as(u32, 7), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 2;
    try loader.request(&h.player, &h.model, .startup, 0, .next);
    try std.testing.expectEqual(@as(u32, 2), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 4;
    try loader.requestDetached(&h.player, &h.model, "solo.imf");
    try std.testing.expectEqual(@as(u32, 0), h.player.track_index);
    loader.finish(&h.model);

    h.player.detached_path = try std.testing.allocator.dupe(u8, "solo.imf");
    h.player.track_index = 6;
    try loader.requestDetached(&h.player, &h.model, "solo.imf");
    try std.testing.expectEqual(@as(u32, 6), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 9;
    try loader.requestDetached(&h.player, &h.model, "other.imf");
    try std.testing.expectEqual(@as(u32, 0), h.player.track_index);
}

test "Loader publishes the AudioT companion path with the request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"game/AUDIOHED.WL6"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expectEqualStrings("game/AUDIOT.WL6", loader.job.?.sibling_path.?);
    try std.testing.expectEqualStrings("game/AUDIOT.WL6", loader.state.req_sibling_path.?);

    loader.state.sibling = try std.testing.allocator.dupe(u8, "HED");
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "DATA"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expect(h.player.unplayable[0]);
}

test "Loader publishes both companions for a compressed AudioT archive" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"game/AUDIO.CK4"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expectEqualStrings("game/AUDIOHED.CK4", loader.job.?.sibling_path.?);
    try std.testing.expect(loader.job.?.sibling_alt_path == null);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.job.?.sibling2_path.?);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.state.req_sibling2_path.?);

    loader.state.sibling = try std.testing.allocator.dupe(u8, "HED");
    loader.state.sibling2 = try std.testing.allocator.dupe(u8, "DCT");
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "DATA"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expect(h.player.unplayable[0]);
}

test "Loader publishes the alternate companion for an AUDIOHED entry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"game/AUDIOHED.CK4"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expectEqualStrings("game/AUDIOT.CK4", loader.job.?.sibling_path.?);
    try std.testing.expectEqualStrings("game/AUDIO.CK4", loader.job.?.sibling_alt_path.?);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.job.?.sibling2_path.?);
    try std.testing.expectEqualStrings("game/AUDIO.CK4", loader.state.req_sibling_alt_path.?);

    loader.state.sibling = try std.testing.allocator.dupe(u8, "AUD");
    loader.state.sibling_is_alt = true;
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "HED"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expect(!loader.state.sibling_is_alt);
    try std.testing.expect(h.player.unplayable[0]);
}

test "fetch worker parks on the futex and serves requests" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"no-such-dir/definitely-missing.imf"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    var fut = try io.concurrent(Loader.fetchWorker, .{ std.testing.allocator, io, &loader.state });
    defer {
        loader.shutdown();
        fut.await(io);
        loader.deinit();
    }

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    var guard: usize = 0;
    while (loader.busy() and guard < 5000) : (guard += 1) {
        _ = try loader.poll(&h.bridge, &h.model, &h.player);
        io.sleep(.fromMilliseconds(1), .real) catch break;
    }
    try std.testing.expect(!loader.busy());
    try std.testing.expect(h.player.unplayable[0]);
}

test "a failed detached load condemns no playlist entry and scans no substitute" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/solo.hsc");
    try std.testing.expect(loader.busy());
    try std.testing.expectEqual(LoadPurpose.detached, loader.job.?.purpose);
    try std.testing.expectEqualStrings("http://elsewhere/solo.hsc", loader.job.?.path);

    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);

    // The detached idx addresses nothing, so entry 0 must survive untouched,
    // and the empty `tried` list must stop advance() from trying entry 1.
    try std.testing.expect(!loader.busy());
    try std.testing.expect(!h.player.unplayable[0]);
    try std.testing.expect(!h.player.unplayable[1]);
    try std.testing.expect(!h.model.loading);
}

test "a detached request supersedes a running job without leaking its path" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expectEqual(@as(usize, 0), loader.job.?.idx);

    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/solo.hsc");
    try std.testing.expectEqual(LoadPurpose.jump, loader.job.?.purpose);
    try std.testing.expect(loader.queued.?.path != null);

    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);

    try std.testing.expect(loader.busy());
    try std.testing.expectEqual(LoadPurpose.detached, loader.job.?.purpose);
    try std.testing.expectEqualStrings("http://elsewhere/solo.hsc", loader.job.?.path);
    try std.testing.expect(loader.queued == null);
}

test "a superseded detached request frees the queued path" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"http://x/a.imf"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/one.hsc");
    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/two.hsc");
    try std.testing.expectEqualStrings("http://elsewhere/two.hsc", loader.queued.?.path.?);

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expect(loader.queued.?.path == null);
}

test "Loader failure scan follows a shuffled play order" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf", "http://x/c.imf", "http://x/d.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    // Play order c, a, d, b: when c fails the scan must try a (index 0),
    // not the next file index.
    h.player.order[0] = 2;
    h.player.order[1] = 0;
    h.player.order[2] = 3;
    h.player.order[3] = 1;

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .advance, 2, .next);

    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expectEqual(@as(usize, 0), loader.job.?.idx);

    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expectEqual(@as(usize, 3), loader.job.?.idx);
}

test "Loader supersedes a running scan with the queued request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf", "http://x/c.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    try std.testing.expect(loader.busy());
    const first_seq = loader.job.?.seq;

    try loader.request(&h.player, &h.model, .jump, 2, .next);
    try std.testing.expectEqual(@as(usize, 0), loader.job.?.idx);

    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(loader.busy());
    try std.testing.expectEqual(@as(usize, 2), loader.job.?.idx);
    try std.testing.expectEqual(first_seq + 1, loader.job.?.seq);
}
