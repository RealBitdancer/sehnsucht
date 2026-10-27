//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const paint = @import("../paint.zig");
const view = @import("../view.zig");
const viz = @import("../visualizer.zig");

pub const name = "example";
pub const requires = view.ViewCaps{};
pub const optional = view.ViewCaps{};

pub fn draw(ctx: *viz.DrawContext) void {
    if (ctx.win.width == 0 or ctx.win.height == 0) return;
    _ = ctx.views.caps();
    paint.printAt(ctx.win, 0, 0, "Example visualizer", ctx.theme.style(.viz_notice));
}

pub const visualizer = viz.Visualizer.init(@This());
