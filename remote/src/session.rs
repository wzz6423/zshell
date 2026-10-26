use crate::protocol::*;
use crate::terminal::Terminal;
use crate::transport::{project_path, Stream};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Serialize;
use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub session_id: String,
    pub project: String,
    pub command: Vec<String>,
    pub pid: i32,
    pub started_at: f64,
    pub running: bool,
    pub exit_code: Option<i32>,
    pub columns: u16,
    pub rows: u16,
    pub client_count: usize,
    pub active_client_id: Option<String>,
    pub total_output_bytes: u64,
}

struct QueuedFrame {
    frame: Frame,
    bytes: usize,
    snapshot: bool,
}

pub struct Attachment {
    pub id: String,
    stream: Stream,
    sender: mpsc::Sender<QueuedFrame>,
    pending: Arc<AtomicUsize>,
    pending_live: Arc<AtomicUsize>,
    closed: Arc<AtomicBool>,
}

impl Attachment {
    pub fn new(id: String, stream: &Stream) -> io::Result<Arc<Self>> {
        let mut writer = stream.try_clone()?;
        let shutdown = stream.try_clone()?;
        let (sender, receiver) = mpsc::channel::<QueuedFrame>();
        let pending = Arc::new(AtomicUsize::new(0));
        let pending_live = Arc::new(AtomicUsize::new(0));
        let closed = Arc::new(AtomicBool::new(false));
        let counters = (pending.clone(), pending_live.clone(), closed.clone());
        thread::spawn(move || {
            while let Ok(queued) = receiver.recv() {
                let result = if counters.2.load(Ordering::Acquire) {
                    Err(invalid("Attachment closed"))
                } else {
                    write_frame(&mut writer, &queued.frame)
                };
                counters.0.fetch_sub(queued.bytes, Ordering::AcqRel);
                if !queued.snapshot {
                    counters.1.fetch_sub(queued.bytes, Ordering::AcqRel);
                }
                if result.is_err() {
                    counters.2.store(true, Ordering::Release);
                    shutdown.shutdown();
                    break;
                }
            }
        });
        Ok(Arc::new(Self {
            id,
            stream: stream.try_clone()?,
            sender,
            pending,
            pending_live,
            closed,
        }))
    }

    pub fn send(&self, frame: Frame, snapshot: bool) {
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        let bytes = frame.data.as_ref().map_or(256, |data| data.len() + 256);
        let total = self.pending.fetch_add(bytes, Ordering::AcqRel) + bytes;
        let live = if snapshot {
            0
        } else {
            self.pending_live.fetch_add(bytes, Ordering::AcqRel) + bytes
        };
        if total > MAX_SNAPSHOT * 4 / 3 + MAX_BACKLOG + 256 * 1024 || live > MAX_BACKLOG {
            self.pending.fetch_sub(bytes, Ordering::AcqRel);
            if !snapshot {
                self.pending_live.fetch_sub(bytes, Ordering::AcqRel);
            }
            self.disconnect();
            return;
        }
        if self
            .sender
            .send(QueuedFrame {
                frame,
                bytes,
                snapshot,
            })
            .is_err()
        {
            self.pending.fetch_sub(bytes, Ordering::AcqRel);
            if !snapshot {
                self.pending_live.fetch_sub(bytes, Ordering::AcqRel);
            }
            self.disconnect();
        }
    }

    pub fn disconnect(&self) {
        self.closed.store(true, Ordering::Release);
        self.stream.shutdown();
    }
}

struct Client {
    attachment: Arc<Attachment>,
    columns: u16,
    rows: u16,
    order: u64,
}
struct State {
    info: SessionInfo,
    terminal: Terminal,
    clients: HashMap<String, Client>,
    next_order: u64,
}

pub struct Session {
    state: Mutex<State>,
    master: File,
    input_sender: mpsc::SyncSender<Vec<u8>>,
    input_pending: Arc<AtomicUsize>,
    terminating: AtomicBool,
}

impl Session {
    pub fn spawn(request: &Frame) -> io::Result<Arc<Self>> {
        let id = request
            .session_id
            .as_deref()
            .ok_or_else(|| invalid("A session ID is required"))?;
        if !is_uuid(id) {
            return Err(invalid("Invalid session ID"));
        }
        let project = project_path(
            request
                .project
                .as_deref()
                .ok_or_else(|| invalid("A project directory is required"))?,
        )?;
        let (columns, rows) = request.dimensions()?;
        let mut command = request
            .command
            .clone()
            .filter(|args| !args.is_empty())
            .unwrap_or_else(|| vec![login_shell(), "-l".into()]);
        if request.command.as_ref().is_none_or(Vec::is_empty) {
            if let Some(initialization) = request
                .initialization_command
                .as_ref()
                .filter(|text| !text.trim().is_empty())
            {
                if initialization.len() > 65_536 || initialization.contains('\0') {
                    return Err(invalid("Invalid initialization command"));
                }
                command = vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!("{initialization}\nexec \"$1\" -l"),
                    "zshell-remote".into(),
                    login_shell(),
                ];
            }
        }
        if command.len() > 128
            || !command[0].starts_with('/')
            || command
                .iter()
                .any(|arg| arg.len() > 65_536 || arg.contains('\0'))
        {
            return Err(invalid(
                "Remote commands need an absolute executable and bounded arguments",
            ));
        }
        let environment = request.environment.clone().unwrap_or_default();
        if environment.len() > 512
            || environment.iter().any(|(key, value)| {
                key.is_empty()
                    || key.contains(['=', '\0'])
                    || key.starts_with("ZSHELL_")
                    || key.len() > 1024
                    || value.contains('\0')
                    || value.len() > 65_536
            })
        {
            return Err(invalid("Invalid remote terminal environment"));
        }
        let terminal = Terminal::new(columns, rows)?;
        let (master, slave) = open_pty(columns, rows)?;
        let mut launch = Command::new(&command[0]);
        launch
            .args(&command[1..])
            .current_dir(&project)
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
        let mut child = launch.spawn()?;
        let info = SessionInfo {
            session_id: id.to_ascii_lowercase(),
            project,
            command,
            pid: child.id() as i32,
            started_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64(),
            running: true,
            exit_code: None,
            columns,
            rows,
            client_count: 0,
            active_client_id: None,
            total_output_bytes: 0,
        };
        let (input_sender, input_receiver) = mpsc::sync_channel::<Vec<u8>>(64);
        let input_pending = Arc::new(AtomicUsize::new(0));
        let session = Arc::new(Self {
            state: Mutex::new(State {
                info,
                terminal,
                clients: HashMap::new(),
                next_order: 0,
            }),
            master,
            input_sender,
            input_pending: input_pending.clone(),
            terminating: AtomicBool::new(false),
        });
        let input_master = session.master.try_clone()?;
        let input_session = Arc::downgrade(&session);
        thread::spawn(move || {
            while let Ok(bytes) = input_receiver.recv() {
                let result = write_pty(input_master.as_raw_fd(), &bytes);
                input_pending.fetch_sub(bytes.len(), Ordering::AcqRel);
                if result.is_err() {
                    if let Some(session) = input_session.upgrade() {
                        session.disconnect_clients();
                    }
                }
            }
        });
        let (drained_sender, drained_receiver) = mpsc::channel();
        let output_session = session.clone();
        thread::spawn(move || {
            output_session.read_output();
            let _ = drained_sender.send(());
        });
        let reaper_session = session.clone();
        thread::spawn(move || {
            let code = child
                .wait()
                .map(|status| {
                    status
                        .code()
                        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
                })
                .unwrap_or(1);
            let _ = drained_receiver.recv_timeout(Duration::from_secs(2));
            let mut state = reaper_session.state.lock().unwrap();
            state.info.running = false;
            state.info.exit_code = Some(code);
            let mut frame = Frame::new("exited");
            frame.exit_code = Some(code);
            frame.result = Some(serde_json::to_value(&state.info).unwrap());
            for client in state.clients.values() {
                client.attachment.send(frame.clone(), false);
            }
        });
        Ok(session)
    }

    pub fn info(&self) -> SessionInfo {
        self.state.lock().unwrap().info.clone()
    }

    pub fn attach(&self, attachment: Arc<Attachment>, request: &Frame) -> io::Result<()> {
        let (columns, rows) = request.dimensions()?;
        let mut state = self.state.lock().unwrap();
        if let Some(previous) = state.clients.remove(&attachment.id) {
            previous.attachment.disconnect();
        }
        state.next_order += 1;
        let order = state.next_order;
        let id = attachment.id.clone();
        state.clients.insert(
            id.clone(),
            Client {
                attachment: attachment.clone(),
                columns,
                rows,
                order,
            },
        );
        if state.info.active_client_id.is_none() {
            state.info.active_client_id = Some(id);
        }
        state.info.client_count = state.clients.len();
        self.resize_active(&mut state);
        let snapshot = state.terminal.snapshot()?;
        let mut attached = Frame::new("attached");
        attached.request_id = request.request_id.clone();
        attached.result = Some(serde_json::to_value(&state.info).unwrap());
        attachment.send(attached, false);
        let mut start = Frame::new("snapshotStart");
        start.sequence = Some(state.info.total_output_bytes);
        start.columns = Some(state.info.columns);
        start.rows = Some(state.info.rows);
        attachment.send(start, true);
        for bytes in snapshot.chunks(64 * 1024) {
            let mut frame = Frame::new("snapshot");
            frame.data = Some(STANDARD.encode(bytes));
            attachment.send(frame, true);
        }
        let mut end = Frame::new("snapshotEnd");
        end.sequence = Some(state.info.total_output_bytes);
        attachment.send(end, true);
        broadcast_state(&state);
        if !state.info.running {
            let mut exited = Frame::new("exited");
            exited.exit_code = state.info.exit_code;
            attachment.send(exited, false);
        }
        Ok(())
    }

    pub fn detach(&self, attachment: &Arc<Attachment>) {
        let mut state = self.state.lock().unwrap();
        if !state
            .clients
            .get(&attachment.id)
            .is_some_and(|client| Arc::ptr_eq(&client.attachment, attachment))
        {
            return;
        }
        state.clients.remove(&attachment.id);
        state.info.client_count = state.clients.len();
        if state.info.active_client_id.as_deref() == Some(&attachment.id) {
            state.info.active_client_id = state
                .clients
                .iter()
                .min_by_key(|(_, client)| client.order)
                .map(|(id, _)| id.clone());
            self.resize_active(&mut state);
        }
        broadcast_state(&state);
    }

    pub fn handle(&self, attachment: &Arc<Attachment>, request: &Frame) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if !state
            .clients
            .get(&attachment.id)
            .is_some_and(|client| Arc::ptr_eq(&client.attachment, attachment))
        {
            return Err(invalid("This attachment was replaced"));
        }
        match request.kind.as_str() {
            "input" => {
                let bytes = STANDARD
                    .decode(request.data.as_deref().unwrap_or(""))
                    .map_err(invalid)?;
                if bytes.len() > MAX_INPUT {
                    return Err(invalid("Input exceeds 256 KiB"));
                }
                // Only one emulator answers terminal queries. Focus/claim makes
                // another client active before any of its keyboard input.
                if state.info.running
                    && state.info.active_client_id.as_deref() == Some(&attachment.id)
                {
                    self.queue_input(bytes)?;
                }
            }
            "resize" => {
                let (columns, rows) = request.dimensions()?;
                let client = state.clients.get_mut(&attachment.id).unwrap();
                client.columns = columns;
                client.rows = rows;
                self.resize_active(&mut state);
                broadcast_state(&state);
            }
            "claim" => {
                state.info.active_client_id = Some(attachment.id.clone());
                self.resize_active(&mut state);
                broadcast_state(&state);
            }
            "ping" => {
                let mut pong = Frame::new("pong");
                pong.result = Some(serde_json::to_value(&state.info).unwrap());
                attachment.send(pong, false);
            }
            _ => return Err(invalid("Unsupported attached-session request")),
        }
        Ok(())
    }

    fn resize_active(&self, state: &mut State) {
        let Some(client) = state
            .info
            .active_client_id
            .as_ref()
            .and_then(|id| state.clients.get(id))
        else {
            return;
        };
        if state.info.columns == client.columns && state.info.rows == client.rows {
            return;
        }
        let size = libc::winsize {
            ws_col: client.columns,
            ws_row: client.rows,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe { libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ as _, &size) } == 0 {
            state.info.columns = client.columns;
            state.info.rows = client.rows;
            state.terminal.resize(client.columns, client.rows);
        }
    }

    fn queue_input(&self, bytes: Vec<u8>) -> io::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let length = bytes.len();
        if self.input_pending.fetch_add(length, Ordering::AcqRel) + length > MAX_INPUT {
            self.input_pending.fetch_sub(length, Ordering::AcqRel);
            return Err(invalid("Remote terminal input backlog exceeds 256 KiB"));
        }
        if self.input_sender.try_send(bytes).is_err() {
            self.input_pending.fetch_sub(length, Ordering::AcqRel);
            return Err(invalid("Remote terminal input queue is full"));
        }
        Ok(())
    }

    fn read_output(&self) {
        let mut buffer = [0; 16 * 1024];
        loop {
            let mut descriptor = libc::pollfd {
                fd: self.master.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut descriptor, 1, 100) } < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                break;
            }
            if descriptor.revents == 0 {
                continue;
            }
            let count =
                unsafe { libc::read(descriptor.fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count > 0 {
                let bytes = &buffer[..count as usize];
                let mut state = self.state.lock().unwrap();
                let detached = state.clients.is_empty();
                let replies = state.terminal.feed(bytes, detached);
                let _ = self.queue_input(replies);
                state.info.total_output_bytes += count as u64;
                let mut frame = Frame::new("output");
                frame.data = Some(STANDARD.encode(bytes));
                frame.sequence = Some(state.info.total_output_bytes);
                for client in state.clients.values() {
                    client.attachment.send(frame.clone(), false);
                }
            } else if count == 0 {
                break;
            } else {
                let error = io::Error::last_os_error();
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) {
                    continue;
                }
                break;
            }
        }
    }

    pub fn terminate(self: &Arc<Self>) {
        if self.terminating.swap(true, Ordering::AcqRel) {
            return;
        }
        let root = self.info().pid;
        signal_session(root, libc::SIGHUP);
        let session = self.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(500));
            signal_session(root, libc::SIGKILL);
            session.disconnect_clients();
        });
    }

    fn disconnect_clients(&self) {
        for client in self.state.lock().unwrap().clients.values() {
            client.attachment.disconnect();
        }
    }
}

fn broadcast_state(state: &State) {
    let mut frame = Frame::new("state");
    frame.result = Some(serde_json::to_value(&state.info).unwrap());
    for client in state.clients.values() {
        client.attachment.send(frame.clone(), false);
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

fn login_shell() -> String {
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
