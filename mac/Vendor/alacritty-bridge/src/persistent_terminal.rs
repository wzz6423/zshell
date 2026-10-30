use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::Cursor;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Config, Osc52, Term, TermMode};
use alacritty_terminal::vte::ansi::{
    self, CursorShape, CursorStyle, Handler, KeyboardModes, NamedPrivateMode, PrivateMode,
    Processor,
};
use alacritty_terminal::vte::{Parser, Perform};
use unicode_width::UnicodeWidthChar;

use crate::{push_hyperlink, push_sgr, serialize_vt, style_for, unpack, TermSize, ZshellTheme};

const MAX_REPLIES: usize = 64 * 1024;
const MAX_SCROLLBACK_CELLS: usize = 512 * 1024;
const MAX_CONTROL_BYTES: usize = 64 * 1024;
const MAX_COMBINING_MARKS: usize = 16;
const MAX_HYPERLINK_BYTES: usize = 4096;
const MAX_KEYBOARD_MODES: usize = 64;
// DECSCUSR never selects a hollow block, so it marks a style no program set
// and the restored GUI keeps the user's configured cursor.
const UNSET_CURSOR_STYLE: CursorStyle = CursorStyle {
    shape: CursorShape::HollowBlock,
    blinking: false,
};

#[derive(Default)]
struct OutputBoundary {
    pending: Vec<u8>,
    state: BoundaryState,
    discarding: bool,
    string_utf8_continuations: u8,
}

#[derive(Default, Clone, Copy)]
enum BoundaryState {
    #[default]
    Ground,
    Escape,
    Csi,
    String,
    StringEscape,
    Utf8(u8),
}

impl OutputBoundary {
    fn complete_bytes(&mut self, input: &[u8]) -> Vec<u8> {
        let mut output = Vec::with_capacity(input.len());
        for &byte in input {
            if matches!(self.state, BoundaryState::Ground) {
                self.state = match byte {
                    0x1b => BoundaryState::Escape,
                    0x9b => BoundaryState::Csi,
                    0x90 | 0x98 | 0x9d | 0x9e | 0x9f => BoundaryState::String,
                    0xc2..=0xdf => BoundaryState::Utf8(1),
                    0xe0..=0xef => BoundaryState::Utf8(2),
                    0xf0..=0xf4 => BoundaryState::Utf8(3),
                    _ => {
                        output.push(byte);
                        continue;
                    }
                };
                self.pending.push(byte);
                continue;
            }
            if let BoundaryState::Utf8(remaining) = self.state {
                if (0x80..=0xbf).contains(&byte) {
                    self.pending.push(byte);
                    self.state = if remaining == 1 {
                        BoundaryState::Ground
                    } else {
                        BoundaryState::Utf8(remaining - 1)
                    };
                    if remaining == 1 {
                        output.append(&mut self.pending);
                    }
                    continue;
                }
                output.append(&mut self.pending);
                self.state = BoundaryState::Ground;
                // An invalid sequence is followed by a new parser boundary.
                output.extend(self.complete_bytes(&[byte]));
                continue;
            }
            if !self.discarding {
                self.pending.push(byte);
                if self.pending.len() > MAX_CONTROL_BYTES {
                    self.pending.clear();
                    self.discarding = true;
                }
            }
            if matches!(self.state, BoundaryState::String) {
                if self.string_utf8_continuations > 0 && (0x80..=0xbf).contains(&byte) {
                    self.string_utf8_continuations -= 1;
                    continue;
                }
                self.string_utf8_continuations = match byte {
                    0xc2..=0xdf => 1,
                    0xe0..=0xef => 2,
                    0xf0..=0xf4 => 3,
                    _ => 0,
                };
            }
            let finished = match self.state {
                BoundaryState::Escape | BoundaryState::StringEscape => match byte {
                    b'[' => {
                        self.state = BoundaryState::Csi;
                        false
                    }
                    b']' | b'P' | b'X' | b'^' | b'_' => {
                        self.state = BoundaryState::String;
                        false
                    }
                    0x1b => {
                        self.state = BoundaryState::Escape;
                        false
                    }
                    0x20..=0x2f => {
                        self.state = BoundaryState::Escape;
                        false
                    }
                    _ => true,
                },
                BoundaryState::Csi => {
                    if byte == 0x1b {
                        self.state = BoundaryState::Escape;
                        false
                    } else {
                        (0x40..=0x7e).contains(&byte) || byte == 0x18 || byte == 0x1a
                    }
                }
                BoundaryState::String => {
                    if byte == 0x1b {
                        self.state = BoundaryState::StringEscape;
                        false
                    } else {
                        byte == 7 || byte == 0x9c || byte == 0x18 || byte == 0x1a
                    }
                }
                _ => false,
            };
            if finished {
                if !self.discarding {
                    output.append(&mut self.pending);
                }
                self.pending.clear();
                self.discarding = false;
                self.state = BoundaryState::Ground;
                self.string_utf8_continuations = 0;
            }
        }
        output
    }
}

struct Replies {
    answer: bool,
    bytes: Vec<u8>,
    theme: ZshellTheme,
    size: WindowSize,
}

#[derive(Clone)]
struct HeadlessEvents(Arc<Mutex<Replies>>);

impl EventListener for HeadlessEvents {
    fn send_event(&self, event: Event) {
        let mut state = self.0.lock().unwrap();
        if !state.answer {
            return;
        }
        let reply = match event {
            Event::PtyWrite(text) => Some(text),
            Event::ColorRequest(index, format) => {
                Some(format(unpack(crate::color_for_index(index, &state.theme))))
            }
            Event::TextAreaSizeRequest(format) => Some(format(state.size)),
            // Detached programs receive a declined clipboard read, never the
            // host clipboard. Attached programs keep the GUI's confirmation.
            Event::ClipboardLoad(_, format) => Some(format("")),
            _ => None,
        };
        if let Some(reply) = reply {
            if state.bytes.len() + reply.len() <= MAX_REPLIES {
                state.bytes.extend_from_slice(reply.as_bytes());
            }
        }
    }
}

#[derive(Default)]
struct SnapshotState {
    scroll_region: Option<(usize, usize)>,
    mouse_shape: Option<String>,
    progress: Option<String>,
    keyboard_modes: Vec<KeyboardModes>,
    inactive_keyboard_modes: Vec<KeyboardModes>,
}

impl Perform for SnapshotState {
    fn esc_dispatch(&mut self, intermediates: &[u8], _: bool, byte: u8) {
        if intermediates.is_empty() && byte == b'c' {
            self.mouse_shape = None;
            self.progress = None;
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _: bool) {
        if params.first() == Some(&b"22".as_slice()) {
            if let Some(name) = params.get(1) {
                if name.len() <= 64 && name.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-')
                {
                    self.mouse_shape = Some(String::from_utf8_lossy(name).into_owned());
                }
            }
        } else if params.first() == Some(&b"9".as_slice())
            && params.get(1) == Some(&b"4".as_slice())
        {
            let value = params
                .iter()
                .skip(1)
                .map(|p| String::from_utf8_lossy(p))
                .collect::<Vec<_>>()
                .join(";");
            if value.len() <= 32 && value.bytes().all(|c| c.is_ascii_digit() || c == b';') {
                self.progress = Some(value);
            }
        }
    }
}

struct HeadlessHandler<'a> {
    term: &'a mut Term<HeadlessEvents>,
    state: &'a mut SnapshotState,
}

macro_rules! forward_handler_methods {
    ($(fn $name:ident($($arg:ident: $ty:ty),*);)*) => {
        $(fn $name(&mut self $(, $arg: $ty)*) { Handler::$name(self.term $(, $arg)*); })*
    };
}

impl Handler for HeadlessHandler<'_> {
    fn input(&mut self, character: char) {
        if character.width() == Some(0) {
            let cursor = &self.term.grid().cursor;
            let mut point = cursor.point;
            if !cursor.input_needs_wrap {
                point.column.0 = point.column.0.saturating_sub(1);
            }
            if self.term.grid()[point]
                .flags
                .contains(Flags::WIDE_CHAR_SPACER)
            {
                point.column.0 = point.column.0.saturating_sub(1);
            }
            if self.term.grid()[point]
                .zerowidth()
                .is_some_and(|marks| marks.len() >= MAX_COMBINING_MARKS)
            {
                return;
            }
        }
        Handler::input(self.term, character);
    }

    fn set_hyperlink(&mut self, hyperlink: Option<ansi::Hyperlink>) {
        let hyperlink = hyperlink.filter(|link| {
            link.uri.len() <= MAX_HYPERLINK_BYTES
                && link
                    .id
                    .as_ref()
                    .is_none_or(|id| id.len() <= MAX_HYPERLINK_BYTES)
        });
        Handler::set_hyperlink(self.term, hyperlink);
    }

    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) {
        let bottom = bottom.unwrap_or_else(|| self.term.screen_lines());
        if top < bottom {
            self.state.scroll_region = Some((
                top.min(self.term.screen_lines()),
                bottom.min(self.term.screen_lines()),
            ));
        }
        Handler::set_scrolling_region(self.term, top, Some(bottom));
    }

    fn reset_state(&mut self) {
        self.state.scroll_region = None;
        self.state.keyboard_modes.clear();
        self.state.inactive_keyboard_modes.clear();
        Handler::reset_state(self.term);
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::SwapScreenAndSetRestoreCursor.into()
            && !self.term.mode().contains(TermMode::ALT_SCREEN)
        {
            std::mem::swap(
                &mut self.state.keyboard_modes,
                &mut self.state.inactive_keyboard_modes,
            );
        } else if mode == NamedPrivateMode::ColumnMode.into() {
            self.state.scroll_region = None;
        }
        Handler::set_private_mode(self.term, mode);
    }

    fn unset_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::SwapScreenAndSetRestoreCursor.into()
            && self.term.mode().contains(TermMode::ALT_SCREEN)
        {
            std::mem::swap(
                &mut self.state.keyboard_modes,
                &mut self.state.inactive_keyboard_modes,
            );
        } else if mode == NamedPrivateMode::ColumnMode.into() {
            self.state.scroll_region = None;
        }
        Handler::unset_private_mode(self.term, mode);
    }

    fn push_keyboard_mode(&mut self, mode: KeyboardModes) {
        if self.state.keyboard_modes.len() == MAX_KEYBOARD_MODES {
            self.state.keyboard_modes.remove(0);
            Handler::pop_keyboard_modes(self.term, u16::MAX);
            for &mode in &self.state.keyboard_modes {
                Handler::push_keyboard_mode(self.term, mode);
            }
        }
        self.state.keyboard_modes.push(mode);
        Handler::push_keyboard_mode(self.term, mode);
    }

    fn pop_keyboard_modes(&mut self, count: u16) {
        self.state.keyboard_modes.truncate(
            self.state
                .keyboard_modes
                .len()
                .saturating_sub(count as usize),
        );
        Handler::pop_keyboard_modes(self.term, count);
    }

    forward_handler_methods! {
        fn set_cursor_style(style: Option<ansi::CursorStyle>);
        fn set_cursor_shape(shape: ansi::CursorShape);
        fn goto(line: i32, column: usize);
        fn goto_line(line: i32);
        fn goto_col(column: usize);
        fn insert_blank(count: usize);
        fn move_up(rows: usize);
        fn move_down(rows: usize);
        fn identify_terminal(intermediate: Option<char>);
        fn device_status(status: usize);
        fn move_forward(columns: usize);
        fn move_backward(columns: usize);
        fn move_down_and_cr(rows: usize);
        fn move_up_and_cr(rows: usize);
        fn put_tab(count: u16);
        fn backspace();
        fn carriage_return();
        fn linefeed();
        fn bell();
        fn substitute();
        fn newline();
        fn set_horizontal_tabstop();
        fn scroll_up(rows: usize);
        fn scroll_down(rows: usize);
        fn insert_blank_lines(lines: usize);
        fn delete_lines(lines: usize);
        fn erase_chars(count: usize);
        fn delete_chars(count: usize);
        fn move_backward_tabs(count: u16);
        fn move_forward_tabs(count: u16);
        fn save_cursor_position();
        fn restore_cursor_position();
        fn clear_line(mode: ansi::LineClearMode);
        fn clear_screen(mode: ansi::ClearMode);
        fn clear_tabs(mode: ansi::TabulationClearMode);
        fn set_tabs(interval: u16);
        fn reverse_index();
        fn terminal_attribute(attr: ansi::Attr);
        fn set_mode(mode: ansi::Mode);
        fn unset_mode(mode: ansi::Mode);
        fn report_mode(mode: ansi::Mode);
        fn report_private_mode(mode: ansi::PrivateMode);
        fn set_keypad_application_mode();
        fn unset_keypad_application_mode();
        fn set_active_charset(index: ansi::CharsetIndex);
        fn configure_charset(index: ansi::CharsetIndex, charset: ansi::StandardCharset);
        fn set_color(index: usize, color: ansi::Rgb);
        fn dynamic_color_sequence(prefix: String, index: usize, terminator: &str);
        fn reset_color(index: usize);
        fn clipboard_store(clipboard: u8, data: &[u8]);
        fn clipboard_load(clipboard: u8, terminator: &str);
        fn decaln();
        fn text_area_size_pixels();
        fn text_area_size_chars();
        fn set_mouse_cursor_icon(icon: ansi::cursor_icon::CursorIcon);
        fn report_keyboard_mode();
        fn set_keyboard_mode(mode: KeyboardModes, behavior: ansi::KeyboardModesApplyBehavior);
        fn set_modify_other_keys(mode: ansi::ModifyOtherKeys);
        fn report_modify_other_keys();
        fn set_scp(char_path: ansi::ScpCharPath, update_mode: ansi::ScpUpdateMode);
    }
}

fn terminal_config(columns: usize) -> Config {
    Config {
        scrolling_history: (MAX_SCROLLBACK_CELLS / columns).min(10_000),
        kitty_keyboard: true,
        osc52: Osc52::CopyPaste,
        default_cursor_style: UNSET_CURSOR_STYLE,
        ..Config::default()
    }
}

/// The daemon retains emulation only; the GUI still receives the original
/// stream so each backend owns its protocol and clipboard behavior.
pub struct ZshellPersistentTerminal {
    term: Term<HeadlessEvents>,
    processor: Processor,
    state_parser: Parser,
    state: SnapshotState,
    events: HeadlessEvents,
    theme: ZshellTheme,
    snapshot: Vec<u8>,
    replies: Vec<u8>,
    boundary: OutputBoundary,
}

impl ZshellPersistentTerminal {
    fn new(columns: u16, rows: u16, theme: ZshellTheme) -> Self {
        let size = WindowSize {
            num_cols: columns.max(1),
            num_lines: rows.max(1),
            cell_width: 8,
            cell_height: 16,
        };
        let events = HeadlessEvents(Arc::new(Mutex::new(Replies {
            answer: false,
            bytes: Vec::new(),
            theme,
            size,
        })));
        let config = terminal_config(size.num_cols as usize);
        let term = Term::new(
            config,
            &TermSize {
                columns: size.num_cols as usize,
                screen_lines: size.num_lines as usize,
            },
            events.clone(),
        );
        Self {
            term,
            processor: Processor::new(),
            state_parser: Parser::new(),
            state: SnapshotState::default(),
            events,
            theme,
            snapshot: Vec::new(),
            replies: Vec::new(),
            boundary: OutputBoundary::default(),
        }
    }

    fn feed(&mut self, bytes: &[u8], answer: bool) {
        self.events.0.lock().unwrap().answer = answer;
        // Feed complete UTF-8 and control sequences, retaining only a bounded
        // prefix to append after the snapshot when a client joins mid-stream.
        let bytes = self.boundary.complete_bytes(bytes);
        self.state_parser.advance(&mut self.state, &bytes);
        let mut handler = HeadlessHandler {
            term: &mut self.term,
            state: &mut self.state,
        };
        self.processor.advance(&mut handler, &bytes);
        self.processor.stop_sync(&mut handler);
        self.replies = std::mem::take(&mut self.events.0.lock().unwrap().bytes);
    }

    fn resize(&mut self, columns: u16, rows: u16, cell_width: u16, cell_height: u16) {
        self.events.0.lock().unwrap().size = WindowSize {
            num_cols: columns.max(1),
            num_lines: rows.max(1),
            cell_width,
            cell_height,
        };
        if self.term.columns() != columns as usize || self.term.screen_lines() != rows as usize {
            self.term.resize(TermSize {
                columns: columns.max(1) as usize,
                screen_lines: rows.max(1) as usize,
            });
            self.term
                .set_options(terminal_config(columns.max(1) as usize));
            self.state.scroll_region = None;
        }
    }

    fn snapshot(&mut self) -> &[u8] {
        let mode = *self.term.mode();
        let alternate = mode.contains(TermMode::ALT_SCREEN);
        let mut output = b"\x1bc".to_vec();
        if alternate {
            let grid = self.term.grid().clone();
            let keyboard = (mode & TermMode::KITTY_KEYBOARD_PROTOCOL).bits() >> 18;
            // Swapping out of the alternate screen exposes the primary
            // scrollback. Restore the alternate grid after the return swap,
            // whose normal entry semantics clear that screen.
            self.term.swap_alt();
            append_grid(&mut output, &self.term, &self.theme);
            append_saved_cursor(&mut output, &self.term, &self.theme);
            append_cursor(&mut output, &self.term, &self.theme, 0);
            append_keyboard_modes(
                &mut output,
                &self.state.inactive_keyboard_modes,
                *self.term.mode(),
            );
            output.extend_from_slice(b"\x1b[?1049h\x1b[H");
            self.term.swap_alt();
            *self.term.grid_mut() = grid;
            // A mode set with CSI = u is absent from Alacritty's stack; swap_alt
            // otherwise discards it while producing a read-only snapshot.
            self.processor
                .advance(&mut self.term, format!("\x1b[={keyboard}u").as_bytes());
        }
        append_grid(&mut output, &self.term, &self.theme);
        append_saved_cursor(&mut output, &self.term, &self.theme);
        let mut origin = 0;
        if let Some((top, bottom)) = self.state.scroll_region {
            let bottom = if bottom == 0 {
                self.term.screen_lines()
            } else {
                bottom
            };
            output.extend_from_slice(format!("\x1b[{top};{bottom}r").as_bytes());
            if mode.contains(TermMode::ORIGIN) {
                origin = top - 1;
            }
        }
        append_modes(&mut output, mode);
        append_keyboard_modes(&mut output, &self.state.keyboard_modes, mode);
        append_cursor(&mut output, &self.term, &self.theme, origin);
        if let Some(shape) = &self.state.mouse_shape {
            output.extend_from_slice(format!("\x1b]22;{shape}\x1b\\").as_bytes());
        }
        if let Some(progress) = &self.state.progress {
            output.extend_from_slice(format!("\x1b]9;{progress}\x1b\\").as_bytes());
        }
        output.extend_from_slice(&self.boundary.pending);
        // Snapshot consists only of cells and current modes. BEL, OSC 52,
        // desktop notifications and query requests never run a second time.
        self.snapshot = output;
        &self.snapshot
    }
}

fn append_grid(output: &mut Vec<u8>, term: &Term<HeadlessEvents>, theme: &ZshellTheme) {
    let mut bytes = serialize_vt(term, theme, false);
    if bytes.ends_with(b"\r\n") {
        bytes.truncate(bytes.len() - 2);
    }
    output.extend_from_slice(&bytes);
}

fn append_saved_cursor(output: &mut Vec<u8>, term: &Term<HeadlessEvents>, theme: &ZshellTheme) {
    let save = &term.grid().saved_cursor;
    // A saved cursor can precede the active scroll region; restore it while
    // the snapshot still has the default origin and physical coordinates.
    append_cursor_position(output, term, save, theme, 0);
    output.extend_from_slice(b"\x1b7");
}

fn append_cursor(
    output: &mut Vec<u8>,
    term: &Term<HeadlessEvents>,
    theme: &ZshellTheme,
    origin: usize,
) {
    append_cursor_position(output, term, &term.grid().cursor, theme, origin);
    let style = term.cursor_style();
    let shape = match style.shape {
        CursorShape::HollowBlock => 0,
        CursorShape::Underline => 3 + u8::from(!style.blinking),
        CursorShape::Beam => 5 + u8::from(!style.blinking),
        _ => 1 + u8::from(!style.blinking),
    };
    output.extend_from_slice(format!("\x1b[{shape} q").as_bytes());
}

fn append_cursor_position(
    output: &mut Vec<u8>,
    term: &Term<HeadlessEvents>,
    cursor: &Cursor<Cell>,
    theme: &ZshellTheme,
    origin: usize,
) {
    let mut point = cursor.point;
    if cursor.input_needs_wrap && term.grid()[point].flags.contains(Flags::WIDE_CHAR_SPACER) {
        point.column.0 = point.column.0.saturating_sub(1);
    }
    let line = (point.line.0 as usize).saturating_sub(origin) + 1;
    output.extend_from_slice(format!("\x1b[{line};{}H", point.column.0 + 1).as_bytes());
    if cursor.input_needs_wrap {
        let cell = &term.grid()[point];
        push_sgr(output, &style_for(cell, term.colors(), theme));
        let mut encoded = [0; 4];
        output.extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
        for mark in cell.zerowidth().into_iter().flatten() {
            output.extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
        }
    }
    push_sgr(output, &style_for(&cursor.template, term.colors(), theme));
    let hyperlink = cursor.template.hyperlink();
    push_hyperlink(output, hyperlink.as_ref().map(|link| link.uri()));
}

fn append_modes(output: &mut Vec<u8>, mode: TermMode) {
    for (flag, number) in [
        (TermMode::APP_CURSOR, 1),
        (TermMode::ORIGIN, 6),
        (TermMode::LINE_WRAP, 7),
        (TermMode::SHOW_CURSOR, 25),
        (TermMode::MOUSE_REPORT_CLICK, 1000),
        (TermMode::MOUSE_DRAG, 1002),
        (TermMode::MOUSE_MOTION, 1003),
        (TermMode::FOCUS_IN_OUT, 1004),
        (TermMode::UTF8_MOUSE, 1005),
        (TermMode::SGR_MOUSE, 1006),
        (TermMode::ALTERNATE_SCROLL, 1007),
        (TermMode::BRACKETED_PASTE, 2004),
    ] {
        output.extend_from_slice(
            format!(
                "\x1b[?{number}{}",
                if mode.contains(flag) { 'h' } else { 'l' }
            )
            .as_bytes(),
        );
    }
    output.extend_from_slice(if mode.contains(TermMode::APP_KEYPAD) {
        b"\x1b="
    } else {
        b"\x1b>"
    });
    for (flag, number) in [(TermMode::INSERT, 4), (TermMode::LINE_FEED_NEW_LINE, 20)] {
        output.extend_from_slice(
            format!(
                "\x1b[{number}{}",
                if mode.contains(flag) { 'h' } else { 'l' }
            )
            .as_bytes(),
        );
    }
}

fn append_keyboard_modes(output: &mut Vec<u8>, stack: &[KeyboardModes], mode: TermMode) {
    for mode in stack {
        output.extend_from_slice(format!("\x1b[>{}u", mode.bits()).as_bytes());
    }
    let keyboard = ((mode & TermMode::KITTY_KEYBOARD_PROTOCOL).bits() >> 18) & 31;
    output.extend_from_slice(format!("\x1b[={keyboard}u").as_bytes());
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_new(
    columns: u16,
    rows: u16,
    theme: *const ZshellTheme,
) -> *mut ZshellPersistentTerminal {
    if theme.is_null() {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(ZshellPersistentTerminal::new(
        columns, rows, *theme,
    )))
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_free(handle: *mut ZshellPersistentTerminal) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_feed(
    handle: *mut ZshellPersistentTerminal,
    bytes: *const u8,
    len: usize,
    answer_queries: bool,
) {
    if let Some(terminal) = handle.as_mut() {
        if !bytes.is_null() {
            terminal.feed(std::slice::from_raw_parts(bytes, len), answer_queries);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_resize(
    handle: *mut ZshellPersistentTerminal,
    columns: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) {
    if let Some(terminal) = handle.as_mut() {
        terminal.resize(columns, rows, cell_width, cell_height);
    }
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_set_theme(
    handle: *mut ZshellPersistentTerminal,
    theme: *const ZshellTheme,
) {
    if let (Some(terminal), Some(theme)) = (handle.as_mut(), theme.as_ref()) {
        terminal.theme = *theme;
        terminal.events.0.lock().unwrap().theme = *theme;
    }
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_snapshot(
    handle: *mut ZshellPersistentTerminal,
    length: *mut usize,
) -> *const u8 {
    let (Some(terminal), Some(length)) = (handle.as_mut(), length.as_mut()) else {
        return std::ptr::null();
    };
    let bytes = terminal.snapshot();
    *length = bytes.len();
    bytes.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn zshell_persistent_terminal_replies(
    handle: *mut ZshellPersistentTerminal,
    length: *mut usize,
) -> *const u8 {
    let (Some(terminal), Some(length)) = (handle.as_mut(), length.as_mut()) else {
        return std::ptr::null();
    };
    *length = terminal.replies.len();
    terminal.replies.as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal() -> ZshellPersistentTerminal {
        ZshellPersistentTerminal::new(
            40,
            6,
            ZshellTheme {
                palette: [0; 256],
                foreground: 0xeeeeee,
                background: 0x111111,
                cursor: 0xffffff,
            },
        )
    }

    fn equal_screen(left: &ZshellPersistentTerminal, right: &ZshellPersistentTerminal) {
        for row in 0..left.term.screen_lines() {
            for col in 0..left.term.columns() {
                let point = alacritty_terminal::index::Point::new(
                    alacritty_terminal::index::Line(row as i32),
                    alacritty_terminal::index::Column(col),
                );
                assert_eq!(
                    left.term.grid()[point].c,
                    right.term.grid()[point].c,
                    "{row}:{col}"
                );
                assert_eq!(
                    left.term.grid()[point].zerowidth().unwrap_or_default(),
                    right.term.grid()[point].zerowidth().unwrap_or_default(),
                    "marks {row}:{col}"
                );
                assert_eq!(
                    style_for(&left.term.grid()[point], left.term.colors(), &left.theme),
                    style_for(&right.term.grid()[point], right.term.colors(), &right.theme),
                    "style {row}:{col}"
                );
            }
        }
        assert_eq!(
            left.term.grid().cursor.point,
            right.term.grid().cursor.point
        );
        assert_eq!(
            left.term.grid().cursor.input_needs_wrap,
            right.term.grid().cursor.input_needs_wrap
        );
        assert_eq!(left.term.mode(), right.term.mode());
    }

    #[test]
    fn primary_snapshot_preserves_screen_cursor_and_continued_output() {
        let mut original = terminal();
        for i in 0..100 {
            original.feed(format!("line {i}\r\n").as_bytes(), false);
        }
        original.feed(b"\x1b[32mhello\x1b[2D\x1b[?2004h", false);
        let mut restored = terminal();
        restored.feed(original.snapshot(), false);
        equal_screen(&original, &restored);
        assert!(String::from_utf8_lossy(original.snapshot()).contains("line 10"));
        original.feed(b"XY\r\nnext", false);
        restored.feed(b"XY\r\nnext", false);
        equal_screen(&original, &restored);
    }

    #[test]
    fn alternate_snapshot_preserves_primary_and_input_modes_without_side_effects() {
        let mut original = terminal();
        original.feed(b"shell history\r\nprompt> \x1b[?1049h\x1b[2J\x1b[3;4Hagent\x1b[?1h\x1b[?1006h\x1b[?1003h\x1b[?25l\x1b[?2004h\x1b[=3u\x07\x1b]52;c;?\x07\x1b]777;notify;t;b\x1b\\", false);
        let snapshot = original.snapshot().to_vec();
        assert!(!snapshot.contains(&7));
        assert!(!snapshot.windows(4).any(|s| s == b"]52;"));
        assert!(!snapshot.windows(5).any(|s| s == b"]777;"));
        let mut restored = terminal();
        restored.feed(&snapshot, false);
        equal_screen(&original, &restored);
        original.feed(b" reply\x1b[?1049l", false);
        restored.feed(b" reply\x1b[?1049l", false);
        equal_screen(&original, &restored);
    }

    #[test]
    fn snapshot_restores_only_program_cursor_styles() {
        let mut original = terminal();
        assert!(original.snapshot().ends_with(b"\x1b[0 q"));
        for (bytes, style) in [
            (b"\x1b[2 q".as_slice(), b"\x1b[2 q".as_slice()),
            (b"\x1b[5 q", b"\x1b[5 q"),
            (b"\x1b[0 q", b"\x1b[0 q"),
        ] {
            original.feed(bytes, false);
            assert!(original.snapshot().ends_with(style));
        }
    }

    #[test]
    fn query_responses_have_one_owner_and_offline_clipboard_is_declined() {
        let mut original = terminal();
        original.feed(b"\x1b[6n\x1b]52;c;?\x07", false);
        assert!(original.replies.is_empty());
        original.feed(b"\x1b[6n\x1b]52;c;?\x07", true);
        assert!(original.replies.windows(6).any(|s| s == b"\x1b[1;1R"));
        assert!(original.replies.windows(7).any(|s| s == b"]52;c;\x07"));
        assert!(original.replies.len() <= MAX_REPLIES);
    }

    #[test]
    fn snapshot_at_every_utf8_and_control_boundary_continues_without_corruption() {
        let bytes = "提示 ❯ e\u{301}\r\n\x1b]8;;https://example.com/✓❯\x1b\\link\x1b]8;;\x1b\\\x1b[12\x1b[31mred\x1b]0;interrupted\x1b[0m\r\n\x1b[?1049h\x1b[2J\x1b[3;4H中文\x1b[?1h\x1b[?2004h\x1b[>3u\x1b[?1006h".as_bytes();
        for boundary in 0..=bytes.len() {
            let mut original = terminal();
            original.feed(&bytes[..boundary], false);
            let mut restored = terminal();
            restored.feed(original.snapshot(), false);
            original.feed(&bytes[boundary..], false);
            restored.feed(&bytes[boundary..], false);
            equal_screen(&original, &restored);
            original.feed(b"\x1b[<u\x1b[?1049l\r\nnext", false);
            restored.feed(b"\x1b[<u\x1b[?1049l\r\nnext", false);
            equal_screen(&original, &restored);
        }
    }

    #[test]
    fn snapshot_restores_scroll_region_origin_wrap_and_resize() {
        let mut original = terminal();
        original.feed(
            b"primary\r\n\x1b[?1049h\x1b[2;5r\x1b[?6h\x1b[2;4Hbefore",
            false,
        );
        let mut restored = terminal();
        restored.feed(original.snapshot(), false);
        equal_screen(&original, &restored);
        for bytes in [
            b"\x1b[4;1Hbottom\nnext".as_slice(),
            b"\x1b[?6l\x1b[r\x1b[6;40HXnext",
        ] {
            original.feed(bytes, false);
            restored.feed(bytes, false);
            equal_screen(&original, &restored);
        }
        original.resize(50, 8, 10, 20);
        let mut restored = ZshellPersistentTerminal::new(50, 8, original.theme);
        restored.feed(original.snapshot(), false);
        equal_screen(&original, &restored);
        original.feed(b"\x1b[?1049l\r\nnext", false);
        restored.feed(b"\x1b[?1049l\r\nnext", false);
        equal_screen(&original, &restored);
    }

    #[test]
    fn snapshot_preserves_nested_keyboard_modes_on_both_screens() {
        let mut original = terminal();
        original.feed(
            b"\x1b[>1u\x1b[>3u\x1b[?1049h\x1b[>8u\x1b[>16u\x1b[=31u",
            false,
        );
        let mut restored = terminal();
        restored.feed(original.snapshot(), false);
        equal_screen(&original, &restored);
        for bytes in [
            b"\x1b[<u".as_slice(),
            b"\x1b[?1049l",
            b"\x1b[<u",
            b"\x1b[<u",
        ] {
            original.feed(bytes, false);
            restored.feed(bytes, false);
            equal_screen(&original, &restored);
        }
        for _ in 0..5000 {
            original.feed(b"\x1b[>1u", false);
        }
        assert_eq!(original.state.keyboard_modes.len(), MAX_KEYBOARD_MODES);
        let mut restored = terminal();
        restored.feed(original.snapshot(), false);
        original.feed(b"\x1b[<64u", false);
        restored.feed(b"\x1b[<64u", false);
        equal_screen(&original, &restored);
    }

    #[test]
    fn snapshot_at_pending_wrap_preserves_wide_and_saved_cursors() {
        for text in ["x", "中", "e\u{301}"] {
            let mut original = terminal();
            original.feed(b"\x1b[1;39H", false);
            original.feed(
                text.repeat(if text == "x" { 2 } else { 1 }).as_bytes(),
                false,
            );
            original.feed(b"\x1b7", false);
            let mut restored = terminal();
            restored.feed(original.snapshot(), false);
            equal_screen(&original, &restored);
            for bytes in [b"next".as_slice(), b"\x1b8again"] {
                original.feed(bytes, false);
                restored.feed(bytes, false);
                equal_screen(&original, &restored);
            }
        }
    }

    #[test]
    fn resize_and_cell_metadata_remain_bounded() {
        let mut original = terminal();
        original.feed("e".as_bytes(), false);
        original.feed("\u{301}".repeat(20_000).as_bytes(), false);
        let point = alacritty_terminal::index::Point::new(
            alacritty_terminal::index::Line(0),
            alacritty_terminal::index::Column(0),
        );
        assert_eq!(
            original.term.grid()[point].zerowidth().unwrap().len(),
            MAX_COMBINING_MARKS
        );
        original.feed(
            format!("\x1b]8;;https://{}\x1b\\x", "a".repeat(MAX_HYPERLINK_BYTES)).as_bytes(),
            false,
        );
        assert!(original.term.grid().cursor.template.hyperlink().is_none());
        for _ in 0..12_000 {
            original.feed(b"line\r\n", false);
        }
        original.resize(240, 6, 10, 20);
        assert!(original.term.history_size() * original.term.columns() <= MAX_SCROLLBACK_CELLS);
        assert!(original.snapshot().len() <= 16 * 1024 * 1024);
    }

    #[test]
    fn unterminated_control_output_and_scrollback_are_bounded() {
        let mut original = terminal();
        original.feed(b"\x1b]0;", false);
        original.feed(&vec![b'x'; 4 * MAX_CONTROL_BYTES], false);
        assert!(original.boundary.pending.is_empty());
        original.feed(b"\x07ready", false);
        assert!(String::from_utf8_lossy(original.snapshot()).contains("ready"));
        for _ in 0..12_000 {
            original.feed(b"line\r\n", false);
        }
        assert!(original.term.history_size() <= 10_000);
        assert!(original.snapshot().len() <= 16 * 1024 * 1024);
    }
}
