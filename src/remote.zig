//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const format = @import("format.zig");

const user_agent = build_options.name ++ "/" ++ build_options.version;
const max_redirects = 5;
const redirect_buffer_len = 8 * 1024;

pub fn isRemotePath(path: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(path, "http://") or
        std.ascii.startsWithIgnoreCase(path, "https://");
}

pub fn hasUrlScheme(path: []const u8) bool {
    if (path.len == 0 or !std.ascii.isAlphabetic(path[0])) return false;
    for (path[1..], 1..) |c, i| {
        if (c == ':') {
            if (i < 2) return false;
            return path.len > i + 2 and path[i + 1] == '/' and path[i + 2] == '/';
        }
        const scheme_char = std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-';
        if (!scheme_char) return false;
    }
    return false;
}

pub fn isFileUrl(path: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(path, "file://");
}

pub fn fileUrlToPath(
    gpa: std.mem.Allocator,
    url: []const u8,
) error{ OutOfMemory, InvalidFileUrl }![]u8 {
    const work = try gpa.dupe(u8, url["file://".len..]);
    defer gpa.free(work);
    std.mem.replaceScalar(u8, work, '\\', '/');
    const slash = std.mem.indexOfScalar(u8, work, '/') orelse work.len;
    const host = work[0..slash];
    const rest = work[slash..];

    const drive_host = host.len == 2 and host[1] == ':' and std.ascii.isAlphabetic(host[0]);
    const local_host = host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost");

    const joined = if (drive_host)
        try std.mem.concat(gpa, u8, &.{ host, rest })
    else if (local_host)
        try gpa.dupe(u8, rest)
    else
        try std.mem.concat(gpa, u8, &.{ "//", host, rest });
    defer gpa.free(joined);

    var decoded = std.Uri.percentDecodeInPlace(joined);
    if (local_host and decoded.len >= 3 and decoded[0] == '/' and
        std.ascii.isAlphabetic(decoded[1]) and decoded[2] == ':')
    {
        decoded = decoded[1..];
    }
    if (decoded.len == 0) return error.InvalidFileUrl;
    return gpa.dupe(u8, decoded);
}

fn lowerSchemeInPlace(url: []u8) void {
    const end = std.mem.indexOf(u8, url, "://") orelse return;
    for (url[0..end]) |*c| c.* = std.ascii.toLower(c.*);
}

pub fn encodeUrlAlloc(gpa: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    std.Uri.Component.percentEncode(&aw.writer, url, urlByteIsSafe) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `%` is deliberately safe: an entry that already carries escapes must survive
/// unchanged rather than become `%25`. `#` and `?` are escaped so a filename
/// cannot cut the request path into a fragment or a query.
fn urlByteIsSafe(c: u8) bool {
    if (c <= 0x20 or c >= 0x7F) return false;
    return switch (c) {
        '"', '#', '<', '>', '?', '\\', '^', '`', '{', '|', '}' => false,
        else => true,
    };
}

pub fn displayBasename(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const base = format.basenameOf(path);
    if (std.mem.indexOfScalar(u8, base, '%') == null) return base;
    const buf = arena.dupe(u8, base) catch return base;
    return std.Uri.percentDecodeInPlace(buf);
}

pub fn readPathAlloc(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    abort: ?*const std.atomic.Value(bool),
) ![]u8 {
    if (isRemotePath(path)) return fetch(gpa, io, path, abort);
    if (hasUrlScheme(path)) return error.UnsupportedUrlScheme;
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(format.max_input_bytes));
}

const download_timeout_ms: u64 = 30_000;
const download_poll_ms: u64 = 100;

const FetchResult = anyerror![]u8;

fn fetchTask(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    out: *FetchResult,
    done: *std.atomic.Value(bool),
) void {
    out.* = fetchNow(gpa, io, url);
    done.store(true, .release);
}

pub fn fetch(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    abort: ?*const std.atomic.Value(bool),
) ![]u8 {
    var result: FetchResult = error.Canceled;
    var done = std.atomic.Value(bool).init(false);
    var fut = try io.concurrent(fetchTask, .{ gpa, io, url, &result, &done });
    var aborted = false;
    var waited: u64 = 0;
    while (!done.load(.acquire) and waited < download_timeout_ms) : (waited += download_poll_ms) {
        if (abort) |flag| {
            if (flag.load(.acquire)) {
                aborted = true;
                break;
            }
        }
        io.sleep(.fromMilliseconds(download_poll_ms), .real) catch break;
    }
    if (done.load(.acquire)) {
        fut.await(io);
        return result;
    }
    fut.cancel(io);
    return if (result) |data| data else |err| switch (err) {
        error.Canceled => if (aborted) error.Canceled else error.DownloadTimeout,
        else => err,
    };
}

fn fetchNow(gpa: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const norm = try gpa.dupe(u8, url);
    defer gpa.free(norm);
    lowerSchemeInPlace(norm);
    const uri = try std.Uri.parse(norm);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .init(max_redirects),
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [redirect_buffer_len]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.HttpRequestFailed;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);

    var transfer_buffer: [8 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(format.max_input_bytes));
}

// --- tests -------------------------------------------------------------------

test "remote path detection" {
    try std.testing.expect(isRemotePath("https://modland.com/pub/x.dro"));
    try std.testing.expect(isRemotePath("HTTP://example.com/t.imf"));
    try std.testing.expect(!isRemotePath("ftp://ftp.modland.com/x.hsc"));
    try std.testing.expect(!isRemotePath("music/tune.hsc"));
    try std.testing.expect(!isRemotePath("C:\\music\\tune.hsc"));
}

test "file url detection" {
    try std.testing.expect(isFileUrl("file:///C:/music/tune.hsc"));
    try std.testing.expect(isFileUrl("FILE://localhost/tmp/x.hsc"));
    try std.testing.expect(!isFileUrl("https://x/y.hsc"));
    try std.testing.expect(!isFileUrl("music/file.hsc"));
}

test "file url to local path" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { url: []const u8, path: []const u8 }{
        .{ .url = "file:///C:/My%20Music/tune.hsc", .path = "C:/My Music/tune.hsc" },
        .{ .url = "file:///usr/share/x.hsc", .path = "/usr/share/x.hsc" },
        .{ .url = "file://localhost/usr/x.hsc", .path = "/usr/x.hsc" },
        .{ .url = "file://C:\\music\\tune.hsc", .path = "C:/music/tune.hsc" },
        .{ .url = "file://server/share/x.hsc", .path = "//server/share/x.hsc" },
        .{ .url = "FILE:///tmp/x.hsc", .path = "/tmp/x.hsc" },
    };
    for (cases) |c| {
        const got = try fileUrlToPath(gpa, c.url);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.path, got);
    }
    try std.testing.expectError(error.InvalidFileUrl, fileUrlToPath(gpa, "file://"));
    try std.testing.expectError(error.InvalidFileUrl, fileUrlToPath(gpa, "file://localhost"));
}

test "display basename decodes valid percent sequences only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "dune 1.dro",
        displayBasename(arena, "https://modland.com/Ad%20Lib/dune%201.dro"),
    );
    try std.testing.expectEqualStrings(
        "dune1.dro",
        displayBasename(arena, "https://modland.com/dune1.dro"),
    );
    try std.testing.expectEqualStrings("tune.hsc", displayBasename(arena, "music/tune.hsc"));
    try std.testing.expectEqualStrings("100%.hsc", displayBasename(arena, "100%.hsc"));
    try std.testing.expectEqualStrings("%GG.hsc", displayBasename(arena, "%GG.hsc"));
}

test "scheme lowercasing touches only the scheme" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, "HTTPS://Example.com/A%20B.dro");
    defer gpa.free(buf);
    lowerSchemeInPlace(buf);
    try std.testing.expectEqualStrings("https://Example.com/A%20B.dro", buf);
}

test "url encoding escapes raw spaces and keeps existing escapes" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{
            .in = "https://x.com/my song.dro",
            .out = "https://x.com/my%20song.dro",
        },
        .{
            .in = "https://x.com/a%20b.imf",
            .out = "https://x.com/a%20b.imf",
        },
        .{
            .in = "https://x.com/caf\xc3\xa9.hsc",
            .out = "https://x.com/caf%C3%A9.hsc",
        },
        .{
            .in = "https://x.com/a\x01b\x7f.dro",
            .out = "https://x.com/a%01b%7F.dro",
        },
        .{
            .in = "https://x.com/a|b^c{d}.imf",
            .out = "https://x.com/a%7Cb%5Ec%7Bd%7D.imf",
        },
        .{
            .in = "https://x.com/track#1.dro",
            .out = "https://x.com/track%231.dro",
        },
        .{
            .in = "https://x.com/what?.imf",
            .out = "https://x.com/what%3F.imf",
        },
    };
    for (cases) |c| {
        const got = try encodeUrlAlloc(gpa, c.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "url scheme detection leaves local paths alone" {
    try std.testing.expect(hasUrlScheme("https://x/y.dro"));
    try std.testing.expect(hasUrlScheme("ftp://x/y.hsc"));
    try std.testing.expect(hasUrlScheme("file:///y.hsc"));
    try std.testing.expect(!hasUrlScheme("C://music/tune.hsc"));
    try std.testing.expect(!hasUrlScheme("C:\\music\\tune.hsc"));
    try std.testing.expect(!hasUrlScheme("music/tune.hsc"));
    try std.testing.expect(!hasUrlScheme("weird:name.hsc"));
    try std.testing.expect(!hasUrlScheme("no scheme://here.hsc"));
}
