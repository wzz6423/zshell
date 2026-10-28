use crate::protocol::invalid;
use std::collections::BTreeMap;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;

pub struct Pty {
    master: File,
    pid: i32,
}

pub struct PtyChild(Child);

impl PtyChild {
    pub fn wait(&mut self) -> i32 {
        self.0
            .wait()
            .map(|status| {
                status
                    .code()
                    .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
            })
            .unwrap_or(1)
    }
}

impl Pty {
    pub fn spawn(
        command: &[String],
        project: &str,
        environment: BTreeMap<String, String>,
        columns: u16,
        rows: u16,
    ) -> io::Result<(Arc<Self>, PtyChild)> {
        let (master, slave) = open_pty(columns, rows)?;
        let mut launch = Command::new(&command[0]);
        launch
            .args(&command[1..])
            .current_dir(project)
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        for (key, _) in std::env::vars().filter(|(key, _)| key.starts_with("ZSHELL_")) {
            launch.env_remove(key);
        }
        launch
            .envs(environment)
            .env("TERM", "xterm-256color")
            .env("COLORTERM", "truecolor")
            .env("TERM_PROGRAM", "ghostty");
        unsafe {
            launch.pre_exec(|| {
                if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = launch.spawn()?;
        let pty = Arc::new(Self {
            master,
            pid: child.id() as i32,
        });
        Ok((pty, PtyChild(child)))
    }
    pub fn pid(&self) -> i32 {
        self.pid
    }
    pub fn foreground_pid(&self) -> Option<i32> {
        let pid = unsafe { libc::tcgetpgrp(self.master.as_raw_fd()) };
        (pid > 1).then_some(pid)
    }
    pub fn owns_process(&self, _pid: i32) -> bool {
        true
    }
    pub fn write(&self, bytes: &[u8]) -> io::Result<()> {
        write_pty(self.master.as_raw_fd(), bytes)
    }
    pub fn read(&self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            let mut descriptor = libc::pollfd {
                fd: self.master.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut descriptor, 1, 100) } < 0 {
                return Err(io::Error::last_os_error());
            }
            if descriptor.revents == 0 {
                continue;
            }
            let count =
                unsafe { libc::read(descriptor.fd, bytes.as_mut_ptr().cast(), bytes.len()) };
            return if count < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(count as usize)
            };
        }
    }
    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        let size = libc::winsize {
            ws_col: columns,
            ws_row: rows,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe { libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ as _, &size) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
    pub fn terminate(&self, force: bool) {
        signal_session(self.pid, if force { libc::SIGKILL } else { libc::SIGHUP });
    }
}

fn open_pty(columns: u16, rows: u16) -> io::Result<(File, File)> {
    let mut master = -1;
    let mut slave = -1;
    let mut size = libc::winsize {
        ws_col: columns,
        ws_row: rows,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let master = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    for fd in [master.as_raw_fd(), slave.as_raw_fd()] {
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok((master, slave))
}

fn write_pty(fd: RawFd, bytes: &[u8]) -> io::Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let count =
            unsafe { libc::write(fd, bytes[offset..].as_ptr().cast(), bytes.len() - offset) };
        if count > 0 {
            offset += count as usize;
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() != io::ErrorKind::WouldBlock {
            return Err(error);
        }
        let mut descriptor = libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        };
        if unsafe { libc::poll(&mut descriptor, 1, 2_000) } <= 0 {
            return Err(invalid("PTY input timed out"));
        }
    }
    Ok(())
}

fn signal_session(root: i32, signal: i32) {
    let pids = session_processes(root);
    let mut groups = std::collections::HashSet::new();
    for pid in &pids {
        let group = unsafe { libc::getpgid(*pid) };
        if group > 1 && group != unsafe { libc::getpgrp() } {
            groups.insert(group);
        }
    }
    for group in groups {
        unsafe {
            libc::kill(-group, signal);
        }
    }
    for pid in pids {
        if unsafe { libc::getsid(pid) } == root {
            unsafe {
                libc::kill(pid, signal);
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn session_processes(root: i32) -> Vec<i32> {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
        .filter(|pid| *pid > 1 && unsafe { libc::getsid(*pid) } == root)
        .collect()
}

#[cfg(target_os = "macos")]
fn session_processes(root: i32) -> Vec<i32> {
    unsafe extern "C" {
        fn proc_listallpids(buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
    }
    let count = unsafe { proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return vec![root];
    }
    let mut pids = vec![0; count as usize + 64];
    let actual = unsafe {
        proc_listallpids(
            pids.as_mut_ptr().cast(),
            (pids.len() * std::mem::size_of::<i32>()) as i32,
        )
    };
    pids.into_iter()
        .take(actual.max(0) as usize)
        .filter(|pid| *pid > 1 && unsafe { libc::getsid(*pid) } == root)
        .collect()
}

pub fn login_shell() -> String {
    let mut entry = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut buffer = vec![0; 16 * 1024];
    let mut result = std::ptr::null_mut();
    if unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    } == 0
        && !result.is_null()
        && !entry.pw_shell.is_null()
    {
        let shell = unsafe { std::ffi::CStr::from_ptr(entry.pw_shell) }
            .to_string_lossy()
            .into_owned();
        if shell.starts_with('/') && std::path::Path::new(&shell).is_file() {
            return shell;
        }
    }
    "/bin/sh".into()
}

pub fn default_command(initialization: Option<&str>) -> Vec<String> {
    match initialization {
        Some(initialization) => vec![
            "/bin/sh".into(),
            "-c".into(),
            format!("{initialization}\nexec \"$1\" -l"),
            "zshell-remote".into(),
            login_shell(),
        ],
        None => vec![login_shell(), "-l".into()],
    }
}
