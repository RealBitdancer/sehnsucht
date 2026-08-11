//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "High Contrast";
pub const description = "Color-vision-safe theme with bold text and strong contrast.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const black = rgb(0x00, 0x00, 0x00);
const white = rgb(0xFF, 0xFF, 0xFF);
const yellow = rgb(0xFF, 0xFF, 0x00);
const cyan = rgb(0x00, 0xFF, 0xFF);
const magenta = rgb(0xFF, 0x66, 0xFF);
const secondary = rgb(0xD0, 0xD0, 0xD0);
const disabled = rgb(0xA0, 0xA0, 0xA0);
const ghost = rgb(0x90, 0x90, 0x90);
const rail = rgb(0x60, 0x60, 0x60);
const open_bg = rgb(0x00, 0x3D, 0x52);
const toolbar = rgb(0x12, 0x12, 0x12);

pub const typography = Typography{
    .body = .{ .bold = true },
    .decoration = .{ .bold = true },
    .emphasis = .{ .bold = true },
    .selected = .{ .bold = true, .underline = .single },
    .menu_hotkey = .{ .bold = true },
    .menu_hotkey_selected = .{ .bold = true, .underline = .double },
    .menu_hotkey_disabled = .{ .bold = true },
    .meter = .{ .bold = true },
    .meter_peak = .{ .bold = true },
};

pub const colors = Colors{
    .bg = black,
    .shell_fill_fg = white,
    .resize_notice_fg = white,
    .header_frame_fg = white,
    .viz_frame_fg = white,
    .status_frame_fg = white,

    .brand_fg = yellow,
    .state_loading_fg = cyan,
    .state_playing_fg = cyan,
    .state_paused_fg = yellow,
    .state_stopped_fg = secondary,
    .playlist_pos_fg = white,
    .title_fg = white,
    .title_time_fg = white,
    .format_tag_fg = secondary,
    .artist_fg = secondary,
    .volume_label_fg = secondary,
    .volume_value_fg = white,
    .volume_gauge_on_fg = cyan,
    .volume_gauge_off_fg = ghost,
    .mode_light_on_fg = yellow,
    .mode_light_off_fg = disabled,

    .menu_enabled_fg = white,
    .menu_disabled_fg = disabled,
    .menu_hotkey_fg = yellow,
    .menu_focus_fg = black,
    .menu_focus_bg = yellow,
    .menu_open_fg = white,
    .menu_open_bg = open_bg,

    .transport_icon_fg = cyan,
    .status_time_fg = white,
    .loop_count_fg = secondary,
    .progress_on_fg = cyan,
    .progress_off_fg = rail,
    .notice_mark_fg = magenta,
    .notice_text_fg = white,

    .key_sep_fg = secondary,
    .key_fg = yellow,
    .key_disabled_fg = disabled,
    .key_label_fg = white,
    .key_label_disabled_fg = disabled,

    .list_header_fg = yellow,
    .list_row_fg = white,
    .list_cursor_fg = black,
    .list_cursor_bg = yellow,
    .list_rule_fg = secondary,
    .scroll_track_bg = rail,
    .scroll_thumb_bg = white,

    .browse_path_fg = secondary,
    .browse_error_fg = magenta,
    .browse_empty_fg = secondary,
    .browse_dir_fg = cyan,

    .playlist_empty_fg = secondary,
    .playlist_title_fg = secondary,
    .playlist_playing_fg = white,
    .playlist_playing_bg = open_bg,
    .playlist_played_fg = disabled,
    .playlist_dead_fg = secondary,
    .playlist_dead_mark_fg = magenta,

    .viz_notice_fg = secondary,
    .inst_title_fg = cyan,
    .inst_label_fg = secondary,
    .inst_flag_on_fg = cyan,
    .inst_flag_off_fg = disabled,
    .inst_value_fg = white,
    .gauge_on_fg = cyan,
    .gauge_off_fg = ghost,
    .order_title_fg = cyan,
    .order_row_fg = white,
    .order_skip_fg = secondary,
    .order_cur_fg = black,
    .order_cur_bg = yellow,
    .pat_bar_bg = toolbar,
    .pat_bar_fg = white,
    .pat_head_fg = cyan,
    .pat_gutter_fg = secondary,
    .note_fg = white,
    .note_empty_fg = disabled,
    .inst_cell_fg = yellow,
    .fx_fg = magenta,
    .pat_sep_fg = secondary,
    .pat_cur_fg = black,
    .pat_cur_bg = yellow,

    .spectrum_frame_fg = white,
    .spectrum_title_fg = cyan,
    .spec_digit_on_fg = yellow,
    .spec_digit_off_fg = disabled,
    .analyzer_base_fg = white,
    .freq_label_fg = secondary,

    .info_bar_bg = toolbar,
    .info_dim_fg = secondary,
    .info_label_fg = cyan,
    .info_value_fg = white,
    .loop_badge_on_fg = cyan,
    .loop_badge_off_fg = secondary,
    .rate_value_fg = yellow,
    .peak_label_fg = white,
    .meter_off_fg = disabled,
    .master_label_fg = secondary,
    .vu_empty_fg = ghost,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = .{ 0x00, 0xFF, 0xFF } },
    .{ .pos = 0.75, .rgb = .{ 0xFF, 0xFF, 0x00 } },
    .{ .pos = 1.0, .rgb = .{ 0xFF, 0x66, 0xFF } },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = .{ 0x60, 0x60, 0x60 } },
    .{ .pos = 0.8, .rgb = .{ 0x00, 0xFF, 0xFF } },
    .{ .pos = 1.0, .rgb = .{ 0xFF, 0xFF, 0xFF } },
};

pub const theme = Theme.init(@This());

// --- tests -------------------------------------------------------------------

test "high contrast theme uses inverse selection and bold text" {
    try std.testing.expectEqual(@as([3]u8, .{ 0x00, 0x00, 0x00 }), colors.bg.rgb);
    try std.testing.expectEqual(@as([3]u8, .{ 0xFF, 0xFF, 0x00 }), colors.list_cursor_bg.rgb);
    try std.testing.expectEqual(@as([3]u8, .{ 0x00, 0x00, 0x00 }), colors.list_cursor_fg.rgb);
    try std.testing.expect(theme.listEntry(colors.list_row_fg, colors.bg, false).bold);
    try std.testing.expectEqual(vaxis.Style.Underline.single, theme.listEntry(colors.list_cursor_fg, colors.list_cursor_bg, true).ul_style);
}

test "high contrast text meets WCAG contrast minimums" {
    const Pair = struct { fg: [3]u8, bg: [3]u8 };
    const pairs = [_]Pair{
        .{ .fg = white.rgb, .bg = black.rgb },
        .{ .fg = secondary.rgb, .bg = black.rgb },
        .{ .fg = disabled.rgb, .bg = black.rgb },
        .{ .fg = ghost.rgb, .bg = black.rgb },
        .{ .fg = cyan.rgb, .bg = black.rgb },
        .{ .fg = yellow.rgb, .bg = black.rgb },
        .{ .fg = magenta.rgb, .bg = black.rgb },
        .{ .fg = black.rgb, .bg = yellow.rgb },
        .{ .fg = white.rgb, .bg = open_bg.rgb },
        .{ .fg = white.rgb, .bg = toolbar.rgb },
        .{ .fg = secondary.rgb, .bg = toolbar.rgb },
        .{ .fg = disabled.rgb, .bg = toolbar.rgb },
        .{ .fg = ghost.rgb, .bg = toolbar.rgb },
        .{ .fg = cyan.rgb, .bg = toolbar.rgb },
        .{ .fg = yellow.rgb, .bg = toolbar.rgb },
    };

    for (pairs) |pair| {
        try std.testing.expect(contrastRatio(pair.fg, pair.bg) >= 4.5);
    }
    try std.testing.expect(contrastRatio(rail.rgb, black.rgb) >= 3);
}

test "high contrast visualizer gradients remain visible" {
    for (0..101) |step| {
        const frac = @as(f32, @floatFromInt(step)) / 100;
        try std.testing.expect(contrastRatio(theme.meterBar(frac, false).fg.rgb, black.rgb) >= 4.5);
        try std.testing.expect(contrastRatio(theme.infoMeter(frac, true).fg.rgb, toolbar.rgb) >= 4.5);
        try std.testing.expect(contrastRatio(theme.barPeak(frac).fg.rgb, black.rgb) >= 3);
    }
}

test "high contrast semantic colors avoid red-green encoding" {
    try std.testing.expectEqual(cyan.rgb, colors.state_playing_fg.rgb);
    try std.testing.expectEqual(yellow.rgb, colors.state_paused_fg.rgb);
    try std.testing.expectEqual(magenta.rgb, colors.notice_mark_fg.rgb);
    try std.testing.expectEqual(cyan.rgb, vu_stops[0].rgb);
    try std.testing.expectEqual(yellow.rgb, vu_stops[1].rgb);
    try std.testing.expectEqual(magenta.rgb, vu_stops[2].rgb);
}

fn contrastRatio(a: [3]u8, b: [3]u8) f64 {
    const lighter = @max(luminance(a), luminance(b));
    const darker = @min(luminance(a), luminance(b));
    return (lighter + 0.05) / (darker + 0.05);
}

fn luminance(value: [3]u8) f64 {
    const weights = [3]f64{ 0.2126, 0.7152, 0.0722 };
    var result: f64 = 0;
    for (value, weights) |component, weight| {
        const srgb = @as(f64, @floatFromInt(component)) / 255;
        const linear = if (srgb <= 0.04045)
            srgb / 12.92
        else
            std.math.pow(f64, (srgb + 0.055) / 1.055, 2.4);
        result += linear * weight;
    }
    return result;
}
