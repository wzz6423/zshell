//! C ABI over `alacritty_terminal` for Zshell's Alacritty backend.
//!
//! `alacritty_terminal` is emulation only — VT parser, grid, PTY, selection —
//! with no renderer of any kind. This crate owns the terminal state and the
//! PTY read loop, and hands Swift a flat snapshot of the visible grid to draw
//! with a Metal renderer backed by a CoreText glyph atlas. Everything that
//! would need a reply written back to the PTY (DSR, color queries, text-area
//! size) is answered here rather than crossing the boundary twice.
//!
//! Threading: the PTY read loop runs on its own thread and mutates the
//! terminal behind a `FairMutex`. Every `zshell_alacritty_*` entry point takes
//! that lock, so Swift may call them from the main thread while the loop runs.
//! The snapshot buffer is owned by the handle and is only valid until the next
//! call on that handle.

#[cfg(feature = "renderer")]
mod graphics_event_loop;
#[cfg(feature = "renderer")]
mod kitty_graphics;
#[cfg(feature = "renderer")]
mod kitty_graphics_tracking;
mod persistent_terminal;
#[cfg(feature = "renderer")]
mod renderer;
mod vt_snapshot;

pub use persistent_terminal::*;
#[cfg(feature = "renderer")]
pub use renderer::*;
pub use vt_snapshot::{
    ZshellTheme, ZSHELL_CELL_BOLD, ZSHELL_CELL_DIM, ZSHELL_CELL_HIDDEN, ZSHELL_CELL_INVERSE,
    ZSHELL_CELL_ITALIC, ZSHELL_CELL_SELECTED, ZSHELL_CELL_STRIKEOUT, ZSHELL_CELL_UNDERLINE,
    ZSHELL_CELL_WIDE, ZSHELL_CELL_WIDE_SPACER,
};

pub(crate) use vt_snapshot::{
    color_for_index, push_hyperlink, push_sgr, serialize_vt, style_for, unpack, TermSize,
};
