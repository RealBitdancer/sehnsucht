//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

pub fn loadErrorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.EndOfStream => "truncated file",
        error.NonOplVgm => "not an OPL-family VGM",
        error.InvalidCmf => "invalid CMF file",
        error.InvalidRad => "invalid RAD file",
        error.InvalidRaw => "invalid RAW file",
        error.AudioTNeedsSibling => "missing AudioT companion",
        error.AudioTNeedsDict => "missing AUDIODCT dictionary",
        error.UnsupportedRadVersion => "unsupported RAD version",
        error.UnplayableFile => "not a playable music file",
        error.UnsupportedUrlScheme => "unsupported URL scheme",
        error.HttpRequestFailed => "HTTP request failed",
        error.DownloadTimeout => "download timed out",
        error.StreamTooLong => "file too large",
        error.UnsupportedCompressionMethod => "unsupported HTTP compression",
        error.ConnectionRefused => "connection refused",
        error.ConnectionResetByPeer => "connection reset",
        error.UnknownHostName => "unknown host",
        error.NetworkUnreachable => "network unreachable",
        error.TlsInitializationFailed => "TLS handshake failed",
        error.ConcurrencyUnavailable => "cannot start download task",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

pub fn printLoadError(io: Io, path: []const u8, err: anyerror) void {
    if (err == error.UnplayableFile) {
        return printStderr(
            io,
            build_options.name ++ ": {s} is not a playable music file\n",
            .{path},
        );
    }
    const msg: []const u8 = switch (err) {
        error.NonOplVgm => "not an OPL-family VGM (no YM3812/YM3526/Y8950/YMF262 clock)",
        error.MissingTrackerView => "tracker visualizer requires TrackerView",
        error.UnsupportedUrlScheme => "only http://, https://, and file:// URLs are supported",
        error.HttpRequestFailed => "HTTP request failed",
        error.DownloadTimeout => "download timed out",
        else => return printStderr(
            io,
            build_options.name ++ ": cannot load {s}: {s}\n",
            .{ path, loadErrorLabel(err) },
        ),
    };
    printStderr(io, build_options.name ++ ": {s}: {s}\n", .{ path, msg });
}

fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

// --- tests -------------------------------------------------------------------

test "loadErrorLabel maps common failures to plain phrases" {
    try std.testing.expectEqualStrings("file not found", loadErrorLabel(error.FileNotFound));
    try std.testing.expectEqualStrings("download timed out", loadErrorLabel(error.DownloadTimeout));
    try std.testing.expectEqualStrings("truncated file", loadErrorLabel(error.EndOfStream));
    try std.testing.expectEqualStrings("invalid RAW file", loadErrorLabel(error.InvalidRaw));
    try std.testing.expectEqualStrings("unknown host", loadErrorLabel(error.UnknownHostName));
    try std.testing.expectEqualStrings("NoResult", loadErrorLabel(error.NoResult));
}
