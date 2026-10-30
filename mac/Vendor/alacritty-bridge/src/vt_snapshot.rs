use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::Term;
use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};

/// Per-cell attributes handed to the renderer. A subset of
/// `alacritty_terminal`'s `Flags` plus Zshell's own `SELECTED`.
pub const ZSHELL_CELL_INVERSE: u16 = 1 << 0;
pub const ZSHELL_CELL_BOLD: u16 = 1 << 1;
pub const ZSHELL_CELL_ITALIC: u16 = 1 << 2;
pub const ZSHELL_CELL_UNDERLINE: u16 = 1 << 3;
pub const ZSHELL_CELL_STRIKEOUT: u16 = 1 << 4;
pub const ZSHELL_CELL_DIM: u16 = 1 << 5;
pub const ZSHELL_CELL_HIDDEN: u16 = 1 << 6;
pub const ZSHELL_CELL_WIDE: u16 = 1 << 7;
pub const ZSHELL_CELL_WIDE_SPACER: u16 = 1 << 8;
pub const ZSHELL_CELL_SELECTED: u16 = 1 << 9;
pub const ZSHELL_CELL_WRAPPED: u16 = 1 << 10;

/// A theme in the form the bridge resolves colors against. Zshell owns the
/// palette so Alacritty panes match Ghostty panes exactly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZshellTheme {
    pub palette: [u32; 256],
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
}

pub(crate) struct TermSize {
    pub(crate) columns: usize,
    pub(crate) screen_lines: usize,
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

pub(crate) fn pack(rgb: Rgb) -> u32 {
    ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32
}

pub(crate) fn unpack(value: u32) -> Rgb {
    Rgb {
        r: (value >> 16) as u8,
        g: (value >> 8) as u8,
        b: value as u8,
    }
}

/// Two thirds brightness, matching how terminals conventionally render SGR 2.
pub(crate) fn dim(value: u32) -> u32 {
    let scale = |channel: u32| (channel * 2 / 3) & 0xff;
    (scale((value >> 16) & 0xff) << 16) | (scale((value >> 8) & 0xff) << 8) | scale(value & 0xff)
}

/// Resolves a `Colors` index — which is `NamedColor as usize` — to the theme.
pub(crate) fn color_for_index(index: usize, theme: &ZshellTheme) -> u32 {
    match index {
        0..=255 => theme.palette[index],
        i if i == NamedColor::Foreground as usize => theme.foreground,
        i if i == NamedColor::Background as usize => theme.background,
        i if i == NamedColor::Cursor as usize => theme.cursor,
        i if i == NamedColor::BrightForeground as usize => theme.foreground,
        i if i == NamedColor::DimForeground as usize => dim(theme.foreground),
        i if i >= NamedColor::DimBlack as usize && i <= NamedColor::DimWhite as usize => {
            dim(theme.palette[i - NamedColor::DimBlack as usize])
        }
        _ => theme.foreground,
    }
}

/// OSC 4 / OSC 10-11 overrides win over the theme, exactly as they do in
/// Zshell's Ghostty panes.
pub(crate) fn resolve(color: Color, colors: &Colors, theme: &ZshellTheme) -> u32 {
    match color {
        Color::Spec(rgb) => pack(rgb),
        Color::Indexed(index) => colors[index as usize]
            .map(pack)
            .unwrap_or_else(|| theme.palette[index as usize]),
        Color::Named(named) => {
            let index = named as usize;
            colors[index]
                .map(pack)
                .unwrap_or_else(|| color_for_index(index, theme))
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct VtStyle {
    pub(crate) foreground: u32,
    pub(crate) background: u32,
    pub(crate) flags: u16,
    pub(crate) hyperlink: Option<String>,
}

pub(crate) fn style_for(cell: &Cell, colors: &Colors, theme: &ZshellTheme) -> VtStyle {
    let mut flags = 0;
    for (source, target) in [
        (Flags::BOLD, ZSHELL_CELL_BOLD),
        (Flags::ITALIC, ZSHELL_CELL_ITALIC),
        (Flags::STRIKEOUT, ZSHELL_CELL_STRIKEOUT),
        (Flags::DIM, ZSHELL_CELL_DIM),
        (Flags::HIDDEN, ZSHELL_CELL_HIDDEN),
        (Flags::INVERSE, ZSHELL_CELL_INVERSE),
    ] {
        if cell.flags.contains(source) {
            flags |= target;
        }
    }
    if cell.flags.intersects(Flags::ALL_UNDERLINES) {
        flags |= ZSHELL_CELL_UNDERLINE;
    }
    VtStyle {
        foreground: resolve(cell.fg, colors, theme),
        background: resolve(cell.bg, colors, theme),
        flags,
        hyperlink: cell.hyperlink().map(|link| link.uri().to_owned()),
    }
}

pub(crate) fn push_sgr(output: &mut Vec<u8>, style: &VtStyle) {
    let foreground = unpack(style.foreground);
    let background = unpack(style.background);
    let mut codes = vec![
        "0".to_owned(),
        format!("38;2;{};{};{}", foreground.r, foreground.g, foreground.b),
        format!("48;2;{};{};{}", background.r, background.g, background.b),
    ];
    for (flag, code) in [
        (ZSHELL_CELL_BOLD, "1"),
        (ZSHELL_CELL_DIM, "2"),
        (ZSHELL_CELL_ITALIC, "3"),
        (ZSHELL_CELL_UNDERLINE, "4"),
        (ZSHELL_CELL_INVERSE, "7"),
        (ZSHELL_CELL_HIDDEN, "8"),
        (ZSHELL_CELL_STRIKEOUT, "9"),
    ] {
        if style.flags & flag != 0 {
            codes.push(code.to_owned());
        }
    }
    output.extend_from_slice(b"\x1b[");
    output.extend_from_slice(codes.join(";").as_bytes());
    output.push(b'm');
}

pub(crate) fn push_hyperlink(output: &mut Vec<u8>, uri: Option<&str>) {
    output.extend_from_slice(b"\x1b]8;;");
    if let Some(uri) = uri {
        output.extend_from_slice(uri.as_bytes());
    }
    output.extend_from_slice(b"\x1b\\");
}

pub(crate) fn cell_has_visible_content(cell: &Cell) -> bool {
    cell.c != ' '
        || cell.zerowidth().is_some_and(|marks| !marks.is_empty())
        || cell.fg != Color::Named(NamedColor::Foreground)
        || cell.bg != Color::Named(NamedColor::Background)
        || cell.flags.intersects(
            Flags::BOLD
                | Flags::ITALIC
                | Flags::ALL_UNDERLINES
                | Flags::STRIKEOUT
                | Flags::DIM
                | Flags::HIDDEN
                | Flags::INVERSE,
        )
        || cell.hyperlink().is_some()
}

/// Serializes screen contents with enough VT state to replay their appearance
/// into either backend. Soft-wrapped rows stay joined so the new terminal can
/// reflow them at its current width.
pub(crate) fn serialize_vt<T: EventListener>(
    term: &Term<T>,
    theme: &ZshellTheme,
    scrollback_only: bool,
) -> Vec<u8> {
    let first_line = term.topmost_line();
    let last_line = if scrollback_only {
        Line(-1)
    } else {
        term.bottommost_line()
    };
    if last_line < first_line {
        return Vec::new();
    }

    let colors = term.colors();
    let columns = term.columns();
    let mut output = Vec::new();
    let mut active_style: Option<VtStyle> = None;
    let mut active_link: Option<String> = None;

    for line in (first_line.0..=last_line.0).map(Line::from) {
        let row = &term.grid()[line];
        let wrapped = row[Column(columns - 1)].flags.contains(Flags::WRAPLINE);
        let length = if wrapped {
            columns
        } else {
            row[..]
                .iter()
                .rposition(cell_has_visible_content)
                .map_or(0, |column| column + 1)
        };

        for column in 0..length {
            let cell = &row[Column(column)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            let style = style_for(cell, colors, theme);
            if active_style.as_ref() != Some(&style) {
                if active_link.as_deref() != style.hyperlink.as_deref() {
                    if active_link.is_some() {
                        push_hyperlink(&mut output, None);
                    }
                    if let Some(uri) = style.hyperlink.as_deref() {
                        push_hyperlink(&mut output, Some(uri));
                    }
                    active_link = style.hyperlink.clone();
                }
                push_sgr(&mut output, &style);
                active_style = Some(style);
            }

            let mut encoded = [0; 4];
            output.extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
            for mark in cell.zerowidth().into_iter().flatten() {
                output.extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
            }
        }

        if !wrapped {
            if active_link.take().is_some() {
                push_hyperlink(&mut output, None);
            }
            if active_style.take().is_some() {
                output.extend_from_slice(b"\x1b[0m");
            }
            output.extend_from_slice(b"\r\n");
        }
    }
    if active_link.is_some() {
        push_hyperlink(&mut output, None);
    }
    if active_style.is_some() {
        output.extend_from_slice(b"\x1b[0m");
    }
    output
}
