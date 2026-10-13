//! The themes that ship with the app.
//!
//! Ported from opencode's theme assets, which express each color twice (dark
//! and light) behind a table of named definitions. That indirection is theirs
//! to maintain; here each theme is the resolved variant, as plain data, so
//! switching one is an assignment rather than a parse.

const std = @import("std");

const theme = @import("theme.zig");

pub const Theme = struct {
    /// Stable id: what the database stores.
    id: []const u8,
    /// What a person calls it.
    label: []const u8,
    palette: theme.Palette,
};

/// Used when nothing has been chosen.
pub const default_id: []const u8 = "synth";

pub const all: []const Theme = &.{
    .{
        .id = "synth",
        .label = "Synth",
        .palette = .{
            .bg = 0x1c1e25,
            .surface = 0x22242c,
            .surface_alt = 0x3a332e,
            .fg = 0xe7e5dd,
            .fg_muted = 0x8b8e99,
            .fg_dim = 0x5c5f6a,
            .accent = 0xe8a33d,
            .accent_alt = 0xe8a33d,
            .success = 0x5fc9a8,
            .warning = 0xe8a33d,
            .danger = 0xe2695b,
            .border = 0x34363f,
            .selection_bg = 0xe7e5dd,
            .diff_added_bg = 0x212829,
            .diff_removed_bg = 0x2b2326,
            .diff_added_fg = 0x6fa88c,
            .diff_removed_fg = 0xc77b72,
        },
    },
    .{
        .id = "tokyonight",
        .label = "Tokyo Night",
        .palette = .{
            .bg = 0x1a1b26,
            .surface = 0x1e2030,
            .surface_alt = 0x222436,
            .fg = 0xc8d3f5,
            .fg_muted = 0x9aa5ce,
            .fg_dim = 0x737aa2,
            .accent = 0x82aaff,
            .accent_alt = 0xc099ff,
            .success = 0xc3e88d,
            .warning = 0xff966c,
            .danger = 0xff757f,
            .border = 0x3b4261,
            .selection_bg = 0xc8d3f5,
            .diff_added_bg = 0x20303b,
            .diff_removed_bg = 0x37222c,
            .diff_added_fg = 0xc8d3f5,
            .diff_removed_fg = 0xc8d3f5,
        },
    },
    .{
        .id = "catppuccin",
        .label = "Catppuccin",
        .palette = .{
            .bg = 0x1e1e2e,
            .surface = 0x181825,
            .surface_alt = 0x11111b,
            .fg = 0xcdd6f4,
            .fg_muted = 0xa6adc8,
            .fg_dim = 0x6c7086,
            .accent = 0x89b4fa,
            .accent_alt = 0xcba6f7,
            .success = 0xa6e3a1,
            .warning = 0xf9e2af,
            .danger = 0xf38ba8,
            .border = 0x45475a,
            .selection_bg = 0xcdd6f4,
            .diff_added_bg = 0x24312b,
            .diff_removed_bg = 0x3c2a32,
            .diff_added_fg = 0xcdd6f4,
            .diff_removed_fg = 0xcdd6f4,
        },
    },
    .{
        .id = "gruvbox",
        .label = "Gruvbox",
        .palette = .{
            .bg = 0x282828,
            .surface = 0x3c3836,
            .surface_alt = 0x504945,
            .fg = 0xebdbb2,
            .fg_muted = 0xb4a692,
            .fg_dim = 0x85796f,
            .accent = 0x83a598,
            .accent_alt = 0xd3869b,
            .success = 0xb8bb26,
            .warning = 0xfe8019,
            .danger = 0xfb4934,
            .border = 0x504945,
            .selection_bg = 0xebdbb2,
            .diff_added_bg = 0x32302f,
            .diff_removed_bg = 0x322929,
            .diff_added_fg = 0xebdbb2,
            .diff_removed_fg = 0xebdbb2,
        },
    },
    .{
        .id = "nord",
        .label = "Nord",
        .palette = .{
            .bg = 0x2e3440,
            .surface = 0x3b4252,
            .surface_alt = 0x434c5e,
            .fg = 0xeceff4,
            .fg_muted = 0xb6bccb,
            .fg_dim = 0x7d889b,
            .accent = 0x88c0d0,
            .accent_alt = 0x81a1c1,
            .success = 0xa3be8c,
            .warning = 0xd08770,
            .danger = 0xbf616a,
            .border = 0x434c5e,
            .selection_bg = 0xeceff4,
            .diff_added_bg = 0x414a4c,
            .diff_removed_bg = 0x453b47,
            .diff_added_fg = 0xeceff4,
            .diff_removed_fg = 0xeceff4,
        },
    },
    .{
        .id = "rose-pine",
        .label = "Rosé Pine",
        .palette = .{
            .bg = 0x191724,
            .surface = 0x1f1d2e,
            .surface_alt = 0x26233a,
            .fg = 0xe0def4,
            .fg_muted = 0x988ba2,
            .fg_dim = 0x6e6a86,
            .accent = 0x9ccfd8,
            .accent_alt = 0xc4a7e7,
            .success = 0x31748f,
            .warning = 0xf6c177,
            .danger = 0xeb6f92,
            .border = 0x403d52,
            .selection_bg = 0xe0def4,
            .diff_added_bg = 0x1f2d3a,
            .diff_removed_bg = 0x3a1f2d,
            .diff_added_fg = 0xe0def4,
            .diff_removed_fg = 0xe0def4,
        },
    },
    .{
        .id = "one-dark",
        .label = "One Dark",
        .palette = .{
            .bg = 0x282c34,
            .surface = 0x21252b,
            .surface_alt = 0x353b45,
            .fg = 0xabb2bf,
            .fg_muted = 0x9aa3b3,
            .fg_dim = 0x737a85,
            .accent = 0x61afef,
            .accent_alt = 0xc678dd,
            .success = 0x98c379,
            .warning = 0xe5c07b,
            .danger = 0xe06c75,
            .border = 0x3e4451,
            .selection_bg = 0xabb2bf,
            .diff_added_bg = 0x2c382b,
            .diff_removed_bg = 0x3a2d2f,
            .diff_added_fg = 0xabb2bf,
            .diff_removed_fg = 0xabb2bf,
        },
    },
    .{
        .id = "everforest",
        .label = "Everforest",
        .palette = .{
            .bg = 0x2d353b,
            .surface = 0x333c43,
            .surface_alt = 0x343f44,
            .fg = 0xd3c6aa,
            .fg_muted = 0xa8b1a3,
            .fg_dim = 0x859289,
            .accent = 0xa7c080,
            .accent_alt = 0x7fbbb3,
            .success = 0xa7c080,
            .warning = 0xe69875,
            .danger = 0xe67e80,
            .border = 0x4f585e,
            .selection_bg = 0xd3c6aa,
            .diff_added_bg = 0x20303b,
            .diff_removed_bg = 0x37222c,
            .diff_added_fg = 0xd3c6aa,
            .diff_removed_fg = 0xd3c6aa,
        },
    },
    .{
        .id = "dracula",
        .label = "Dracula",
        .palette = .{
            .bg = 0x282a36,
            .surface = 0x21222c,
            .surface_alt = 0x44475a,
            .fg = 0xf8f8f2,
            .fg_muted = 0xa1a8c8,
            .fg_dim = 0x8a91b3,
            .accent = 0xbd93f9,
            .accent_alt = 0xff79c6,
            .success = 0x50fa7b,
            .warning = 0xf1fa8c,
            .danger = 0xff5555,
            .border = 0x44475a,
            .selection_bg = 0xf8f8f2,
            .diff_added_bg = 0x1a3a1a,
            .diff_removed_bg = 0x3a1a1a,
            .diff_added_fg = 0xf8f8f2,
            .diff_removed_fg = 0xf8f8f2,
        },
    },
    .{
        .id = "github-light",
        .label = "GitHub Light",
        .palette = .{
            .bg = 0xffffff,
            .surface = 0xf6f8fa,
            .surface_alt = 0xf0f3f6,
            .fg = 0x24292f,
            .fg_muted = 0x424b53,
            .fg_dim = 0x6e7787,
            .accent = 0x0969da,
            .accent_alt = 0x8250df,
            .success = 0x1a7f37,
            .warning = 0x9a6700,
            .danger = 0xcf222e,
            .border = 0xd0d7de,
            .selection_bg = 0x24292f,
            .diff_added_bg = 0xdafbe1,
            .diff_removed_bg = 0xffebe9,
            .diff_added_fg = 0x24292f,
            .diff_removed_fg = 0x24292f,
        },
    },
    .{
        .id = "solarized-light",
        .label = "Solarized Light",
        .palette = .{
            .bg = 0xfdf6e3,
            .surface = 0xeee8d5,
            .surface_alt = 0xeee8d5,
            .fg = 0x586e75,
            .fg_muted = 0x788a91,
            .fg_dim = 0xa6ada0,
            .accent = 0x268bd2,
            .accent_alt = 0x6c71c4,
            .success = 0x859900,
            .warning = 0xb58900,
            .danger = 0xdc322f,
            .border = 0xd8d0bd,
            .selection_bg = 0x657b83,
            .diff_added_bg = 0xeae7bf,
            .diff_removed_bg = 0xf8d7c6,
            .diff_added_fg = 0x586e75,
            .diff_removed_fg = 0x586e75,
        },
    },
};

/// The theme with this id, or null.
pub fn find(id: []const u8) ?Theme {
    for (all) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// The theme with this id, or the default. An id from a newer build should
/// leave the app looking like something rather than refusing to draw.
pub fn findOrDefault(id: []const u8) Theme {
    return find(id) orelse find(default_id).?;
}

/// Paint the app in the theme with this id, and say which one that was.
pub fn apply(id: []const u8) Theme {
    const chosen = findOrDefault(id);
    theme.apply(chosen.palette);
    return chosen;
}

test "every theme is findable, and an unknown id falls back" {
    const testing = std.testing;

    for (all) |entry| {
        try testing.expect(entry.id.len > 0);
        try testing.expect(entry.label.len > 0);
        try testing.expectEqualStrings(entry.id, find(entry.id).?.id);
    }

    try testing.expect(find("no-such-theme") == null);
    try testing.expectEqualStrings(default_id, findOrDefault("no-such-theme").id);
    try testing.expectEqualStrings(default_id, findOrDefault("").id);
}

test "applying a theme repaints the palette" {
    const testing = std.testing;
    defer _ = apply(default_id);

    const gruvbox = apply("gruvbox");
    try testing.expectEqualStrings("gruvbox", gruvbox.id);
    try testing.expectEqual(theme.rgbOf(gruvbox.palette.bg), theme.bg);
    try testing.expectEqual(theme.rgbOf(gruvbox.palette.fg), theme.fg);

    const restored = apply("no-such-theme");
    try testing.expectEqualStrings(default_id, restored.id);
    try testing.expectEqual(theme.rgbOf(restored.palette.bg), theme.bg);
}

test "every theme reaches the palette whole" {
    const testing = std.testing;
    defer _ = apply(default_id);

    for (all) |entry| {
        const applied = apply(entry.id);
        const palette = applied.palette;

        try testing.expectEqual(theme.rgbOf(palette.bg), theme.bg);
        try testing.expectEqual(theme.rgbOf(palette.surface), theme.surface);
        try testing.expectEqual(theme.rgbOf(palette.surface_alt), theme.surface_alt);
        try testing.expectEqual(theme.rgbOf(palette.fg), theme.fg);
        try testing.expectEqual(theme.rgbOf(palette.fg_muted), theme.fg_muted);
        try testing.expectEqual(theme.rgbOf(palette.fg_dim), theme.fg_dim);
        try testing.expectEqual(theme.rgbOf(palette.accent), theme.accent);
        try testing.expectEqual(theme.rgbOf(palette.accent_alt), theme.accent_alt);
        try testing.expectEqual(theme.rgbOf(palette.success), theme.success);
        try testing.expectEqual(theme.rgbOf(palette.warning), theme.warning);
        try testing.expectEqual(theme.rgbOf(palette.danger), theme.danger);
        try testing.expectEqual(theme.rgbOf(palette.border), theme.border);
        try testing.expectEqual(theme.rgbOf(palette.selection_bg), theme.selection_bg);
        try testing.expectEqual(theme.rgbOf(palette.diff_added_bg), theme.diff_added_bg);
        try testing.expectEqual(theme.rgbOf(palette.diff_removed_bg), theme.diff_removed_bg);
        try testing.expectEqual(theme.rgbOf(palette.diff_added_fg), theme.diff_added_fg);
        try testing.expectEqual(theme.rgbOf(palette.diff_removed_fg), theme.diff_removed_fg);
    }
}

test "a theme that colours its diff text says so on both sides" {
    const testing = std.testing;

    const synth = find("synth").?.palette;
    try testing.expect(synth.diff_added_fg != synth.diff_removed_fg);
    try testing.expect(synth.diff_added_fg != synth.fg);

    // The rest keep the look they had, which was the transcript's own colour.
    for (all) |entry| {
        if (std.mem.startsWith(u8, entry.id, "synth")) continue;
        try testing.expectEqual(entry.palette.fg, entry.palette.diff_added_fg);
        try testing.expectEqual(entry.palette.fg, entry.palette.diff_removed_fg);
    }
}

test "the synth palette is the design's own, variable for variable" {
    const synth = find("synth").?.palette;

    // --bg-panel: the window. --bg is the page behind it, which a terminal has not got.
    try std.testing.expectEqual(@as(u24, 0x1c1e25), synth.bg);
    // --bg-raised: what is lifted off it, dialogs and boxed tool output.
    try std.testing.expectEqual(@as(u24, 0x22242c), synth.surface);
    // --sel over that: the row under the cursor, warm rather than lighter.
    try std.testing.expectEqual(@as(u24, 0x3a332e), synth.surface_alt);
    try std.testing.expectEqual(@as(u24, 0x34363f), synth.border);

    try std.testing.expectEqual(@as(u24, 0xe7e5dd), synth.fg);
    try std.testing.expectEqual(@as(u24, 0x8b8e99), synth.fg_muted);
    try std.testing.expectEqual(@as(u24, 0x5c5f6a), synth.fg_dim);

    // One accent, amber, reserved for what is in progress.
    try std.testing.expectEqual(@as(u24, 0xe8a33d), synth.accent);
    try std.testing.expectEqual(@as(u24, 0x5fc9a8), synth.success);
    try std.testing.expectEqual(@as(u24, 0xe2695b), synth.danger);
    try std.testing.expectEqual(@as(u24, 0x6fa88c), synth.diff_added_fg);
    try std.testing.expectEqual(@as(u24, 0xc77b72), synth.diff_removed_fg);
}
