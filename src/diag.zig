//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const build_options = @import("build_options");

const crash_log = build_options.name ++ "-crash.log";

var log_io: ?Io = null;

pub fn arm(io: Io) void {
    log_io = io;
}

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    writeCrash("PANIC: {s}\n", .{msg});
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

fn writeCrash(comptime f: []const u8, args: anytype) void {
    const io = log_io orelse return;
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, f, args) catch return;
    const file = Io.Dir.cwd().createFile(io, crash_log, .{ .truncate = false }) catch return;
    defer file.close(io);
    const off = file.length(io) catch 0;
    file.writePositionalAll(io, line, off) catch {};
    file.sync(io) catch {};
}
