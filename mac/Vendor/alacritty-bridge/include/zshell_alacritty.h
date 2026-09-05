//
//  zshell_alacritty.h
//  Zshell's Alacritty backend — C ABI over the `alacritty_terminal` crate.
//
//  Hand-maintained to match `src/lib.rs`. Layouts are `#[repr(C)]` on the Rust
//  side; keep field order and types in step when either changes.
//

#ifndef ZSHELL_ALACRITTY_H
#define ZSHELL_ALACRITTY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Event kinds delivered on the PTY thread. The host bounces them to the main
/// thread before touching any view state.
#define ZSHELL_EVENT_WAKEUP 0u
#define ZSHELL_EVENT_TITLE 1u
#define ZSHELL_EVENT_BELL 2u
#define ZSHELL_EVENT_EXIT 3u
#define ZSHELL_EVENT_CLIPBOARD_STORE 4u
#define ZSHELL_EVENT_CLIPBOARD_LOAD 5u
#define ZSHELL_EVENT_WORKING_DIRECTORY 6u
/// Three bytes: state (0-4), percent (0-100), and whether percent is present.
#define ZSHELL_EVENT_PROGRESS 7u
#define ZSHELL_EVENT_NOTIFICATION 8u
/// OSC 133 semantic prompt and command lifecycle markers.
#define ZSHELL_EVENT_SHELL_PROMPT_START 9u
#define ZSHELL_EVENT_SHELL_COMMAND_START 10u
#define ZSHELL_EVENT_SHELL_COMMAND_EXECUTING 11u
/// Four-byte little-endian int32 exit code; -1 when the shell omitted it.
#define ZSHELL_EVENT_SHELL_COMMAND_FINISHED 12u
/// UTF-8 OSC 22 pointer-shape name — a CSS cursor keyword such as "pointer".
#define ZSHELL_EVENT_MOUSE_SHAPE 13u

/// Per-cell attributes in `ZshellCell.flags`.
#define ZSHELL_CELL_INVERSE (1u << 0)
#define ZSHELL_CELL_BOLD (1u << 1)
#define ZSHELL_CELL_ITALIC (1u << 2)
#define ZSHELL_CELL_UNDERLINE (1u << 3)
#define ZSHELL_CELL_STRIKEOUT (1u << 4)
#define ZSHELL_CELL_DIM (1u << 5)
#define ZSHELL_CELL_HIDDEN (1u << 6)
#define ZSHELL_CELL_WIDE (1u << 7)
#define ZSHELL_CELL_WIDE_SPACER (1u << 8)
#define ZSHELL_CELL_SELECTED (1u << 9)

/// Bits returned by `zshell_alacritty_mode`.
#define ZSHELL_MODE_APP_CURSOR (1u << 0)
#define ZSHELL_MODE_APP_KEYPAD (1u << 1)
#define ZSHELL_MODE_ALT_SCREEN (1u << 2)
#define ZSHELL_MODE_BRACKETED_PASTE (1u << 3)
#define ZSHELL_MODE_MOUSE (1u << 4)
#define ZSHELL_MODE_FOCUS_REPORTING (1u << 5)
#define ZSHELL_MODE_MOUSE_CLICK (1u << 6)
#define ZSHELL_MODE_MOUSE_DRAG (1u << 7)
#define ZSHELL_MODE_MOUSE_MOTION (1u << 8)
#define ZSHELL_MODE_SGR_MOUSE (1u << 9)
#define ZSHELL_MODE_ALTERNATE_SCROLL (1u << 10)

typedef struct ZshellTerminal ZshellTerminal;

typedef void (*ZshellEventCallback)(void *context, uint32_t kind, const uint8_t *data, size_t len);

typedef struct {
  /// Unicode scalar; a space when the cell is empty.
  uint32_t ch;
  /// Packed 0x00RRGGBB, already resolved through the palette.
  uint32_t fg;
  uint32_t bg;
  /// UTF-8 text in `ZshellSnapshot.text` when this cell has combining marks.
  uint32_t text_offset;
  uint16_t text_len;
  uint16_t flags;
} ZshellCell;

typedef struct {
  /// Inclusive viewport-relative cell bounds. Lines can be outside the
  /// viewport when a soft-wrapped URL begins or ends in scrollback.
  int32_t start_line;
  size_t start_column;
  int32_t end_line;
  size_t end_column;
} ZshellURLRange;

typedef struct {
  uint32_t palette[256];
  uint32_t foreground;
  uint32_t background;
  uint32_t cursor;
} ZshellTheme;

typedef struct {
  /// `columns * rows` cells in row-major order. Owned by the handle and valid
  /// only until the next call on it.
  const ZshellCell *cells;
  size_t columns;
  size_t rows;
  /// Viewport-relative cursor, or -1 when it should not be drawn.
  intptr_t cursor_line;
  intptr_t cursor_column;
  /// 0 block, 1 underline, 2 beam, 3 hollow block.
  uint32_t cursor_shape;
  uint32_t cursor_color;
  uint32_t background;
  bool cursor_blinking;
  /// UTF-8 backing for cells with a non-zero `text_len`.
  const uint8_t *text;
  size_t text_len;
  size_t display_offset;
  size_t total_lines;
  size_t screen_lines;
} ZshellSnapshot;

typedef struct {
  uint64_t placement_serial;
  uint32_t image_id;
  uint32_t placement_id;
  /// PNG bytes owned by the terminal handle and valid until its next FFI call.
  const uint8_t *png;
  size_t png_len;
  uint32_t image_width;
  uint32_t image_height;
  uint64_t image_generation;
  int32_t viewport_row;
  size_t column;
  uint32_t source_x;
  uint32_t source_y;
  uint32_t source_width;
  uint32_t source_height;
  uint32_t display_columns;
  uint32_t display_rows;
  uint32_t occupied_columns;
  uint32_t occupied_rows;
  uint32_t x_offset;
  uint32_t y_offset;
  int32_t z_index;
} ZshellKittyPlacement;

typedef struct {
  uint64_t revision;
  const ZshellKittyPlacement *placements;
  size_t placements_len;
} ZshellKittySnapshot;

typedef struct {
  const char *shell;
  const char *const *args;
  size_t args_len;
  const char *working_directory;
  /// `KEY=VALUE` pairs.
  const char *const *env;
  size_t env_len;
  uint16_t columns;
  uint16_t rows;
  uint16_t cell_width;
  uint16_t cell_height;
  size_t scrollback_lines;
  /// 0 block, 1 underline, 2 beam.
  uint8_t cursor_shape;
  bool cursor_blinking;
} ZshellConfig;

/// Spawns a shell on a new PTY and starts reading it. Returns NULL on failure.
/// `context` must outlive the handle.
ZshellTerminal *zshell_alacritty_new(const ZshellConfig *config, const ZshellTheme *theme,
                                 ZshellEventCallback callback, void *context);

/// Stops the read loop and releases the handle.
void zshell_alacritty_free(ZshellTerminal *handle);

/// PID of the shell, for the process panel and teardown signals.
int32_t zshell_alacritty_child_pid(ZshellTerminal *handle);

/// PID of the PTY's foreground process group — the running job rather than the
/// shell that launched it. Falls back to the shell's own PID.
int32_t zshell_alacritty_foreground_pid(ZshellTerminal *handle);

void zshell_alacritty_write(ZshellTerminal *handle, const uint8_t *bytes, size_t len);
/// Writes protocol input without moving the user's scrollback viewport.
void zshell_alacritty_write_control(ZshellTerminal *handle, const uint8_t *bytes, size_t len);
/// Completes a pending OSC 52 clipboard read. `request_id` is the little-endian
/// UInt64 delivered with `ZSHELL_EVENT_CLIPBOARD_LOAD`.
void zshell_alacritty_resolve_clipboard(ZshellTerminal *handle, uint64_t request_id,
                                      const uint8_t *bytes, size_t len, bool approved);
void zshell_alacritty_resize(ZshellTerminal *handle, uint16_t columns, uint16_t rows,
                           uint16_t cell_width, uint16_t cell_height);
/// Scrolls by `delta` lines, positive toward older output.
void zshell_alacritty_scroll(ZshellTerminal *handle, int32_t delta);
/// Puts the viewport `offset` lines above the live prompt.
void zshell_alacritty_scroll_to_offset(ZshellTerminal *handle, size_t offset);
void zshell_alacritty_set_theme(ZshellTerminal *handle, const ZshellTheme *theme);
/// Updates the default cursor unless the terminal application selected its own style.
void zshell_alacritty_set_cursor_style(ZshellTerminal *handle, uint8_t shape, bool blinking);

/// `kind`: 0 simple, 1 semantic (word), 2 line — single, double, triple click.
void zshell_alacritty_selection_start(ZshellTerminal *handle, int32_t line, size_t column,
                                    uint32_t kind, bool right_half);
void zshell_alacritty_selection_update(ZshellTerminal *handle, int32_t line, size_t column,
                                     bool right_half);
void zshell_alacritty_selection_clear(ZshellTerminal *handle);
void zshell_alacritty_select_all(ZshellTerminal *handle);
bool zshell_alacritty_has_selection(ZshellTerminal *handle);

/// Copies into `buffer`, returning bytes written — or the length required when
/// `buffer` is NULL or `capacity` is too small.
size_t zshell_alacritty_selection_text(ZshellTerminal *handle, uint8_t *buffer, size_t capacity);

/// Whole buffer (or scrollback alone) as a styled VT stream, same length
/// protocol. ANSI attributes, truecolor, hyperlinks and combining marks are
/// retained so Zshell can restore history without flattening it.
size_t zshell_alacritty_buffer_text(ZshellTerminal *handle, bool scrollback_only, uint8_t *buffer,
                                  size_t capacity);

/// OSC 8 hyperlink or recognized plain-text URL under one viewport cell. Also
/// writes its inclusive cell bounds when `range` is non-NULL. The URL uses the
/// same length protocol as selection text; zero means neither kind was found.
size_t zshell_alacritty_url_at(ZshellTerminal *handle, int32_t line, size_t column,
                             ZshellURLRange *range, uint8_t *buffer, size_t capacity);

/// Counts every literal match of `needle` in screen and scrollback. Regex
/// metacharacters are escaped, not interpreted.
size_t zshell_alacritty_find(ZshellTerminal *handle, const char *needle);

/// Selects and reveals the next or previous match; returns its zero-based
/// index, or -1 when there are none.
intptr_t zshell_alacritty_find_step(ZshellTerminal *handle, bool forward);

void zshell_alacritty_find_end(ZshellTerminal *handle);

/// Whether the primary screen has rows above the viewport.
bool zshell_alacritty_has_scrollback(ZshellTerminal *handle);

void zshell_alacritty_clear(ZshellTerminal *handle);

/// Nothing changed; the host can drop the frame entirely.
#define ZSHELL_DAMAGE_NONE 0u
/// Only the listed rows changed.
#define ZSHELL_DAMAGE_PARTIAL 1u
/// Everything changed — a resize, a screen swap, a scroll.
#define ZSHELL_DAMAGE_FULL 2u

typedef struct {
  uint32_t kind;
  /// Viewport row indices, owned by the handle and valid only until the next
  /// call on it. Empty unless `kind` is ZSHELL_DAMAGE_PARTIAL.
  const size_t *rows;
  size_t rows_len;
} ZshellDamage;

/// Which viewport rows changed since the last call, resetting damage as it
/// goes. A wakeup only means bytes arrived — ask this before paying for a
/// snapshot, and rebuild only the rows it names.
void zshell_alacritty_take_damage(ZshellTerminal *handle, ZshellDamage *out);

/// Whether a DEC synchronized update is still being buffered.
bool zshell_alacritty_synchronized_update(ZshellTerminal *handle);

/// Fills `out` with the visible grid.
void zshell_alacritty_snapshot(ZshellTerminal *handle, ZshellSnapshot *out);

/// Fills `out` with visible Kitty image placements.
void zshell_alacritty_kitty_snapshot(ZshellTerminal *handle, ZshellKittySnapshot *out);

/// `ZSHELL_MODE_*` bits.
uint32_t zshell_alacritty_mode(ZshellTerminal *handle);

void zshell_alacritty_mark_exited(ZshellTerminal *handle);

#ifdef __cplusplus
}
#endif

#endif /* ZSHELL_ALACRITTY_H */
