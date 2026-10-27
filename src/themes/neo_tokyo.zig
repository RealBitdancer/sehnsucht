//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const vaxis = @import("vaxis");

const Colors = @import("../theme.zig").Colors;
const Theme = @import("../theme.zig").Theme;
const Typography = @import("../theme.zig").Typography;
const VuStop = @import("../theme.zig").VuStop;

pub const display_name = "Neo Tokyo";
pub const description = "Kaneda red, highway cyan, and sodium light over night blue.";

fn rgb(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

const canvas = rgb(0x07, 0x0A, 0x16);
const base = rgb(0xE2, 0xE7, 0xF3);
const bright = rgb(0xF8, 0xFA, 0xFF);
const label = rgb(0xA6, 0xB2, 0xCE);
const dim = rgb(0x76, 0x82, 0xA2);
const ink = rgb(0x12, 0x06, 0x0A);
const seal = rgb(0xB3, 0x2A, 0x26);
const capsule = rgb(0xFF, 0x4A, 0x3D);
const neon = rgb(0x36, 0xD3, 0xF0);
const tube = rgb(0x2A, 0x8F, 0xB0);
const deep = rgb(0x1E, 0x5E, 0x80);
const sodium = rgb(0xFF, 0x8F, 0x2E);
const signage = rgb(0xF2, 0x48, 0x9A);
const disabled = rgb(0x5F, 0x6B, 0x8E);
const ghost = rgb(0x1C, 0x24, 0x40);
const rail = rgb(0x22, 0x30, 0x5A);
const panel = rgb(0x21, 0x3A, 0x6E);
const open = rgb(0x21, 0x3A, 0x6E);
const toolbar = rgb(0x10, 0x17, 0x31);
const patbar = rgb(0x15, 0x1E, 0x3D);
const played = rgb(0x6E, 0x7A, 0x99);

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
    .header_frame_fg = tube,
    .viz_frame_fg = tube,
    .status_frame_fg = tube,

    .brand_fg = capsule,
    .state_loading_fg = neon,
    .state_playing_fg = capsule,
    .state_paused_fg = sodium,
    .state_stopped_fg = dim,
    .playlist_pos_fg = label,
    .title_fg = bright,
    .title_time_fg = neon,
    .format_tag_fg = neon,
    .artist_fg = label,
    .volume_label_fg = label,
    .volume_value_fg = bright,
    .volume_gauge_on_fg = neon,
    .volume_gauge_off_fg = rail,
    .mode_light_on_fg = sodium,
    .mode_light_off_fg = disabled,

    .menu_enabled_fg = label,
    .menu_disabled_fg = disabled,
    .menu_hotkey_fg = sodium,
    .menu_focus_fg = bright,
    .menu_focus_bg = seal,
    .menu_open_fg = bright,
    .menu_open_bg = open,

    .transport_icon_fg = neon,
    .status_time_fg = bright,
    .loop_count_fg = dim,
    .progress_on_fg = neon,
    .progress_off_fg = rail,
    .notice_mark_fg = capsule,
    .notice_text_fg = label,

    .key_sep_fg = dim,
    .key_fg = sodium,
    .key_disabled_fg = disabled,
    .key_label_fg = label,
    .key_label_disabled_fg = disabled,

    .list_header_fg = neon,
    .list_row_fg = base,
    .list_cursor_fg = bright,
    .list_cursor_bg = seal,
    .list_rule_fg = rail,
    .scroll_track_bg = toolbar,
    .scroll_thumb_bg = seal,

    .browse_path_fg = dim,
    .browse_error_fg = capsule,
    .browse_empty_fg = dim,
    .browse_dir_fg = neon,

    .playlist_empty_fg = dim,
    .playlist_title_fg = label,
    .playlist_playing_fg = ink,
    .playlist_playing_bg = neon,
    .playlist_played_fg = played,
    .playlist_dead_fg = disabled,
    .playlist_dead_mark_fg = capsule,

    .viz_notice_fg = dim,
    .inst_title_fg = neon,
    .inst_label_fg = label,
    .inst_flag_on_fg = capsule,
    .inst_flag_off_fg = dim,
    .inst_value_fg = base,
    .gauge_on_fg = neon,
    .gauge_off_fg = rail,
    .order_title_fg = neon,
    .order_row_fg = base,
    .order_skip_fg = dim,
    .order_cur_fg = bright,
    .order_cur_bg = panel,
    .pat_bar_bg = patbar,
    .pat_bar_fg = base,
    .pat_head_fg = capsule,
    .pat_gutter_fg = dim,
    .note_fg = bright,
    .note_empty_fg = ghost,
    .inst_cell_fg = capsule,
    .fx_fg = sodium,
    .pat_sep_fg = ghost,
    .pat_cur_fg = bright,
    .pat_cur_bg = panel,

    .spectrum_frame_fg = tube,
    .spectrum_title_fg = neon,
    .spec_digit_on_fg = capsule,
    .spec_digit_off_fg = dim,
    .analyzer_base_fg = sodium,
    .freq_label_fg = dim,

    .info_bar_bg = toolbar,
    .info_dim_fg = dim,
    .info_label_fg = label,
    .info_value_fg = base,
    .loop_badge_on_fg = neon,
    .loop_badge_off_fg = dim,
    .rate_value_fg = sodium,
    .peak_label_fg = label,
    .meter_off_fg = disabled,
    .master_label_fg = dim,
    .vu_empty_fg = rail,

    .trk_summary_fg = label,
    .trk_focus_fg = bright,
    .trk_focus_bg = seal,
    .trk_live_fg = neon,
    .vol_cell_fg = neon,
    .fx_letter_fg = sodium,
    .ch_pcm_fg = signage,
    .ch_control_fg = dim,
    .ch_drum_fg = sodium,
    .ch_4op_fg = neon,
    .ch_page_fg = label,
    .macro_pos_fg = neon,
    .note_fixed_fg = capsule,
    .voice_key_on_fg = neon,
    .voice_key_off_fg = ghost,
    .dump_reg_fg = neon,
    .dump_val_fg = bright,
    .seq_track_fg = capsule,
    .seq_event_fg = base,
    .order_ptr_fg = capsule,
};

pub const vu_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = deep.rgb },
    .{ .pos = 0.6, .rgb = signage.rgb },
    .{ .pos = 1.0, .rgb = sodium.rgb },
};

pub const peak_stops = [3]VuStop{
    .{ .pos = 0.0, .rgb = canvas.rgb },
    .{ .pos = 0.75, .rgb = capsule.rgb },
    .{ .pos = 1.0, .rgb = bright.rgb },
};

pub const theme = Theme.init(@This());
