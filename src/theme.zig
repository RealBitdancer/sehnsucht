//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");
const vaxis = @import("vaxis");

pub const VuStop = struct {
    pos: f32,
    rgb: [3]u8,
};

pub const TextAttributes = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    underline: vaxis.Style.Underline = .off,
    underline_color: vaxis.Color = .default,

    pub fn apply(self: TextAttributes, fg: vaxis.Color, bg: vaxis.Color) vaxis.Style {
        return .{
            .fg = fg,
            .bg = bg,
            .ul = self.underline_color,
            .ul_style = self.underline,
            .bold = self.bold,
            .dim = self.dim,
            .italic = self.italic,
            .blink = self.blink,
            .reverse = self.reverse,
            .invisible = self.invisible,
            .strikethrough = self.strikethrough,
        };
    }
};

pub const Typography = struct {
    body: TextAttributes,
    decoration: TextAttributes,
    emphasis: TextAttributes,
    selected: TextAttributes,
    menu_hotkey: TextAttributes,
    menu_hotkey_selected: TextAttributes,
    menu_hotkey_disabled: TextAttributes,
    meter: TextAttributes,
    meter_peak: TextAttributes,
};

pub const TextAttributeOverrides = struct {
    bold: ?bool = null,
    dim: ?bool = null,
    italic: ?bool = null,
    blink: ?bool = null,
    reverse: ?bool = null,
    invisible: ?bool = null,
    strikethrough: ?bool = null,
    underline: ?vaxis.Style.Underline = null,
    underline_color: ?vaxis.Color = null,

    fn merge(self: TextAttributeOverrides, base: TextAttributes) TextAttributes {
        var out = base;
        if (self.bold) |value| out.bold = value;
        if (self.dim) |value| out.dim = value;
        if (self.italic) |value| out.italic = value;
        if (self.blink) |value| out.blink = value;
        if (self.reverse) |value| out.reverse = value;
        if (self.invisible) |value| out.invisible = value;
        if (self.strikethrough) |value| out.strikethrough = value;
        if (self.underline) |value| out.underline = value;
        if (self.underline_color) |value| out.underline_color = value;
        return out;
    }
};

pub const ColorOverride = struct {
    field: []const u8,
    value: vaxis.Color,
};

pub const TypographyOverride = struct {
    field: []const u8,
    attributes: TextAttributeOverrides,
};

pub const ThemeOverrides = struct {
    colors: []const ColorOverride = &.{},
    typography: []const TypographyOverride = &.{},
    vu_stops: ?[3]VuStop = null,
    peak_stops: ?[3]VuStop = null,
};

pub const Colors = struct {
    bg: vaxis.Color,
    shell_fill_fg: vaxis.Color,
    resize_notice_fg: vaxis.Color,
    header_frame_fg: vaxis.Color,
    viz_frame_fg: vaxis.Color,
    status_frame_fg: vaxis.Color,

    brand_fg: vaxis.Color,
    state_loading_fg: vaxis.Color,
    state_playing_fg: vaxis.Color,
    state_paused_fg: vaxis.Color,
    state_stopped_fg: vaxis.Color,
    playlist_pos_fg: vaxis.Color,
    title_fg: vaxis.Color,
    title_time_fg: vaxis.Color,
    format_tag_fg: vaxis.Color,
    artist_fg: vaxis.Color,
    volume_label_fg: vaxis.Color,
    volume_value_fg: vaxis.Color,
    volume_gauge_on_fg: vaxis.Color,
    volume_gauge_off_fg: vaxis.Color,
    mode_light_on_fg: vaxis.Color,
    mode_light_off_fg: vaxis.Color,

    menu_enabled_fg: vaxis.Color,
    menu_disabled_fg: vaxis.Color,
    menu_hotkey_fg: vaxis.Color,
    menu_focus_fg: vaxis.Color,
    menu_focus_bg: vaxis.Color,
    menu_open_fg: vaxis.Color,
    menu_open_bg: vaxis.Color,

    transport_icon_fg: vaxis.Color,
    status_time_fg: vaxis.Color,
    loop_count_fg: vaxis.Color,
    progress_on_fg: vaxis.Color,
    progress_off_fg: vaxis.Color,
    notice_mark_fg: vaxis.Color,
    notice_text_fg: vaxis.Color,

    key_sep_fg: vaxis.Color,
    key_fg: vaxis.Color,
    key_disabled_fg: vaxis.Color,
    key_label_fg: vaxis.Color,
    key_label_disabled_fg: vaxis.Color,

    list_header_fg: vaxis.Color,
    list_row_fg: vaxis.Color,
    list_cursor_fg: vaxis.Color,
    list_cursor_bg: vaxis.Color,
    list_rule_fg: vaxis.Color,
    scroll_track_bg: vaxis.Color,
    scroll_thumb_bg: vaxis.Color,

    browse_path_fg: vaxis.Color,
    browse_error_fg: vaxis.Color,
    browse_empty_fg: vaxis.Color,
    browse_dir_fg: vaxis.Color,

    playlist_empty_fg: vaxis.Color,
    playlist_title_fg: vaxis.Color,
    playlist_playing_fg: vaxis.Color,
    playlist_playing_bg: vaxis.Color,
    playlist_played_fg: vaxis.Color,
    playlist_dead_fg: vaxis.Color,
    playlist_dead_mark_fg: vaxis.Color,

    viz_notice_fg: vaxis.Color,
    inst_title_fg: vaxis.Color,
    inst_label_fg: vaxis.Color,
    inst_flag_on_fg: vaxis.Color,
    inst_flag_off_fg: vaxis.Color,
    inst_value_fg: vaxis.Color,
    gauge_on_fg: vaxis.Color,
    gauge_off_fg: vaxis.Color,
    order_title_fg: vaxis.Color,
    order_row_fg: vaxis.Color,
    order_skip_fg: vaxis.Color,
    order_cur_fg: vaxis.Color,
    order_cur_bg: vaxis.Color,
    pat_bar_bg: vaxis.Color,
    pat_bar_fg: vaxis.Color,
    pat_head_fg: vaxis.Color,
    pat_gutter_fg: vaxis.Color,
    note_fg: vaxis.Color,
    note_empty_fg: vaxis.Color,
    inst_cell_fg: vaxis.Color,
    fx_fg: vaxis.Color,
    pat_sep_fg: vaxis.Color,
    pat_cur_fg: vaxis.Color,
    pat_cur_bg: vaxis.Color,

    spectrum_frame_fg: vaxis.Color,
    spectrum_title_fg: vaxis.Color,
    spec_digit_on_fg: vaxis.Color,
    spec_digit_off_fg: vaxis.Color,
    analyzer_base_fg: vaxis.Color,
    freq_label_fg: vaxis.Color,

    info_bar_bg: vaxis.Color,
    info_dim_fg: vaxis.Color,
    info_label_fg: vaxis.Color,
    info_value_fg: vaxis.Color,
    loop_badge_on_fg: vaxis.Color,
    loop_badge_off_fg: vaxis.Color,
    rate_value_fg: vaxis.Color,
    peak_label_fg: vaxis.Color,
    meter_off_fg: vaxis.Color,
    master_label_fg: vaxis.Color,
    vu_empty_fg: vaxis.Color,
};

pub const Theme = struct {
    display_name: []const u8,
    description: []const u8,
    colors: *const Colors,
    typography: *const Typography,
    vu_stops: *const [3]VuStop,
    peak_stops: *const [3]VuStop,

    pub fn color(comptime field: []const u8, value: vaxis.Color) ColorOverride {
        if (!@hasField(Colors, field)) @compileError("unknown theme color role: " ++ field);
        return .{ .field = field, .value = value };
    }

    pub fn text(
        comptime field: []const u8,
        attributes: TextAttributeOverrides,
    ) TypographyOverride {
        if (!@hasField(Typography, field)) @compileError("unknown theme typography role: " ++ field);
        return .{ .field = field, .attributes = attributes };
    }

    pub fn derive(
        comptime base: Theme,
        comptime display_name: []const u8,
        comptime description: []const u8,
        comptime overrides: ThemeOverrides,
    ) Theme {
        const Storage = struct {
            const colors = blk: {
                var out = base.colors.*;
                for (overrides.colors) |item| {
                    @field(out, item.field) = item.value;
                }
                break :blk out;
            };

            const typography = blk: {
                var out = base.typography.*;
                for (overrides.typography) |item| {
                    @field(out, item.field) = item.attributes.merge(@field(out, item.field));
                }
                break :blk out;
            };

            const vu_stops = overrides.vu_stops orelse base.vu_stops.*;
            const peak_stops = overrides.peak_stops orelse base.peak_stops.*;
        };

        return .{
            .display_name = display_name,
            .description = description,
            .colors = &Storage.colors,
            .typography = &Storage.typography,
            .vu_stops = &Storage.vu_stops,
            .peak_stops = &Storage.peak_stops,
        };
    }

    pub fn init(comptime T: type) Theme {
        comptime {
            if (!@hasDecl(T, "display_name")) @compileError(@typeName(T) ++ " must provide display_name");
            if (!@hasDecl(T, "description")) @compileError(@typeName(T) ++ " must provide description");
            if (!@hasDecl(T, "colors")) @compileError(@typeName(T) ++ " must provide colors");
            if (!@hasDecl(T, "typography")) @compileError(@typeName(T) ++ " must provide typography");
            if (!@hasDecl(T, "vu_stops")) @compileError(@typeName(T) ++ " must provide vu_stops");
            if (!@hasDecl(T, "peak_stops")) @compileError(@typeName(T) ++ " must provide peak_stops");
        }
        return .{
            .display_name = T.display_name,
            .description = T.description,
            .colors = &T.colors,
            .typography = &T.typography,
            .vu_stops = &T.vu_stops,
            .peak_stops = &T.peak_stops,
        };
    }

    /// Every fixed style role the UI and visualizers draw with. One role is
    /// one (typography, foreground, background) triple in `style`.
    pub const Role = enum {
        shell_fill,
        resize_notice,
        header_frame,
        viz_frame,
        status_frame,
        brand,
        state_loading,
        state_playing,
        state_paused,
        state_stopped,
        playlist_pos,
        title_text,
        title_time,
        format_tag,
        artist_line,
        volume_label,
        volume_value,
        mode_light_on,
        mode_light_off,
        menu_enabled,
        menu_disabled,
        menu_focus,
        menu_open,
        menu_hotkey,
        menu_hotkey_focus,
        menu_hotkey_open,
        menu_hotkey_disabled,
        transport_icon,
        status_time,
        loop_count,
        notice_mark,
        notice_text,
        key_sep,
        key_key,
        key_key_disabled,
        key_label,
        key_label_disabled,
        list_header,
        list_rule,
        browse_path,
        browse_error,
        browse_empty,
        playlist_empty,
        playlist_title,
        viz_notice,
        inst_title,
        inst_label,
        inst_flag_on,
        inst_flag_off,
        inst_value,
        gauge_on,
        gauge_off,
        order_title,
        order_row,
        order_skip,
        order_cur,
        pat_bar,
        pat_head,
        pat_gutter,
        note,
        note_empty,
        inst_cell,
        fx_cell,
        pat_separator,
        pat_cursor_fill,
        spectrum_frame,
        spectrum_title,
        spec_digit_on,
        spec_digit_off,
        analyzer_base,
        freq_label,
        info_dim,
        info_label,
        info_value,
        loop_badge_on,
        loop_badge_off,
        rate_value,
        peak_label,
        master_label,
        meter_empty,
    };

    pub fn style(self: Theme, comptime role: Role) vaxis.Style {
        const c = self.colors;
        const t = self.typography;
        return switch (role) {
            .shell_fill => t.decoration.apply(c.shell_fill_fg, c.bg),
            .resize_notice => t.body.apply(c.resize_notice_fg, c.bg),
            .header_frame => t.decoration.apply(c.header_frame_fg, c.bg),
            .viz_frame => t.decoration.apply(c.viz_frame_fg, c.bg),
            .status_frame => t.decoration.apply(c.status_frame_fg, c.bg),
            .brand => t.emphasis.apply(c.brand_fg, c.bg),
            .state_loading => t.emphasis.apply(c.state_loading_fg, c.bg),
            .state_playing => t.emphasis.apply(c.state_playing_fg, c.bg),
            .state_paused => t.emphasis.apply(c.state_paused_fg, c.bg),
            .state_stopped => t.emphasis.apply(c.state_stopped_fg, c.bg),
            .playlist_pos => t.body.apply(c.playlist_pos_fg, c.bg),
            .title_text => t.emphasis.apply(c.title_fg, c.bg),
            .title_time => t.body.apply(c.title_time_fg, c.bg),
            .format_tag => t.body.apply(c.format_tag_fg, c.bg),
            .artist_line => t.body.apply(c.artist_fg, c.bg),
            .volume_label => t.body.apply(c.volume_label_fg, c.bg),
            .volume_value => t.emphasis.apply(c.volume_value_fg, c.bg),
            .mode_light_on => t.emphasis.apply(c.mode_light_on_fg, c.bg),
            .mode_light_off => t.body.apply(c.mode_light_off_fg, c.bg),
            .menu_enabled => t.body.apply(c.menu_enabled_fg, c.bg),
            .menu_disabled => t.body.apply(c.menu_disabled_fg, c.bg),
            .menu_focus => t.selected.apply(c.menu_focus_fg, c.menu_focus_bg),
            .menu_open => t.selected.apply(c.menu_open_fg, c.menu_open_bg),
            .menu_hotkey => t.menu_hotkey.apply(c.menu_hotkey_fg, c.bg),
            .menu_hotkey_focus => t.menu_hotkey_selected.apply(c.menu_focus_fg, c.menu_focus_bg),
            .menu_hotkey_open => t.menu_hotkey_selected.apply(c.menu_hotkey_fg, c.menu_open_bg),
            .menu_hotkey_disabled => t.menu_hotkey_disabled.apply(c.menu_disabled_fg, c.bg),
            .transport_icon => t.body.apply(c.transport_icon_fg, c.bg),
            .status_time => t.emphasis.apply(c.status_time_fg, c.bg),
            .loop_count => t.body.apply(c.loop_count_fg, c.bg),
            .notice_mark => t.body.apply(c.notice_mark_fg, c.bg),
            .notice_text => t.body.apply(c.notice_text_fg, c.bg),
            .key_sep => t.body.apply(c.key_sep_fg, c.bg),
            .key_key => t.emphasis.apply(c.key_fg, c.bg),
            .key_key_disabled => t.body.apply(c.key_disabled_fg, c.bg),
            .key_label => t.body.apply(c.key_label_fg, c.bg),
            .key_label_disabled => t.body.apply(c.key_label_disabled_fg, c.bg),
            .list_header => t.emphasis.apply(c.list_header_fg, c.bg),
            .list_rule => t.decoration.apply(c.list_rule_fg, c.bg),
            .browse_path => t.body.apply(c.browse_path_fg, c.bg),
            .browse_error => t.body.apply(c.browse_error_fg, c.bg),
            .browse_empty => t.body.apply(c.browse_empty_fg, c.bg),
            .playlist_empty => t.body.apply(c.playlist_empty_fg, c.bg),
            .playlist_title => t.body.apply(c.playlist_title_fg, c.bg),
            .viz_notice => t.body.apply(c.viz_notice_fg, c.bg),
            .inst_title => t.body.apply(c.inst_title_fg, c.bg),
            .inst_label => t.body.apply(c.inst_label_fg, c.bg),
            .inst_flag_on => t.body.apply(c.inst_flag_on_fg, c.bg),
            .inst_flag_off => t.body.apply(c.inst_flag_off_fg, c.bg),
            .inst_value => t.body.apply(c.inst_value_fg, c.bg),
            .gauge_on => t.decoration.apply(c.gauge_on_fg, c.bg),
            .gauge_off => t.decoration.apply(c.gauge_off_fg, c.bg),
            .order_title => t.body.apply(c.order_title_fg, c.bg),
            .order_row => t.body.apply(c.order_row_fg, c.bg),
            .order_skip => t.body.apply(c.order_skip_fg, c.bg),
            .order_cur => t.selected.apply(c.order_cur_fg, c.order_cur_bg),
            .pat_bar => t.body.apply(c.pat_bar_fg, c.pat_bar_bg),
            .pat_head => t.body.apply(c.pat_head_fg, c.bg),
            .pat_gutter => t.body.apply(c.pat_gutter_fg, c.bg),
            .note => t.body.apply(c.note_fg, c.bg),
            .note_empty => t.body.apply(c.note_empty_fg, c.bg),
            .inst_cell => t.body.apply(c.inst_cell_fg, c.bg),
            .fx_cell => t.body.apply(c.fx_fg, c.bg),
            .pat_separator => t.decoration.apply(c.pat_sep_fg, c.bg),
            .pat_cursor_fill => t.selected.apply(c.pat_cur_fg, c.pat_cur_bg),
            .spectrum_frame => t.decoration.apply(c.spectrum_frame_fg, c.bg),
            .spectrum_title => t.body.apply(c.spectrum_title_fg, c.bg),
            .spec_digit_on => t.body.apply(c.spec_digit_on_fg, c.bg),
            .spec_digit_off => t.body.apply(c.spec_digit_off_fg, c.bg),
            .analyzer_base => t.decoration.apply(c.analyzer_base_fg, c.bg),
            .freq_label => t.body.apply(c.freq_label_fg, c.bg),
            .info_dim => t.body.apply(c.info_dim_fg, c.info_bar_bg),
            .info_label => t.body.apply(c.info_label_fg, c.info_bar_bg),
            .info_value => t.body.apply(c.info_value_fg, c.info_bar_bg),
            .loop_badge_on => t.emphasis.apply(c.loop_badge_on_fg, c.info_bar_bg),
            .loop_badge_off => t.body.apply(c.loop_badge_off_fg, c.info_bar_bg),
            .rate_value => t.emphasis.apply(c.rate_value_fg, c.info_bar_bg),
            .peak_label => t.body.apply(c.peak_label_fg, c.info_bar_bg),
            .master_label => t.body.apply(c.master_label_fg, c.bg),
            .meter_empty => t.meter.apply(c.vu_empty_fg, c.bg),
        };
    }

    pub fn listEntry(self: Theme, fg: vaxis.Color, background: vaxis.Color, selected: bool) vaxis.Style {
        const attributes = if (selected) self.typography.selected else self.typography.body;
        return attributes.apply(fg, background);
    }

    pub fn patSeparator(self: Theme, is_cur: bool) vaxis.Style {
        if (is_cur) return self.style(.pat_cursor_fill);
        return self.style(.pat_separator);
    }

    pub fn rowStyle(self: Theme, is_cur: bool, normal: vaxis.Style) vaxis.Style {
        if (!is_cur) return normal;
        return self.style(.pat_cursor_fill);
    }

    pub fn infoMeter(self: Theme, frac: f32, lit: bool) vaxis.Style {
        const fg = if (lit) gradientColor(self.vu_stops, frac) else self.colors.meter_off_fg;
        return self.typography.meter.apply(fg, self.colors.info_bar_bg);
    }

    pub fn meterBar(self: Theme, frac: f32, peak: bool) vaxis.Style {
        const attributes = if (peak) self.typography.meter_peak else self.typography.meter;
        return attributes.apply(gradientColor(self.vu_stops, frac), self.colors.bg);
    }

    pub fn barPeak(self: Theme, glow: f32) vaxis.Style {
        return self.typography.meter_peak.apply(gradientColor(self.peak_stops, glow), self.colors.bg);
    }
};

fn gradientColor(stops: []const VuStop, frac: f32) vaxis.Color {
    const f = std.math.clamp(frac, 0.0, 1.0);
    var k: usize = 0;
    while (k + 2 < stops.len and f > stops[k + 1].pos) : (k += 1) {}
    const a = stops[k];
    const b = stops[k + 1];
    const span = b.pos - a.pos;
    const t = if (span > 0) (f - a.pos) / span else 1.0;
    var out: [3]u8 = undefined;
    for (&out, a.rgb, b.rgb) |*o, av, bv| {
        const af: f32 = @floatFromInt(av);
        const bf: f32 = @floatFromInt(bv);
        o.* = @intFromFloat(@round(af + (bf - af) * t));
    }
    return .{ .rgb = out };
}

pub const themes = @import("registry.zig").themes;
pub const default_theme = themes[0];

// --- tests -------------------------------------------------------------------

test "TextAttributes maps every terminal text attribute" {
    const underline_color: vaxis.Color = .{ .rgb = .{ 1, 2, 3 } };
    const style = (TextAttributes{
        .bold = true,
        .dim = true,
        .italic = true,
        .blink = true,
        .reverse = true,
        .invisible = true,
        .strikethrough = true,
        .underline = .curly,
        .underline_color = underline_color,
    }).apply(.default, .default);

    try std.testing.expect(style.bold);
    try std.testing.expect(style.dim);
    try std.testing.expect(style.italic);
    try std.testing.expect(style.blink);
    try std.testing.expect(style.reverse);
    try std.testing.expect(style.invisible);
    try std.testing.expect(style.strikethrough);
    try std.testing.expectEqual(vaxis.Style.Underline.curly, style.ul_style);
    try std.testing.expect(std.meta.eql(underline_color, style.ul));
}
