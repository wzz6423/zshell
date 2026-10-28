#[cfg(unix)]
#[path = "pty_unix.rs"]
mod implementation;
#[cfg(windows)]
#[path = "pty_windows.rs"]
mod implementation;
pub use implementation::*;
