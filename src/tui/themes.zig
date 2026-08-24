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
            .bg = 0x14161a,
            .surface = 0x1d2026,
            .surface_alt = 0x252932,
            .fg = 0xc5cad4,
            .fg_muted = 0x9aa3b3,
            .fg_dim = 0x6e7787,
            .accent = 0xbb9af7,
            .accent_alt = 0x7aa2f7,
            .success = 0x9ece6a,
            .warning = 0xe0af68,
            .danger = 0xf7768e,
            .selection_bg = 0xa9b1c6,
            .diff_added_bg = 0x1c2a1e,
            .diff_removed_bg = 0x2e1c22,
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
            .selection_bg = 0xc8d3f5,
            .diff_added_bg = 0x20303b,
            .diff_removed_bg = 0x37222c,
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
            .selection_bg = 0xcdd6f4,
            .diff_added_bg = 0x24312b,
            .diff_removed_bg = 0x3c2a32,
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
            .selection_bg = 0xebdbb2,
            .diff_added_bg = 0x32302f,
            .diff_removed_bg = 0x322929,
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
            .selection_bg = 0xeceff4,
            .diff_added_bg = 0x414a4c,
            .diff_removed_bg = 0x453b47,
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
            .selection_bg = 0xe0def4,
            .diff_added_bg = 0x1f2d3a,
            .diff_removed_bg = 0x3a1f2d,
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
            .selection_bg = 0xabb2bf,
            .diff_added_bg = 0x2c382b,
            .diff_removed_bg = 0x3a2d2f,
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
            .selection_bg = 0xd3c6aa,
            .diff_added_bg = 0x20303b,
            .diff_removed_bg = 0x37222c,
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
            .selection_bg = 0xf8f8f2,
            .diff_added_bg = 0x1a3a1a,
            .diff_removed_bg = 0x3a1a1a,
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
            .selection_bg = 0x24292f,
            .diff_added_bg = 0xdafbe1,
            .diff_removed_bg = 0xffebe9,
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
            .selection_bg = 0x657b83,
            .diff_added_bg = 0xeae7bf,
            .diff_removed_bg = 0xf8d7c6,
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
