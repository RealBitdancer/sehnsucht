//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "LCD Ink";
pub const description = "Dark ink on a green-grey LCD backplane.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const canvas = rgb(0xA8, 0xB0, 0x9A);
const ink = rgb(0x14, 0x1A, 0x12);
const ink_hi = rgb(0x08, 0x0C, 0x06);
const readout = rgb(0x00, 0x00, 0x00);
const ghost = rgb(0x7A, 0x84, 0x70);
const text = rgb(0x14, 0x22, 0x2C);
const dim = rgb(0x32, 0x38, 0x3C);
const frame = rgb(0x36, 0x44, 0x4C);
const danger = rgb(0xB0, 0x28, 0x28);
const amber = rgb(0xC0, 0x68, 0x18);
const cream = rgb(0xF4, 0xEE, 0xD8);
const toolbar = rgb(0x7A, 0x82, 0x70);

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
    .shell_fill_fg = text,
    .resize_notice_fg = text,
    .header_frame_fg = frame,
    .viz_frame_fg = frame,
    .status_frame_fg = frame,

    .brand_fg = amber,
    .state_loading_fg = amber,
    .state_playing_fg = amber,
    .state_paused_fg = danger,
    .state_stopped_fg = dim,
    .playlist_pos_fg = dim,
    .title_fg = readout,
    .title_time_fg = readout,
    .format_tag_fg = dim,
    .artist_fg = dim,
    .volume_label_fg = dim,
    .volume_value_fg = readout,
    .volume_gauge_on_fg = ink,
    .volume_gauge_off_fg = ghost,
    .mode_light_on_fg = amber,
    .mode_light_off_fg = dim,

    .menu_enabled_fg = dim,
    .menu_disabled_fg = dim,
    .menu_hotkey_fg = amber,
    .menu_focus_fg = cream,
    .menu_focus_bg = amber,
    .menu_open_fg = ink,
    .menu_open_bg = cream,

    .transport_icon_fg = ink,
    .status_time_fg = readout,
    .loop_count_fg = dim,
    .progress_on_fg = ink,
    .progress_off_fg = ghost,
    .notice_mark_fg = danger,
    .notice_text_fg = dim,

    .key_sep_fg = dim,
    .key_fg = ink,
    .key_disabled_fg = dim,
    .key_label_fg = dim,
    .key_label_disabled_fg = dim,

    .list_header_fg = dim,
    .list_row_fg = text,
    .list_cursor_fg = cream,
    .list_cursor_bg = amber,
    .list_rule_fg = ghost,
    .scroll_track_bg = toolbar,
    .scroll_thumb_bg = frame,

    .browse_path_fg = dim,
    .browse_error_fg = danger,
    .browse_empty_fg = dim,
    .browse_dir_fg = ink,

    .playlist_empty_fg = dim,
    .playlist_title_fg = dim,
    .playlist_playing_fg = ink,
    .playlist_playing_bg = cream,
    .playlist_played_fg = dim,
    .playlist_dead_fg = dim,
    .playlist_dead_mark_fg = danger,

    .viz_notice_fg = dim,
    .inst_title_fg = ink,
    .inst_label_fg = dim,
    .inst_flag_on_fg = amber,
    .inst_flag_off_fg = ghost,
    .inst_value_fg = text,
    .gauge_on_fg = ink,
    .gauge_off_fg = ghost,
    .order_title_fg = ink,
    .order_row_fg = text,
    .order_skip_fg = dim,
    .order_cur_fg = cream,
    .order_cur_bg = amber,
    .pat_bar_bg = toolbar,
    .pat_bar_fg = text,
    .pat_head_fg = dim,
    .pat_gutter_fg = dim,
    .note_fg = readout,
    .note_empty_fg = ghost,
    .inst_cell_fg = amber,
    .fx_fg = danger,
    .pat_sep_fg = ghost,
    .pat_cur_fg = cream,
    .pat_cur_bg = amber,

    .spectrum_frame_fg = frame,
    .spectrum_title_fg = ink,
    .spec_digit_on_fg = ink_hi,
    .spec_digit_off_fg = ghost,
    .analyzer_base_fg = frame,
    .freq_label_fg = dim,

    .info_bar_bg = toolbar,
    .info_dim_fg = dim,
    .info_label_fg = dim,
    .info_value_fg = text,
    .loop_badge_on_fg = ink,
    .loop_badge_off_fg = dim,
    .rate_value_fg = ink,
    .peak_label_fg = dim,
    .meter_off_fg = dim,
    .master_label_fg = dim,
    .vu_empty_fg = ghost,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = ink.rgb },
    .{ .pos = 0.75, .rgb = amber.rgb },
    .{ .pos = 1.0, .rgb = danger.rgb },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = canvas.rgb },
    .{ .pos = 0.8, .rgb = frame.rgb },
    .{ .pos = 1.0, .rgb = ink_hi.rgb },
};

pub const theme = Theme.init(@This());
