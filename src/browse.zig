//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const paint = @import("paint.zig");
const format = @import("format.zig");
const playlist = @import("playlist.zig");
const Theme = @import("theme.zig").Theme;

pub const Kind = enum { dir, playlist, music };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

fn nameOwned(name: []const u8) bool {
    return !std.mem.eql(u8, name, "..");
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn isUncRootPath(path: []const u8) bool {
    var rest = path;
    if (std.ascii.startsWithIgnoreCase(rest, "\\\\?\\UNC\\") or
        std.ascii.startsWithIgnoreCase(rest, "//?/UNC/"))
    {
        rest = rest["//?/UNC/".len..];
    } else if (rest.len >= 2 and isSep(rest[0]) and isSep(rest[1])) {
        rest = rest[2..];
    } else {
        return false;
    }
    var comps: usize = 0;
    var it = std.mem.tokenizeAny(u8, rest, "/\\");
    while (it.next()) |_| comps += 1;
    return comps <= 2;
}

fn isRootPath(path: []const u8) bool {
    if (format.isWindowsDriveRoot(path)) return true;
    if (path.len == 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return isUncRootPath(path);
}

pub const State = struct {
    gpa: std.mem.Allocator,
    io: ?Io = null,
    path: []u8 = &.{},
    entries: []Entry = &.{},
    nav: paint.ListNav = .{},
    err_msg: ?[]const u8 = null,
    pending_play_path: ?[]u8 = null,

    pub fn deinit(self: *State) void {
        self.clearEntries();
        self.gpa.free(self.path);
        if (self.pending_play_path) |p| self.gpa.free(p);
        self.pending_play_path = null;
    }

    pub fn takePendingPlay(self: *State) ?[]u8 {
        const p = self.pending_play_path;
        self.pending_play_path = null;
        return p;
    }

    pub fn ensure(self: *State) !void {
        const io = self.io orelse {
            self.err_msg = "I/O unavailable";
            return;
        };
        if (self.path.len == 0) {
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().realPath(io, &buf) catch {
                self.path = try self.gpa.dupe(u8, ".");
                try self.refreshList(.keep);
                return;
            };
            self.path = try self.gpa.dupe(u8, buf[0..n]);
        }
        try self.refreshList(.keep);
    }

    pub fn goParent(self: *State) void {
        if (self.path.len == 0) return;
        self.normalizePath() catch return;
        if (isRootPath(self.path)) return;

        const parent = format.dirnameOf(self.path);
        if (std.mem.eql(u8, parent, self.path)) return;
        const leaving = format.basenameOf(self.path);
        const child: ?[]u8 = if (leaving.len == 0) null else self.gpa.dupe(u8, leaving) catch null;
        defer if (child) |c| self.gpa.free(c);
        const copy = self.gpa.dupe(u8, parent) catch return;
        self.gpa.free(self.path);
        self.path = copy;
        self.normalizePath() catch {};
        const selection: RefreshSelection = if (child) |c| .{ .select = c } else .reset;
        self.refreshList(selection) catch {
            self.err_msg = "cannot open directory";
        };
    }

    pub fn activate(self: *State) void {
        if (self.entries.len == 0) return;
        const e = self.entries[@min(self.nav.cursor, self.entries.len - 1)];
        switch (e.kind) {
            .dir => {
                if (std.mem.eql(u8, e.name, "..")) {
                    self.goParent();
                } else {
                    self.enterDir(e.name);
                }
            },
            .music, .playlist => self.requestPlay(e.name),
        }
    }

    pub fn draw(self: *State, win: vaxis.Window, theme: Theme) void {
        const list_top: u16 = 3;
        const with_bar = win.height >= list_top + paint.key_bar_height + 1;
        const bar_h: u16 = if (with_bar) paint.key_bar_height else 0;
        if (win.height < list_top + 1) return;

        const path_line = if (self.path.len > 0) self.path else ".";
        paint.printFitTail(win, 1, 0, path_line, win.width -| 2, theme.style(.browse_path));

        if (self.err_msg) |err| {
            paint.printFit(win, 1, 1, err, win.width -| 2, theme.style(.browse_error));
            if (with_bar) self.drawKeyBar(win, theme);
            return;
        }

        const col_style = theme.style(.list_header);
        paint.printAt(win, 1, 1, "Type", col_style);
        paint.printAt(win, 8, 1, "Name", col_style);

        const n = self.entries.len;
        const list_h = win.height - list_top - bar_h;
        self.nav.page_h = list_h;

        const show_sb = n > list_h;
        const row_w = if (show_sb) win.width -| 1 else win.width;

        paint.drawRule(win, theme, 2, row_w);

        if (n == 0) {
            paint.printAt(win, 1, list_top, "(empty)", theme.style(.browse_empty));
            if (with_bar) self.drawKeyBar(win, theme);
            return;
        }

        const cursor = @min(self.nav.cursor, n - 1);
        self.nav.cursor = cursor;
        paint.listEnsureVisible(&self.nav.scroll, cursor, n, list_h);
        const first = self.nav.scroll;

        self.nav.hit_x0 = @intCast(@max(0, win.x_off));
        self.nav.hit_x1 = @as(u16, @intCast(@max(0, win.x_off))) + row_w;
        self.nav.hit_y0 = @as(u16, @intCast(@max(0, win.y_off))) + list_top;
        self.nav.hit_rows = @intCast(@min(@as(usize, list_h), n - first));

        const focus_bg = theme.colors.list_cursor_bg;
        const focus_fg = theme.colors.list_cursor_fg;
        const canvas = theme.colors.bg;
        const dir_fg = theme.colors.browse_dir_fg;
        const type_x: u16 = 1;
        const name_x: u16 = 8;

        var row: u16 = 0;
        while (row < list_h) : (row += 1) {
            const y = list_top + row;
            const idx = first + row;
            if (idx >= n) {
                paint.fillRowBg(win, y, 0, win.width, canvas);
                continue;
            }
            const e = self.entries[idx];
            const is_cursor = idx == cursor;
            const bg = if (is_cursor) focus_bg else canvas;
            const fg = if (is_cursor) focus_fg else theme.colors.list_row_fg;
            const name_style = theme.listEntry(fg, bg, is_cursor);

            paint.fillRowBg(win, y, 0, row_w, bg);

            if (e.kind == .dir) {
                paint.printAt(
                    win,
                    type_x,
                    y,
                    "<DIR>",
                    theme.listEntry(if (is_cursor) focus_fg else dir_fg, bg, is_cursor),
                );
            }

            const label_w = row_w -| name_x -| 2;
            paint.printFit(win, name_x, y, e.name, label_w, name_style);
        }

        if (show_sb) paint.drawScrollbar(win, theme, list_top, list_h, n, first);
        if (with_bar) self.drawKeyBar(win, theme);
    }

    fn drawKeyBar(self: *const State, win: vaxis.Window, theme: Theme) void {
        const n = self.entries.len;
        const can_open = n > 0;
        const can_parent = self.path.len > 0 and !isRootPath(self.path);
        const hints = paint.listNavigationHints(n, self.nav.cursor) ++ [_]paint.Hotkey{
            .{ .key = "Enter", .label = "", .enabled = can_open },
            .{ .key = "→", .label = "open", .enabled = can_open, .glue = true },
            .{ .key = "Bksp", .label = "", .enabled = can_parent },
            .{ .key = "←", .label = "parent", .enabled = can_parent, .glue = true },
        };
        paint.drawListKeyBar(win, theme, &hints);
    }

    fn clearEntries(self: *State) void {
        for (self.entries) |e| {
            if (nameOwned(e.name)) self.gpa.free(e.name);
        }
        self.gpa.free(self.entries);
        self.entries = &.{};
        self.nav.cursor = 0;
        self.err_msg = null;
    }

    fn normalizePath(self: *State) !void {
        const p = self.path;
        if (p.len == 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) {
            const rooted = try std.fmt.allocPrint(self.gpa, "{c}:\\", .{p[0]});
            self.gpa.free(self.path);
            self.path = rooted;
        }
    }

    fn openDir(self: *State, io: Io) !Io.Dir {
        try self.normalizePath();
        const path = self.path;
        if (path.len >= 2 and path[1] == ':') {
            return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        }
        if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) {
            return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        }
        return Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    }

    const RefreshSelection = union(enum) {
        keep,
        reset,
        select: []const u8,
    };

    fn refreshList(self: *State, selection: RefreshSelection) !void {
        const io = self.io orelse {
            self.err_msg = "I/O unavailable";
            return;
        };
        const selected: ?[]u8 = switch (selection) {
            .keep => if (self.entries.len != 0) blk: {
                const e = self.entries[@min(self.nav.cursor, self.entries.len - 1)];
                break :blk self.gpa.dupe(u8, e.name) catch null;
            } else null,
            .reset => null,
            .select => |name| self.gpa.dupe(u8, name) catch null,
        };
        defer if (selected) |s| self.gpa.free(s);
        self.clearEntries();

        const dir = self.openDir(io) catch {
            self.err_msg = "cannot open directory";
            return;
        };
        defer dir.close(io);

        var list: std.ArrayList(Entry) = .empty;
        defer {
            for (list.items) |e| {
                if (nameOwned(e.name)) self.gpa.free(e.name);
            }
            list.deinit(self.gpa);
        }

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const name = try self.gpa.dupe(u8, entry.name);
            errdefer self.gpa.free(name);
            if (entry.kind == .directory) {
                try list.append(self.gpa, .{ .name = name, .kind = .dir });
            } else if (playlist.isPlaylistPath(entry.name)) {
                try list.append(self.gpa, .{ .name = name, .kind = .playlist });
            } else if (format.isPlayablePath(entry.name)) {
                try list.append(self.gpa, .{ .name = name, .kind = .music });
            } else {
                self.gpa.free(name);
            }
        }

        const less = struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if ((a.kind == .dir) != (b.kind == .dir)) return a.kind == .dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less;
        std.mem.sort(Entry, list.items, {}, less);

        const parent_rows: usize = if (isRootPath(self.path)) 0 else 1;
        const total = parent_rows + list.items.len;
        const out = try self.gpa.alloc(Entry, total);
        if (parent_rows != 0) out[0] = .{ .name = "..", .kind = .dir };
        @memcpy(out[parent_rows..], list.items);
        list.clearRetainingCapacity();
        self.entries = out;
        self.nav.cursor = 0;
        self.nav.scroll = 0;
        if (selected) |want| {
            for (out, 0..) |e, idx| {
                if (std.mem.eql(u8, e.name, want)) {
                    self.nav.cursor = idx;
                    break;
                }
            }
            self.nav.syncTo(self.nav.cursor, self.entries.len);
        }
        self.err_msg = null;
    }

    fn enterDir(self: *State, name: []const u8) void {
        self.normalizePath() catch return;
        const joined = format.joinDir(self.gpa, self.path, name) catch return;
        self.gpa.free(self.path);
        self.path = joined;
        self.refreshList(.reset) catch {
            self.err_msg = "cannot open directory";
        };
    }

    fn requestPlay(self: *State, name: []const u8) void {
        self.normalizePath() catch return;
        const full = format.joinDir(self.gpa, self.path, name) catch return;
        if (self.pending_play_path) |old| self.gpa.free(old);
        self.pending_play_path = full;
    }
};

// --- tests -------------------------------------------------------------------

test "root path detection stops UNC walks at the share" {
    try std.testing.expect(isRootPath("/"));
    try std.testing.expect(isRootPath("\\"));
    try std.testing.expect(isRootPath("C:\\"));
    try std.testing.expect(isRootPath("\\\\server\\share"));
    try std.testing.expect(isRootPath("//server/share"));
    try std.testing.expect(isRootPath("\\\\server"));
    try std.testing.expect(isRootPath("\\\\?\\UNC\\server\\share"));
    try std.testing.expect(!isRootPath("\\\\server\\share\\music"));
    try std.testing.expect(!isRootPath("//server/share/music"));
    try std.testing.expect(!isRootPath("C:\\music"));
    try std.testing.expect(!isRootPath("music"));
}
