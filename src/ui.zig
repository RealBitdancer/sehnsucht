//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Bridge = @import("bridge.zig").Bridge;
const pcm_band_count = @import("bridge.zig").pcm_band_count;
const browse = @import("browse.zig");
const paint = @import("paint.zig");
const format = @import("format.zig");
const playlist = @import("playlist.zig");
const remote = @import("remote.zig");
const Theme = @import("theme.zig").Theme;
const default_theme = @import("theme.zig").default_theme;
const themes = @import("theme.zig").themes;
const theme_browser = @import("theme_browser.zig");
const visualizer = @import("visualizer.zig");

const floor_cols: u16 = 46;
const floor_rows: u16 = 15;

const spark_retention = visualizer.spark_retention;

const volume_gauge_cells: u16 = 6;

pub const MenuTab = enum { browse, playlist, visualize, theme, quit };

pub const MenuItem = struct {
    label: []const u8,
    hotkey: u21,
};

pub const menu_items = [_]MenuItem{
    .{ .label = "Browse", .hotkey = 'b' },
    .{ .label = "Playlist", .hotkey = 'p' },
    .{ .label = "Visualize", .hotkey = 'v' },
    .{ .label = "Theme", .hotkey = 't' },
    .{ .label = "Quit", .hotkey = 'q' },
};

comptime {
    if (menu_items.len != @typeInfo(MenuTab).@"enum".fields.len) {
        @compileError("menu_items must cover every MenuTab");
    }
    for (menu_items) |item| {
        if (std.ascii.toLower(item.label[0]) != item.hotkey) {
            @compileError("menu hotkey must be the label's first letter: " ++ item.label);
        }
    }
}

pub const transport_keys = [_]u21{ vaxis.Key.space, '+', '=', '-', 'm', 'r', ',', '.', 'l', 's', '[', ']' };

const build_options = @import("build_options");
const version = build_options.version;

const spec_release: f32 = 0.045;
const peak_fall: f32 = 0.02;
const peak_hold_ticks: u8 = 15;
const peak_glow_fall: f32 = 0.018;

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_div: u32 = 3;

const notice_hold_ticks: u32 = 150;

const volume_ratio_num: u16 = 23;
const volume_ratio_den: u16 = 20;

const wheel_rows: u8 = 3;

const HitSpan = struct { x0: u16 = 0, x1: u16 = 0 };

pub const Model = struct {
    gpa: std.mem.Allocator,
    bridge: *Bridge,
    viz: *const visualizer.Visualizer,
    view: ?format.TrackerView,
    track: format.TrackInfo,
    source: ?format.MusicSource = null,
    has_track: bool = true,
    loading: bool = false,
    spin_ticks: u32 = 0,
    notice: []const u8 = &.{},
    notice_ticks: u32 = 0,
    filename: []const u8,
    system: []const u8 = "OPL2",
    playlist_index: usize = 0,
    playlist_count: usize = 0,
    playlist_playing: bool = true,
    shuffle: bool = false,
    loop_all: bool = false,
    can_playlist_prev: bool = false,
    can_playlist_next: bool = false,
    playlist_name: []const u8 = &.{},
    playlist_entries: []const []const u8 = &.{},
    playlist_titles: []const ?[]const u8 = &.{},
    playlist_played: []const bool = &.{},
    playlist_unplayable: []const bool = &.{},
    playlist_list: playlist.ListState = .{},
    theme_list: theme_browser.State = .{},
    browse: browse.State,
    menu: MenuTab = .visualize,
    menu_view: MenuTab = .visualize,
    menu_focused: bool = false,
    menu_hit_row: u16 = 0,
    menu_hits: [menu_items.len]HitSpan = @splat(HitSpan{}),
    theme_index: usize = 0,
    paused_view: bool = false,
    tick_rate_hz: ?u32 = null,
    spec_levels: [9]f32 = @splat(0),
    spec_peaks: [9]f32 = @splat(0),
    spec_hold: [9]u8 = @splat(0),
    spec_glow: [9]f32 = @splat(0),
    pcm_bands: [pcm_band_count]f32 = @splat(0),
    pcm_band_peaks: [pcm_band_count]f32 = @splat(0),
    pcm_band_hold: [pcm_band_count]u8 = @splat(0),
    pcm_band_glow: [pcm_band_count]f32 = @splat(0),
    pcm_peak: f32 = 0,
    vu_l: f32 = 0,
    vu_r: f32 = 0,
    vu_peak_l: f32 = 0,
    vu_peak_r: f32 = 0,
    spark: [spark_retention]f32 = @splat(0),
    spark_head: usize = 0,
    spark_len: usize = 0,
    frame_arena: std.heap.ArenaAllocator,

    /// What the shell shows for one track. `filename` is copied, and every other
    /// slice belongs to the decoder and must outlive the model's use of it.
    pub const Track = struct {
        info: format.TrackInfo,
        filename: []const u8,
        view: ?format.TrackerView = null,
        source: ?format.MusicSource = null,
        system: []const u8 = "OPL2",
    };

    pub fn init(gpa: std.mem.Allocator, bridge: *Bridge, track: Track) !Model {
        const viz = visualizer.find(track.info.visualizer) orelse return error.UnknownVisualizer;
        const tick = if (track.source) |s| s.getTickRate() else null;
        const owned_name = try gpa.dupe(u8, track.filename);
        return .{
            .gpa = gpa,
            .bridge = bridge,
            .viz = viz,
            .view = track.view,
            .track = track.info,
            .source = track.source,
            .filename = owned_name,
            .system = track.system,
            .tick_rate_hz = tick,
            .browse = .{ .gpa = gpa },
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Model) void {
        self.gpa.free(self.filename);
        self.gpa.free(self.notice);
        self.browse.deinit();
        self.frame_arena.deinit();
    }

    pub fn selectedTheme(self: *const Model) Theme {
        return themes[self.theme_index % themes.len];
    }

    fn resetVisualMeters(self: *Model) void {
        self.spec_levels = @splat(0);
        self.spec_peaks = @splat(0);
        self.spec_hold = @splat(0);
        self.spec_glow = @splat(0);
        self.pcm_bands = @splat(0);
        self.pcm_band_peaks = @splat(0);
        self.pcm_band_hold = @splat(0);
        self.pcm_band_glow = @splat(0);
        self.pcm_peak = 0;
        self.vu_l = 0;
        self.vu_r = 0;
        self.vu_peak_l = 0;
        self.vu_peak_r = 0;
        self.spark = @splat(0);
        self.spark_head = 0;
        self.spark_len = 0;
    }

    pub fn setTrack(self: *Model, track: Track) !void {
        self.viz = visualizer.find(track.info.visualizer) orelse return error.UnknownVisualizer;
        const owned_name = try self.gpa.dupe(u8, track.filename);
        self.gpa.free(self.filename);
        self.track = track.info;
        self.view = track.view;
        self.source = track.source;
        self.has_track = true;
        self.filename = owned_name;
        self.system = track.system;
        self.tick_rate_hz = if (track.source) |s| s.getTickRate() else null;
        self.resetVisualMeters();
    }

    pub fn clearTrack(self: *Model) void {
        self.viz = visualizer.find("stream") orelse self.viz;
        self.track = .{ .format_name = "-", .visualizer = "stream" };
        self.view = null;
        self.source = null;
        self.has_track = false;
        self.gpa.free(self.filename);
        self.filename = &.{};
        self.system = "OPL2";
        self.tick_rate_hz = null;
        self.resetVisualMeters();
        if (self.menu_view == .visualize) {
            const dest: MenuTab = if (self.playlist_entries.len > 0) .playlist else .browse;
            self.menu_view = dest;
            self.menu = dest;
            if (dest == .browse) {
                self.browse.ensure() catch {
                    self.browse.err_msg = "cannot open directory";
                };
            }
        } else if (!self.menuEnabled(self.menu)) {
            self.menu = self.menu_view;
        }
    }

    pub fn noticeSkip(self: *Model, path: []const u8, reason: []const u8) void {
        var stack: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack);
        const base = remote.displayBasename(fba.allocator(), path);
        const text = std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ base, reason }) catch return;
        self.gpa.free(self.notice);
        self.notice = text;
        self.notice_ticks = notice_hold_ticks;
    }

    pub const InputResult = enum { handled, quit };

    const ActiveList = struct {
        nav: *paint.ListNav,
        count: usize,
    };

    fn activeList(self: *Model) ?ActiveList {
        return switch (self.menu_view) {
            .browse => .{ .nav = &self.browse.nav, .count = self.browse.entries.len },
            .playlist => .{ .nav = &self.playlist_list.nav, .count = self.playlist_entries.len },
            .theme => .{ .nav = &self.theme_list.nav, .count = themes.len },
            else => null,
        };
    }

    fn routeListNavKey(key: vaxis.Key, list: ActiveList) bool {
        switch (key.codepoint) {
            vaxis.Key.up, vaxis.Key.kp_up => list.nav.move(list.count, -1),
            vaxis.Key.down, vaxis.Key.kp_down => list.nav.move(list.count, 1),
            vaxis.Key.page_up, vaxis.Key.kp_page_up => list.nav.page(list.count, -1),
            vaxis.Key.page_down, vaxis.Key.kp_page_down => list.nav.page(list.count, 1),
            vaxis.Key.home, vaxis.Key.kp_home => list.nav.goHome(list.count),
            vaxis.Key.end, vaxis.Key.kp_end => list.nav.goEnd(list.count),
            else => return false,
        }
        return true;
    }

    /// The shell half of the status frame's transport row. Matched before the
    /// menu and the list panes so that focus never swallows a key the row
    /// advertises as live. Returns whether the key belonged to the row.
    pub fn handleTransportKey(self: *Model, key: vaxis.Key) bool {
        if (key.mods.alt or key.mods.ctrl or key.mods.super) return false;
        switch (key.codepoint) {
            vaxis.Key.space => {
                if (self.has_track) {
                    self.bridge.paused.store(!self.bridge.paused.load(.acquire), .release);
                }
            },
            '+', '=' => self.adjustVolume(.up),
            '-' => self.adjustVolume(.down),
            'm', 'M' => {
                if (self.has_track) {
                    self.bridge.muted.store(!self.bridge.muted.load(.acquire), .release);
                }
            },
            'r', 'R' => {
                if (self.source) |src| {
                    if (src.cycleTickRate()) |hz| self.tick_rate_hz = hz;
                }
            },
            else => return false,
        }
        return true;
    }

    pub fn handleKey(self: *Model, key: vaxis.Key) InputResult {
        if (self.handleTransportKey(key)) return .handled;
        const focus_key = (key.codepoint == vaxis.Key.f10 and
            !key.mods.alt and !key.mods.ctrl and !key.mods.super) or
            ((key.codepoint == vaxis.Key.left_alt or key.codepoint == vaxis.Key.right_alt) and
                !key.mods.ctrl and !key.mods.super);
        if (focus_key) {
            self.menu_focused = !self.menu_focused;
            if (!self.menu_focused) self.menu = self.menu_view;
            return .handled;
        }
        if (key.mods.alt and !key.mods.ctrl and !key.mods.super) {
            return self.menuHotkey(key.codepoint) orelse .handled;
        }
        if (key.mods.alt or key.mods.ctrl or key.mods.super) return .handled;
        if (key.codepoint == vaxis.Key.tab) {
            return self.menuCycle(if (key.mods.shift) -1 else 1);
        }
        if (self.menu_focused) {
            if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.kp_left) {
                self.menuMove(-1);
                return .handled;
            }
            if (key.codepoint == vaxis.Key.right or key.codepoint == vaxis.Key.kp_right) {
                self.menuMove(1);
                return .handled;
            }
            if (key.codepoint == vaxis.Key.enter or key.codepoint == vaxis.Key.kp_enter) {
                return self.menuActivate(self.menu);
            }
            if (key.codepoint == vaxis.Key.escape) {
                self.menu_focused = false;
                self.menu = self.menu_view;
                return .handled;
            }
            return self.menuHotkey(key.codepoint) orelse .handled;
        }
        if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.kp_left) {
            if (self.menu_view == .browse) self.browse.goParent();
            return .handled;
        }
        if (key.codepoint == vaxis.Key.right or key.codepoint == vaxis.Key.kp_right) {
            if (self.menu_view == .browse) self.browse.activate();
            return .handled;
        }
        if (self.menu_view == .browse and key.codepoint == vaxis.Key.backspace) {
            self.browse.goParent();
            return .handled;
        }
        if (self.activeList()) |list| {
            if (routeListNavKey(key, list)) return .handled;
        }
        if (key.codepoint == vaxis.Key.enter or key.codepoint == vaxis.Key.kp_enter) {
            switch (self.menu_view) {
                .browse => self.browse.activate(),
                .playlist => self.playlist_list.requestPlay(self.playlist_entries.len),
                .theme => self.theme_index = @min(self.theme_list.nav.cursor, themes.len - 1),
                .visualize, .quit => {},
            }
        }
        return .handled;
    }

    pub fn handleMouse(self: *Model, mouse: vaxis.Mouse) InputResult {
        if (mouse.col < 0 or mouse.row < 0) return .handled;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
            const dir: i8 = if (mouse.button == .wheel_up) -1 else 1;
            if (self.activeList()) |list| {
                var step: u8 = 0;
                while (step < wheel_rows) : (step += 1) {
                    list.nav.move(list.count, dir);
                }
            }
            return .handled;
        }
        if (mouse.type != .press or mouse.button != .left) return .handled;
        if (row == self.menu_hit_row) {
            for (self.menu_hits, 0..) |span, i| {
                if (col >= span.x0 and col < span.x1) {
                    return self.menuActivate(@enumFromInt(i));
                }
            }
        }
        if (self.activeList()) |list| {
            if (list.nav.rowAt(col, row, list.count)) |idx| {
                if (idx != list.nav.cursor) {
                    list.nav.cursor = idx;
                } else switch (self.menu_view) {
                    .browse => self.browse.activate(),
                    .playlist => self.playlist_list.requestPlay(self.playlist_entries.len),
                    .theme => self.theme_index = idx,
                    else => {},
                }
            }
        }
        return .handled;
    }

    fn menuEnabled(self: *const Model, tab: MenuTab) bool {
        return switch (tab) {
            .playlist => self.playlist_entries.len > 0,
            .visualize => self.has_track,
            .theme => themes.len > 0,
            else => true,
        };
    }

    fn menuMove(self: *Model, dir: i8) void {
        const n = menu_items.len;
        var i: usize = @intFromEnum(self.menu);
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            if (dir > 0) {
                i = (i + 1) % n;
            } else {
                i = if (i == 0) n - 1 else i - 1;
            }
            if (self.menuEnabled(@enumFromInt(i))) {
                self.menu = @enumFromInt(i);
                return;
            }
        }
    }

    fn menuCycle(self: *Model, dir: i8) InputResult {
        self.menuMove(dir);
        if (self.menu == .quit) {
            self.menu_focused = true;
            return .handled;
        }
        return self.menuActivate(self.menu);
    }

    fn menuActivate(self: *Model, tab: MenuTab) InputResult {
        if (!self.menuEnabled(tab)) return .handled;
        self.menu = tab;
        self.menu_focused = false;
        if (tab == .quit) {
            self.bridge.quit.store(true, .release);
            return .quit;
        }
        self.menu_view = tab;
        if (tab == .playlist and self.playlist_entries.len > 0) {
            self.playlist_list.nav.syncTo(self.playlist_index, self.playlist_entries.len);
        }
        if (tab == .theme) {
            self.theme_list.nav.syncTo(self.theme_index, themes.len);
        }
        if (tab == .browse) {
            self.browse.ensure() catch {
                self.browse.err_msg = "cannot open directory";
            };
        }
        return .handled;
    }

    fn menuHotkey(self: *Model, cp: u21) ?InputResult {
        const lower: u21 = if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
        for (menu_items, 0..) |item, i| {
            if (item.hotkey != lower) continue;
            if (!self.menuEnabled(@enumFromInt(i))) return .handled;
            return self.menuActivate(@enumFromInt(i));
        }
        return null;
    }

    fn adjustVolume(self: *Model, dir: enum { up, down }) void {
        const cur: u16 = self.bridge.volume.load(.acquire);
        const scaled: u16 = switch (dir) {
            .up => (cur * volume_ratio_num + volume_ratio_den / 2) / volume_ratio_den,
            .down => (cur * volume_ratio_den + volume_ratio_num / 2) / volume_ratio_num,
        };
        // The ratio rounds to a no-op below 8%, so the ends of the range need a
        // guaranteed step of 1 to stay reachable.
        const next: u16 = switch (dir) {
            .up => @min(100, @max(cur + 1, scaled)),
            .down => if (cur == 0) 0 else @min(cur - 1, scaled),
        };
        self.bridge.volume.store(@intCast(next), .release);
        self.bridge.muted.store(false, .release);
    }

    pub fn sampleVisuals(self: *Model) void {
        self.paused_view = self.bridge.paused.load(.acquire);
        if (self.loading) self.spin_ticks +%= 1;
        if (self.notice_ticks > 0) self.notice_ticks -= 1;
        for (0..self.spec_levels.len) |ch| {
            const raw = self.bridge.levels[ch].load(.acquire);
            const target = if (self.paused_view) 0.0 else @as(f32, @floatFromInt(raw)) / 255.0;
            smoothMeter(&self.spec_levels[ch], &self.spec_peaks[ch], &self.spec_hold[ch], &self.spec_glow[ch], target);
        }
        for (0..pcm_band_count) |b| {
            const raw = self.bridge.pcm_bands[b].load(.acquire);
            const target = if (self.paused_view) 0.0 else @as(f32, @floatFromInt(raw)) / 255.0;
            smoothMeter(&self.pcm_bands[b], &self.pcm_band_peaks[b], &self.pcm_band_hold[b], &self.pcm_band_glow[b], target);
        }
        const peak_raw = self.bridge.pcm_peak.load(.acquire);
        const peak_t = if (self.paused_view) 0.0 else @as(f32, @floatFromInt(peak_raw)) / 255.0;
        self.pcm_peak = attackRelease(self.pcm_peak, peak_t);

        const gate: f32 = if (self.paused_view) 0.0 else 1.0;
        const rms_l = gate * @as(f32, @floatFromInt(self.bridge.pcm_rms_l.load(.acquire))) / 255.0;
        const rms_r = gate * @as(f32, @floatFromInt(self.bridge.pcm_rms_r.load(.acquire))) / 255.0;
        self.vu_l = attackRelease(self.vu_l, rms_l);
        self.vu_r = attackRelease(self.vu_r, rms_r);
        const pk_l = gate * @as(f32, @floatFromInt(self.bridge.pcm_peak_l.load(.acquire))) / 255.0;
        const pk_r = gate * @as(f32, @floatFromInt(self.bridge.pcm_peak_r.load(.acquire))) / 255.0;
        self.vu_peak_l = @max(pk_l, self.vu_peak_l - peak_fall);
        self.vu_peak_r = @max(pk_r, self.vu_peak_r - peak_fall);

        if (self.has_track and !self.paused_view) {
            self.spark[self.spark_head] = (rms_l + rms_r) * 0.5;
            self.spark_head = (self.spark_head + 1) % spark_retention;
            if (self.spark_len < spark_retention) self.spark_len += 1;
        }
    }

    pub fn draw(self: *Model, win: vaxis.Window) void {
        _ = self.frame_arena.reset(.retain_capacity);
        const theme = self.selectedTheme();
        win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = theme.style(.shell_fill) });

        self.menu_hits = @splat(HitSpan{});
        self.browse.nav.hit_rows = 0;
        self.playlist_list.nav.hit_rows = 0;
        self.theme_list.nav.hit_rows = 0;

        if (win.width < floor_cols or win.height < floor_rows) {
            const msg = "resize to at least 46x15";
            const x = (win.width -| @as(u16, @intCast(msg.len))) / 2;
            paint.printAt(win, x, win.height / 2, msg, theme.style(.resize_notice));
            return;
        }

        self.drawHeaderFrame(win, theme);
        self.drawVisualizerFrame(win, theme);
        self.drawStatusFrame(win, theme);

        const content = contentWindow(win);
        switch (self.menu_view) {
            .playlist => self.playlist_list.draw(
                content,
                theme,
                self.frame_arena.allocator(),
                self.playlist_name,
                self.playlist_entries,
                self.playlist_titles,
                self.playlist_played,
                self.playlist_unplayable,
                if (self.playlist_playing) self.playlist_index else null,
            ),
            .browse => self.browse.draw(content, theme),
            .theme => self.theme_list.draw(
                content,
                theme,
                self.frame_arena.allocator(),
                &themes,
                self.theme_index,
            ),
            .visualize, .quit => {
                var ctx = visualizer.DrawContext{
                    .win = content,
                    .theme = theme,
                    .bridge = self.bridge,
                    .track = self.track,
                    .view = self.view,
                    .tick_rate_hz = self.tick_rate_hz,
                    .rate_adjustable = self.track.rate_adjustable,
                    .spec_levels = &self.spec_levels,
                    .spec_peaks = &self.spec_peaks,
                    .spec_peak_glow = &self.spec_glow,
                    .pcm_bands = &self.pcm_bands,
                    .pcm_band_peaks = &self.pcm_band_peaks,
                    .pcm_band_peak_glow = &self.pcm_band_glow,
                    .pcm_peak = self.pcm_peak,
                    .vu_l = self.vu_l,
                    .vu_r = self.vu_r,
                    .vu_peak_l = self.vu_peak_l,
                    .vu_peak_r = self.vu_peak_r,
                    .spark = &self.spark,
                    .spark_head = self.spark_head,
                    .spark_len = self.spark_len,
                    .arena = self.frame_arena.allocator(),
                };
                self.viz.draw(&ctx);
            },
        }
    }

    fn contentWindow(win: vaxis.Window) vaxis.Window {
        const y = visualizer.header_frame_h;
        const h = win.height -| visualizer.header_frame_h -| visualizer.status_frame_h;
        return win.child(.{
            .x_off = 1,
            .y_off = y + 1,
            .width = win.width -| 2,
            .height = h -| 2,
        });
    }

    fn elapsedSecs(self: *const Model) u64 {
        const sr = @max(1, self.bridge.sample_rate);
        return self.bridge.position_frames.load(.acquire) / sr;
    }

    fn durationSecs(self: *const Model) ?u64 {
        const src = self.source orelse return null;
        const frames = src.durationFrames() orelse return null;
        return frames / @max(1, self.bridge.sample_rate);
    }

    fn timeText(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const elapsed = self.elapsedSecs();
        if (self.durationSecs()) |total| {
            return std.fmt.allocPrint(arena, "{f} / {f}", .{
                fmtTime(elapsed),
                fmtTime(total),
            }) catch "";
        }
        return std.fmt.allocPrint(arena, "{f}", .{fmtTime(elapsed)}) catch "";
    }

    fn drawHeaderFrame(self: *Model, win: vaxis.Window, theme: Theme) void {
        const box = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = visualizer.header_frame_h,
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = theme.style(.header_frame) },
        });

        const brand = " " ++ build_options.brand ++ " v" ++ version ++ " ";
        const brand_w = win.gwidth(brand);
        const brand_x = (win.width -| brand_w) / 2;
        paint.printAt(win, brand_x, 0, brand, theme.style(.brand));

        self.drawTitleBar(box, theme);
        self.drawMenuBar(win, theme);
    }

    fn drawVisualizerFrame(_: *Model, win: vaxis.Window, theme: Theme) void {
        const y = visualizer.header_frame_h;
        const h = win.height -| visualizer.header_frame_h -| visualizer.status_frame_h;
        _ = win.child(.{
            .x_off = 0,
            .y_off = y,
            .width = win.width,
            .height = h,
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = theme.style(.viz_frame) },
        });
    }

    fn drawStatusHotkeys(self: *Model, win: vaxis.Window, theme: Theme) void {
        if (self.notice_ticks > 0 and self.notice.len != 0) {
            paint.printAt(win, 1, 1, "✗", theme.style(.notice_mark));
            paint.printFit(win, 3, 1, self.notice, win.width -| 4, theme.style(.notice_text));
            return;
        }
        const live = self.has_track;
        const paused = self.paused_view;
        const muted = self.bridge.muted.load(.acquire);
        const vol = self.bridge.volume.load(.acquire);
        const can_vol_up = muted or vol < 100;
        const can_vol_down = muted or vol > 0;

        var buf: [12]paint.Hotkey = undefined;
        var hints: std.ArrayList(paint.Hotkey) = .initBuffer(&buf);
        hints.appendAssumeCapacity(.{
            .key = "⎵",
            .label = if (live and paused) "resume" else "pause",
            .enabled = live,
        });
        hints.appendAssumeCapacity(.{
            .key = "+",
            .label = "",
            .enabled = can_vol_up,
        });
        hints.appendAssumeCapacity(.{
            .key = "-",
            .label = "volume",
            .enabled = can_vol_down,
            .label_enabled = can_vol_up or can_vol_down,
            .glue = true,
        });
        hints.appendAssumeCapacity(.{
            .key = "M",
            .label = if (live and muted) "unmute" else "mute",
            .enabled = live,
        });
        if (live and self.track.rate_adjustable) {
            hints.appendAssumeCapacity(.{ .key = "R", .label = "rate" });
        }
        if (live and self.track.archive_track_count > 1) {
            hints.appendAssumeCapacity(.{ .key = ",", .label = "" });
            hints.appendAssumeCapacity(.{ .key = ".", .label = "track", .glue = true });
        }
        if (self.playlist_count > 1) {
            hints.appendAssumeCapacity(.{
                .key = "L",
                .label = if (self.loop_all) "once" else "loop",
            });
            hints.appendAssumeCapacity(.{
                .key = "S",
                .label = if (self.shuffle) "order" else "shuffle",
            });
            hints.appendAssumeCapacity(.{
                .key = "[",
                .label = "prev",
                .enabled = self.can_playlist_prev,
            });
            hints.appendAssumeCapacity(.{
                .key = "]",
                .label = "next",
                .enabled = self.can_playlist_next,
                .glue = true,
            });
        }
        paint.drawHotkeyHints(win, theme, 1, hints.items, 1);
    }

    fn drawStatusFrame(self: *Model, win: vaxis.Window, theme: Theme) void {
        const y = win.height -| visualizer.status_frame_h;
        const box = win.child(.{
            .x_off = 0,
            .y_off = y,
            .width = win.width,
            .height = visualizer.status_frame_h,
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = theme.style(.status_frame) },
        });
        self.drawStatusBar(box, theme);
        self.drawStatusHotkeys(box, theme);
    }

    fn drawTitleBar(self: *Model, win: vaxis.Window, theme: Theme) void {
        paint.fillRow(win, 0, theme.style(.shell_fill));
        paint.fillRow(win, 1, theme.style(.shell_fill));

        const arena = self.frame_arena.allocator();

        const stopped = !self.has_track;
        const state: struct { txt: []const u8, style: vaxis.Style } = if (self.loading)
            .{ .txt = "[Loading]", .style = theme.style(.state_loading) }
        else if (stopped)
            .{ .txt = "[Stopped]", .style = theme.style(.state_stopped) }
        else if (self.paused_view)
            .{ .txt = "[Paused]", .style = theme.style(.state_paused) }
        else
            .{ .txt = "[Playing]", .style = theme.style(.state_playing) };
        paint.printAt(win, 1, 0, state.txt, state.style);
        var left0: u16 = 1 + @as(u16, @intCast(state.txt.len));
        if (self.playlist_count > 1 and self.playlist_playing) {
            const pos = std.fmt.allocPrint(arena, "{d}/{d}", .{
                self.playlist_index + 1,
                self.playlist_count,
            }) catch "";
            paint.printAt(win, left0 + 1, 0, pos, theme.style(.playlist_pos));
            left0 += 1 + @as(u16, @intCast(pos.len));
        }

        const muted = self.bridge.muted.load(.acquire);
        const vol = self.bridge.volume.load(.acquire);
        const pct: []const u8 = if (muted)
            "mute"
        else
            std.fmt.allocPrint(arena, "{d: >3}%", .{vol}) catch "";
        const vol_w: u16 = 8 + volume_gauge_cells + 1 + 4;
        const vol_x = win.width -| vol_w -| 1;
        {
            var x = vol_x;
            paint.printAt(win, x, 0, "Volume: ", theme.style(.volume_label));
            x += 8;
            const filled: u16 = if (muted) 0 else (@as(u16, vol) * volume_gauge_cells + 50) / 100;
            for (0..volume_gauge_cells) |i| {
                const on = i < filled;
                win.writeCell(x + @as(u16, @intCast(i)), 0, .{
                    .char = .{ .grapheme = paint.eighths[i], .width = 1 },
                    .style = .{
                        .fg = if (on) theme.colors.volume_gauge_on_fg else theme.colors.volume_gauge_off_fg,
                        .bg = theme.colors.bg,
                    },
                });
            }
            x += volume_gauge_cells + 1;
            paint.printAt(win, x, 0, pct, theme.style(.volume_value));
        }

        const embedded: ?[]const u8 = if (self.track.title_embedded) self.track.title else null;
        const curated: ?[]const u8 = if (self.has_track and self.playlist_playing and
            self.playlist_index < self.playlist_titles.len)
            self.playlist_titles[self.playlist_index]
        else
            null;
        const title = embedded orelse curated orelse self.track.title orelse
            format.stemOf(remote.displayBasename(arena, self.filename));
        printCentered(win, 0, title, theme.style(.title_text), left0, vol_x);

        const time_txt = self.timeText(arena);
        paint.printAt(win, 1, 1, time_txt, theme.style(.title_time));
        var left1: u16 = 1 + @as(u16, @intCast(time_txt.len));
        if (!stopped) {
            const tag = std.fmt.allocPrint(arena, "({s} · {s})", .{
                self.track.format_name,
                self.system,
            }) catch "";
            paint.printAt(win, left1 + 1, 1, tag, theme.style(.format_tag));
            left1 += 1 + win.gwidth(tag);
        }

        var right1 = win.width -| 1;
        {
            // Rightmost first. Mute sits outside the playlist pair, so it keeps
            // its column when that pair is hidden.
            const playlist_lights = self.playlist_count > 1;
            const lights = [_]struct { icon: []const u8, on: bool, shown: bool = true }{
                .{ .icon = "⊘", .on = muted },
                .{ .icon = "⤨", .on = self.shuffle, .shown = playlist_lights },
                .{ .icon = "↻", .on = self.loop_all, .shown = playlist_lights },
            };
            for (lights) |light| {
                if (!light.shown) continue;
                right1 -|= win.gwidth(light.icon);
                const style = if (light.on) theme.style(.mode_light_on) else theme.style(.mode_light_off);
                paint.printAt(win, right1, 1, light.icon, style);
                right1 -|= 1;
            }
        }

        const artist = self.track.artist orelse "";
        const game = self.track.game orelse "";
        const line: []const u8 = if (artist.len > 0 and game.len > 0)
            std.fmt.allocPrint(arena, "{s} - {s}", .{ artist, game }) catch ""
        else if (artist.len > 0)
            artist
        else
            game;
        if (line.len > 0) printCentered(win, 1, line, theme.style(.artist_line), left1, right1);
    }

    fn drawMenuBar(self: *Model, win: vaxis.Window, theme: Theme) void {
        const row = visualizer.header_frame_h -| 1;

        var total: u16 = 0;
        for (menu_items) |item| {
            total += 2 + @as(u16, @intCast(item.label.len));
        }
        var x = (win.width -| total) / 2;
        self.menu_hit_row = row;
        for (menu_items, 0..) |item, i| {
            const l = item.label;
            const tab: MenuTab = @enumFromInt(i);
            self.menu_hits[i] = .{ .x0 = x, .x1 = x + 2 + @as(u16, @intCast(l.len)) };
            const focused = self.menu_focused and self.menu == tab;
            const open = self.menu_view == tab and tab != .quit;
            const enabled = self.menuEnabled(tab);

            const base: vaxis.Style = if (focused and enabled)
                theme.style(.menu_focus)
            else if (open and enabled)
                theme.style(.menu_open)
            else if (enabled)
                theme.style(.menu_enabled)
            else
                theme.style(.menu_disabled);

            const key_style: vaxis.Style = if (focused and enabled)
                theme.style(.menu_hotkey_focus)
            else if (open and enabled)
                theme.style(.menu_hotkey_open)
            else if (enabled)
                theme.style(.menu_hotkey)
            else
                theme.style(.menu_hotkey_disabled);

            paint.printAt(win, x, row, " ", base);
            paint.printAt(win, x + 1, row, l[0..1], key_style);
            paint.printAt(win, x + 2, row, l[1..], base);
            paint.printAt(win, x + 1 + @as(u16, @intCast(l.len)), row, " ", base);
            x += 2 + @as(u16, @intCast(l.len));
        }
    }

    fn drawStatusBar(self: *Model, win: vaxis.Window, theme: Theme) void {
        const row: u16 = 0;
        const arena = self.frame_arena.allocator();

        const icon: []const u8 = if (self.loading)
            spinner_frames[(self.spin_ticks / spinner_div) % spinner_frames.len]
        else if (!self.has_track)
            "■"
        else if (self.paused_view)
            "▮▮"
        else
            "▶";
        paint.printAt(win, 1, row, icon, theme.style(.transport_icon));

        const time_txt = self.timeText(arena);
        const tx = win.width -| 1 -| @as(u16, @intCast(time_txt.len));
        paint.printAt(win, tx, row, time_txt, theme.style(.status_time));

        var bar_end = tx -| 2;
        const loops = self.bridge.loop_count.load(.acquire);
        if (loops > 0) {
            const loop_txt = std.fmt.allocPrint(arena, "Loop {d}", .{loops}) catch "";
            const lx = tx -| 2 -| @as(u16, @intCast(loop_txt.len));
            paint.printAt(win, lx, row, loop_txt, theme.style(.loop_count));
            bar_end = lx -| 2;
        }

        const bar_x: u16 = 4;
        if (bar_end <= bar_x) return;
        const bar_w = bar_end - bar_x;

        const pos_frames = self.bridge.position_frames.load(.acquire);
        const dur_frames: ?u64 = if (self.source) |s| s.durationFrames() else null;
        const filled: u16 = if (dur_frames) |df|
            @intCast(@min(bar_w, pos_frames * bar_w / @max(1, df)))
        else
            0;
        for (0..bar_w) |i| {
            const on = i < filled;
            win.writeCell(bar_x + @as(u16, @intCast(i)), row, .{
                .char = .{ .grapheme = if (on) "━" else "─", .width = 1 },
                .style = .{
                    .fg = if (on) theme.colors.progress_on_fg else theme.colors.progress_off_fg,
                    .bg = theme.colors.bg,
                },
            });
        }
    }
};

fn printCentered(
    win: vaxis.Window,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
    left_end: u16,
    right_start: u16,
) void {
    const gap_x = left_end + 2;
    if (right_start <= gap_x + 2) return;
    const gap_w = right_start - 2 - gap_x;
    const tw = @min(win.gwidth(text), gap_w);
    if (tw == 0) return;
    var x = (win.width -| tw) / 2;
    if (x < gap_x) x = gap_x;
    if (x + tw > right_start - 2) x = right_start - 2 - tw;
    paint.printFit(win, x, row, text, gap_w, style);
}

const TimeFmt = struct {
    secs: u64,

    pub fn format(self: TimeFmt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.secs >= 3600) {
            try writer.print("{d}:{d:0>2}:{d:0>2}", .{
                self.secs / 3600,
                (self.secs / 60) % 60,
                self.secs % 60,
            });
        } else {
            try writer.print("{d}:{d:0>2}", .{ self.secs / 60, self.secs % 60 });
        }
    }
};

fn fmtTime(secs: u64) TimeFmt {
    return .{ .secs = secs };
}

fn attackRelease(cur: f32, target: f32) f32 {
    return if (target > cur) target else @max(cur - spec_release, target);
}

fn smoothMeter(level: *f32, peak: *f32, hold: *u8, glow: *f32, target: f32) void {
    level.* = attackRelease(level.*, target);
    if (level.* > peak.*) {
        peak.* = level.*;
        hold.* = peak_hold_ticks;
        glow.* = 1.0;
    } else if (hold.* > 0) {
        hold.* -= 1;
    } else {
        peak.* = @max(peak.* - peak_fall, 0);
        glow.* = @max(glow.* - peak_glow_fall, 0);
    }
}

// --- tests -------------------------------------------------------------------

test "setTrack swaps visualizer and resets meters" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();
    m.spec_levels[0] = 0.7;
    m.pcm_bands[0] = 0.4;
    m.pcm_peak = 0.5;

    const view = format.TrackerView{
        .ctx = undefined,
        .channels = 9,
        .rows_per_pattern = 64,
        .num_patterns = 1,
        .order = &.{0},
        .cell = undefined,
        .instrument = undefined,
    };
    const next = format.TrackInfo{ .format_name = "HSC", .visualizer = "tracker" };
    try m.setTrack(.{ .info = next, .filename = "b.hsc", .view = view });

    try std.testing.expectEqualStrings("tracker", m.viz.name);
    try std.testing.expectEqualStrings("b.hsc", m.filename);
    try std.testing.expectEqual(@as(f32, 0), m.spec_levels[0]);
    try std.testing.expectEqual(@as(f32, 0), m.pcm_bands[0]);
    try std.testing.expectEqual(@as(f32, 0), m.pcm_peak);

    const bad = format.TrackInfo{ .format_name = "X", .visualizer = "nope" };
    try std.testing.expectError(error.UnknownVisualizer, m.setTrack(.{ .info = bad, .filename = "x" }));
}

fn testRowText(screen: *vaxis.Screen, buf: []u8, row: u16, width: u16) []const u8 {
    for (0..width) |c| {
        const cell = screen.readCell(@intCast(c), row).?;
        const g = cell.char.grapheme;
        buf[c] = if (g.len == 1) g[0] else '?';
    }
    return buf[0..width];
}

test "shell bars stay intact across widths" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{
        .format_name = "IMF",
        .visualizer = "stream",
        .rate_adjustable = true,
    };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "duke2.imf" });
    defer m.deinit();
    m.playlist_count = 6;
    m.playlist_index = 2;

    const height: u16 = 16;
    var width: u16 = 46;
    while (width <= 120) : (width += 1) {
        var screen = try vaxis.Screen.init(gpa, .{
            .rows = height,
            .cols = width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(gpa);
        screen.width_method = .unicode;
        const win = vaxis.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = width,
            .height = height,
            .screen = &screen,
        };
        m.draw(win);

        var buf: [120]u8 = undefined;
        const row0 = testRowText(&screen, &buf, 0, width);
        try std.testing.expect(std.mem.indexOf(u8, row0, build_options.brand ++ " v") != null);

        var buf1: [120]u8 = undefined;
        const row1 = testRowText(&screen, &buf1, 1, width);
        try std.testing.expect(std.mem.indexOf(u8, row1, "[Playing]") != null);
        try std.testing.expect(std.mem.indexOf(u8, row1, "3/6") != null);
        try std.testing.expect(std.mem.indexOf(u8, row1, "duke2") != null);
        try std.testing.expect(std.mem.indexOf(u8, row1, ".imf") == null);
        try std.testing.expect(std.mem.indexOf(u8, row1, "Volume:") != null);
        try std.testing.expect(std.mem.indexOf(u8, row1, "100%") != null);

        var buf2: [120]u8 = undefined;
        const row2 = testRowText(&screen, &buf2, 2, width);
        try std.testing.expect(std.mem.indexOf(u8, row2, "0:00") != null);
        try std.testing.expect(std.mem.indexOf(u8, row2, "(IMF") != null);

        var buf3: [120]u8 = undefined;
        const row3 = testRowText(&screen, &buf3, 3, width);
        try std.testing.expect(std.mem.indexOf(u8, row3, "Browse") != null);
        try std.testing.expect(std.mem.indexOf(u8, row3, "Playlist") != null);
        try std.testing.expect(std.mem.indexOf(u8, row3, "Visualize") != null);
        try std.testing.expect(std.mem.indexOf(u8, row3, "Theme") != null);
        try std.testing.expect(std.mem.indexOf(u8, row3, "Quit") != null);
        try std.testing.expect(m.menu == .visualize);

        var buf4: [120]u8 = undefined;
        const status_row = height - visualizer.status_frame_h + 1;
        const bottom = testRowText(&screen, &buf4, status_row, width);
        try std.testing.expect(std.mem.indexOf(u8, bottom, "0:00") != null);
    }
}

test "shell bars show pause state and duration" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    br.sample_rate = 100;
    br.paused.store(true, .release);
    br.position_frames.store(5000, .release);
    br.loop_count.store(2, .release);

    const Stub = struct {
        fn step(_: *anyopaque, _: format.Chip) format.StepResult {
            return .{ .frames = 0 };
        }
        fn info(_: *anyopaque) format.TrackInfo {
            return .{ .format_name = "VGM", .visualizer = "stream" };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
        fn dur(_: *anyopaque) u64 {
            return 20000;
        }
        const vt = format.MusicSource.VTable{
            .step = step,
            .info = info,
            .deinit = deinit,
            .durationFrames = dur,
        };
    };
    var stub_state: u8 = 0;
    const src = format.MusicSource{ .ptr = &stub_state, .vtable = &Stub.vt };

    const track = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "t.vgm", .source = src });
    defer m.deinit();
    m.sampleVisuals();

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    var buf: [80]u8 = undefined;
    const row1 = testRowText(&screen, &buf, 1, width);
    try std.testing.expect(std.mem.indexOf(u8, row1, "[Paused]") != null);

    var buf2: [80]u8 = undefined;
    const row2 = testRowText(&screen, &buf2, 2, width);
    try std.testing.expect(std.mem.indexOf(u8, row2, "0:50 / 3:20") != null);

    var buf3: [80]u8 = undefined;
    const row3 = testRowText(&screen, &buf3, 3, width);
    try std.testing.expect(std.mem.indexOf(u8, row3, "Visualize") != null);
    try std.testing.expect(std.mem.indexOf(u8, row3, "Theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, row3, "Quit") != null);

    var buf4: [80]u8 = undefined;
    const bottom = testRowText(&screen, &buf4, height - visualizer.status_frame_h + 1, width);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "Loop 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "0:50 / 3:20") != null);
}

test "the mute light is always drawn and the playlist lights sit inside it" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };

    const theme = default_theme;
    const light_row: u16 = 2;
    const light_x = width - 3;

    m.draw(win);
    const off = screen.readCell(light_x, light_row).?;
    try std.testing.expectEqualStrings("⊘", off.char.grapheme);
    try std.testing.expectEqual(theme.style(.mode_light_off).fg, off.style.fg);

    br.muted.store(true, .release);
    m.playlist_count = 3;
    m.draw(win);
    const on = screen.readCell(light_x, light_row).?;
    try std.testing.expectEqualStrings("⊘", on.char.grapheme);
    try std.testing.expectEqual(theme.style(.mode_light_on).fg, on.style.fg);

    const shuffle = screen.readCell(light_x - 2, light_row).?;
    try std.testing.expectEqualStrings("⤨", shuffle.char.grapheme);
    const loop = screen.readCell(light_x - 4, light_row).?;
    try std.testing.expectEqualStrings("↻", loop.char.grapheme);
}

test "vu meters and spark history follow the bridge" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "t.vgm" });
    defer m.deinit();

    br.pcm_rms_l.store(128, .release);
    br.pcm_rms_r.store(64, .release);
    br.pcm_peak_l.store(255, .release);
    br.pcm_peak_r.store(200, .release);
    m.sampleVisuals();

    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), m.vu_l, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), m.vu_r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m.vu_peak_l, 0.01);
    try std.testing.expectEqual(@as(usize, 1), m.spark_len);

    br.paused.store(true, .release);
    m.sampleVisuals();
    try std.testing.expect(m.vu_l < 128.0 / 255.0);
    try std.testing.expectEqual(@as(usize, 1), m.spark_len);

    br.paused.store(false, .release);
    const next = format.TrackInfo{ .format_name = "DRO", .visualizer = "stream" };
    try m.setTrack(.{ .info = next, .filename = "u.dro" });
    try std.testing.expectEqual(@as(f32, 0), m.vu_l);
    try std.testing.expectEqual(@as(f32, 0), m.vu_peak_l);
    try std.testing.expectEqual(@as(usize, 0), m.spark_len);
}

test "rate hotkey appears on the key row only when adjustable" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{
        .format_name = "IMF",
        .visualizer = "stream",
        .rate_adjustable = true,
    };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const width: u16 = 60;
    const height: u16 = 16;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const key_row = height - visualizer.status_frame_h + 2;
    const border_row = height - visualizer.status_frame_h - 1;
    var buf: [60]u8 = undefined;
    const row = testRowText(&screen, &buf, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row, "R rate") != null);

    var bbuf: [60]u8 = undefined;
    const border = testRowText(&screen, &bbuf, border_row, width);
    try std.testing.expect(std.mem.indexOf(u8, border, "rate") == null);

    const vgm = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    try m.setTrack(.{ .info = vgm, .filename = "t.vgm" });
    m.draw(win);
    var buf2: [60]u8 = undefined;
    const row2 = testRowText(&screen, &buf2, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row2, "R rate") == null);
}

test "status frame key row shows shell playback shortcuts" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "t.vgm" });
    defer m.deinit();

    const width: u16 = 72;
    const height: u16 = 16;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const progress_row = height - visualizer.status_frame_h + 1;
    const key_row = progress_row + 1;
    var buf: [72]u8 = undefined;
    const row = testRowText(&screen, &buf, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row, "pause") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "mute") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, " ? ") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "[ prev") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "] next") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "Browse") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "Quit") == null);

    m.paused_view = true;
    br.muted.store(true, .release);
    m.draw(win);
    var buf_t: [72]u8 = undefined;
    const row_t = testRowText(&screen, &buf_t, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row_t, "resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, row_t, "unmute") != null);

    m.playlist_count = 1;
    m.draw(win);
    var buf_s: [72]u8 = undefined;
    const row_s = testRowText(&screen, &buf_s, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row_s, "loop") == null);
    try std.testing.expect(std.mem.indexOf(u8, row_s, "shuffle") == null);

    m.playlist_count = 3;
    m.draw(win);
    var buf2: [72]u8 = undefined;
    const row2 = testRowText(&screen, &buf2, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row2, "L loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "S shuffle") != null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "[ prev") != null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "] next") != null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "prev ? ]") == null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "prev ] next") != null);

    m.has_track = false;
    m.draw(win);
    var buf3: [72]u8 = undefined;
    const row3 = testRowText(&screen, &buf3, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row3, "pause") != null or std.mem.indexOf(u8, row3, "resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, row3, "volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, row3, "mute") != null or std.mem.indexOf(u8, row3, "unmute") != null);
}

test "theme menu opens browser and applies selected theme" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    _ = m.handleKey(.{ .codepoint = 't', .mods = .{ .ctrl = true } });
    try std.testing.expect(m.menu_view == .visualize);
    try std.testing.expectEqualStrings(default_theme.display_name, m.selectedTheme().display_name);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    _ = m.handleKey(.{ .codepoint = 't' });
    try std.testing.expect(m.menu_view == .theme);
    try std.testing.expectEqual(@as(usize, 0), m.theme_list.nav.cursor);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.down });
    _ = m.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(themes[1].display_name, m.selectedTheme().display_name);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.home });
    _ = m.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(default_theme.display_name, m.selectedTheme().display_name);
}

test "r cycles the tick rate and modified r does not" {
    const Stub = struct {
        var rate: u32 = 560;
        fn step(_: *anyopaque, _: format.Chip) format.StepResult {
            return .{ .frames = 0 };
        }
        fn info(_: *anyopaque) format.TrackInfo {
            return .{ .format_name = "IMF", .visualizer = "stream" };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
        fn get(_: *anyopaque) u32 {
            return rate;
        }
        fn set(_: *anyopaque, hz: u32) void {
            rate = hz;
        }
        const vt = format.MusicSource.VTable{
            .step = step,
            .info = info,
            .deinit = deinit,
            .getTickRate = get,
            .setTickRate = set,
        };
    };
    Stub.rate = 560;
    var stub_state: u8 = 0;
    const src = format.MusicSource{ .ptr = &stub_state, .vtable = &Stub.vt };

    var br = Bridge{};
    const track = format.TrackInfo{
        .format_name = "IMF",
        .visualizer = "stream",
        .rate_adjustable = true,
    };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf", .source = src });
    defer m.deinit();
    try std.testing.expectEqual(@as(?u32, 560), m.tick_rate_hz);

    _ = m.handleKey(.{ .codepoint = 'r' });
    try std.testing.expectEqual(@as(u32, 700), Stub.rate);
    try std.testing.expectEqual(@as(?u32, 700), m.tick_rate_hz);

    _ = m.handleKey(.{ .codepoint = 'R' });
    try std.testing.expectEqual(@as(?u32, 280), m.tick_rate_hz);

    _ = m.handleKey(.{ .codepoint = 'r', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(u32, 280), Stub.rate);
    try std.testing.expectEqual(@as(?u32, 280), m.tick_rate_hz);
}

test "F10 and Alt focus the menu and navigation moves among enabled items" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    try std.testing.expect(m.menu == .visualize);
    try std.testing.expect(m.menu_view == .visualize);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .visualize);
    try std.testing.expect(!m.menu_focused);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.left_alt });
    try std.testing.expect(m.menu_focused);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right_alt });
    try std.testing.expect(!m.menu_focused);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.menu_focused);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .theme);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .quit);
    try std.testing.expect(m.menu_view == .visualize);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .browse);
    try std.testing.expect(m.menu_view == .visualize);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .visualize);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .browse);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .quit);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .theme);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .visualize);
    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.enter }) != .quit);
    try std.testing.expect(!br.quit.load(.acquire));
    try std.testing.expect(m.menu_view == .visualize);
    try std.testing.expect(!m.menu_focused);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.enter }) == .quit);
    try std.testing.expect(br.quit.load(.acquire));
    try std.testing.expect(m.menu_view == .visualize);
}

test "tab cycles menu views and only focuses action items" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();
    const entries = [_][]const u8{"a.imf"};
    m.playlist_entries = &entries;

    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expect(m.menu_view == .theme);
    try std.testing.expect(!m.menu_focused);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expect(m.menu == .quit);
    try std.testing.expect(m.menu_view == .theme);
    try std.testing.expect(m.menu_focused);
    try std.testing.expect(!br.quit.load(.acquire));

    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expect(m.menu_view == .browse);
    try std.testing.expect(!m.menu_focused);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expect(m.menu_view == .playlist);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } });
    try std.testing.expect(m.menu_view == .browse);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } });
    try std.testing.expect(m.menu == .quit);
    try std.testing.expect(m.menu_view == .browse);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } });
    try std.testing.expect(m.menu_view == .theme);
}

test "Alt menu accelerators respect enabled items" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    try std.testing.expect(m.handleKey(.{ .codepoint = 'b' }) != .quit);
    try std.testing.expect(m.menu_view == .visualize);

    try std.testing.expect(m.handleKey(.{ .codepoint = 'b', .mods = .{ .alt = true } }) != .quit);
    try std.testing.expect(m.menu == .browse);
    try std.testing.expect(m.menu_view == .browse);

    try std.testing.expect(m.handleKey(.{ .codepoint = 'P', .mods = .{ .alt = true } }) != .quit);
    try std.testing.expect(m.menu == .browse);
    try std.testing.expect(m.menu_view == .browse);

    const entries = [_][]const u8{"a.hsc"};
    m.playlist_entries = &entries;
    try std.testing.expect(m.handleKey(.{ .codepoint = 'P', .mods = .{ .alt = true } }) != .quit);
    try std.testing.expect(m.menu == .playlist);
    try std.testing.expect(m.menu_view == .playlist);

    try std.testing.expect(m.handleKey(.{ .codepoint = 'v', .mods = .{ .alt = true } }) != .quit);
    try std.testing.expect(m.menu == .visualize);
    try std.testing.expect(m.menu_view == .visualize);

    try std.testing.expect(m.handleKey(.{ .codepoint = 'q', .mods = .{ .alt = true } }) == .quit);
    try std.testing.expect(m.menu == .quit);
    try std.testing.expect(br.quit.load(.acquire));
}

test "visualize tab is disabled until a track loads" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();
    m.has_track = false;
    m.menu = .browse;
    m.menu_view = .browse;

    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.handleKey(.{ .codepoint = 'v' }) != .quit);
    try std.testing.expect(m.menu == .browse);
    try std.testing.expect(m.menu_view == .browse);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });

    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .browse);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .browse);

    const next = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    try m.setTrack(.{ .info = next, .filename = "t.vgm" });
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.handleKey(.{ .codepoint = 'v' }) != .quit);
    try std.testing.expect(m.menu == .visualize);
    try std.testing.expect(m.menu_view == .visualize);
}

test "playlist view lists entries and keeps open view under quit focus" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "music/one.hsc", "music/two.vgm", "music/three.imf" };
    m.playlist_entries = &entries;
    m.playlist_count = entries.len;
    m.playlist_index = 1;
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.handleKey(.{ .codepoint = 'p' }) != .quit);
    try std.testing.expect(m.menu_view == .playlist);
    try std.testing.expectEqual(@as(usize, 1), m.playlist_list.nav.cursor);

    m.menu = .quit;
    try std.testing.expect(m.menu_view == .playlist);

    const width: u16 = 60;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    var found_one = false;
    var found_two = false;
    var found_three = false;
    var found_header = false;
    var found_format = false;
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        var buf: [60]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, "track") != null) found_header = true;
        if (std.mem.indexOf(u8, row, "Title") != null) found_format = true;
        if (std.mem.indexOf(u8, row, "one.hsc") != null) found_one = true;
        if (std.mem.indexOf(u8, row, "two.vgm") != null) found_two = true;
        if (std.mem.indexOf(u8, row, "three.imf") != null) found_three = true;
    }
    try std.testing.expect(found_header);
    try std.testing.expect(found_format);
    try std.testing.expect(found_one);
    try std.testing.expect(found_two);
    try std.testing.expect(found_three);
}

test "browse cursor activates play request for music" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    m.browse.path = try std.testing.allocator.dupe(u8, "music");
    const entries = try std.testing.allocator.alloc(browse.Entry, 3);
    entries[0] = .{ .name = "..", .kind = .dir };
    entries[1] = .{ .name = try std.testing.allocator.dupe(u8, "sub"), .kind = .dir };
    entries[2] = .{ .name = try std.testing.allocator.dupe(u8, "tune.hsc"), .kind = .music };
    m.browse.entries = entries;
    m.menu = .browse;
    m.menu_view = .browse;
    m.browse.nav.cursor = 2;

    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.enter }) != .quit);
    const path = m.browse.takePendingPlay() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "tune.hsc") != null);

    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.right }) != .quit);
    try std.testing.expect(m.menu == .browse);
    const via_right = m.browse.takePendingPlay() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(via_right);
    try std.testing.expect(std.mem.indexOf(u8, via_right, "tune.hsc") != null);
}

test "enter acts on the open list even when focus strayed" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm" };
    m.playlist_entries = &entries;
    m.playlist_count = 2;
    m.menu_view = .playlist;
    m.menu = .quit;

    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.enter }) != .quit);
    try std.testing.expect(!br.quit.load(.acquire));
    try std.testing.expectEqual(@as(?usize, 0), m.playlist_list.pending_jump);
}

test "browse and playlist panes draw navigation key bars" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    m.browse.path = try gpa.dupe(u8, "music");
    const b_entries = try gpa.alloc(browse.Entry, 1);
    b_entries[0] = .{ .name = try gpa.dupe(u8, "tune.hsc"), .kind = .music };
    m.browse.entries = b_entries;
    m.menu = .browse;
    m.menu_view = .browse;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const content_bottom = height - visualizer.status_frame_h - 2;
    var buf: [80]u8 = undefined;
    const brow = testRowText(&screen, &buf, content_bottom, width);
    try std.testing.expect(std.mem.indexOf(u8, brow, "move") != null);
    try std.testing.expect(std.mem.indexOf(u8, brow, "page") != null);
    try std.testing.expect(std.mem.indexOf(u8, brow, "open") != null);
    try std.testing.expect(std.mem.indexOf(u8, brow, "parent") != null);

    const p_entries = [_][]const u8{ "a.hsc", "b.vgm" };
    m.playlist_entries = &p_entries;
    m.playlist_count = 2;
    m.menu = .playlist;
    m.menu_view = .playlist;
    m.draw(win);
    var buf2: [80]u8 = undefined;
    const prow = testRowText(&screen, &buf2, content_bottom, width);
    try std.testing.expect(std.mem.indexOf(u8, prow, "move") != null);
    try std.testing.expect(std.mem.indexOf(u8, prow, "play") != null);
    try std.testing.expect(std.mem.indexOf(u8, prow, "parent") == null);

    var floor_screen = try vaxis.Screen.init(gpa, .{
        .rows = 15,
        .cols = 46,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer floor_screen.deinit(gpa);
    floor_screen.width_method = .unicode;
    const floor_win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 46,
        .height = 15,
        .screen = &floor_screen,
    };
    m.menu = .browse;
    m.menu_view = .browse;
    m.draw(floor_win);
    var fbuf: [46]u8 = undefined;
    const list_row = testRowText(&floor_screen, &fbuf, 8, 46);
    try std.testing.expect(std.mem.indexOf(u8, list_row, "tune.hsc") != null);
    var fbuf2: [46]u8 = undefined;
    const last_row = testRowText(&floor_screen, &fbuf2, 9, 46);
    try std.testing.expect(std.mem.indexOf(u8, last_row, "move") == null);
}

test "playlist played rows extinguish their number" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "HSC", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.hsc" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf" };
    const played = [_]bool{ true, false, true };
    m.playlist_entries = &entries;
    m.playlist_played = &played;
    m.playlist_count = 3;
    m.playlist_index = 0;
    m.menu = .playlist;
    m.menu_view = .playlist;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const theme = default_theme;
    const unplayed = screen.readCell(5, 9).?;
    try std.testing.expectEqual(theme.colors.list_row_fg, unplayed.style.fg);
    const extinguished = screen.readCell(5, 10).?;
    try std.testing.expectEqual(theme.colors.playlist_played_fg, extinguished.style.fg);
}

test "playlist unplayable rows mark and dim" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "HSC", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.hsc" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf" };
    const unplayable = [_]bool{ false, true, false };
    m.playlist_entries = &entries;
    m.playlist_unplayable = &unplayable;
    m.playlist_count = 3;
    m.playlist_index = 0;
    m.menu = .playlist;
    m.menu_view = .playlist;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const theme = default_theme;
    const dead_marker = screen.readCell(1, 9).?;
    try std.testing.expectEqualStrings("✗", dead_marker.char.grapheme);
    try std.testing.expectEqual(theme.colors.playlist_dead_mark_fg, dead_marker.style.fg);
    const dead_num = screen.readCell(5, 9).?;
    try std.testing.expectEqual(theme.colors.playlist_dead_fg, dead_num.style.fg);
    const alive_marker = screen.readCell(1, 10).?;
    try std.testing.expectEqualStrings(" ", alive_marker.char.grapheme);
    const alive_num = screen.readCell(5, 10).?;
    try std.testing.expectEqual(theme.colors.list_row_fg, alive_num.style.fg);

    const key_row = height - visualizer.status_frame_h - 2;
    var buf: [80]u8 = undefined;
    const row_play = testRowText(&screen, &buf, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row_play, "play") != null);
    try std.testing.expect(std.mem.indexOf(u8, row_play, "retry") == null);
    m.playlist_list.nav.cursor = 1;
    m.draw(win);
    var buf2: [80]u8 = undefined;
    const row_retry = testRowText(&screen, &buf2, key_row, width);
    try std.testing.expect(std.mem.indexOf(u8, row_retry, "retry") != null);
}

test "loading state shows the spinner and header label" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "t.vgm" });
    defer m.deinit();
    m.loading = true;

    const width: u16 = 60;
    const height: u16 = 16;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    var buf: [60]u8 = undefined;
    const row1 = testRowText(&screen, &buf, 1, width);
    try std.testing.expect(std.mem.indexOf(u8, row1, "[Loading]") != null);

    const status_row = height - visualizer.status_frame_h + 1;
    const findIcon = struct {
        fn at(s: *vaxis.Screen, row: u16) ?[]const u8 {
            var x: u16 = 0;
            while (x < 6) : (x += 1) {
                const cell = s.readCell(x, row) orelse continue;
                for (spinner_frames) |f| {
                    if (std.mem.eql(u8, cell.char.grapheme, f)) return f;
                }
            }
            return null;
        }
    }.at;
    const frame0 = findIcon(&screen, status_row) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("⠋", frame0);

    m.spin_ticks = spinner_div;
    m.draw(win);
    const frame1 = findIcon(&screen, status_row) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("⠙", frame1);

    m.loading = false;
    m.draw(win);
    try std.testing.expect(findIcon(&screen, status_row) == null);
    var buf2: [60]u8 = undefined;
    const row1b = testRowText(&screen, &buf2, 1, width);
    try std.testing.expect(std.mem.indexOf(u8, row1b, "[Playing]") != null);
}

test "clearTrack drops to idle and falls back to the playlist view" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm" };
    m.playlist_entries = &entries;
    m.playlist_count = 2;
    m.menu = .visualize;
    m.menu_view = .visualize;

    m.clearTrack();
    try std.testing.expect(!m.has_track);
    try std.testing.expect(m.source == null);
    try std.testing.expect(m.view == null);
    try std.testing.expectEqual(@as(?u32, null), m.tick_rate_hz);
    try std.testing.expectEqualStrings("", m.filename);
    try std.testing.expect(m.menu_view == .playlist);
    try std.testing.expect(m.menu == .playlist);

    try std.testing.expect(!m.menuEnabled(.visualize));
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.handleKey(.{ .codepoint = 'v' }) != .quit);
    try std.testing.expect(m.menu_view == .playlist);
}

test "playlist cursor moves and Enter queues jump" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf" };
    m.playlist_entries = &entries;
    m.playlist_count = 3;
    m.playlist_index = 0;
    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    _ = m.handleKey(.{ .codepoint = 'p' });
    try std.testing.expectEqual(@as(usize, 0), m.playlist_list.nav.cursor);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(usize, 1), m.playlist_list.nav.cursor);
    try std.testing.expectEqual(@as(usize, 0), m.playlist_index);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(usize, 2), m.playlist_list.nav.cursor);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqual(@as(usize, 1), m.playlist_list.nav.cursor);

    try std.testing.expect(m.playlist_list.pending_jump == null);
    try std.testing.expect(m.handleKey(.{ .codepoint = vaxis.Key.enter }) != .quit);
    try std.testing.expectEqual(@as(?usize, 1), m.playlist_list.pending_jump);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expect(m.menu == .playlist);
    _ = m.handleKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expect(m.menu == .playlist);
    try std.testing.expectEqual(@as(usize, 1), m.playlist_list.nav.cursor);
}

test "fmtTime rolls into hours" {
    const gpa = std.testing.allocator;
    const short = try std.fmt.allocPrint(gpa, "{f}", .{fmtTime(215)});
    defer gpa.free(short);
    try std.testing.expectEqualStrings("3:35", short);
    const long = try std.fmt.allocPrint(gpa, "{f}", .{fmtTime(3661)});
    defer gpa.free(long);
    try std.testing.expectEqualStrings("1:01:01", long);
}

test "header updates emit intact text across frames" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .{ .array_hash_map = .{}, .allocator = gpa };
    defer env.array_hash_map.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    var vx = try vaxis.init(io, gpa, &env, .{});
    vx.state.alt_screen = true;
    try vx.resize(gpa, w, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer vx.deinit(gpa, w);

    var br = Bridge{};
    const track = format.TrackInfo{
        .format_name = "IMF",
        .visualizer = "stream",
        .rate_adjustable = true,
    };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();
    m.playlist_count = 6;
    m.playlist_index = 2;

    m.draw(vx.window());
    try vx.render(w);
    const end1 = aw.writer.end;

    br.volume.store(95, .release);
    m.draw(vx.window());
    try vx.render(w);
    const end2 = aw.writer.end;

    br.volume.store(100, .release);
    m.draw(vx.window());
    try vx.render(w);
    const end3 = aw.writer.end;

    const bytes = aw.writer.buffered();
    const frame2 = bytes[end1..end2];
    const frame3 = bytes[end2..end3];
    try std.testing.expect(std.mem.indexOf(u8, frame2, "95") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame3, "100") != null);
    for ([_][]const u8{ frame2, frame3 }) |frame| {
        for (frame) |b| try std.testing.expect(b < 0x80);
    }
}

test "volume keys step, clamp, and unmute" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    _ = m.handleKey(.{ .codepoint = '+' });
    try std.testing.expectEqual(@as(u8, 100), br.volume.load(.acquire));
    _ = m.handleKey(.{ .codepoint = '-' });
    try std.testing.expectEqual(@as(u8, 87), br.volume.load(.acquire));
    _ = m.handleKey(.{ .codepoint = '-' });
    try std.testing.expectEqual(@as(u8, 76), br.volume.load(.acquire));
    _ = m.handleKey(.{ .codepoint = '=' });
    try std.testing.expectEqual(@as(u8, 87), br.volume.load(.acquire));

    _ = m.handleKey(.{ .codepoint = 'm' });
    try std.testing.expect(br.muted.load(.acquire));
    _ = m.handleKey(.{ .codepoint = '-' });
    try std.testing.expect(!br.muted.load(.acquire));
    try std.testing.expectEqual(@as(u8, 76), br.volume.load(.acquire));

    br.volume.store(1, .release);
    _ = m.handleKey(.{ .codepoint = '-' });
    try std.testing.expectEqual(@as(u8, 0), br.volume.load(.acquire));
}

test "every volume press moves, both ends stay reachable" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    var prev: u8 = 100;
    for (0..64) |_| {
        _ = m.handleKey(.{ .codepoint = '-' });
        const cur = br.volume.load(.acquire);
        try std.testing.expect(cur < prev or cur == 0);
        prev = cur;
    }
    try std.testing.expectEqual(@as(u8, 0), br.volume.load(.acquire));

    for (0..64) |_| {
        _ = m.handleKey(.{ .codepoint = '+' });
        const cur = br.volume.load(.acquire);
        try std.testing.expect(cur > prev or cur == 100);
        prev = cur;
    }
    try std.testing.expectEqual(@as(u8, 100), br.volume.load(.acquire));
}

test "space and mute do nothing while no track is loaded" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();
    m.has_track = false;

    _ = m.handleKey(.{ .codepoint = vaxis.Key.space });
    try std.testing.expect(!br.paused.load(.acquire));
    _ = m.handleKey(.{ .codepoint = 'm' });
    try std.testing.expect(!br.muted.load(.acquire));

    m.has_track = true;
    _ = m.handleKey(.{ .codepoint = vaxis.Key.space });
    try std.testing.expect(br.paused.load(.acquire));
    _ = m.handleKey(.{ .codepoint = 'M' });
    try std.testing.expect(br.muted.load(.acquire));
}

test "playlist rows prefer EXTINF titles over basenames" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "music/one.hsc", "music/two.vgm" };
    const titles = [_]?[]const u8{ "Curated Name", null };
    m.playlist_entries = &entries;
    m.playlist_titles = &titles;
    m.playlist_name = "Goldbox";
    m.playlist_count = 2;
    m.menu = .playlist;
    m.menu_view = .playlist;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    var found_curated = false;
    var found_one_basename = false;
    var found_two_basename = false;
    var found_list_title = false;
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        var buf: [80]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, "Curated Name") != null) found_curated = true;
        if (std.mem.indexOf(u8, row, "one.hsc") != null) found_one_basename = true;
        if (std.mem.indexOf(u8, row, "two.vgm") != null) found_two_basename = true;
        if (std.mem.indexOf(u8, row, "Goldbox ? 2 tracks") != null) found_list_title = true;
    }
    try std.testing.expect(found_curated);
    try std.testing.expect(!found_one_basename);
    try std.testing.expect(found_two_basename);
    try std.testing.expect(found_list_title);
}

test "header title ranks embedded, curated, synthesized, then stem" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const synthesized = format.TrackInfo{
        .title = "DRO v1 (OPL2)",
        .format_name = "DRO",
        .visualizer = "stream",
    };
    var m = try Model.init(gpa, &br, .{ .info = synthesized, .filename = "dune%203.dro" });
    defer m.deinit();

    const titles = [_]?[]const u8{"Curated Name"};
    m.playlist_titles = &titles;
    m.playlist_count = 1;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    const scan = struct {
        fn has(s: *vaxis.Screen, h: u16, w: u16, needle: []const u8) bool {
            var r: u16 = 0;
            while (r < h) : (r += 1) {
                var buf: [width]u8 = undefined;
                const row = testRowText(s, &buf, r, w);
                if (std.mem.indexOf(u8, row, needle) != null) return true;
            }
            return false;
        }
    };

    m.draw(win);
    try std.testing.expect(scan.has(&screen, height, width, "Curated Name"));
    try std.testing.expect(!scan.has(&screen, height, width, "DRO v1"));

    m.playlist_playing = false;
    m.draw(win);
    try std.testing.expect(scan.has(&screen, height, width, "DRO v1 (OPL2)"));
    try std.testing.expect(!scan.has(&screen, height, width, "Curated Name"));

    m.playlist_playing = true;
    var embedded = synthesized;
    embedded.title = "GD3 Title";
    embedded.title_embedded = true;
    try m.setTrack(.{ .info = embedded, .filename = "b.vgm" });
    m.draw(win);
    try std.testing.expect(scan.has(&screen, height, width, "GD3 Title"));
    try std.testing.expect(!scan.has(&screen, height, width, "Curated Name"));

    m.playlist_playing = false;
    const bare = format.TrackInfo{ .format_name = "VGM", .visualizer = "stream" };
    try m.setTrack(.{ .info = bare, .filename = "dune%203.dro" });
    m.draw(win);
    try std.testing.expect(scan.has(&screen, height, width, "dune 3"));
    try std.testing.expect(!scan.has(&screen, height, width, ".dro"));
}

test "mouse clicks activate menu items and list rows" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    const entries = [_][]const u8{ "a.hsc", "b.vgm", "c.imf" };
    m.playlist_entries = &entries;
    m.playlist_count = 3;

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    const span = m.menu_hits[@intFromEnum(MenuTab.playlist)];
    try std.testing.expect(span.x1 > span.x0);
    try std.testing.expect(m.handleMouse(.{
        .col = @intCast(span.x0),
        .row = @intCast(m.menu_hit_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    }) != .quit);
    try std.testing.expect(m.menu_view == .playlist);

    m.draw(win);
    try std.testing.expectEqual(@as(u16, 3), m.playlist_list.nav.hit_rows);
    const col: i16 = @intCast(m.playlist_list.nav.hit_x0 + 3);
    const row1: i16 = @intCast(m.playlist_list.nav.hit_y0 + 1);
    _ = m.handleMouse(.{ .col = col, .row = row1, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 1), m.playlist_list.nav.cursor);
    try std.testing.expect(m.playlist_list.pending_jump == null);
    _ = m.handleMouse(.{ .col = col, .row = row1, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(?usize, 1), m.playlist_list.pending_jump);

    _ = m.handleMouse(.{ .col = col, .row = row1, .button = .wheel_down, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 2), m.playlist_list.nav.cursor);

    const theme_span = m.menu_hits[@intFromEnum(MenuTab.theme)];
    try std.testing.expect(m.handleMouse(.{
        .col = @intCast(theme_span.x0),
        .row = @intCast(m.menu_hit_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    }) != .quit);
    try std.testing.expect(m.menu_view == .theme);

    m.draw(win);
    var theme_buf0: [80]u8 = undefined;
    const theme_text0 = testRowText(&screen, &theme_buf0, m.theme_list.nav.hit_y0, width);
    try std.testing.expect(std.mem.indexOf(u8, theme_text0, themes[0].display_name) != null);
    var theme_buf1: [80]u8 = undefined;
    const theme_text1 = testRowText(&screen, &theme_buf1, m.theme_list.nav.hit_y0 + 1, width);
    try std.testing.expect(std.mem.indexOf(u8, theme_text1, themes[1].display_name) != null);

    const theme_col: i16 = @intCast(m.theme_list.nav.hit_x0 + 3);
    const theme_row: i16 = @intCast(m.theme_list.nav.hit_y0 + 1);
    _ = m.handleMouse(.{
        .col = theme_col,
        .row = theme_row,
        .button = .left,
        .mods = .{},
        .type = .press,
    });
    try std.testing.expectEqual(@as(usize, 1), m.theme_list.nav.cursor);
    _ = m.handleMouse(.{
        .col = theme_col,
        .row = theme_row,
        .button = .left,
        .mods = .{},
        .type = .press,
    });
    try std.testing.expectEqualStrings(themes[1].display_name, m.selectedTheme().display_name);

    const q = m.menu_hits[@intFromEnum(MenuTab.quit)];
    try std.testing.expect(m.handleMouse(.{
        .col = @intCast(q.x0),
        .row = @intCast(m.menu_hit_row),
        .button = .left,
        .mods = .{},
        .type = .press,
    }) == .quit);
    try std.testing.expect(br.quit.load(.acquire));
}

test "track chip appears only for multi-track archives" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{
        .format_name = "AudioT",
        .visualizer = "stream",
        .archive_track_count = 27,
        .archive_track_index = 1,
    };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "AUDIOT.WL6" });
    defer m.deinit();

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };

    m.draw(win);
    var found = false;
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        var buf: [80]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, ", . track") != null) found = true;
    }
    try std.testing.expect(found);

    m.track.archive_track_count = 0;
    m.draw(win);
    found = false;
    r = 0;
    while (r < height) : (r += 1) {
        var buf: [80]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, ", . track") != null) found = true;
    }
    try std.testing.expect(!found);
}

test "skip notice holds the status key row and expires" {
    const gpa = std.testing.allocator;
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(gpa, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    m.noticeSkip("music/tune%201.hsc", "file not found");
    try std.testing.expectEqualStrings("tune 1.hsc: file not found", m.notice);

    const width: u16 = 80;
    const height: u16 = 18;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    screen.width_method = .unicode;
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    m.draw(win);

    var found = false;
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        var buf: [80]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, "tune 1.hsc: file not found") != null) found = true;
    }
    try std.testing.expect(found);

    m.notice_ticks = 1;
    m.sampleVisuals();
    try std.testing.expectEqual(@as(u32, 0), m.notice_ticks);
    m.draw(win);
    var notice_gone = true;
    var chips_back = false;
    r = 0;
    while (r < height) : (r += 1) {
        var buf: [80]u8 = undefined;
        const row = testRowText(&screen, &buf, r, width);
        if (std.mem.indexOf(u8, row, "tune 1.hsc:") != null) notice_gone = false;
        if (std.mem.indexOf(u8, row, "pause") != null) chips_back = true;
    }
    try std.testing.expect(notice_gone);
    try std.testing.expect(chips_back);
}

test "spectrum smoothing attacks fast and releases slowly" {
    var br = Bridge{};
    const view = format.TrackerView{
        .ctx = undefined,
        .channels = 9,
        .rows_per_pattern = 64,
        .num_patterns = 1,
        .order = &.{0},
        .cell = undefined,
        .instrument = undefined,
    };
    const track = format.TrackInfo{ .format_name = "HSC", .visualizer = "tracker" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "t.hsc", .view = view });
    defer m.deinit();

    br.levels[0].store(255, .release);
    m.sampleVisuals();
    try std.testing.expectEqual(@as(f32, 1.0), m.spec_levels[0]);
    try std.testing.expectEqual(@as(f32, 1.0), m.spec_peaks[0]);

    br.levels[0].store(0, .release);
    m.sampleVisuals();
    try std.testing.expect(m.spec_levels[0] < 1.0);
    try std.testing.expect(m.spec_levels[0] > 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), m.spec_peaks[0]);
}

test "peak cap glow stays full through the hold and fades as it falls" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    br.pcm_bands[0].store(255, .release);
    m.sampleVisuals();
    try std.testing.expectEqual(@as(f32, 1.0), m.pcm_band_glow[0]);

    br.pcm_bands[0].store(0, .release);
    for (0..peak_hold_ticks) |_| m.sampleVisuals();
    try std.testing.expectEqual(@as(f32, 1.0), m.pcm_band_glow[0]);
    try std.testing.expectEqual(@as(f32, 1.0), m.pcm_band_peaks[0]);

    m.sampleVisuals();
    try std.testing.expect(m.pcm_band_glow[0] < 1.0);
    try std.testing.expect(m.pcm_band_peaks[0] < 1.0);
}

test "menu hotkeys stay off the transport row and match their labels" {
    for (menu_items) |item| {
        try std.testing.expectEqual(item.hotkey, std.ascii.toLower(item.label[0]));
        try std.testing.expect(std.mem.indexOfScalar(u21, &transport_keys, item.hotkey) == null);
    }
}

test "transport keys act while the menu holds focus" {
    var br = Bridge{};
    const track = format.TrackInfo{ .format_name = "IMF", .visualizer = "stream" };
    var m = try Model.init(std.testing.allocator, &br, .{ .info = track, .filename = "a.imf" });
    defer m.deinit();

    _ = m.handleKey(.{ .codepoint = vaxis.Key.f10 });
    try std.testing.expect(m.menu_focused);

    _ = m.handleKey(.{ .codepoint = vaxis.Key.space });
    try std.testing.expect(br.paused.load(.acquire));
    _ = m.handleKey(.{ .codepoint = '-' });
    try std.testing.expectEqual(@as(u8, 87), br.volume.load(.acquire));
    _ = m.handleKey(.{ .codepoint = 'm' });
    try std.testing.expect(br.muted.load(.acquire));

    // Focus survives: the row acts without stealing the menu.
    try std.testing.expect(m.menu_focused);
}
