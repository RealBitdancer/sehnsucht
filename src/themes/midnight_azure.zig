//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "Midnight Azure";
pub const description = "Dark blue theme with cyan accents and amber highlights.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const canvas = rgb(0x0A, 0x0D, 0x13);
const base = rgb(0xC8, 0xD2, 0xDC);
const dim = rgb(0x75, 0x80, 0x8E);
const bright = rgb(0xF2, 0xF6, 0xFA);
const label = rgb(0x9F, 0xB6, 0xD2);
const brand = rgb(0x8F, 0xE3, 0xFF);
const accent = rgb(0x00, 0xD9, 0xFF);
const hotkey = rgb(0xFF, 0xB9, 0x2E);
const danger = rgb(0xFF, 0x4D, 0x57);
const live = rgb(0x2E, 0xE6, 0x7A);
const disabled = rgb(0x52, 0x5C, 0x6E);
const ghost = rgb(0x38, 0x42, 0x52);
const frame = rgb(0x3E, 0x71, 0xAD);
const chrome = rgb(0x5C, 0x96, 0xDE);
const rail = rgb(0x26, 0x2E, 0x3B);
const focus_fg = rgb(0x10, 0x15, 0x1C);
const focus_bg = rgb(0xC8, 0xD0, 0xDA);
const toolbar = rgb(0x18, 0x24, 0x37);
const pill = rgb(0x21, 0x45, 0x6F);
const scroll_track = rgb(0x16, 0x1C, 0x26);
const scroll_thumb = rgb(0x5A, 0x93, 0xD6);
const inst_orange = rgb(0xFF, 0x94, 0x36);
const fx_violet = rgb(0xCF, 0x7D, 0xFF);

pub const typography = Typography{
    .body = .{},
    .decoration = .{},
    .emphasis = .{ .bold = true },
    .selected = .{ .bold = true },
    .menu_hotkey = .{ .bold = true },
    .menu_hotkey_selected = .{ .bold = true, .underline = .single },
    .menu_hotkey_disabled = .{ .bold = true },
    .meter = .{},
    .meter_peak = .{ .bold = true },
};

pub const colors = Colors{
    .bg = canvas,
    .shell_fill_fg = base,
    .resize_notice_fg = base,
    .header_frame_fg = frame,
    .viz_frame_fg = frame,
    .status_frame_fg = frame,

    .brand_fg = brand,
    .state_loading_fg = accent,
    .state_playing_fg = hotkey,
    .state_paused_fg = danger,
    .state_stopped_fg = dim,
    .playlist_pos_fg = label,
    .title_fg = bright,
    .title_time_fg = bright,
    .format_tag_fg = label,
    .artist_fg = label,
    .volume_label_fg = label,
    .volume_value_fg = bright,
    .volume_gauge_on_fg = accent,
    .volume_gauge_off_fg = frame,
    .mode_light_on_fg = hotkey,
    .mode_light_off_fg = disabled,

    .menu_enabled_fg = label,
    .menu_disabled_fg = disabled,
    .menu_hotkey_fg = hotkey,
    .menu_focus_fg = focus_fg,
    .menu_focus_bg = focus_bg,
    .menu_open_fg = bright,
    .menu_open_bg = pill,

    .transport_icon_fg = accent,
    .status_time_fg = bright,
    .loop_count_fg = dim,
    .progress_on_fg = accent,
    .progress_off_fg = rail,
    .notice_mark_fg = danger,
    .notice_text_fg = label,

    .key_sep_fg = dim,
    .key_fg = bright,
    .key_disabled_fg = disabled,
    .key_label_fg = label,
    .key_label_disabled_fg = disabled,

    .list_header_fg = label,
    .list_row_fg = base,
    .list_cursor_fg = focus_fg,
    .list_cursor_bg = focus_bg,
    .list_rule_fg = rail,
    .scroll_track_bg = scroll_track,
    .scroll_thumb_bg = scroll_thumb,

    .browse_path_fg = dim,
    .browse_error_fg = danger,
    .browse_empty_fg = dim,
    .browse_dir_fg = accent,

    .playlist_empty_fg = dim,
    .playlist_title_fg = dim,
    .playlist_playing_fg = bright,
    .playlist_playing_bg = pill,
    .playlist_played_fg = ghost,
    .playlist_dead_fg = disabled,
    .playlist_dead_mark_fg = danger,

    .viz_notice_fg = dim,
    .inst_title_fg = accent,
    .inst_label_fg = dim,
    .inst_flag_on_fg = live,
    .inst_flag_off_fg = dim,
    .inst_value_fg = base,
    .gauge_on_fg = live,
    .gauge_off_fg = ghost,
    .order_title_fg = accent,
    .order_row_fg = base,
    .order_skip_fg = dim,
    .order_cur_fg = bright,
    .order_cur_bg = pill,
    .pat_bar_bg = toolbar,
    .pat_bar_fg = base,
    .pat_head_fg = chrome,
    .pat_gutter_fg = dim,
    .note_fg = bright,
    .note_empty_fg = ghost,
    .inst_cell_fg = inst_orange,
    .fx_fg = fx_violet,
    .pat_sep_fg = ghost,
    .pat_cur_fg = bright,
    .pat_cur_bg = pill,

    .spectrum_frame_fg = frame,
    .spectrum_title_fg = accent,
    .spec_digit_on_fg = accent,
    .spec_digit_off_fg = dim,
    .analyzer_base_fg = frame,
    .freq_label_fg = dim,

    .info_bar_bg = toolbar,
    .info_dim_fg = dim,
    .info_label_fg = label,
    .info_value_fg = base,
    .loop_badge_on_fg = live,
    .loop_badge_off_fg = dim,
    .rate_value_fg = hotkey,
    .peak_label_fg = label,
    .meter_off_fg = disabled,
    .master_label_fg = dim,
    .vu_empty_fg = ghost,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = .{ 0x1F, 0xE5, 0x6B } },
    .{ .pos = 0.75, .rgb = .{ 0xFF, 0xB9, 0x2E } },
    .{ .pos = 1.0, .rgb = .{ 0xFF, 0x3D, 0x4F } },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = .{ 0x0A, 0x0D, 0x13 } },
    .{ .pos = 0.8, .rgb = .{ 0x5C, 0x96, 0xDE } },
    .{ .pos = 1.0, .rgb = .{ 0xE0, 0xF0, 0xFF } },
};

pub const theme = Theme.init(@This());
