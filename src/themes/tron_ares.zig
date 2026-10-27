//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "Tron Ares";
pub const description = "Red light lines, orange energy, and cool white on black.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const canvas = rgb(0x00, 0x00, 0x00);
const base = rgb(0xD8, 0xDC, 0xE8);
const bright = rgb(0xF5, 0xF7, 0xFF);
const label = rgb(0xAE, 0xB4, 0xC4);
const dim = rgb(0x90, 0x96, 0xA6);
const ink = rgb(0x14, 0x00, 0x00);
const red = rgb(0xFF, 0x2D, 0x2D);
const ember = rgb(0xFF, 0x5C, 0x22);
const hot = rgb(0xFF, 0x8A, 0x3D);
const ice = rgb(0xB7, 0xC4, 0xDE);
const danger = rgb(0xFF, 0x8A, 0x8A);
const disabled = rgb(0x62, 0x68, 0x78);
const ghost = rgb(0x4A, 0x20, 0x28);
const rail = rgb(0x7A, 0x38, 0x44);
const panel = rgb(0xC0, 0x18, 0x30);
const open = rgb(0x3A, 0x0C, 0x12);
const toolbar = rgb(0x24, 0x08, 0x0C);
const patbar = rgb(0x5A, 0x14, 0x20);
const played = rgb(0x7E, 0x84, 0x94);
const white = rgb(0xFF, 0xFF, 0xFF);
const meter_hi = rgb(0xFF, 0xF4, 0xEA);

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
    .header_frame_fg = red,
    .viz_frame_fg = red,
    .status_frame_fg = ember,

    .brand_fg = bright,
    .state_loading_fg = ember,
    .state_playing_fg = red,
    .state_paused_fg = ember,
    .state_stopped_fg = dim,
    .playlist_pos_fg = label,
    .title_fg = bright,
    .title_time_fg = bright,
    .format_tag_fg = ember,
    .artist_fg = label,
    .volume_label_fg = label,
    .volume_value_fg = bright,
    .volume_gauge_on_fg = red,
    .volume_gauge_off_fg = rail,
    .mode_light_on_fg = ember,
    .mode_light_off_fg = disabled,

    .menu_enabled_fg = label,
    .menu_disabled_fg = disabled,
    .menu_hotkey_fg = ember,
    .menu_focus_fg = ink,
    .menu_focus_bg = red,
    .menu_open_fg = bright,
    .menu_open_bg = open,

    .transport_icon_fg = ember,
    .status_time_fg = bright,
    .loop_count_fg = dim,
    .progress_on_fg = red,
    .progress_off_fg = rail,
    .notice_mark_fg = danger,
    .notice_text_fg = label,

    .key_sep_fg = dim,
    .key_fg = ember,
    .key_disabled_fg = disabled,
    .key_label_fg = label,
    .key_label_disabled_fg = disabled,

    .list_header_fg = ember,
    .list_row_fg = base,
    .list_cursor_fg = ink,
    .list_cursor_bg = red,
    .list_rule_fg = rail,
    .scroll_track_bg = toolbar,
    .scroll_thumb_bg = red,

    .browse_path_fg = dim,
    .browse_error_fg = danger,
    .browse_empty_fg = dim,
    .browse_dir_fg = ember,

    .playlist_empty_fg = dim,
    .playlist_title_fg = label,
    .playlist_playing_fg = bright,
    .playlist_playing_bg = panel,
    .playlist_played_fg = played,
    .playlist_dead_fg = disabled,
    .playlist_dead_mark_fg = danger,

    .viz_notice_fg = dim,
    .inst_title_fg = ember,
    .inst_label_fg = dim,
    .inst_flag_on_fg = red,
    .inst_flag_off_fg = dim,
    .inst_value_fg = base,
    .gauge_on_fg = red,
    .gauge_off_fg = rail,
    .order_title_fg = ember,
    .order_row_fg = base,
    .order_skip_fg = dim,
    .order_cur_fg = bright,
    .order_cur_bg = panel,
    .pat_bar_bg = patbar,
    .pat_bar_fg = base,
    .pat_head_fg = red,
    .pat_gutter_fg = dim,
    .note_fg = bright,
    .note_empty_fg = ghost,
    .inst_cell_fg = ember,
    .fx_fg = ice,
    .pat_sep_fg = ghost,
    .pat_cur_fg = bright,
    .pat_cur_bg = panel,

    .spectrum_frame_fg = red,
    .spectrum_title_fg = bright,
    .spec_digit_on_fg = red,
    .spec_digit_off_fg = dim,
    .analyzer_base_fg = ember,
    .freq_label_fg = dim,

    .info_bar_bg = toolbar,
    .info_dim_fg = dim,
    .info_label_fg = label,
    .info_value_fg = base,
    .loop_badge_on_fg = red,
    .loop_badge_off_fg = dim,
    .rate_value_fg = ember,
    .peak_label_fg = label,
    .meter_off_fg = disabled,
    .master_label_fg = dim,
    .vu_empty_fg = rail,

    .trk_summary_fg = label,
    .trk_focus_fg = ink,
    .trk_focus_bg = red,
    .trk_live_fg = red,
    .vol_cell_fg = ember,
    .fx_letter_fg = ice,
    .ch_pcm_fg = ember,
    .ch_control_fg = dim,
    .ch_drum_fg = red,
    .ch_4op_fg = bright,
    .ch_page_fg = label,
    .macro_pos_fg = ember,
    .note_fixed_fg = ember,
    .voice_key_on_fg = red,
    .voice_key_off_fg = ghost,
    .dump_reg_fg = ember,
    .dump_val_fg = bright,
    .seq_track_fg = ember,
    .seq_event_fg = base,
    .order_ptr_fg = red,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = red.rgb },
    .{ .pos = 0.7, .rgb = hot.rgb },
    .{ .pos = 1.0, .rgb = meter_hi.rgb },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = canvas.rgb },
    .{ .pos = 0.75, .rgb = ember.rgb },
    .{ .pos = 1.0, .rgb = white.rgb },
};

pub const theme = Theme.init(@This());
