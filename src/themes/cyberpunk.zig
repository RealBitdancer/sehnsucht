//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "Cyberpunk";
pub const description = "Acid yellow, neon cyan, and hot pink over Night City black.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const canvas = rgb(0x0A, 0x0C, 0x13);
const base = rgb(0xD9, 0xF2, 0xF4);
const bright = rgb(0xF4, 0xFD, 0xFE);
const label = rgb(0xA3, 0xC4, 0xC8);
const dim = rgb(0x6E, 0x8A, 0x90);
const yellow = rgb(0xFC, 0xEE, 0x0A);
const cyan = rgb(0x00, 0xF0, 0xFF);
const red = rgb(0xFF, 0x00, 0x3C);
const hud = rgb(0xFF, 0x5F, 0x56);
const amber = rgb(0xE8, 0xD6, 0x3C);
const steel = rgb(0x2E, 0x72, 0x7E);
const teal = rgb(0x00, 0xA8, 0xB8);
const tint = rgb(0x0F, 0x45, 0x50);
const pink = rgb(0xFF, 0x2A, 0x6D);
const ink = rgb(0x0A, 0x0A, 0x0A);
const disabled = rgb(0x66, 0x78, 0x7F);
const ghost = rgb(0x24, 0x30, 0x37);
const rail = rgb(0x1D, 0x3C, 0x44);
const panel = rgb(0x1C, 0x4C, 0x59);
const open = rgb(0x1C, 0x4C, 0x59);
const toolbar = rgb(0x15, 0x19, 0x1F);
const patbar = rgb(0x1B, 0x21, 0x29);
const played = rgb(0x78, 0x92, 0x98);
const white = rgb(0xFF, 0xFF, 0xFF);

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
    .header_frame_fg = steel,
    .viz_frame_fg = steel,
    .status_frame_fg = steel,

    .brand_fg = yellow,
    .state_loading_fg = cyan,
    .state_playing_fg = yellow,
    .state_paused_fg = hud,
    .state_stopped_fg = dim,
    .playlist_pos_fg = label,
    .title_fg = bright,
    .title_time_fg = cyan,
    .format_tag_fg = cyan,
    .artist_fg = label,
    .volume_label_fg = label,
    .volume_value_fg = bright,
    .volume_gauge_on_fg = cyan,
    .volume_gauge_off_fg = rail,
    .mode_light_on_fg = yellow,
    .mode_light_off_fg = disabled,

    .menu_enabled_fg = label,
    .menu_disabled_fg = disabled,
    .menu_hotkey_fg = yellow,
    .menu_focus_fg = ink,
    .menu_focus_bg = pink,
    .menu_open_fg = bright,
    .menu_open_bg = open,

    .transport_icon_fg = yellow,
    .status_time_fg = bright,
    .loop_count_fg = dim,
    .progress_on_fg = yellow,
    .progress_off_fg = rail,
    .notice_mark_fg = red,
    .notice_text_fg = label,

    .key_sep_fg = dim,
    .key_fg = yellow,
    .key_disabled_fg = disabled,
    .key_label_fg = label,
    .key_label_disabled_fg = disabled,

    .list_header_fg = cyan,
    .list_row_fg = base,
    .list_cursor_fg = ink,
    .list_cursor_bg = pink,
    .list_rule_fg = rail,
    .scroll_track_bg = toolbar,
    .scroll_thumb_bg = pink,

    .browse_path_fg = dim,
    .browse_error_fg = red,
    .browse_empty_fg = dim,
    .browse_dir_fg = cyan,

    .playlist_empty_fg = dim,
    .playlist_title_fg = label,
    .playlist_playing_fg = cyan,
    .playlist_playing_bg = tint,
    .playlist_played_fg = played,
    .playlist_dead_fg = disabled,
    .playlist_dead_mark_fg = red,

    .viz_notice_fg = dim,
    .inst_title_fg = yellow,
    .inst_label_fg = label,
    .inst_flag_on_fg = cyan,
    .inst_flag_off_fg = dim,
    .inst_value_fg = base,
    .gauge_on_fg = cyan,
    .gauge_off_fg = rail,
    .order_title_fg = yellow,
    .order_row_fg = base,
    .order_skip_fg = dim,
    .order_cur_fg = bright,
    .order_cur_bg = panel,
    .pat_bar_bg = patbar,
    .pat_bar_fg = base,
    .pat_head_fg = pink,
    .pat_gutter_fg = dim,
    .note_fg = bright,
    .note_empty_fg = ghost,
    .inst_cell_fg = pink,
    .fx_fg = amber,
    .pat_sep_fg = ghost,
    .pat_cur_fg = bright,
    .pat_cur_bg = panel,

    .spectrum_frame_fg = steel,
    .spectrum_title_fg = yellow,
    .spec_digit_on_fg = pink,
    .spec_digit_off_fg = dim,
    .analyzer_base_fg = cyan,
    .freq_label_fg = dim,

    .info_bar_bg = toolbar,
    .info_dim_fg = dim,
    .info_label_fg = label,
    .info_value_fg = base,
    .loop_badge_on_fg = cyan,
    .loop_badge_off_fg = dim,
    .rate_value_fg = cyan,
    .peak_label_fg = label,
    .meter_off_fg = disabled,
    .master_label_fg = dim,
    .vu_empty_fg = rail,

    .trk_summary_fg = label,
    .trk_focus_fg = ink,
    .trk_focus_bg = pink,
    .trk_live_fg = cyan,
    .vol_cell_fg = cyan,
    .fx_letter_fg = amber,
    .ch_pcm_fg = pink,
    .ch_control_fg = dim,
    .ch_drum_fg = hud,
    .ch_4op_fg = cyan,
    .ch_page_fg = yellow,
    .macro_pos_fg = cyan,
    .note_fixed_fg = pink,
    .voice_key_on_fg = cyan,
    .voice_key_off_fg = ghost,
    .dump_reg_fg = cyan,
    .dump_val_fg = bright,
    .seq_track_fg = pink,
    .seq_event_fg = base,
    .order_ptr_fg = pink,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = teal.rgb },
    .{ .pos = 0.7, .rgb = pink.rgb },
    .{ .pos = 1.0, .rgb = yellow.rgb },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = canvas.rgb },
    .{ .pos = 0.75, .rgb = yellow.rgb },
    .{ .pos = 1.0, .rgb = white.rgb },
};

pub const theme = Theme.init(@This());
