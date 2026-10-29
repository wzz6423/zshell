use crate::paste::{PasteBatch, PasteStore};
use crate::agent_history::History;
use crate::codex_binding::Bindings;
use crate::protocol::*;
use crate::session::{Attachment, Session};
use crate::transport::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io;
use std::net::{SocketAddr, TcpListener};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub struct Daemon {
    sessions: Arc<Mutex<HashMap<String, Arc<Session>>>>,
    instance_id: String,
    paste_store: PasteStore,
    state_path: std::path::PathBuf,
    history: Arc<History>,
    bindings: Arc<Bindings>,
}

struct PendingPaste {
    session: Arc<Session>,
    attachment: Arc<Attachment>,
    client_id: String,
    batch: PasteBatch,
}

impl Daemon {
    pub fn new(state: &Path) -> io::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            instance_id: new_id()?,
            paste_store: PasteStore::new(state)?,
            state_path: state.into(),
            history: History::open(state)?,
            bindings: Arc::new(Bindings::default()),
        }))
    }

    pub fn serve(
        state: &Path,
        listen: Option<u16>,
        tailscale: std::path::PathBuf,
        allow: Vec<String>,
    ) -> io::Result<()> {
        let _lock = lock_state(state)?;
        let mut listener = LocalListener::bind(state)?;
        let daemon = Self::new(state)?;
        if let Some(port) = listen {
            let policy = Arc::new(TailnetPolicy {
                executable: tailscale,
                allow,
            });
            for ip in policy.addresses()? {
                let listener = TcpListener::bind(SocketAddr::new(ip, port))?;
                let policy = policy.clone();
                let daemon = daemon.clone();
                thread::spawn(move || {
                    for stream in listener.incoming().flatten() {
                        let daemon = daemon.clone();
                        let policy = policy.clone();
                        thread::spawn(move || {
                            let Ok(peer) = stream.peer_addr() else {
                                return;
                            };
                            if policy.authorize(peer).is_err() {
                                return;
                            }
                            let _ = daemon.handle(Stream::Tcp(stream));
                        });
                    }
                });
            }
        }
        loop {
            let stream = listener.accept()?;
            let daemon = daemon.clone();
            thread::spawn(move || {
                let _ = daemon.handle(stream);
            });
        }
    }

    pub fn handle(&self, mut stream: Stream) -> io::Result<()> {
        stream.deadlines(Duration::from_secs(10), Duration::from_secs(10))?;
        server_handshake(&mut stream)?;
        let mut pending_paste = None;
        loop {
            let request = read_frame(&mut stream)?;
            if request.kind == "attach" {
                let result = self.session(&request).and_then(|session| {
                    let client_id = request
                        .client_id
                        .as_deref()
                        .ok_or_else(|| invalid("A client ID is required"))?;
                    if !is_uuid(client_id) {
                        return Err(invalid("Invalid client ID"));
                    }
                    stream.deadlines(Duration::from_secs(30), Duration::from_secs(10))?;
                    let attachment = Attachment::new(client_id.to_ascii_lowercase(), &stream)?;
                    if let Err(error) = session.attach(attachment.clone(), &request) {
                        session.detach(&attachment);
                        attachment.disconnect();
                        return Err(error);
                    }
                    loop {
                        match read_frame(&mut stream) {
                            Ok(frame) if frame.kind == "detach" => break,
                            Ok(frame) => {
                                if let Err(error) = session.handle(&attachment, &frame) {
                                    attachment.send(Frame::failure(&frame, error), false);
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    session.detach(&attachment);
                    attachment.disconnect();
                    Ok(())
                });
                if let Err(error) = result {
                    let _ = write_frame(&mut stream, &Frame::failure(&request, error));
                }
                return Ok(());
            }
            let result = if request.kind.starts_with("paste") {
                let result = self.paste_request(&request, &mut pending_paste);
                if result.is_err() {
                    pending_paste = None;
                }
                result
            } else {
                if request.kind == "agentHook" {
                    let hook = request.hook.as_ref().ok_or_else(|| invalid("A native Agent hook is required"));
                    hook.and_then(|hook| {
                        if hook.provider == "codex" && stream.peer_pid().and_then(|peer| crate::agent_process::shared_codex_service(peer, hook.reporter_pid)).is_some() {
                            let sessions: Vec<_> = self.sessions.lock().unwrap().values().cloned().collect();
                            self.bindings.accept(hook, stream.peer_pid(), &sessions)?;
                        } else { self.session(&request)?.accept_hook(hook, stream.peer_pid())?; }
                        Ok(json!({"accepted": true}))
                    })
                } else { self.request(&request) }
            };
            let response = match result {
                Ok(result) => Frame::success(&request, result),
                Err(error) => Frame::failure(&request, error),
            };
            write_frame(&mut stream, &response)?;
            if request.kind == "shutdown" && response.error.is_none() {
                thread::sleep(Duration::from_millis(600));
                std::process::exit(0);
            }
        }
    }

    fn paste_request(
        &self,
        request: &Frame,
        pending: &mut Option<PendingPaste>,
    ) -> io::Result<Value> {
        let session = self.session(request)?;
        let client_id = request
            .client_id
            .as_deref()
            .filter(|id| is_uuid(id))
            .ok_or_else(|| invalid("A valid paste client ID is required"))?
            .to_ascii_lowercase();
        let attachment =
            session.with_active_client(&client_id, |attachment| Ok(attachment.clone()))?;
        if request.kind == "pasteStart" {
            if pending.is_some() {
                return Err(invalid("A paste upload is already in progress"));
            }
            let batch = self
                .paste_store
                .begin(request.paste_files.as_deref().unwrap_or(&[]))?;
            let upload_id = batch.id.clone();
            *pending = Some(PendingPaste {
                session,
                attachment,
                client_id,
                batch,
            });
            return Ok(json!({ "uploadId": upload_id }));
        }
        let upload = pending
            .as_mut()
            .ok_or_else(|| invalid("Start a paste upload first"))?;
        if !Arc::ptr_eq(&upload.session, &session)
            || !Arc::ptr_eq(&upload.attachment, &attachment)
            || upload.client_id != client_id
            || request.upload_id.as_deref() != Some(&upload.batch.id)
        {
            return Err(invalid(
                "Paste upload belongs to a different session or client",
            ));
        }
        match request.kind.as_str() {
            "pasteChunk" => upload.batch.write(request),
            "pasteCommit" => {
                upload.batch.prepare_commit()?;
                // The rename is the only filesystem operation under the session
                // lock: claim/detach cannot race a successful commit.
                session.with_active_client(&client_id, |current| {
                    if !Arc::ptr_eq(current, &upload.attachment) {
                        return Err(invalid("The paste attachment was replaced"));
                    }
                    upload.batch.commit()
                })
            }
            "pasteAbort" => {
                *pending = None;
                Ok(json!({ "aborted": true }))
            }
            _ => Err(invalid("Unknown paste request")),
        }
    }

    pub fn request(&self, request: &Frame) -> io::Result<Value> {
        match request.kind.as_str() {
            "hello" => Ok(
                json!({ "instanceID": self.instance_id, "protocolVersion": VERSION, "platform": std::env::consts::OS,
                    "daemonPID": std::process::id(), "capabilities": ["agentHistory", "agentResume", "processes"] }),
            ),
            "projects" => {
                let sessions = self.sessions.lock().unwrap();
                let mut projects: Vec<String> = sessions
                    .values()
                    .map(|session| session.info().project)
                    .collect();
                projects.extend(self.history.projects());
                projects.sort();
                projects.dedup();
                Ok(json!(projects))
            }
            "list" => {
                let project = project_path(
                    request
                        .project
                        .as_deref()
                        .ok_or_else(|| invalid("A project directory is required"))?,
                )?;
                let sessions = self.sessions.lock().unwrap();
                let mut infos: Vec<_> = sessions
                    .values()
                    .map(|session| session.info())
                    .filter(|info| info.project == project)
                    .collect();
                infos.sort_by(|first, second| first.started_at.total_cmp(&second.started_at));
                Ok(json!(infos))
            }
            "agentHistory" => {
                let project = project_path(request.project.as_deref().ok_or_else(|| invalid("A project directory is required"))?)?;
                Ok(json!(self.history.list(&project)))
            }
            "agentResume" => {
                let project = project_path(request.project.as_deref().ok_or_else(|| invalid("A project directory is required"))?)?;
                let provider = request.provider.as_deref().ok_or_else(|| invalid("A provider is required"))?;
                let id = request.conversation_id.as_deref().ok_or_else(|| invalid("An exact provider conversation ID is required"))?;
                let record = self.history.find(&project, provider, id)?;
                let mut sessions = self.sessions.lock().unwrap();
                if let Some(session) = sessions.values().find(|session| {
                    let info = session.info();
                    info.project == project && info.running && info.conversation.as_ref() == Some(&record.identity)
                }) { return Ok(json!(session.info())); }
                let (command, environment) = record.identity.resume()?;
                let mut create = Frame::new("create");
                create.project = Some(project);
                create.working_directory = Some(record.identity.working_directory.clone());
                create.session_id = Some(new_id()?);
                create.command = Some(command);
                create.environment = Some(environment);
                if sessions.len() >= MAX_SESSIONS { return Err(invalid("Remote session limit reached")); }
                let session = Session::spawn(&create, &self.state_path, self.history.clone(), self.bindings.clone(), Arc::downgrade(&self.sessions))?;
                let info = session.info();
                sessions.insert(info.session_id.clone(), session);
                Ok(json!(info))
            }
            "create" => {
                let id = request
                    .session_id
                    .as_deref()
                    .ok_or_else(|| invalid("A session ID is required"))?
                    .to_ascii_lowercase();
                if !is_uuid(&id) {
                    return Err(invalid("Invalid session ID"));
                }
                let project = project_path(
                    request
                        .project
                        .as_deref()
                        .ok_or_else(|| invalid("A project directory is required"))?,
                )?;
                let mut sessions = self.sessions.lock().unwrap();
                if let Some(session) = sessions.get(&id) {
                    if session.info().project != project {
                        return Err(invalid("Session belongs to a different project"));
                    }
                    return Ok(json!(session.info()));
                }
                if sessions.len() >= MAX_SESSIONS {
                    return Err(invalid(
                        "Remote session limit reached; end an unused session first",
                    ));
                }
                let session = Session::spawn(request, &self.state_path, self.history.clone(), self.bindings.clone(), Arc::downgrade(&self.sessions))?;
                let info = session.info();
                sessions.insert(id, session);
                Ok(json!(info))
            }
            "get" => Ok(json!(self.session(request)?.info())),
            "processes" => {
                let info = self.session(request)?.info();
                if !info.running {
                    return Ok(json!([]));
                }
                Ok(json!(crate::processes::descendants(info.pid)?))
            }
            "terminate" => {
                let session = self.session(request)?;
                session.terminate();
                self.sessions
                    .lock()
                    .unwrap()
                    .remove(&session.info().session_id);
                Ok(json!({ "terminated": true }))
            }
            "shutdown" => {
                for session in self.sessions.lock().unwrap().values() {
                    session.terminate();
                }
                Ok(json!({ "stopped": true }))
            }
            _ => Err(invalid("Unknown remote request")),
        }
    }

    fn session(&self, request: &Frame) -> io::Result<Arc<Session>> {
        let project = project_path(
            request
                .project
                .as_deref()
                .ok_or_else(|| invalid("A project directory is required"))?,
        )?;
        let id = request
            .session_id
            .as_deref()
            .ok_or_else(|| invalid("A session ID is required"))?
            .to_ascii_lowercase();
        let session = self
            .sessions
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| {
                invalid("Remote session is unavailable; create a new session explicitly")
            })?;
        if session.info().project != project {
            return Err(invalid("Session belongs to a different project"));
        }
        Ok(session)
    }
}
