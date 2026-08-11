//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

const Theme = @import("../theme.zig").Theme;
const base = @import("midnight_azure.zig");

pub const theme = Theme.derive(base.theme, "Example", "Example theme derived from Midnight Azure.", .{
    .colors = &.{
        Theme.color("brand_fg", .{ .rgb = .{ 0xFF, 0xFF, 0xFF } }),
    },
    .typography = &.{
        Theme.text("emphasis", .{ .italic = true }),
    },
});

// --- tests -------------------------------------------------------------------

test "derived theme changes selected roles and inherits the rest" {
    try std.testing.expectEqualStrings("Example", theme.display_name);
    try std.testing.expect(!std.meta.eql(base.theme.colors.brand_fg, theme.colors.brand_fg));
    try std.testing.expect(std.meta.eql(base.theme.colors.bg, theme.colors.bg));
    try std.testing.expect(std.meta.eql(base.theme.vu_stops.*, theme.vu_stops.*));
    try std.testing.expect(!base.theme.style(.brand).italic);
    try std.testing.expect(theme.style(.brand).bold);
    try std.testing.expect(theme.style(.brand).italic);
    try std.testing.expectEqual(base.theme.style(.order_cur).bold, theme.style(.order_cur).bold);
}
