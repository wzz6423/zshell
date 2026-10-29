use crate::protocol::*;
use crate::pty::{default_command, Pty};
use crate::agent::{self, Osc, Records, Report, Scanner, Status};
use crate::agent_history::{History, Identity, timestamp};
use crate::agent_hooks::Hook;
use crate::agent_process;
use crate::codex_binding::{Bindings, TitleEvidence};
use crate::terminal::Terminal;
use crate::transport::{project_path, Stream};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Serialize;
use std::collections::HashMap;
use std::io;
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
    pub agent_status: Status,
    pub conversation: Option<Identity>,
    pub profile_context: crate::profile_context::ProfileContext,
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
    scanner: Scanner,
    records: Records,
    agent_owner: Option<(i32, u64)>,
    codex_title: Option<(TitleEvidence, (i32, u64))>,
    terminal_title: Option<String>,
    shared_codex: bool,
    shared_codex_revision: Option<u64>,
    shared_codex_service: Option<(i32, u64)>,
}

pub struct Session {
    state: Mutex<State>,
    pty: Arc<Pty>,
    input_sender: mpsc::SyncSender<Vec<u8>>,
    input_pending: Arc<AtomicUsize>,
    terminating: AtomicBool,
    hook_token: String,
    history: Arc<History>,
    bindings: Arc<Bindings>,
    registry: std::sync::Weak<Mutex<HashMap<String, Arc<Session>>>>,
}

impl Session {
    pub fn spawn(request: &Frame, state_path: &std::path::Path, history: Arc<History>, bindings: Arc<Bindings>,
        registry: std::sync::Weak<Mutex<HashMap<String, Arc<Session>>>>) -> io::Result<Arc<Self>> {
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
        let working_directory = request.working_directory.as_deref().map(project_path).transpose()?.unwrap_or_else(|| project.clone());
        if !std::path::Path::new(&working_directory).starts_with(&project) { return Err(invalid("Remote working directory belongs to a different project")); }
        let (columns, rows) = request.dimensions()?;
        let mut command = request
            .command
            .clone()
            .filter(|args| !args.is_empty())
            .unwrap_or_else(|| default_command(None));
        if request.command.as_ref().is_none_or(Vec::is_empty) {
            if let Some(initialization) = request
                .initialization_command
                .as_ref()
                .filter(|text| !text.trim().is_empty())
            {
                if initialization.len() > 65_536 || initialization.contains('\0') {
                    return Err(invalid("Invalid initialization command"));
                }
                command = default_command(Some(initialization));
            }
        }
        if command.len() > 128
            || !std::path::Path::new(&command[0]).is_absolute()
            || command
                .iter()
                .any(|arg| arg.len() > 65_536 || arg.contains('\0'))
        {
            return Err(invalid(
                "Remote commands need an absolute executable and bounded arguments",
            ));
        }
        let mut environment = request.environment.clone().unwrap_or_default();
        if environment.len() > 512
            || environment.iter().any(|(key, value)| {
                key.is_empty()
                    || key.contains(['=', '\0'])
                    || key.to_ascii_uppercase().starts_with("ZSHELL_")
                    || key.len() > 1024
                    || value.contains('\0')
                    || value.len() > 65_536
            })
        {
            return Err(invalid("Invalid remote terminal environment"));
        }
        let hook_token = new_id()? + &new_id()?;
        for (key, value) in [("ZSHELL_AUTOMATION", "1".into()), ("ZSHELL_AUTOMATION_TOKEN", hook_token.clone()),
            ("ZSHELL_TERMINAL_ID", id.to_ascii_lowercase()), ("ZSHELL_REMOTE_PROJECT", project.clone()),
            ("ZSHELL_REMOTE_STATE", state_path.to_string_lossy().into_owned()),
            ("ZSHELL_EXECUTABLE", std::env::current_exe()?.to_string_lossy().into_owned())] {
            environment.insert(key.into(), value);
        }
        let terminal = Terminal::new(columns, rows)?;
        let (pty, mut child) = Pty::spawn(&command, &working_directory, environment, columns, rows)?;
        let info = SessionInfo {
            session_id: id.to_ascii_lowercase(),
            project,
            command,
            pid: pty.pid(),
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
            agent_status: Status { phase: "idle".into(), ..Status::default() },
            conversation: None,
            profile_context: crate::profile_context::snapshot(pty.pid()),
        };
        let (input_sender, input_receiver) = mpsc::sync_channel::<Vec<u8>>(64);
        let input_pending = Arc::new(AtomicUsize::new(0));
        let session = Arc::new(Self {
            state: Mutex::new(State {
                info,
                terminal,
                clients: HashMap::new(),
                next_order: 0,
                scanner: Scanner::default(),
                records: Records::default(),
                agent_owner: None,
                codex_title: None,
                terminal_title: None,
                shared_codex: false,
                shared_codex_revision: None,
                shared_codex_service: None,
            }),
            pty,
            input_sender,
            input_pending: input_pending.clone(),
            terminating: AtomicBool::new(false),
            hook_token,
            history,
            bindings,
            registry,
        });
        let input_pty = session.pty.clone();
        let input_session = Arc::downgrade(&session);
        thread::spawn(move || {
            while let Ok(bytes) = input_receiver.recv() {
                let result = input_pty.write(&bytes);
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
            let code = child.wait();
            let _ = drained_receiver.recv_timeout(Duration::from_secs(2));
            let mut state = reaper_session.state.lock().unwrap();
            state.info.running = false;
            state.info.exit_code = Some(code);
            state.records.drop_live();
            state.info.agent_status = state.records.status();
            if let Some(identity) = state.info.conversation.take() {
                let _ = reaper_session.history.ended(&identity, &state.info.session_id);
            }
            state.agent_owner = None;
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
        let mut state = self.state.lock().unwrap();
        self.refresh_agent_owner(&mut state);
        self.refresh_profile_context(&mut state);
        state.info.clone()
    }

    fn refresh_profile_context(&self, state: &mut State) {
        if state.info.running {
            state.info.profile_context = crate::profile_context::snapshot(
                self.pty.foreground_pid().unwrap_or(state.info.pid)
            );
        }
    }

    pub fn accept_hook(&self, hook: &Hook, peer_pid: Option<i32>) -> io::Result<()> {
        let peer_pid = peer_pid.ok_or_else(|| invalid("Native Agent hooks require local process credentials"))?;
        if hook.token != self.hook_token || hook.token.len() != 72 || !self.pty.owns_process(peer_pid) {
            return Err(invalid("Agent hook belongs to another terminal"));
        }
        let mut state = self.state.lock().unwrap();
        if !state.info.running || self.terminating.load(Ordering::Acquire) { return Err(invalid("Remote Agent terminal has exited")); }
        let root = agent_process::root_agent(peer_pid, hook.reporter_pid, state.info.pid, self.pty.foreground_pid(), &hook.provider)
            .ok_or_else(|| invalid("Only the foreground root Agent can report this terminal"))?;
        let owner = agent_process::process(root).ok_or_else(|| invalid("Remote Agent process has exited"))?;
        let record = hook.record(&state.info.agent_status.phase)?;
        if let Some(identity) = &hook.identity {
            identity.validate()?;
            let directory = project_path(&identity.working_directory)?;
            if identity.provider != hook.provider || !std::path::Path::new(&directory).starts_with(&state.info.project) {
                return Err(invalid("Agent conversation belongs to a different project"));
            }
            if let Some(previous) = &state.info.conversation {
                if previous != identity { self.history.ended(previous, &state.info.session_id)?; }
            }
            self.history.note(identity.clone(), &state.info.project, &state.info.session_id)?;
            state.info.conversation = Some(identity.clone());
        }
        if hook.event == "SessionEnd" && hook.task_id.is_none() {
            if let Some(previous) = state.info.conversation.take() { self.history.ended(&previous, &state.info.session_id)?; }
        }
        state.agent_owner = Some((root, owner.started));
        state.shared_codex = false;
        state.records.apply(record);
        state.info.agent_status = state.records.status();
        broadcast_state(&state);
        Ok(())
    }

    pub fn codex_title_evidence(&self) -> Option<TitleEvidence> {
        let state = self.state.lock().unwrap();
        let (title, owner) = state.codex_title.as_ref()?;
        (state.info.running
            && agent_process::foreground_agent(state.info.pid, self.pty.foreground_pid(), "codex").as_ref() == Some(owner)
            && self.pty.owns_process(owner.0)).then(|| title.clone())
    }

    pub fn sync_shared_codex(&self, identity: &Identity, service: (i32, u64), records: &Records, revision: u64, ending: bool) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        let Some((title, owner)) = state.codex_title.as_ref() else { return Err(invalid("Remote Codex TUI title is unavailable")); };
        let owner = *owner;
        if !title.matches(&identity.session_id) || identity.provider != "codex" || !state.info.running
            || agent_process::foreground_agent(state.info.pid, self.pty.foreground_pid(), "codex") != Some(owner)
            || !self.pty.owns_process(owner.0) { return Err(invalid("Remote Codex TUI no longer owns its title")); }
        let directory = project_path(&identity.working_directory)?;
        if !std::path::Path::new(&directory).starts_with(&state.info.project) { return Err(invalid("Shared Agent conversation belongs to a different project")); }
        if state.info.conversation.as_ref() != Some(identity) || state.agent_owner != Some(owner) {
            if let Some(previous) = &state.info.conversation { self.history.ended(previous, &state.info.session_id)?; }
            self.history.note(identity.clone(), &state.info.project, &state.info.session_id)?;
            state.info.conversation = Some(identity.clone());
            state.agent_owner = Some(owner);
            state.shared_codex = true;
        }
        if state.shared_codex_revision == Some(revision) { return Ok(()); }
        state.shared_codex_revision = Some(revision);
        state.shared_codex_service = Some(service);
        state.records.replace(records);
        state.info.agent_status = state.records.status();
        if ending {
            if let Some(previous) = state.info.conversation.take() { self.history.ended(&previous, &state.info.session_id)?; }
            state.codex_title = None;
            state.shared_codex = false;
            state.shared_codex_revision = None;
            state.shared_codex_service = None;
            state.agent_owner = None;
        }
        broadcast_state(&state);
        Ok(())
    }

    pub fn clear_shared_codex(&self) {
        let mut state = self.state.lock().unwrap();
        if !state.shared_codex { return; }
        state.shared_codex = false;
        state.shared_codex_revision = None;
        state.shared_codex_service = None;
        state.records.reset();
        state.info.agent_status = state.records.status();
        if let Some(previous) = state.info.conversation.take() { let _ = self.history.ended(&previous, &state.info.session_id); }
        state.agent_owner = None;
        broadcast_state(&state);
    }

    fn refresh_agent_owner(&self, state: &mut State) {
        let Some((pid, started)) = state.agent_owner else { return; };
        if agent_process::process(pid).is_some_and(|process| process.started == started)
            && (!state.shared_codex || (state.codex_title.as_ref().is_some_and(|(_, owner)|
                *owner == (pid, started) && agent_process::foreground_agent(state.info.pid, self.pty.foreground_pid(), "codex") == Some(*owner))
                && state.shared_codex_service.is_some_and(|(service, started)| agent_process::process(service).is_some_and(|process| process.started == started)))) { return; }
        state.agent_owner = None;
        state.shared_codex = false;
        state.shared_codex_revision = None;
        state.shared_codex_service = None;
        state.records.drop_live();
        state.info.agent_status = state.records.status();
        if let Some(identity) = state.info.conversation.take() { let _ = self.history.ended(&identity, &state.info.session_id); }
        broadcast_state(state);
    }

    pub fn with_active_client<T>(
        &self,
        client_id: &str,
        action: impl FnOnce(&Arc<Attachment>) -> io::Result<T>,
    ) -> io::Result<T> {
        let state = self.state.lock().unwrap();
        let client = state
            .clients
            .get(client_id)
            .ok_or_else(|| invalid("The paste client is no longer attached"))?;
        if !state.info.running
            || self.terminating.load(Ordering::Acquire)
            || state.info.active_client_id.as_deref() != Some(client_id)
            || client.attachment.closed.load(Ordering::Acquire)
        {
            return Err(invalid(
                "Only the active client of a running session can paste files",
            ));
        }
        action(&client.attachment)
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
        // Titles emitted before attach are absent from the screen-only VT snapshot.
        if let Some(title) = &state.terminal_title {
            let mut frame = Frame::new("snapshot");
            frame.data = Some(STANDARD.encode(format!("\x1b]2;{title}\x1b\\")));
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
        self.refresh_agent_owner(&mut state);
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
            "agentSeen" => {
                if state.info.active_client_id.as_deref() == Some(&attachment.id) {
                    state.records.dismiss_finished();
                    state.info.agent_status = state.records.status();
                    broadcast_state(&state);
                }
            }
            "ping" => {
                self.refresh_profile_context(&mut state);
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
        if self.pty.resize(client.columns, client.rows).is_ok() {
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
            let count = match self.pty.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => count,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) =>
                {
                    continue
                }
                Err(_) => break,
            };
            let mut changed_codex_title = false;
            {
                let bytes = &buffer[..count];
                let mut state = self.state.lock().unwrap();
                let previous = state.info.agent_status.clone();
                for event in state.scanner.scan(bytes) {
                    match event {
                        Osc::Reset => { state.records.reset(); state.codex_title = None; state.terminal_title = None; changed_codex_title = true; }
                        Osc::Title(bytes) => {
                            state.terminal_title = std::str::from_utf8(&bytes).ok()
                                .filter(|title| agent::valid_text(title, 4096)).map(str::to_owned);
                            let title = state.terminal_title.as_deref().and_then(TitleEvidence::parse)
                                .and_then(|title| agent_process::foreground_agent(state.info.pid, self.pty.foreground_pid(), "codex").map(|owner| (title, owner)));
                            if state.codex_title != title { state.codex_title = title; changed_codex_title = true; }
                        }
                        Osc::Body(body) if body.starts_with(b"7501;") => {
                            if let Ok(body) = std::str::from_utf8(&body[5..]) {
                                match agent::parse_status(body, (timestamp() * 1000.0) as u64) {
                                    Some(Report::Query) => { let _ = self.queue_input(agent::QUERY_REPLY.to_vec()); }
                                    Some(Report::Record(record)) => state.records.apply(record),
                                    None => {}
                                }
                            }
                        }
                        Osc::Body(body) if body.starts_with(b"133;A") => {
                            state.records.drop_live();
                            if let Some(identity) = state.info.conversation.take() { let _ = self.history.ended(&identity, &state.info.session_id); }
                            state.agent_owner = None;
                            state.codex_title = None;
                            changed_codex_title = true;
                        }
                        _ => {}
                    }
                }
                state.info.agent_status = state.records.status();
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
                if previous != state.info.agent_status { broadcast_state(&state); }
            }
            if changed_codex_title { if let Some(registry) = self.registry.upgrade() {
                let sessions: Vec<_> = registry.lock().unwrap().values().cloned().collect();
                self.bindings.reconcile(&sessions);
            } }
        }
    }

    pub fn terminate(self: &Arc<Self>) {
        if self.terminating.swap(true, Ordering::AcqRel) {
            return;
        }
        self.pty.terminate(false);
        let session = self.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(500));
            session.pty.terminate(true);
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
