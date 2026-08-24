//! Central color palette. Every cell the app paints gets an explicit `bg` so
//! the terminal's own background (and any wallpaper behind it) never shows
//! through.

const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
pub const Color = Cell.Color;

/// A packed `0xRRGGBB` as a vaxis color. Public so a test can compare what a
/// palette says against what was applied.
pub fn rgbOf(hex: u24) Color {
    return rgb(hex);
}

fn rgb(hex: u24) Color {
    return .{
        .rgb = .{
            @intCast((hex >> 16) & 0xff),
            @intCast((hex >> 8) & 0xff),
            @intCast(hex & 0xff),
        },
    };
}

/// The colors a theme sets, as packed `0xRRGGBB`. Separate from the `Color`
/// values below so a theme is plain data: `themes.zig` is a table of these.
pub const Palette = struct {
    /// App background. Painted edge to edge.
    bg: u24,
    /// Raised surface: message cards, the prompt box, tool output.
    surface: u24,
    /// Slightly brighter raised surface, for headers inside a card.
    surface_alt: u24,
    /// Primary text.
    fg: u24,
    /// Secondary text: labels, metadata.
    fg_muted: u24,
    /// Tertiary text: status bar, hints.
    fg_dim: u24,
    accent: u24,
    accent_alt: u24,
    success: u24,
    warning: u24,
    danger: u24,
    /// Selected text: the ink and the ground swap, the way a terminal's own
    /// selection reads.
    selection_bg: u24,
    /// Diff row backgrounds. Dark enough that the text on top stays legible,
    /// tinted enough to read as added or removed at a glance.
    diff_added_bg: u24,
    diff_removed_bg: u24,
};

/// The palette in use. These are `var` rather than `const` so a theme switch is
/// an assignment and every `theme.fg` in the app keeps working unchanged; the
/// UI thread is the only one that reads or writes them.
pub var bg = rgb(0x14161a);
pub var surface = rgb(0x1d2026);
pub var surface_alt = rgb(0x252932);

pub var fg = rgb(0xc5cad4);
pub var fg_muted = rgb(0x8b93a1);
pub var fg_dim = rgb(0x5b6472);

pub var accent = rgb(0xbb9af7);
pub var accent_alt = rgb(0x7aa2f7);
pub var success = rgb(0x9ece6a);
pub var warning = rgb(0xe0af68);
pub var danger = rgb(0xf7768e);

pub var selection_bg = rgb(0xa9b1c6);

pub var diff_added_bg = rgb(0x1c2a1e);
pub var diff_removed_bg = rgb(0x2e1c22);

/// Base style for the app background.
pub var base: Style = .{ .cell = .{ .fg = rgb(0xc5cad4), .bg = rgb(0x14161a) } };
/// Base style for raised surfaces.
pub var card: Style = .{ .cell = .{ .fg = rgb(0xc5cad4), .bg = rgb(0x1d2026) } };

/// Repaint the app in `palette`. Takes effect on the next draw, so a caller
/// that is not already drawing has to ask for a redraw.
pub fn apply(palette: Palette) void {
    bg = rgb(palette.bg);
    surface = rgb(palette.surface);
    surface_alt = rgb(palette.surface_alt);
    fg = rgb(palette.fg);
    fg_muted = rgb(palette.fg_muted);
    fg_dim = rgb(palette.fg_dim);
    accent = rgb(palette.accent);
    accent_alt = rgb(palette.accent_alt);
    success = rgb(palette.success);
    warning = rgb(palette.warning);
    danger = rgb(palette.danger);
    selection_bg = rgb(palette.selection_bg);
    diff_added_bg = rgb(palette.diff_added_bg);
    diff_removed_bg = rgb(palette.diff_removed_bg);

    base = .{ .cell = .{ .fg = fg, .bg = bg } };
    card = .{ .cell = .{ .fg = fg, .bg = surface } };
}

/// A style on the app background.
pub fn on_bg(color: Color) Style {
    return .{ .cell = .{ .fg = color, .bg = bg } };
}

/// A style on a raised surface.
pub fn on_card(color: Color) Style {
    return .{ .cell = .{ .fg = color, .bg = surface } };
}

/// A `vaxis.Cell.Style` plus chainable modifiers.
pub const Style = struct {
    /// The style vaxis actually consumes.
    cell: Cell.Style = .{},

    pub fn bold(self: Style) Style {
        var out = self;
        out.cell.bold = true;
        return out;
    }

    pub fn dim(self: Style) Style {
        var out = self;
        out.cell.dim = true;
        return out;
    }

    pub fn italic(self: Style) Style {
        var out = self;
        out.cell.italic = true;
        return out;
    }

    pub fn reverse(self: Style) Style {
        var out = self;
        out.cell.reverse = true;
        return out;
    }

    pub fn strikethrough(self: Style) Style {
        var out = self;
        out.cell.strikethrough = true;
        return out;
    }

    pub fn underline(self: Style, style: Cell.Style.Underline) Style {
        var out = self;
        out.cell.ul_style = style;
        return out;
    }

    /// Recolor the text, keeping every other attribute.
    pub fn withFg(self: Style, color: Color) Style {
        var out = self;
        out.cell.fg = color;
        return out;
    }

    /// Recolor the background, keeping every other attribute.
    pub fn withBg(self: Style, color: Color) Style {
        var out = self;
        out.cell.bg = color;
        return out;
    }

    pub fn eql(a: Style, b: Style) bool {
        return Cell.Style.eql(a.cell, b.cell);
    }
};
