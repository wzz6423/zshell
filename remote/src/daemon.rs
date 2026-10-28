use crate::protocol::*;
use crate::session::{Attachment, Session};
use crate::transport::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::net::{SocketAddr, TcpListener};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub struct Daemon {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    instance_id: String,
}

impl Daemon {
    pub fn new() -> io::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            sessions: Mutex::new(HashMap::new()),
            instance_id: new_id()?,
        }))
    }

    pub fn serve(
        state: &Path,
        listen: Option<u16>,
        tailscale: std::path::PathBuf,
        allow: Vec<String>,
    ) -> io::Result<()> {
        let _lock = lock_state(state)?;
        let path = state.join("control.sock");
        remove_stale_socket(&path)?;
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let daemon = Self::new()?;
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
        for stream in listener.incoming() {
            let stream = stream?;
            if !same_user(&stream) {
                continue;
            }
            let daemon = daemon.clone();
            thread::spawn(move || {
                let _ = daemon.handle(Stream::Unix(stream));
            });
        }
        Ok(())
    }

    pub fn handle(&self, mut stream: Stream) -> io::Result<()> {
        stream.deadlines(Duration::from_secs(10), Duration::from_secs(10))?;
        server_handshake(&mut stream)?;
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
            let response = match self.request(&request) {
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

    pub fn request(&self, request: &Frame) -> io::Result<Value> {
        match request.kind.as_str() {
            "hello" => Ok(
                json!({ "instanceID": self.instance_id, "protocolVersion": VERSION, "platform": std::env::consts::OS }),
            ),
            "projects" => {
                let sessions = self.sessions.lock().unwrap();
                let mut projects: Vec<String> = sessions
                    .values()
                    .map(|session| session.info().project)
                    .collect();
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
                let session = Session::spawn(request)?;
                let info = session.info();
                sessions.insert(id, session);
                Ok(json!(info))
            }
            "get" => Ok(json!(self.session(request)?.info())),
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
