use crate::protocol::{invalid, MAX_SNAPSHOT};
use std::io;
use zshell_alacritty::*;

pub struct Terminal(*mut ZshellPersistentTerminal);

// Every call is serialized by the owning remote session's mutex.
unsafe impl Send for Terminal {}

impl Terminal {
    pub fn new(columns: u16, rows: u16) -> io::Result<Self> {
        let basic = [
            0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
            0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
        ];
        let mut palette = [0; 256];
        palette[..16].copy_from_slice(&basic);
        let values = [0, 95, 135, 175, 215, 255];
        for index in 0..216 {
            palette[index + 16] =
                values[index / 36] << 16 | values[index / 6 % 6] << 8 | values[index % 6];
        }
        for index in 0..24 {
            let value = 8 + index as u32 * 10;
            palette[index + 232] = value * 0x010101;
        }
        let theme = ZshellTheme {
            palette,
            foreground: 0xc5c8c6,
            background: 0x1d1f21,
            cursor: 0xeaeaea,
        };
        let pointer = unsafe { zshell_persistent_terminal_new(columns, rows, &theme) };
        if pointer.is_null() {
            return Err(invalid("Could not allocate terminal state"));
        }
        Ok(Self(pointer))
    }

    pub fn feed(&mut self, bytes: &[u8], answer_queries: bool) -> Vec<u8> {
        unsafe {
            zshell_persistent_terminal_feed(self.0, bytes.as_ptr(), bytes.len(), answer_queries);
            let mut count = 0;
            let bytes = zshell_persistent_terminal_replies(self.0, &mut count);
            if count == 0 || bytes.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(bytes, count).to_vec()
            }
        }
    }

    pub fn snapshot(&mut self) -> io::Result<Vec<u8>> {
        unsafe {
            let mut count = 0;
            let bytes = zshell_persistent_terminal_snapshot(self.0, &mut count);
            if bytes.is_null() || count > MAX_SNAPSHOT {
                return Err(invalid("Terminal snapshot exceeds 16 MiB"));
            }
            Ok(std::slice::from_raw_parts(bytes, count).to_vec())
        }
    }

    pub fn resize(&mut self, columns: u16, rows: u16) {
        unsafe {
            zshell_persistent_terminal_resize(self.0, columns, rows, 8, 16);
        }
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            zshell_persistent_terminal_free(self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_keeps_history_and_tui_without_repeating_side_effects() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        terminal.feed(
            b"history\r\n\x1b[?1049h\x1b[Hremote tui\x1b]52;c;aGVsbG8=\x07\x07",
            true,
        );
        let snapshot = terminal.snapshot().unwrap();
        assert!(snapshot.windows(7).any(|b| b == b"history"));
        assert!(snapshot.windows(10).any(|b| b == b"remote tui"));
        assert!(!snapshot.windows(4).any(|b| b == b"]52;"));
        assert!(!snapshot.contains(&7));
        terminal.resize(100, 30);
        assert!(!terminal.snapshot().unwrap().is_empty());
    }
}
