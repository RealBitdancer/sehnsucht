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
const view = @import("view.zig");

/// Substitute selection after a failed load walks the play order in the
/// job's direction, so a shuffle pass or a backward skip scans the entries
/// the user would have heard next, not raw file indices.
/// `wrap` is for startup (find any playable file) and for loop-all.
/// Mid-session advance stops at the same ends as `stepOrder`.
fn nextCandidate(
    order: []const usize,
    tried: []const bool,
    unplayable: []const bool,
    from: usize,
    dir: Direction,
    wrap: bool,
) ?usize {
    const n = order.len;
    if (n == 0) return null;
    var pos = std.mem.findScalar(usize, order, from) orelse 0;
    var steps: usize = 0;
    while (steps < n) : (steps += 1) {
        switch (dir) {
            .next => {
                if (pos + 1 >= n) {
                    if (!wrap) return null;
                    pos = 0;
                } else {
                    pos += 1;
                }
            },
            .prev => {
                if (pos == 0) {
                    if (!wrap) return null;
                    pos = n - 1;
                } else {
                    pos -= 1;
                }
            },
        }
        const idx = order[pos];
        const dead = idx < unplayable.len and unplayable[idx];
        if (idx < tried.len and !tried[idx] and !dead) return idx;
    }
    return null;
}

pub const FetchState = struct {
    req_path: ?[]const u8 = null,
    req_companions: format.CompanionPaths = .{},
    req_seq: std.atomic.Value(u64) = .init(0),
    abort: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),
    wake: std.atomic.Value(u32) = .init(0),
    done_seq: std.atomic.Value(u64) = .init(0),
    result: anyerror![]u8 = error.NoResult,
    sibling: ?[]u8 = null,
    sibling2: ?[]u8 = null,
    sibling_is_alt: bool = false,
    cache: ?*remote.ArchiveCache = null,
    resources: std.ArrayList(format.Resource) = .empty,
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
    companions: format.CompanionPaths,
    tried: []bool,
    track_index: u32 = 0,
    skip_n: u32 = 0,
    engine_intact: bool = true,
    model_detached: bool = false,
    on_done: enum { proceed, skip, discard } = .proceed,
};

pub const PollResult = enum { none, startup_failed };

const VisualSnapshot = struct {
    playhead: view.Playhead,
    channels: view.ChannelStateBank,
    pattern_cursors: view.PatternCursorBank,
    sequence: view.SequenceStateBank,
    chip: view.ChipSnapshot,
    pcm: view.PcmState,
    write_log: [view.write_log_cap]u32,
    write_log_i: u32,

    fn capture(bridge: *const Bridge) VisualSnapshot {
        var write_log: [view.write_log_cap]u32 = undefined;
        for (&write_log, &bridge.write_log) |*slot, *logged| slot.* = logged.load(.acquire);
        return .{
            .playhead = bridge.playhead.read(),
            .channels = bridge.channels.read(),
            .pattern_cursors = bridge.pattern_cursors.read(),
            .sequence = bridge.sequence.read(),
            .chip = bridge.chip.read(),
            .pcm = bridge.pcm.read(),
            .write_log = write_log,
            .write_log_i = bridge.write_log_i.load(.acquire),
        };
    }

    fn restore(self: *const VisualSnapshot, bridge: *Bridge) void {
        bridge.playhead.write(self.playhead);
        bridge.channels.write(self.channels);
        bridge.pattern_cursors.write(self.pattern_cursors);
        bridge.sequence.write(self.sequence);
        bridge.chip.write(self.chip);
        bridge.pcm.write(self.pcm);
        for (&bridge.write_log, &self.write_log) |*slot, value| slot.store(value, .release);
        bridge.write_log_i.store(self.write_log_i, .release);
    }
};

fn freeResources(gpa: std.mem.Allocator, resources: std.ArrayList(format.Resource)) void {
    for (resources.items) |resource| {
        gpa.free(resource.name);
        gpa.free(resource.data);
    }
    var owned = resources;
    owned.deinit(gpa);
}

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: Io,
    zip_cache: remote.ArchiveCache = .{},
    state: FetchState = .{},
    seq: u64 = 0,
    job: ?LoadJob = null,
    queued: ?Queued = null,
    resume_visuals: ?VisualSnapshot = null,
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
        const bytes = try remote.readPathAlloc(gpa, io, st.req_path.?, &st.abort, st.cache);
        errdefer gpa.free(bytes);
        if (st.req_companions.sibling) |p| {
            st.sibling = remote.readPathAlloc(gpa, io, p, &st.abort, st.cache) catch |err| blk: {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                const alt = st.req_companions.sibling_alt orelse return err;
                st.sibling_is_alt = true;
                break :blk try remote.readPathAlloc(gpa, io, alt, &st.abort, st.cache);
            };
        }
        if (st.req_companions.sibling2) |p| {
            st.sibling2 = remote.readPathAlloc(gpa, io, p, &st.abort, st.cache) catch |err| blk: {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                // The decoder decides whether a missing second companion is
                // fatal, so absence travels as null rather than a load error.
                break :blk null;
            };
        }
        const requests = try format.resourceRequests(gpa, st.req_path.?, bytes);
        defer {
            for (requests) |res_request| res_request.deinit(gpa);
            gpa.free(requests);
        }
        var total: usize = 0;
        for (requests) |res_request| {
            var resource: ?[]u8 = null;
            for (res_request.paths) |path| {
                resource = remote.readPathAlloc(gpa, io, path, &st.abort, st.cache) catch |err| {
                    if (err == error.Canceled or err == error.OutOfMemory) return err;
                    continue;
                };
                break;
            }
            const data = resource orelse {
                if (res_request.required) return error.MissingResource;
                continue;
            };
            errdefer gpa.free(data);
            total += data.len;
            if (total > 4 * format.max_input_bytes) return error.ResourceLimit;
            const name = try gpa.dupe(u8, res_request.name);
            errdefer gpa.free(name);
            try st.resources.append(gpa, .{ .name = name, .data = data });
        }
        return bytes;
    }

    fn wakeWorker(self: *Loader) void {
        _ = self.state.wake.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.state.wake.raw, 1);
    }

    fn publishFetch(self: *Loader, seq: u64, job: *const LoadJob) void {
        self.state.req_path = job.path;
        self.state.req_companions = job.companions;
        self.state.sibling = null;
        self.state.sibling2 = null;
        self.state.sibling_is_alt = false;
        self.state.req_seq.store(seq, .release);
        self.wakeWorker();
    }

    fn startJob(self: *Loader, player: *Player, model: *ui.Model, job: LoadJob) void {
        player.engine.stop();
        if (player.src != null and self.resume_visuals == null) {
            self.resume_visuals = VisualSnapshot.capture(player.bridge);
        }
        player.bridge.resetVisualState();
        model.beginLoading();
        self.seq += 1;
        self.job = job;
        const started = &self.job.?;
        started.seq = self.seq;
        self.publishFetch(started.seq, started);
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
        return job.purpose == .advance and job.dir == dir;
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
        const tried = try self.gpa.alloc(bool, 0);
        errdefer self.gpa.free(tried);
        const companions = try format.resolveCompanions(self.gpa, owned_path);
        errdefer companions.deinit(self.gpa);
        self.startJob(player, model, .{
            .purpose = .detached,
            .dir = .next,
            .idx = 0,
            .seq = 0,
            .path = owned_path,
            .companions = companions,
            .tried = tried,
            .track_index = if (same_file) player.track_index else 0,
        });
    }

    fn sameFileJob(self: *Loader, player: *const Player) ?*LoadJob {
        const job = if (self.job) |*j| j else return null;
        return switch (job.purpose) {
            .replay => if (job.idx == player.index) job else null,
            .detached => if (player.detached_path) |cur| (if (std.mem.eql(u8, cur, job.path)) job else null) else null,
            .startup, .advance, .jump => null,
        };
    }

    pub fn adoptArchiveIndex(self: *Loader, player: *const Player, index: u32) bool {
        const job = self.sameFileJob(player) orelse return false;
        job.track_index = index;
        return true;
    }

    pub fn pendingArchiveIndex(self: *Loader, player: *const Player) ?u32 {
        const job = self.sameFileJob(player) orelse return null;
        return job.track_index;
    }

    pub fn skipCurrent(self: *Loader) void {
        if (self.job) |*job| {
            job.skip_n += 1;
            job.on_done = .skip;
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
        if (n == 0 or idx >= n) return self.resumeIntact(player);
        const tried = try self.gpa.alloc(bool, n);
        errdefer self.gpa.free(tried);
        @memset(tried, false);
        tried[idx] = true;
        const path = try self.gpa.dupe(u8, player.entries[idx]);
        errdefer self.gpa.free(path);
        const companions = try format.resolveCompanions(self.gpa, path);
        errdefer companions.deinit(self.gpa);
        self.startJob(player, model, .{
            .purpose = purpose,
            .dir = dir,
            .idx = idx,
            .seq = 0,
            .path = path,
            .companions = companions,
            .tried = tried,
            .track_index = switch (purpose) {
                .advance, .jump => 0,
                .startup, .replay, .detached => player.track_index,
            },
        });
    }

    fn stripEngineIfIntact(self: *Loader, job: *LoadJob, player: *Player) void {
        if (!job.engine_intact) return;
        self.resume_visuals = null;
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
        player.track_index = job.track_index;
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
            player.order_pos = std.mem.findScalar(
                usize,
                player.order,
                player.index,
            ) orelse player.order_pos;
            player.markPlayed(player.index);
        }

        try model.setTrack(.{
            .info = loaded.track,
            .filename = loaded.display_name,
            .views = loaded.views,
            .source = loaded.src,
            .system = loaded.system,
        });
        try player.engine.start();

        if (job.purpose == .detached) {
            model.playlist_index = player.index;
            model.playlist_playing = false;
            bridge.paused.store(false, .release);
            return;
        }

        const follow = cursorFollowsPlayback(model);
        model.playlist_index = player.index;
        model.playlist_playing = true;
        if (player.themeForIndex(player.index)) |theme_index| model.theme_index = theme_index;
        if (follow) model.playlist_list.nav.syncTo(player.index, player.entries.len);
        if (job.purpose != .startup) bridge.paused.store(false, .release);
        if (job.purpose == .startup and !self.startup_show_playlist) {
            model.menu_view = .visualize;
            model.menu = .visualize;
        }
    }

    pub fn poll(self: *Loader, bridge: *Bridge, model: *ui.Model, player: *Player) !PollResult {
        const job = if (self.job) |*j| j else return .none;
        if (self.state.done_seq.load(.acquire) != job.seq) return .none;
        self.state.req_path = null;
        self.state.req_companions = .{};
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

        const resources = self.state.resources;
        self.state.resources = .empty;
        defer freeResources(self.gpa, resources);

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
                const skips = @max(1, job.skip_n);
                job.skip_n = 0;
                job.on_done = .proceed;
                return self.skipAhead(bridge, model, player, skips);
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
            if (!job.model_detached) {
                model.views = .{};
                model.source = null;
            }
            const same_file = self.sameFileJob(player) != null;
            self.stripEngineIfIntact(job, player);
            if (!same_file) player.live_rate_hz = 0;
            const loaded = assembleTrack(
                self.gpa,
                player.engine,
                job.path,
                bytes,
                .{ .sibling = sibling, .sibling2 = sibling2, .sibling_is_alt = sibling_is_alt, .resources = resources.items },
                if (job.purpose == .detached)
                    (if (player.live_rate_hz != 0) player.live_rate_hz else player.tick_rate_hz)
                else
                    player.rateForIndex(job.idx),
                job.track_index,
            ) catch |err| {
                if (!job.model_detached) {
                    model.clearTrack();
                    job.model_detached = true;
                }
                return self.advance(bridge, model, player, err);
            };
            self.commitLoadedTrack(bridge, model, player, job, loaded, &detached_path) catch |err| {
                // The old source is already gone and the new one may be
                // published to the engine and the model, so unwind to the
                // no-track state and let the scan continue: erroring out of
                // poll would end the session with the model still pointing at
                // a freed track.
                player.engine.stop();
                player.engine.source = null;
                player.src = null;
                player.clearDetached();
                loaded.src.deinit(self.gpa);
                model.clearTrack();
                job.model_detached = true;
                return self.advance(bridge, model, player, err);
            };
            try player.keepInput(job.path, bytes, .{ .sibling = sibling, .sibling2 = sibling2, .sibling_is_alt = sibling_is_alt, .resources = resources.items });
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
            const wrap = job.purpose == .startup or player.loop_all;
            if (nextCandidate(player.order, job.tried, player.unplayable, job.idx, job.dir, wrap)) |ni| {
                return self.retarget(player, job, ni);
            }
        }
        return self.exhaust(bridge, model, player);
    }

    fn skipAhead(
        self: *Loader,
        bridge: *Bridge,
        model: *ui.Model,
        player: *Player,
        skips: u32,
    ) !PollResult {
        const job = &self.job.?;
        const wrap = job.purpose == .startup or player.loop_all;
        var from = job.idx;
        var left = skips;
        var dest: ?usize = null;
        while (left > 0) : (left -= 1) {
            dest = nextCandidate(player.order, job.tried, player.unplayable, from, job.dir, wrap);
            from = dest orelse return self.exhaust(bridge, model, player);
            if (from < job.tried.len) job.tried[from] = true;
        }
        return self.retarget(player, job, dest.?);
    }

    fn retarget(self: *Loader, player: *Player, job: *LoadJob, ni: usize) !PollResult {
        const new_path = try self.gpa.dupe(u8, player.entries[ni]);
        errdefer self.gpa.free(new_path);
        const new_companions = try format.resolveCompanions(self.gpa, new_path);
        errdefer new_companions.deinit(self.gpa);
        self.gpa.free(job.path);
        job.path = new_path;
        job.companions.deinit(self.gpa);
        job.companions = new_companions;
        job.tried[ni] = true;
        job.idx = ni;
        job.track_index = 0;
        self.seq += 1;
        job.seq = self.seq;
        self.publishFetch(job.seq, job);
        return .none;
    }

    fn exhaust(self: *Loader, bridge: *Bridge, model: *ui.Model, player: *Player) !PollResult {
        const job = self.job.?;
        const was_startup = job.purpose == .startup;
        const intact = job.engine_intact;
        self.finish(model);
        if (was_startup and player.src == null) return .startup_failed;
        if (intact) {
            if (job.purpose == .advance and !bridge.paused.load(.acquire) and !player.engine.park_after_wait) {
                bridge.loop_count.store(0, .release);
            }
            try self.resumeIntact(player);
        } else {
            parkIdle(bridge, model, player);
        }
        return .none;
    }

    fn resumeIntact(self: *Loader, player: *Player) !void {
        if (self.resume_visuals) |*saved| saved.restore(player.bridge);
        self.resume_visuals = null;
        if (player.src != null) try player.engine.start();
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
        job.companions.deinit(self.gpa);
        self.gpa.free(job.tried);
    }

    pub fn deinit(self: *Loader) void {
        self.zip_cache.deinit(self.gpa);
        self.dropQueued();
        if (self.job) |*job| {
            if (self.state.done_seq.load(.acquire) == job.seq) {
                if (self.state.result) |bytes| self.gpa.free(bytes) else |_| {}
                if (self.state.sibling) |s| self.gpa.free(s);
                if (self.state.sibling2) |s| self.gpa.free(s);
                freeResources(self.gpa, self.state.resources);
                self.state.resources = .empty;
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

test "named resources try alternate paths and survive through decoder loading" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const song = [_]u8{ 0x84, 0, 0 } ++ @as([32]u8, @splat(0)) ++ [_]u8{ 0, 0xfc };
    try dir.dir.writeFile(io, .{ .sub_path = "fixture.sci", .data = &song });
    const path = try gpa.print(".zig-cache/tmp/{s}/fixture.sci", .{dir.sub_path});
    defer gpa.free(path);
    var state = FetchState{ .req_path = path };
    defer freeResources(gpa, state.resources);
    try std.testing.expectError(error.MissingResource, Loader.fetchEntry(gpa, io, &state));
    const bank: [48 * 28]u8 = @splat(0);
    try dir.dir.writeFile(io, .{ .sub_path = "3.pat", .data = &bank });
    const bytes = try Loader.fetchEntry(gpa, io, &state);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), state.resources.items.len);
    try std.testing.expectEqualStrings("sci.patch", state.resources.items[0].name);
    const src = (try format.load(gpa, path, bytes, .{ .sample_rate = 44100, .chip = format.noop_chip, .resources = state.resources.items })).?;
    defer src.deinit(gpa);
    freeResources(gpa, state.resources);
    state.resources = .empty;
    try std.testing.expectEqualStrings("SCI0", src.info().format_name);
    try std.testing.expectEqual(@as(u16, 48), src.views().instruments.?.count);
    try std.testing.expect(src.step(format.noop_chip).done);
}

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
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 0, .next, true));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 2, .next, true));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&identity, &tried, &dead, 2, .prev, true));
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&identity, &tried, &dead, 2, .next, false));
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&identity, &tried, &dead, 0, .prev, false));
    // Shuffled order 2, 3, 1, 0: after 2 comes 3 (dead), then 1.
    const shuffled = [_]usize{ 2, 3, 1, 0 };
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&shuffled, &tried, &dead, 2, .next, true));
    try std.testing.expectEqual(@as(?usize, 1), nextCandidate(&shuffled, &tried, &dead, 0, .prev, true));
    const all_tried = [_]bool{ true, true, true, false };
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&identity, &all_tried, &dead, 1, .next, true));
    try std.testing.expectEqual(@as(?usize, null), nextCandidate(&.{}, &tried, &dead, 1, .next, true));
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

fn requestDetachedOomBody(gpa: std.mem.Allocator, io: Io) !void {
    var h: LoaderHarness = .{};
    try h.init(io, &.{"a.imf"});
    defer h.deinit();

    var loader = Loader{ .gpa = gpa, .io = io };
    defer loader.deinit();
    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/AUDIOHED.WL6");
    try std.testing.expect(loader.busy());
}

test "Loader detached request frees its path once on allocation failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        requestDetachedOomBody,
        .{threaded.io()},
    );
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

test "loading clears the old visualizer before the fetch completes" {
    var h: LoaderHarness = .{};
    try h.init(std.testing.io, &.{ "a.imf", "b.imf" });
    defer h.deinit();
    h.bridge.position_frames.store(1234, .release);
    h.bridge.loop_count.store(2, .release);
    h.bridge.levels[0].store(255, .release);
    h.bridge.pcm_peak.store(255, .release);
    h.bridge.pcm_bands[0].store(255, .release);
    h.bridge.playhead.write(.{ .row = 15, .flags = .{ .has_row = true } });
    h.bridge.channels.write(.{ .channels = 9 });
    h.bridge.sequence.write(.{ .channels = 16 });
    h.bridge.write_log_i.store(10, .release);
    h.model.sampleVisuals();
    try std.testing.expect(h.model.spec_levels[0] > 0);

    var loader = Loader{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer loader.deinit();
    try loader.request(&h.player, &h.model, .jump, 1, .next);

    try std.testing.expect(h.model.loading);
    try std.testing.expectEqualStrings("stream", h.model.viz.name);
    try std.testing.expectEqual(@as(f32, 0), h.model.spec_levels[0]);
    try std.testing.expectEqual(@as(f32, 0), h.model.pcm_peak);
    try std.testing.expectEqual(@as(u8, 0), h.bridge.levels[0].load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), h.bridge.pcm_bands[0].load(.acquire));
    try std.testing.expectEqual(@as(u16, 0), h.bridge.playhead.read().row);
    try std.testing.expectEqual(@as(u16, 0), h.bridge.channels.read().channels);
    try std.testing.expectEqual(@as(u16, 0), h.bridge.sequence.read().channels);
    try std.testing.expectEqual(@as(u32, 0), h.bridge.write_log_i.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1234), h.bridge.position_frames.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), h.bridge.loop_count.load(.acquire));
}

test "a failed skip from a paused track puts its snapshots and register history back" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const PausedSrc = struct {
        pub fn step(_: *@This(), _: format.Chip) format.StepResult {
            return .{ .frames = 1 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "HSC", .visualizer = "tracker" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    const entries = [_][]const u8{ "http://x/a.hsc", "http://x/missing.hsc" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();
    var paused_src = PausedSrc{};
    h.player.src = format.MusicSource.init(&paused_src, "tracker");
    h.engine.source = h.player.src;

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    var chip = view.ChipSnapshot{};
    chip.voices[2].keyed = true;
    h.bridge.paused.store(true, .release);
    h.bridge.playhead.write(.{ .order = 5, .row = 30, .last_instrument = 7, .flags = .{ .has_order = true, .has_row = true } });
    h.bridge.chip.write(chip);
    h.bridge.write_log[3].store(0x31b0, .release);
    h.bridge.write_log_i.store(4, .release);

    try loader.request(&h.player, &h.model, .advance, 1, .next);
    try std.testing.expectEqual(@as(u16, 0), h.bridge.playhead.read().row);
    h.engine.started = true;
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);

    try std.testing.expect(!loader.busy());
    try std.testing.expect(h.bridge.paused.load(.acquire));
    const playhead = h.bridge.playhead.read();
    try std.testing.expectEqual(@as(u16, 5), playhead.order);
    try std.testing.expectEqual(@as(u16, 30), playhead.row);
    try std.testing.expectEqual(@as(u16, 7), playhead.last_instrument);
    try std.testing.expect(h.bridge.chip.read().voices[2].keyed);
    try std.testing.expectEqual(@as(u32, 4), h.bridge.write_log_i.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0x31b0), h.bridge.write_log[3].load(.acquire));

    h.engine.started = false;
    h.player.clearUnplayable(1);
    h.bridge.playhead.write(.{ .order = 6, .row = 12, .flags = .{ .has_order = true, .has_row = true } });
    try loader.request(&h.player, &h.model, .advance, 1, .next);
    try loader.request(&h.player, &h.model, .jump, 1, .next);
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(loader.busy());
    try std.testing.expectEqual(@as(u16, 0), h.bridge.playhead.read().row);
    h.engine.started = true;
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);

    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u16, 6), h.bridge.playhead.read().order);
    try std.testing.expectEqual(@as(u16, 12), h.bridge.playhead.read().row);
    try std.testing.expect(h.bridge.chip.read().voices[2].keyed);
}

test "a failed advance from a playing track clears its song end but keeps a parked one" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Src = struct {
        pub fn step(_: *@This(), _: format.Chip) format.StepResult {
            return .{ .frames = 1 };
        }

        pub fn info(_: *@This()) format.TrackInfo {
            return .{ .format_name = "IMF" };
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/missing.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();
    var src = Src{};
    h.player.src = format.MusicSource.init(&src, "stream");
    h.engine.source = h.player.src;

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    h.bridge.loop_count.store(1, .release);
    try loader.request(&h.player, &h.model, .advance, 1, .next);
    h.engine.started = true;
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 0), h.bridge.loop_count.load(.acquire));

    h.engine.started = false;
    h.player.clearUnplayable(1);
    h.bridge.loop_count.store(1, .release);
    h.bridge.paused.store(true, .release);
    try loader.request(&h.player, &h.model, .advance, 1, .next);
    h.engine.started = true;
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 1), h.bridge.loop_count.load(.acquire));
}

test "Loader scans every entry then reports startup failure when all fetches fail" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf", "http://x/c.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var startup_errors: [entries.len]?anyerror = @splat(null);
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

test "Loader jobs target subtrack zero only when aimed at a different file" {
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
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
    try std.testing.expectEqual(@as(u32, 5), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 3;
    try loader.request(&h.player, &h.model, .advance, 0, .next);
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
    try std.testing.expectEqual(@as(u32, 3), h.player.track_index);
    loader.finish(&h.model);

    h.player.track_index = 7;
    try loader.request(&h.player, &h.model, .replay, 0, .next);
    try std.testing.expectEqual(@as(u32, 7), loader.job.?.track_index);
    loader.finish(&h.model);

    h.player.track_index = 2;
    try loader.request(&h.player, &h.model, .startup, 0, .next);
    try std.testing.expectEqual(@as(u32, 2), loader.job.?.track_index);
    loader.finish(&h.model);

    h.player.track_index = 4;
    try loader.requestDetached(&h.player, &h.model, "solo.imf");
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
    try std.testing.expectEqual(@as(u32, 4), h.player.track_index);
    loader.finish(&h.model);

    h.player.detached_path = try std.testing.allocator.dupe(u8, "solo.imf");
    h.player.track_index = 6;
    try loader.requestDetached(&h.player, &h.model, "solo.imf");
    try std.testing.expectEqual(@as(u32, 6), loader.job.?.track_index);
    loader.finish(&h.model);

    h.player.track_index = 9;
    try loader.requestDetached(&h.player, &h.model, "other.imf");
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
    try std.testing.expectEqual(@as(u32, 9), h.player.track_index);
}

test "adoptArchiveIndex updates a same-file replay and ignores other jobs" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "a.imf", "b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    try std.testing.expect(!loader.adoptArchiveIndex(&h.player, 3));

    h.player.track_index = 1;
    try loader.request(&h.player, &h.model, .replay, 0, .next);
    try std.testing.expect(loader.adoptArchiveIndex(&h.player, 4));
    try std.testing.expectEqual(@as(u32, 4), loader.job.?.track_index);
    try std.testing.expectEqual(@as(?u32, 4), loader.pendingArchiveIndex(&h.player));
    loader.finish(&h.model);

    try loader.request(&h.player, &h.model, .advance, 1, .next);
    try std.testing.expectEqual(@as(?u32, null), loader.pendingArchiveIndex(&h.player));
    try std.testing.expect(!loader.adoptArchiveIndex(&h.player, 2));
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
    loader.finish(&h.model);

    h.player.detached_path = try std.testing.allocator.dupe(u8, "solo.imf");
    h.player.track_index = 6;
    try loader.requestDetached(&h.player, &h.model, "solo.imf");
    try std.testing.expect(loader.adoptArchiveIndex(&h.player, 8));
    try std.testing.expectEqual(@as(u32, 8), loader.job.?.track_index);
    loader.finish(&h.model);

    try loader.requestDetached(&h.player, &h.model, "other.imf");
    try std.testing.expect(!loader.adoptArchiveIndex(&h.player, 8));
    try std.testing.expectEqual(@as(u32, 0), loader.job.?.track_index);
}

test "Loader keeps the playing subtrack index when every substitute fails" {
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
    try loader.request(&h.player, &h.model, .advance, 1, .next);
    var guard: usize = 0;
    while (loader.busy() and guard < 8) : (guard += 1) {
        completeFetch(&loader, error.HttpRequestFailed);
        _ = try loader.poll(&h.bridge, &h.model, &h.player);
    }
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 5), h.player.track_index);
}

test "Loader keeps the R rate when every substitute fails and the old track resumes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.hsc", "http://x/b.hsc", "http://x/c.hsc" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    h.player.live_rate_hz = 700;
    try loader.request(&h.player, &h.model, .advance, 1, .next);
    var guard: usize = 0;
    while (loader.busy() and guard < 8) : (guard += 1) {
        completeFetch(&loader, error.HttpRequestFailed);
        _ = try loader.poll(&h.bridge, &h.model, &h.player);
    }
    try std.testing.expect(!loader.busy());
    try std.testing.expect(h.player.unplayable[1] and h.player.unplayable[2]);
    try std.testing.expectEqual(@as(u32, 700), h.player.live_rate_hz);

    h.player.clearUnplayable(1);
    try loader.request(&h.player, &h.model, .replay, 0, .next);
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expectEqual(@as(usize, 1), loader.job.?.idx);
    try std.testing.expectEqual(@as(u32, 700), h.player.live_rate_hz);
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "DATA"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 0), h.player.live_rate_hz);
}

test "a detached load of another file drops the R rate once its fetch succeeds" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{"http://x/a.imf"};
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();

    h.player.detached_path = try std.testing.allocator.dupe(u8, "http://elsewhere/one.hsc");
    h.player.live_rate_hz = 700;
    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/two.hsc");
    completeFetch(&loader, error.HttpRequestFailed);
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 700), h.player.live_rate_hz);

    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/one.hsc");
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "DATA"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 700), h.player.live_rate_hz);

    h.player.detached_path = try std.testing.allocator.dupe(u8, "http://elsewhere/one.hsc");
    try loader.requestDetached(&h.player, &h.model, "http://elsewhere/two.hsc");
    completeFetch(&loader, try std.testing.allocator.dupe(u8, "DATA"));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(u32, 0), h.player.live_rate_hz);
}

test "a playlist entry's theme tag applies when the entry loads" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = [_][]const u8{ "http://x/a.imf", "http://x/b.imf" };
    var h: LoaderHarness = .{};
    try h.init(io, &entries);
    defer h.deinit();
    h.player.themes = &.{ 5, null };
    h.model.theme_index = 0;

    var loader = Loader{ .gpa = std.testing.allocator, .io = io };
    defer loader.deinit();
    const imf = [_]u8{ 0x20, 0x01, 0x10, 0x00, 0x40, 0x10, 0x10, 0x00 };

    try loader.request(&h.player, &h.model, .jump, 0, .next);
    h.engine.started = true;
    completeFetch(&loader, try std.testing.allocator.dupe(u8, &imf));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expect(!loader.busy());
    try std.testing.expectEqual(@as(usize, 0), h.player.index);
    try std.testing.expectEqual(@as(usize, 5), h.model.theme_index);

    h.model.theme_index = 2;
    h.engine.started = false;
    try loader.request(&h.player, &h.model, .jump, 1, .next);
    h.engine.started = true;
    completeFetch(&loader, try std.testing.allocator.dupe(u8, &imf));
    _ = try loader.poll(&h.bridge, &h.model, &h.player);
    try std.testing.expectEqual(@as(usize, 1), h.player.index);
    try std.testing.expectEqual(@as(usize, 2), h.model.theme_index);
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
    try std.testing.expectEqualStrings("game/AUDIOT.WL6", loader.job.?.companions.sibling.?);
    try std.testing.expectEqualStrings("game/AUDIOT.WL6", loader.state.req_companions.sibling.?);

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
    try std.testing.expectEqualStrings("game/AUDIOHED.CK4", loader.job.?.companions.sibling.?);
    try std.testing.expect(loader.job.?.companions.sibling_alt == null);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.job.?.companions.sibling2.?);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.state.req_companions.sibling2.?);

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
    try std.testing.expectEqualStrings("game/AUDIOT.CK4", loader.job.?.companions.sibling.?);
    try std.testing.expectEqualStrings("game/AUDIO.CK4", loader.job.?.companions.sibling_alt.?);
    try std.testing.expectEqualStrings("game/AUDIODCT.CK4", loader.job.?.companions.sibling2.?);
    try std.testing.expectEqualStrings("game/AUDIO.CK4", loader.state.req_companions.sibling_alt.?);

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
