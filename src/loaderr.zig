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
        error.NotVgm => "not a VGM file",
        error.InvalidVgmOffset => "invalid VGM data offset",
        error.InvalidVgmClock => "invalid Y8950 clock or output rate",
        error.InvalidVgmDataBlock => "invalid VGM sample memory block",
        error.GzipFailed => "gzip inflate failed",
        error.TruncatedDro => "truncated DRO file",
        error.UnsupportedDro2 => "unsupported DRO2 options",
        error.MissingResource => "required companion file not found",
        error.ResourceLimit => "companion files exceed the size limit",
        error.InvalidMusicData => "invalid or truncated music data",
        error.InvalidRolBank => "invalid ROL instrument bank",
        error.MissingRolInstrument => "ROL instrument is missing from the bank",
        error.InvalidSciPatch => "invalid SCI0 patch bank",
        error.UnsupportedSciVersion => "unsupported SCI0 sound version",
        error.MissingXmiBank => "missing XMI timbre bank",
        error.InvalidXmiBank => "invalid XMI timbre bank",
        error.MissingXmiTimbre => "XMI instrument is missing from the bank",
        error.UnsupportedXmiTimbre => "unsupported XMI timbre type",
        error.InvalidXmiLoop => "invalid XMI loop",
        error.InvalidXmiBranch => "invalid XMI branch offset",
        error.InvalidTrackIndex => "XMI archive has no sequences",
        error.InvalidCmf => "invalid CMF file",
        error.InvalidRad => "invalid RAD file",
        error.InvalidA2m => "invalid A2M/A2T file",
        error.InvalidA2mChecksum => "A2M/A2T checksum mismatch",
        error.InvalidA2mCompression => "invalid A2M/A2T compressed data",
        error.UnsupportedA2mVersion => "unsupported A2M/A2T version",
        error.InvalidRaw => "invalid RAW file",
        error.InvalidBam => "invalid BAM file",
        error.InvalidXsm => "invalid XSM file",
        error.InvalidGot => "invalid GOT file",
        error.InvalidSng => "invalid SNGPlay file",
        error.InvalidJbm => "invalid JBM file",
        error.InvalidWm => "invalid MusicV file",
        error.InvalidLds => "invalid LDS file",
        error.InvalidAdl => "invalid ADL file",
        error.InvalidHsp => "invalid HSP file",
        error.AudioTNeedsSibling => "missing AudioT companion",
        error.AudioTNeedsDict => "missing AUDIODCT dictionary",
        error.BadAudioHed => "invalid AUDIOHED table",
        error.EmptyAudioT => "empty AudioT archive",
        error.NoMusicInAudioT => "no music in AudioT archive",
        error.UnsupportedRadVersion => "unsupported RAD version",
        error.UnplayableFile => "not a playable music file",
        error.UnsupportedUrlScheme => "unsupported URL scheme",
        error.HttpRequestFailed => "HTTP request failed",
        error.DownloadTimeout => "download timed out",
        error.ReadFailed => "download interrupted",
        error.StreamTooLong => "file too large",
        error.UnsupportedCompressionMethod => "unsupported HTTP compression",
        error.ZipMemberNotFound => "zip member not found",
        error.ZipNoEndRecord => "not a zip archive",
        error.Zip64Unsupported => "zip64 is not supported",
        error.ZipMultiDiskUnsupported => "multi-disk zip is not supported",
        error.ZipEncryptionUnsupported => "encrypted zip",
        error.ZipUnsupportedCompression => "unsupported zip compression",
        error.ZipBadFilename => "invalid zip path",
        error.ZipBadCdOffset => "invalid zip directory",
        error.ZipBadFileOffset => "invalid zip local header",
        error.ZipTruncated => "truncated zip",
        error.ZipDecompressFailed => "zip inflate failed",
        error.ZipDecompressTruncated => "truncated zip member",
        error.ZipSizeMismatch => "zip member size mismatch",
        error.ZipChecksumMismatch => "zip checksum mismatch",
        error.ConnectionRefused => "connection refused",
        error.ConnectionResetByPeer => "connection reset",
        error.UnknownHostName => "unknown host",
        error.NetworkUnreachable => "network unreachable",
        error.TlsInitializationFailed => "TLS handshake failed",
        error.ConcurrencyUnavailable => "cannot start download task",
        error.OutOfMemory => "out of memory",
        error.MissingVisualizerData => "visualizer is missing required track data",
        error.UnknownVisualizer => "unknown visualizer",
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

test "loadErrorLabel gives the Y8950 VGM errors plain phrases" {
    try std.testing.expectEqualStrings("invalid Y8950 clock or output rate", loadErrorLabel(error.InvalidVgmClock));
    try std.testing.expectEqualStrings("invalid VGM sample memory block", loadErrorLabel(error.InvalidVgmDataBlock));
}
