//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const format = @import("format.zig");
const loaderr = @import("loaderr.zig");
const playlist = @import("playlist.zig");
const remote = @import("remote.zig");

pub const Options = struct {
    tick_rate_hz: u32 = 0,
    track_index: u32 = 0,
};

pub const ParsedArgs = struct {
    entries: []const []const u8 = &.{},
    titles: []const ?[]const u8 = &.{},
    rates: []const u32 = &.{},
    list_name: []const u8 = "",
    browse_dir: ?[]const u8 = null,
    was_playlist: bool = false,
    paths: []const []const u8 = &.{},
    options: Options = .{},
};

/// User-facing outcomes print their own diagnostics. `args == null` means the
/// process should stop with `exitCode` (help/version use 0, bad input uses 1).
/// Unexpected failures (OOM, and so on) still return as errors.
pub const ParseResult = struct {
    args: ?ParsedArgs = null,
    exitCode: u8 = 0,
};

fn done(exitCode: u8) ParseResult {
    return .{ .args = null, .exitCode = exitCode };
}

fn ok(args: ParsedArgs) ParseResult {
    return .{ .args = args, .exitCode = 0 };
}

pub fn parse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
) !ParseResult {
    const run = switch (try parseFlags(arena, args)) {
        .help => {
            printStdout(io, usage_text, .{});
            return done(0);
        },
        .version => {
            printStdout(io, build_options.name ++ " {s}\n", .{build_options.version});
            return done(0);
        },
        .fail => |msg| {
            printStderr(io, "{s}\n", .{msg});
            return done(1);
        },
        .run => |r| r,
    };

    const paths = run.paths;
    for (paths) |*p| {
        if (remote.isFileUrl(p.*)) {
            p.* = remote.fileUrlToPath(arena, p.*) catch {
                printStderr(io, build_options.name ++ ": {s}: invalid file URL\n", .{p.*});
                return done(1);
            };
        }
    }

    var result: ParsedArgs = .{ .options = run.options, .paths = paths };
    if (paths.len == 0) return ok(result);

    if (paths.len > 1) {
        for (paths, 0..) |p, pi| {
            const other = paths[if (pi == 0) 1 else 0];
            if (playlist.isPlaylistPath(p)) {
                printStderr(
                    io,
                    build_options.name ++ ": a playlist must be the only argument (got {s} and {s})\n",
                    .{ p, other },
                );
                return done(1);
            }
            if (tryOpenDir(io, p)) |dir| {
                dir.close(io);
                printStderr(
                    io,
                    build_options.name ++ ": a directory must be the only argument (got {s} and {s})\n",
                    .{ p, other },
                );
                return done(1);
            }
        }
        for (paths) |p| {
            if (!format.isPlayablePath(p)) {
                reportUnsupportedPath(io, p);
                return done(1);
            }
        }
        result.entries = paths;
        return ok(result);
    }

    const file_path = paths[0];
    if (tryOpenDir(io, file_path)) |dir| {
        defer dir.close(io);
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const len = dir.realPath(io, &dir_buf) catch 0;
        result.browse_dir = if (len > 0) try arena.dupe(u8, dir_buf[0..len]) else file_path;
        return ok(result);
    }
    if (playlist.isPlaylistPath(file_path)) {
        result.was_playlist = true;
        if (remote.isRemotePath(file_path)) {
            printStderr(io, build_options.name ++ ": fetching {s} ...\n", .{file_path});
        }
        const raw = remote.readPathAlloc(gpa, io, file_path, null) catch |err| {
            printStderr(io, build_options.name ++ ": cannot read {s}: {s}\n", .{ file_path, loaderr.loadErrorLabel(err) });
            return done(1);
        };
        defer gpa.free(raw);
        const parsed = playlist.parse(arena, file_path, raw) catch |err| {
            printStderr(io, build_options.name ++ ": cannot parse {s}: {s}\n", .{ file_path, loaderr.loadErrorLabel(err) });
            return done(1);
        };
        if (parsed.entries.len == 0) {
            printStderr(io, build_options.name ++ ": {s}: no playable entries\n", .{file_path});
            return done(1);
        }
        result.titles = parsed.titles;
        result.rates = parsed.rates;
        result.list_name = parsed.name orelse
            try format.dupeDisplayBasename(arena, file_path);
        result.entries = parsed.entries;
        return ok(result);
    }
    if (!format.isPlayablePath(file_path)) {
        reportUnsupportedPath(io, file_path);
        return done(1);
    }
    const single = try arena.alloc([]const u8, 1);
    single[0] = file_path;
    result.entries = single;
    return ok(result);
}

const FlagResult = union(enum) {
    run: struct {
        options: Options,
        paths: [][]const u8,
    },
    help,
    version,
    fail: []const u8,
};

fn parseFlags(arena: std.mem.Allocator, args: []const []const u8) !FlagResult {
    var paths: std.ArrayList([]const u8) = .empty;
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i >= args.len)
                return .{ .fail = build_options.name ++ ": --rate needs a value (280, 560, or 700)" };
            options.tick_rate_hz = parseRateValue(args[i]) orelse
                return .{ .fail = try badRate(arena, args[i]) };
        } else if (std.mem.startsWith(u8, a, "--rate=")) {
            const v = a["--rate=".len..];
            options.tick_rate_hz = parseRateValue(v) orelse
                return .{ .fail = try badRate(arena, v) };
        } else if (std.mem.eql(u8, a, "--track")) {
            i += 1;
            if (i >= args.len)
                return .{ .fail = build_options.name ++ ": --track needs a track number (counts from 1)" };
            options.track_index = parseTrackValue(args[i]) orelse
                return .{ .fail = try badTrack(arena, args[i]) };
        } else if (std.mem.startsWith(u8, a, "--track=")) {
            const v = a["--track=".len..];
            options.track_index = parseTrackValue(v) orelse
                return .{ .fail = try badTrack(arena, v) };
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            return .version;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .help;
        } else if (a.len > 1 and a[0] == '-') {
            return .{ .fail = try std.fmt.allocPrint(
                arena,
                build_options.name ++ ": unknown option {s} (try --help)",
                .{a},
            ) };
        } else {
            try paths.append(arena, a);
        }
    }
    return .{ .run = .{ .options = options, .paths = paths.items } };
}

fn badRate(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, build_options.name ++ ": --rate must be 280, 560, or 700 (got {s})", .{value});
}

fn badTrack(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        build_options.name ++ ": --track must be a track number counting from 1 (got {s})",
        .{value},
    );
}

pub fn parseRateValue(value: []const u8) ?u32 {
    const hz = std.fmt.parseInt(u32, value, 10) catch return null;
    if (std.mem.indexOfScalar(u32, &format.tick_rates, hz) == null) return null;
    return hz;
}

pub fn parseTrackValue(value: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, value, 10) catch return null;
    if (n == 0) return null;
    return n - 1;
}

fn reportUnsupportedPath(io: Io, path: []const u8) void {
    if (remote.isRemotePath(path)) {
        printStderr(
            io,
            build_options.name ++ ": {s}: unsupported file type (see --help for formats)\n",
            .{path},
        );
    } else if (remote.hasUrlScheme(path)) {
        printStderr(
            io,
            build_options.name ++ ": {s}: only http://, https://, and file:// URLs are supported\n",
            .{path},
        );
    } else if (Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.kind == .directory) {
            printStderr(io, build_options.name ++ ": cannot open directory {s}\n", .{path});
        } else {
            printStderr(
                io,
                build_options.name ++ ": {s}: unsupported file type (see --help for formats)\n",
                .{path},
            );
        }
    } else |err| {
        printStderr(io, build_options.name ++ ": cannot open {s}: {s}\n", .{ path, loaderr.loadErrorLabel(err) });
    }
}

fn tryOpenDir(io: Io, path: []const u8) ?Io.Dir {
    if (std.fs.path.isAbsolute(path))
        return Io.Dir.openDirAbsolute(io, path, .{}) catch null;
    return Io.Dir.cwd().openDir(io, path, .{}) catch null;
}

fn printStdout(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch std.process.exit(1);
    w.interface.flush() catch std.process.exit(1);
}

/// Exits when stderr will not accept the write, because every caller is on its
/// way to a nonzero exit anyway and there is nothing left to report with.
pub fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch std.process.exit(1);
    w.interface.flush() catch std.process.exit(1);
}

const usage_text = "usage: " ++ build_options.name ++ " [options] [files... | playlist | directory | URL]\n" ++
    \\
    \\A music file plays in its visualizer. Several music files
    \\become a playlist and open the Playlist view. A playlist
    \\argument does the same, playing its first entry. A directory
    \\opens the file browser in that directory. With no argument,
    \\the browser opens in the current working directory. A
    \\playlist or directory must be the only argument. Wildcards
    \\are expanded by the shell, not the player.
    \\
    \\formats: .hsc .rad .lds .ld0 .vgm .vgz .dro .raw .bam .xsm .cmf .imf .wlf .adlib
    \\         AUDIOT.* / AUDIO.* / AUDIOHED.* (id Muse archives)
    \\         .m3u / .m3u8 playlists of the above
    \\
    \\Files and playlists may also be http://, https://, or
    \\file:// URLs, on the command line and as playlist entries.
    \\
    \\options:
    \\  --rate <hz>     force IMF/WLF/AudioT tick rate (280 / 560 / 700)
    \\  --track <n>     AudioT music track number (counts from 1)
    \\  -v, --version   print version and exit
    \\  -h, --help      show this help
    \\
    \\transport (always live, whatever holds focus):
    \\           Space pause  +/- volume  M mute
    \\           R cycle IMF/WLF/AudioT rate (280/560/700)
    \\           , previous  . next track in an AudioT archive
    \\           [ previous  ] next playlist entry
    \\           S shuffle  L loop playlist
    \\
    \\in-player: Ctrl+C or Alt+Q quit
    \\           F10/Alt menu focus, Tab/Shift+Tab switch views
    \\           B browse  P playlist  V visualizer
    \\           T themes  Q quit
    \\           Alt+letter activates a menu item directly
    \\           lists: up/down  PgUp/PgDn  Home/End  Enter open
    \\           browse: right/Enter open  left/Backspace parent
    \\
;

// --- tests -------------------------------------------------------------------

test "usage text names the live key bindings" {
    const ui = @import("ui.zig");

    // Every menu item is documented under its own hotkey letter, as
    // "B browse" or "T theme...". A retired mnemonic left in the text
    // fails here, which is how "H themes" once shipped in --help.
    for (ui.menu_items) |item| {
        var want: [8]u8 = undefined;
        want[0] = std.ascii.toUpper(@intCast(item.hotkey));
        want[1] = ' ';
        const n = @min(item.label.len, 5);
        for (item.label[0..n], 2..) |c, i| want[i] = std.ascii.toLower(c);
        try std.testing.expect(std.mem.indexOf(u8, usage_text, want[0 .. 2 + n]) != null);
    }

    // Every single-letter or punctuation key the transport block names
    // must really be a transport key, so the block cannot claim a key
    // the player gave to something else, as "T next track" once did.
    const start = std.mem.indexOf(u8, usage_text, "transport").?;
    const end = std.mem.indexOf(u8, usage_text, "in-player").?;
    const block = usage_text[start..end];
    var it = std.mem.tokenizeAny(u8, block, " \n\\");
    while (it.next()) |tok| {
        if (tok.len != 1 or !std.ascii.isPrint(tok[0])) continue;
        const key = std.ascii.toLower(tok[0]);
        try std.testing.expect(std.mem.indexOfScalar(u21, &ui.transport_keys, key) != null);
    }

    // And the reverse: each reserved transport key is documented in the
    // block, except the undocumented `=` alias and the glued volume pair.
    for (ui.transport_keys) |k| {
        if (k == ' ' or k == '+' or k == '=' or k == '-') continue;
        var found = false;
        var jt = std.mem.tokenizeAny(u8, block, " \n\\");
        while (jt.next()) |tok| {
            if (tok.len != 1) continue;
            const c: u8 = @intCast(k);
            if (tok[0] == c or tok[0] == std.ascii.toUpper(c)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "Space") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "+/- volume") != null);
}

test "parseFlags collects options and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parseFlags(arena, &.{
        "sehnsucht", "--rate", "560", "--track=3", "a.imf", "b.imf",
    });
    switch (result) {
        .run => |r| {
            try std.testing.expectEqual(@as(u32, 560), r.options.tick_rate_hz);
            try std.testing.expectEqual(@as(u32, 2), r.options.track_index);
            try std.testing.expectEqual(@as(usize, 2), r.paths.len);
            try std.testing.expectEqualStrings("a.imf", r.paths[0]);
            try std.testing.expectEqualStrings("b.imf", r.paths[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFlags reports help, version, and bad input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Tag = std.meta.Tag(FlagResult);
    try std.testing.expectEqual(Tag.help, std.meta.activeTag(try parseFlags(arena, &.{ "sehnsucht", "-h" })));
    try std.testing.expectEqual(Tag.version, std.meta.activeTag(try parseFlags(arena, &.{ "sehnsucht", "--version" })));
    try std.testing.expectEqual(Tag.fail, std.meta.activeTag(try parseFlags(arena, &.{ "sehnsucht", "--nope" })));
    try std.testing.expectEqual(Tag.fail, std.meta.activeTag(try parseFlags(arena, &.{ "sehnsucht", "--rate", "9" })));
    try std.testing.expectEqual(Tag.fail, std.meta.activeTag(try parseFlags(arena, &.{ "sehnsucht", "--rate" })));
}
