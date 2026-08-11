//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
// SEHNSUCHT - A classic DOS-style TUI AdLib player -
//   SEHNSUCHT b/c it sounds way better than LONGING
//   and NOSTALGIC was already taken.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const zaudio = @import("zaudio");
const build_options = @import("build_options");

const AudioEngine = @import("audioengine.zig").AudioEngine;
const default_rate = @import("audioengine.zig").default_rate;
const Bridge = @import("bridge.zig").Bridge;
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const format = @import("format.zig");
const Loader = @import("loader.zig").Loader;
const loaderr = @import("loaderr.zig");
const Player = @import("player.zig").Player;
const Direction = @import("player.zig").Direction;
const playlist = @import("playlist.zig");
const remote = @import("remote.zig");
const ui = @import("ui.zig");

// Nothing references it by name, so it looks unused. It is not, don't touch it!
pub const panic = diag.panic;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    diag.arm(io);

    const parseResult = try cli.parse(gpa, arena, io, try init.minimal.args.toSlice(arena));
    const args = parseResult.args orelse return parseResult.exitCode;
    const arg_was_playlist = args.was_playlist;
    const browse_dir = args.browse_dir;
    const entries = args.entries;

    zaudio.init(gpa);
    defer zaudio.deinit();

    var bridge = Bridge{};
    const engine = AudioEngine.create(gpa, &bridge, default_rate) catch {
        cli.printStderr(io, build_options.name ++ ": audio device init failed\n", .{});
        return 1;
    };
    defer engine.destroy(gpa);

    var player = try Player.init(gpa, io, engine, &bridge, .{
        .entries = entries,
        .titles = args.titles,
        .rates = args.rates,
        .name = args.list_name,
        .tick_rate_hz = args.options.tick_rate_hz,
        .track_index = args.options.track_index,
    });
    defer player.deinit();

    // All set up, start the engine and go!
    // ------  ______
    // ---    /|_||_\`.__
    // --    (   _    _ _\
    // -     =`-(_)--(_)-'
    // ~~~~~~~~~~~~~~~~~~~~
    try engine.start();
    defer engine.stop();

    switch (try runUi(init, &bridge, &player, .{
        .browse_dir = browse_dir,
        .show_playlist = arg_was_playlist or entries.len > 1,
    })) {
        .no_terminal => {
            cli.printStderr(io, build_options.name ++ ": cannot open the terminal (an interactive terminal is required)\n", .{});
            return 1;
        },
        .startup_failed => |errs| {
            for (entries, 0..) |entry, i| {
                if (errs[i]) |err| loaderr.printLoadError(io, entry, err);
            }
            if (arg_was_playlist) {
                cli.printStderr(io, build_options.name ++ ": {s}: no playable entries\n", .{args.paths[0]});
            } else if (entries.len > 1) {
                cli.printStderr(io, build_options.name ++ ": no playable files\n", .{});
            }
            return 1;
        },
        .ok => {
            return 0;
        },
    }
}

const Action = enum { none, quit, next, prev, replay, archive_prev, archive_next };

const UiStart = struct {
    browse_dir: ?[]const u8 = null,
    show_playlist: bool = false,
};

const RunResult = union(enum) {
    ok,
    no_terminal,
    startup_failed: []const ?anyerror,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    tick,
};

fn runUi(
    init: std.process.Init,
    bridge: *Bridge,
    player: *Player,
    start: UiStart,
) !RunResult {
    const io = init.io;
    const gpa = init.gpa;
    var buffer: [1024]u8 = undefined;
    var tty = vaxis.Tty.init(io, &buffer) catch return .no_terminal;
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer stopLoop(&loop, &tty, io);

    try enterAltScreen(&vx, &tty);
    try vx.setTitle(tty.writer(), build_options.name);
    vx.setMouseMode(tty.writer(), true) catch {};
    try loop.installResizeHandler();
    try vx.resize(gpa, tty.writer(), try tty.getWinsize());

    var model = try initUiModel(gpa, io, bridge, player, start);
    defer model.deinit();

    var tick_running = std.atomic.Value(bool).init(true);
    var tick_fut = try io.concurrent(tickPoster, .{ &loop, &tick_running, io });
    defer {
        tick_running.store(false, .release);
        tick_fut.await(io);
    }

    const startup_errors = try init.arena.allocator().alloc(?anyerror, player.entries.len);
    @memset(startup_errors, null);
    var loader = Loader{
        .gpa = gpa,
        .io = io,
        .startup_show_playlist = start.show_playlist,
        .startup_errors = startup_errors,
    };
    var fetch_fut = try io.concurrent(Loader.fetchWorker, .{ gpa, io, &loader.state });
    defer {
        loader.shutdown();
        fetch_fut.await(io);
        loader.deinit();
    }
    if (player.entries.len > 0) {
        try loader.request(player, &model, .startup, 0, .next);
    }

    var quit = false;
    var result: RunResult = .ok;
    while (!bridge.quit.load(.acquire) and !quit) {
        var action: Action = .none;
        const ev_first = try loop.nextEvent();
        try handleUiEvent(bridge, &model, player, &vx, gpa, tty.writer(), ev_first, &action);
        while (try loop.tryEvent()) |ev| {
            try handleUiEvent(bridge, &model, player, &vx, gpa, tty.writer(), ev, &action);
        }
        if (action == .quit) quit = true;

        try applyUiAction(gpa, io, bridge, &loader, player, &model, action);

        switch (try loader.poll(bridge, &model, player)) {
            .none => {},
            .startup_failed => {
                result = .{ .startup_failed = startup_errors };
                quit = true;
            },
        }

        model.shuffle = player.shuffle;
        model.loop_all = player.loop_all;
        model.can_playlist_prev = player.canStep(.prev);
        model.can_playlist_next = player.canStep(.next);
        model.playlist_count = player.entries.len;
        model.playlist_unplayable = player.unplayable;

        const end_of_pass = player.multi() and !player.isDetached() and !model.can_playlist_next;
        const one_shot_solo = model.has_track and !model.track.loop and (!player.multi() or player.isDetached());
        bridge.halt_at_songend.store(end_of_pass or one_shot_solo, .release);
        if (quit) break;

        const win = vx.window();
        win.hideCursor();
        model.draw(win);
        try vx.render(tty.writer());
    }
    return result;
}

fn initUiModel(
    gpa: std.mem.Allocator,
    io: Io,
    bridge: *Bridge,
    player: *Player,
    start: UiStart,
) !ui.Model {
    var model = try ui.Model.init(gpa, bridge, .{
        .info = .{ .format_name = "-", .visualizer = "stream" },
        .filename = "",
    });
    model.has_track = false;
    syncPlaylistModel(&model, player);
    model.browse.io = io;
    if (player.entries.len == 0) {
        model.menu = .browse;
        model.menu_view = .browse;
        if (start.browse_dir) |dir| {
            if (gpa.dupe(u8, dir)) |copy| {
                model.browse.path = copy;
            } else |_| {}
        }
        model.browse.ensure() catch {
            model.browse.err_msg = "cannot open directory";
        };
    } else {
        model.menu = .playlist;
        model.menu_view = .playlist;
        model.playlist_list.nav.syncTo(player.index, player.entries.len);
    }
    return model;
}

fn applyUiAction(
    gpa: std.mem.Allocator,
    io: Io,
    bridge: *Bridge,
    loader: *Loader,
    player: *Player,
    model: *ui.Model,
    action: Action,
) !void {
    switch (action) {
        .none => {
            if (model.browse.takePendingPlay()) |path| {
                defer gpa.free(path);
                if (playlist.isPlaylistPath(path)) {
                    try openBrowsePlaylist(gpa, io, loader, player, model, path);
                } else {
                    try loader.requestDetached(player, model, path);
                }
            } else if (model.playlist_list.pending_jump) |idx| {
                model.playlist_list.pending_jump = null;
                try loader.request(player, model, .jump, idx, .next);
            }
            const at_songend = player.multi() and !player.isDetached() and
                !loader.busy() and bridge.loop_count.load(.acquire) > 0;
            if (at_songend) {
                if (try player.stepOrder(.next)) |next_idx| {
                    try loader.request(player, model, .advance, next_idx, .next);
                }
            }
        },
        .archive_prev, .archive_next => {
            const count = @max(1, model.track.archive_track_count);
            const step = if (action == .archive_next) 1 else count - 1;
            player.track_index = (model.track.archive_track_index + step) % count;
            try requestReplay(gpa, loader, player, model);
        },
        .replay => try requestReplay(gpa, loader, player, model),
        .next, .prev => {
            const dir: Direction = if (action == .next) .next else .prev;
            if (loader.sameAdvance(dir)) {
                loader.skipCurrent();
            } else if (player.multi()) {
                if (try player.stepOrder(dir)) |next_idx| {
                    try loader.request(player, model, .advance, next_idx, dir);
                }
            }
        },
        .quit => {},
    }
}

fn requestReplay(
    gpa: std.mem.Allocator,
    loader: *Loader,
    player: *Player,
    model: *ui.Model,
) !void {
    if (player.detached_path) |detached| {
        // requestDetached may clear detached_path before it reads it.
        const copy = try gpa.dupe(u8, detached);
        defer gpa.free(copy);
        try loader.requestDetached(player, model, copy);
    } else if (player.entries.len > 0) {
        try loader.request(player, model, .replay, player.index, .next);
    }
}

fn syncPlaylistModel(model: *ui.Model, player: *const Player) void {
    model.playlist_count = player.entries.len;
    model.playlist_index = player.index;
    model.playlist_entries = player.entries;
    model.playlist_titles = player.titles;
    model.playlist_name = player.name;
    model.playlist_played = player.played;
    model.playlist_unplayable = player.unplayable;
}

fn openBrowsePlaylist(
    gpa: std.mem.Allocator,
    io: Io,
    loader: *Loader,
    player: *Player,
    model: *ui.Model,
    path: []const u8,
) !void {
    const raw = remote.readPathAlloc(gpa, io, path, null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        model.browse.err_msg = "cannot read playlist";
        return;
    };
    defer gpa.free(raw);
    const parsed = playlist.parse(gpa, path, raw) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        model.browse.err_msg = "cannot parse playlist";
        return;
    };
    defer playlist.free(gpa, parsed);
    if (parsed.entries.len == 0) {
        model.browse.err_msg = "playlist has no playable entries";
        return;
    }
    var keep: ?[]u8 = null;
    defer if (keep) |k| gpa.free(k);
    if (player.src != null and player.detached_path == null and player.entries.len > 0) {
        keep = try gpa.dupe(u8, player.entries[player.index % player.entries.len]);
    }
    const fallback_name = try format.dupeDisplayBasename(gpa, path);
    defer gpa.free(fallback_name);
    const list_name = parsed.name orelse
        fallback_name;
    player.replaceEntries(parsed.entries, parsed.titles, parsed.rates, list_name) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        model.browse.err_msg = "cannot load playlist";
        return;
    };
    if (keep) |k| {
        player.detached_path = k;
        keep = null;
    }
    syncPlaylistModel(model, player);
    model.playlist_playing = false;
    model.playlist_list.nav.syncTo(0, player.entries.len);
    model.menu_view = .playlist;
    model.menu = .playlist;
    try loader.request(player, model, .jump, 0, .next);
}

fn handleUiEvent(
    bridge: *Bridge,
    model: *ui.Model,
    player: *Player,
    vx: *vaxis.Vaxis,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    event: Event,
    action: *Action,
) !void {
    switch (event) {
        .key_press => |key| {
            if (key.codepoint == 'c' and key.mods.ctrl) {
                bridge.quit.store(true, .release);
                action.* = .quit;
                return;
            }
            if (try handlePlaylistKey(bridge, model, player, key, action)) return;
            if (model.handleKey(key) == .quit) {
                action.* = .quit;
            }
        },
        .mouse => |mouse| {
            if (model.handleMouse(mouse) == .quit) {
                action.* = .quit;
            }
        },
        .winsize => |ws| {
            vx.resize(gpa, writer, ws) catch {};
        },
        .tick => {
            model.sampleVisuals();
        },
    }
}

/// The playlist half of the status frame's transport row (`[`, `]`, `S`, `L`,
/// `,`, `.`, and Space on a parked one-shot). Matched before the menu and the
/// list panes, like `ui.Model.handleTransportKey`, so focus never swallows a key
/// the row advertises as live. Returns whether the key belonged to the row.
fn handlePlaylistKey(
    bridge: *Bridge,
    model: *ui.Model,
    player: *Player,
    key: vaxis.Key,
    action: *Action,
) !bool {
    if (key.mods.alt or key.mods.ctrl or key.mods.super) return false;
    switch (key.codepoint) {
        '[' => if (action.* == .none) {
            action.* = .prev;
        },
        ']' => if (action.* == .none) {
            action.* = .next;
        },
        's', 'S' => try player.toggleShuffle(),
        'l', 'L' => player.toggleLoop(),
        ',' => if (model.track.archive_track_count > 1 and action.* == .none) {
            action.* = .archive_prev;
        },
        '.' => if (model.track.archive_track_count > 1 and action.* == .none) {
            action.* = .archive_next;
        },
        // A parked one-shot has a finished decoder with nothing to resume into,
        // so Space reloads it. Every other Space is the shell's pause toggle.
        vaxis.Key.space => {
            const parked = model.has_track and !model.track.loop and
                bridge.paused.load(.acquire) and bridge.loop_count.load(.acquire) > 0;
            if (!parked) return false;
            if (action.* == .none) action.* = .replay;
        },
        else => return false,
    }
    return true;
}

fn tickPoster(loop: *vaxis.Loop(Event), running: *std.atomic.Value(bool), io: Io) void {
    while (running.load(.acquire)) {
        io.sleep(.fromMilliseconds(33), .real) catch break;
        _ = loop.tryPostEvent(.tick) catch {};
    }
}

const winconsole = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn WriteConsoleInputW(
        hConsoleInput: std.os.windows.HANDLE,
        lpBuffer: *const vaxis.Tty.INPUT_RECORD,
        nLength: std.os.windows.DWORD,
        lpNumberOfEventsWritten: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn FlushConsoleInputBuffer(
        hConsoleInput: std.os.windows.HANDLE,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// vaxis Loop.stop unblocks its reader with a DSR write (\x1b[5n). On Windows
/// the reply (\x1b[0n) often arrives after alt-screen restore and is left as
/// ^[[0n on the shell prompt. Unblock with a synthetic key and join the
/// reader thread without sending the DSR.
fn stopLoop(loop: *vaxis.Loop(Event), tty: *vaxis.Tty, io: Io) void {
    if (builtin.os.tag == .windows) {
        loop.should_quit = true;
        var rec: vaxis.Tty.INPUT_RECORD = .{
            .EventType = 0x0001,
            .Event = .{ .KeyEvent = .{
                .bKeyDown = .TRUE,
                .wRepeatCount = 1,
                .wVirtualKeyCode = 'Q',
                .wVirtualScanCode = 0,
                .uChar = .{ .UnicodeChar = 'q' },
                .dwControlKeyState = 0,
            } },
        };
        var written: std.os.windows.DWORD = 0;
        _ = winconsole.WriteConsoleInputW(tty.stdin, &rec, 1, &written);
        if (loop.thread) |*thread| {
            thread.await(io);
            loop.thread = null;
        }
        loop.should_quit = false;
        _ = winconsole.FlushConsoleInputBuffer(tty.stdin);
    } else {
        loop.stop();
    }
}

fn enterAltScreen(vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
    try vx.enterAltScreen(tty.writer());
    if (builtin.os.tag == .windows) {
        vx.queries_done.store(true, .unordered);
        try vx.enableDetectedFeatures(tty.writer());
    } else {
        try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    }
}
