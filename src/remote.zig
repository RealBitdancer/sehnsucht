//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const build_options = @import("build_options");

const format = @import("format.zig");
const inflate = @import("inflate.zig");

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
    const slash = std.mem.findScalar(u8, work, '/') orelse work.len;
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
    const end = std.mem.find(u8, url, "://") orelse return;
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
    if (std.mem.findScalar(u8, base, '%') == null) return base;
    const buf = arena.dupe(u8, base) catch return base;
    return std.Uri.percentDecodeInPlace(buf);
}

const zip_cache_cap = 4;

pub const ArchiveCache = struct {
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []u8, blob: []const u8, failure: ?anyerror = null };

    pub fn deinit(self: *ArchiveCache, gpa: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            gpa.free(entry.key);
            gpa.free(entry.blob);
        }
        self.entries.deinit(gpa);
    }

    fn find(self: *const ArchiveCache, key: []const u8) ?Entry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    fn put(self: *ArchiveCache, gpa: std.mem.Allocator, io: Io, key: []const u8, blob: []const u8, failure: ?anyerror) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.find(key) != null) {
            gpa.free(blob);
            return;
        }
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        try self.entries.ensureUnusedCapacity(gpa, 1);
        if (self.entries.items.len >= zip_cache_cap) {
            const oldest = self.entries.orderedRemove(0);
            gpa.free(oldest.key);
            gpa.free(oldest.blob);
        }
        self.entries.appendAssumeCapacity(.{ .key = k, .blob = blob, .failure = failure });
    }
};

pub fn readPathAlloc(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    abort: ?*const std.atomic.Value(bool),
    cache: ?*ArchiveCache,
) ![]u8 {
    const parts = split(path);
    return readDirect(gpa, io, path, abort) catch |err| {
        if (parts == null) return err;
        return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => readZipMember(gpa, io, parts.?, abort, cache),
        };
    };
}

fn readDirect(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    abort: ?*const std.atomic.Value(bool),
) ![]u8 {
    if (isRemotePath(path)) return fetch(gpa, io, path, abort);
    if (hasUrlScheme(path)) return error.UnsupportedUrlScheme;
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(format.max_input_bytes));
}

fn readZipMember(
    gpa: std.mem.Allocator,
    io: Io,
    parts: ZipParts,
    abort: ?*const std.atomic.Value(bool),
    cache: ?*ArchiveCache,
) ![]u8 {
    const c = cache orelse {
        const blob = try readDirect(gpa, io, parts.archive, abort);
        defer gpa.free(blob);
        return extract(gpa, blob, parts.member);
    };
    if (try cachedMember(gpa, io, c, parts)) |member| return member;
    const blob = readDirect(gpa, io, parts.archive, abort) catch |err| {
        if (err == error.StreamTooLong) c.put(gpa, io, parts.archive, "", err) catch {};
        return err;
    };
    c.put(gpa, io, parts.archive, blob, null) catch {
        defer gpa.free(blob);
        return extract(gpa, blob, parts.member);
    };
    return try cachedMember(gpa, io, c, parts) orelse error.ZipMemberNotFound;
}

fn cachedMember(gpa: std.mem.Allocator, io: Io, cache: *ArchiveCache, parts: ZipParts) !?[]u8 {
    try cache.mutex.lock(io);
    defer cache.mutex.unlock(io);
    const entry = cache.find(parts.archive) orelse return null;
    if (entry.failure) |err| return err;
    return try extract(gpa, entry.blob, parts.member);
}

const ZipParts = struct {
    archive: []const u8,
    member: []const u8,
};

fn split(path: []const u8) ?ZipParts {
    const sep = findZipSep(path) orelse return null;
    const member = path[sep + 1 ..];
    if (member.len == 0) return null;
    return .{ .archive = path[0..sep], .member = member };
}

fn findZipSep(path: []const u8) ?usize {
    var i: usize = 0;
    while (i + 5 <= path.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(path[i..][0..4], ".zip")) continue;
        const sep = path[i + 4];
        if (sep == '/' or sep == '\\') return i + 4;
    }
    return null;
}

fn extract(gpa: std.mem.Allocator, zip: []const u8, member: []const u8) ![]u8 {
    const rec = try findEndRecord(zip);
    if (rec.need_zip64()) return error.Zip64Unsupported;
    if (rec.disk_number != 0 or rec.central_directory_disk_number != 0)
        return error.ZipMultiDiskUnsupported;
    if (rec.record_count_disk != rec.record_count_total)
        return error.ZipMultiDiskUnsupported;

    const want_buf = try gpa.dupe(u8, member);
    defer gpa.free(want_buf);
    var want = std.Uri.percentDecodeInPlace(want_buf);
    std.mem.replaceScalar(u8, want, '\\', '/');
    while (std.mem.startsWith(u8, want, "./")) want = want[2..];
    if (want.len == 0 or isBadMember(want)) return error.ZipBadFilename;

    const cd_off: usize = rec.central_directory_offset;
    const cd_end = cd_off + rec.central_directory_size;
    if (cd_end > zip.len) return error.ZipTruncated;

    var off = cd_off;
    var n: u16 = 0;
    var found_ci: ?CdEntry = null;
    while (n < rec.record_count_total) : (n += 1) {
        const hdr = try readStruct(std.zip.CentralDirectoryFileHeader, zip, off);
        if (!std.mem.eql(u8, &hdr.signature, &std.zip.central_file_header_sig))
            return error.ZipBadCdOffset;
        const name_off = off + @sizeOf(std.zip.CentralDirectoryFileHeader);
        const name_end = name_off + hdr.filename_len;
        if (name_end > zip.len) return error.ZipTruncated;
        const name = zip[name_off..name_end];
        if (isBadMember(name)) {
            off = name_end + hdr.extra_len + hdr.comment_len;
            continue;
        }
        if (pathEql(name, want, false)) {
            return extractLocal(gpa, zip, hdr);
        }
        if (found_ci == null and pathEql(name, want, true)) {
            found_ci = .{ .hdr = hdr };
        }
        off = name_end + hdr.extra_len + hdr.comment_len;
        if (off > cd_end) return error.ZipTruncated;
    }
    if (found_ci) |hit| return extractLocal(gpa, zip, hit.hdr);
    return error.ZipMemberNotFound;
}

const CdEntry = struct { hdr: std.zip.CentralDirectoryFileHeader };

fn isBadMember(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '/' or name[0] == '\\') return true;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "..")) return true;
        if (std.mem.findScalar(u8, part, '\\')) |_| {
            var inner = std.mem.splitScalar(u8, part, '\\');
            while (inner.next()) |p| {
                if (std.mem.eql(u8, p, "..")) return true;
            }
        }
    }
    return false;
}

fn pathEql(zip_name: []const u8, want: []const u8, ignore_case: bool) bool {
    if (zip_name.len != want.len) return false;
    for (zip_name, want) |a, b| {
        const na: u8 = if (a == '\\') '/' else a;
        const nb: u8 = if (b == '\\') '/' else b;
        if (ignore_case) {
            if (std.ascii.toLower(na) != std.ascii.toLower(nb)) return false;
        } else if (na != nb) return false;
    }
    return true;
}

fn extractLocal(
    gpa: std.mem.Allocator,
    zip: []const u8,
    hdr: std.zip.CentralDirectoryFileHeader,
) ![]u8 {
    if (hdr.flags.encrypted) return error.ZipEncryptionUnsupported;
    const method = hdr.compression_method;
    switch (method) {
        .store, .deflate => {},
        else => return error.ZipUnsupportedCompression,
    }
    const local_off: usize = hdr.local_file_header_offset;
    const local = try readStruct(std.zip.LocalFileHeader, zip, local_off);
    if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig))
        return error.ZipBadFileOffset;
    const data_off = local_off + @sizeOf(std.zip.LocalFileHeader) +
        local.filename_len + local.extra_len;
    const comp_size: usize = hdr.compressed_size;
    const uncomp_size: usize = hdr.uncompressed_size;
    if (uncomp_size > format.max_input_bytes) return error.StreamTooLong;
    if (data_off + comp_size > zip.len) return error.ZipTruncated;
    const payload = zip[data_off..][0..comp_size];
    if (method == .store and comp_size != uncomp_size) return error.ZipSizeMismatch;

    const bytes = switch (method) {
        .store => try gpa.dupe(u8, payload),
        .deflate => inflate.decode(gpa, payload, .raw, uncomp_size) catch |err| switch (err) {
            error.ReadFailed => return error.ZipDecompressFailed,
            error.StreamTooLong => return error.ZipSizeMismatch,
            else => return err,
        },
        else => return error.ZipUnsupportedCompression,
    };
    errdefer gpa.free(bytes);
    if (bytes.len != uncomp_size) return error.ZipDecompressTruncated;
    if (std.hash.Crc32.hash(bytes) != hdr.crc32) return error.ZipChecksumMismatch;
    return bytes;
}

fn findEndRecord(zip: []const u8) !std.zip.EndRecord {
    const rec_size = @sizeOf(std.zip.EndRecord);
    if (zip.len < rec_size) return error.ZipNoEndRecord;
    var comment_len: u16 = 0;
    while (true) {
        const record_len: usize = @as(usize, comment_len) + rec_size;
        if (record_len > zip.len) return error.ZipNoEndRecord;
        const rec_bytes = zip[zip.len - record_len ..][0..rec_size];
        if (std.mem.eql(u8, rec_bytes[0..4], &std.zip.end_record_sig) and
            std.mem.readInt(u16, rec_bytes[20..22], .little) == comment_len)
        {
            return readStruct(std.zip.EndRecord, rec_bytes, 0);
        }
        if (comment_len == std.math.maxInt(u16)) return error.ZipNoEndRecord;
        comment_len += 1;
    }
}

fn readStruct(comptime T: type, buf: []const u8, off: usize) !T {
    if (off + @sizeOf(T) > buf.len) return error.ZipTruncated;
    var val: T = undefined;
    @memcpy(std.mem.asBytes(&val), buf[off..][0..@sizeOf(T)]);
    if (builtin.target.cpu.arch.endian() != .little) std.mem.byteSwap(T, &val);
    return val;
}

const download_idle_timeout_ms: u64 = 30_000;
const download_poll_ms: u64 = 100;

const FetchResult = anyerror![]u8;

fn fetchTask(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    out: *FetchResult,
    done: *std.atomic.Value(bool),
    progress: *std.atomic.Value(usize),
) void {
    out.* = fetchNow(gpa, io, url, progress);
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
    var progress = std.atomic.Value(usize).init(0);
    var fut = try io.concurrent(fetchTask, .{ gpa, io, url, &result, &done, &progress });
    var aborted = false;
    var seen: usize = 0;
    var idle: u64 = 0;
    while (!done.load(.acquire) and idle < download_idle_timeout_ms) : (idle += download_poll_ms) {
        const received = progress.load(.acquire);
        if (received != seen) {
            seen = received;
            idle = 0;
        }
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

fn fetchNow(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    progress: *std.atomic.Value(usize),
) ![]u8 {
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

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [8 * 1024]u8 = undefined;
    while (true) {
        var vecs: [1][]u8 = .{&chunk};
        const got = reader.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        if (out.items.len + got > format.max_input_bytes) return error.StreamTooLong;
        try out.appendSlice(gpa, chunk[0..got]);
        if (got > 0) progress.store(out.items.len, .release);
    }
    return out.toOwnedSlice(gpa);
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

test "split takes the first .zip/ as the archive boundary" {
    const a = split("https://host/lib/MusicV.zip/TITLE.WM").?;
    try std.testing.expectEqualStrings("https://host/lib/MusicV.zip", a.archive);
    try std.testing.expectEqualStrings("TITLE.WM", a.member);

    const b = split("https://ia/item/game.zip/dir/song.wlf").?;
    try std.testing.expectEqualStrings("https://ia/item/game.zip", b.archive);
    try std.testing.expectEqualStrings("dir/song.wlf", b.member);

    const c = split("C:\\music\\pack.ZIP\\inner\\t.wm").?;
    try std.testing.expectEqualStrings("C:\\music\\pack.ZIP", c.archive);
    try std.testing.expectEqualStrings("inner\\t.wm", c.member);

    const d = split("a.zip/b.zip/c.wm").?;
    try std.testing.expectEqualStrings("a.zip", d.archive);
    try std.testing.expectEqualStrings("b.zip/c.wm", d.member);

    try std.testing.expect(split("https://host/TITLE.WM") == null);
    try std.testing.expect(split("MusicV.zip") == null);
    try std.testing.expect(split("MusicV.zip/") == null);
    try std.testing.expect(split("notazipfile.wm") == null);
}

fn testZip(gpa: std.mem.Allocator, method: std.zip.CompressionMethod, plain: []const u8) ![]u8 {
    var compressed = try Io.Writer.Allocating.initCapacity(gpa, 256);
    defer compressed.deinit();
    switch (method) {
        .store => try compressed.writer.writeAll(plain),
        .deflate => {
            var buffer: [flate.max_window_len]u8 = undefined;
            var compressor = try flate.Compress.init(&compressed.writer, &buffer, .raw, .default);
            try compressor.writer.writeAll(plain);
            try compressor.finish();
        },
        else => unreachable,
    }

    const name = "music/song.wm";
    const payload = compressed.written();
    const local = std.mem.zeroInit(std.zip.LocalFileHeader, .{
        .signature = std.zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .compression_method = method,
        .crc32 = std.hash.Crc32.hash(plain),
        .compressed_size = @as(u32, @intCast(payload.len)),
        .uncompressed_size = @as(u32, @intCast(plain.len)),
        .filename_len = name.len,
    });
    const central = std.mem.zeroInit(std.zip.CentralDirectoryFileHeader, .{
        .signature = std.zip.central_file_header_sig,
        .version_made_by = 20,
        .version_needed_to_extract = local.version_needed_to_extract,
        .compression_method = method,
        .crc32 = local.crc32,
        .compressed_size = local.compressed_size,
        .uncompressed_size = local.uncompressed_size,
        .filename_len = name.len,
    });
    const end = std.mem.zeroInit(std.zip.EndRecord, .{
        .signature = std.zip.end_record_sig,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @sizeOf(std.zip.CentralDirectoryFileHeader) + name.len,
        .central_directory_offset = @as(u32, @intCast(@sizeOf(std.zip.LocalFileHeader) + name.len + payload.len)),
    });

    var zip: Io.Writer.Allocating = .init(gpa);
    errdefer zip.deinit();
    try zip.writer.writeStruct(local, .little);
    try zip.writer.writeAll(name);
    try zip.writer.writeAll(payload);
    try zip.writer.writeStruct(central, .little);
    try zip.writer.writeAll(name);
    try zip.writer.writeStruct(end, .little);
    return zip.toOwnedSlice();
}

test "zip extracts stored and deflated members, including empty files" {
    const gpa = std.testing.allocator;
    for ([_]std.zip.CompressionMethod{ .store, .deflate }) |method| {
        for ([_][]const u8{ "music data\n", "" }) |plain| {
            const zip = try testZip(gpa, method, plain);
            defer gpa.free(zip);
            const got = try extract(gpa, zip, "music/song.wm");
            defer gpa.free(got);
            try std.testing.expectEqualSlices(u8, plain, got);
        }
    }
}

test "zip archives stay cached after a member lookup misses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const zip = try testZip(gpa, .store, "music data\n");
    defer gpa.free(zip);
    try dir.dir.writeFile(io, .{ .sub_path = "pack.zip", .data = zip });
    const archive = try gpa.print(".zig-cache/tmp/{s}/pack.zip", .{dir.sub_path});
    defer gpa.free(archive);
    var cache: ArchiveCache = .{};
    defer cache.deinit(gpa);
    try std.testing.expectError(error.ZipMemberNotFound, readZipMember(gpa, io, .{ .archive = archive, .member = "missing.wm" }, null, &cache));
    try std.testing.expect(cache.find(archive) != null);
    try dir.dir.deleteFile(io, "pack.zip");
    const got = try readZipMember(gpa, io, .{ .archive = archive, .member = "music/song.wm" }, null, &cache);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("music data\n", got);
}

test "zip reports missing members and normalizes member paths" {
    const gpa = std.testing.allocator;
    const zip = try testZip(gpa, .deflate, "music data\n");
    defer gpa.free(zip);
    const got = try extract(gpa, zip, "./MUSIC\\song%2Ewm");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("music data\n", got);
    try std.testing.expectError(error.ZipMemberNotFound, extract(gpa, zip, "missing.wm"));
    try std.testing.expectError(error.ZipBadFilename, extract(gpa, zip, "../song.wm"));
}
