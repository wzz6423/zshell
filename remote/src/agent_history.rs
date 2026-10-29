// Conversation storage and exact provider resume arguments follow egoist/kero
// internal/daemon/conversations.go at 580bdfa8f6a43d71d145958ab76c1bbb45c465f0 (MIT).
use crate::agent::{neutralize, valid_text};
use crate::protocol::{invalid, is_uuid, new_id};
use crate::transport::{prepare_state, project_path};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_CONVERSATIONS: usize = 200;
const MAX_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    pub provider: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub working_directory: String,
    pub config_directory: Option<String>,
    pub session_file: Option<String>,
    pub alias: Option<String>,
    pub configuration_environment: Option<BTreeMap<String, String>>,
}

impl Identity {
    pub fn validate(&self) -> io::Result<()> {
        let id_valid = match self.provider.as_str() {
            "claude" | "codex" | "pi" => is_uuid(&self.session_id),
            "opencode" => self.session_id.starts_with("ses_") && (5..=128).contains(&self.session_id.len())
                && self.session_id[4..].bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)),
            _ => false,
        };
        if !id_valid || !absolute_path(&self.working_directory)
            || self.config_directory.as_deref().is_some_and(|p| !absolute_path(p))
            || self.session_file.as_deref().is_some_and(|p| self.provider != "pi" || !absolute_path(p) || !p.ends_with(".jsonl"))
            || self.alias.as_deref().is_some_and(|s| s.is_empty() || !valid_text(s, 128))
            || self.configuration_environment.as_ref().is_some_and(|values| values.len() > 6
                || values.iter().any(|(key, value)| !configuration_keys(&self.provider).contains(&key.as_str()) || !absolute_path(value))) {
            return Err(invalid("Invalid provider conversation identity"));
        }
        Ok(())
    }

    pub fn resume(&self) -> io::Result<(Vec<String>, BTreeMap<String, String>)> {
        self.validate()?;
        project_path(&self.working_directory)?;
        if self.config_directory.as_deref().is_some_and(|path| !Path::new(path).is_dir()) {
            return Err(invalid("The provider configuration directory is unavailable"));
        }
        let mut arguments: Vec<String> = match self.provider.as_str() {
            "claude" => vec!["claude".into(), "--resume".into(), self.session_id.clone()],
            "codex" => vec!["codex".into(), "resume".into(), self.session_id.clone()],
            "opencode" => vec!["opencode".into(), "--session".into(), self.session_id.clone()],
            "pi" => {
                let path = self.session_file.as_deref().ok_or_else(|| invalid("The Pi session file is unavailable"))?;
                let mut file = File::open(path)?;
                let mut bytes = Vec::new();
                (&mut file).take(16384).read_to_end(&mut bytes)?;
                let header: serde_json::Value = serde_json::from_slice(bytes.split(|b| *b == b'\n').next().unwrap_or(&[])).map_err(invalid)?;
                if header["type"] != "session" || header["id"] != self.session_id || header["cwd"] != self.working_directory {
                    return Err(invalid("The Pi session file belongs to a different conversation"));
                }
                vec!["pi".into(), "--session".into(), path.into()]
            }
            _ => return Err(invalid("Unsupported provider")),
        };
        arguments[0] = executable(&arguments[0])?;
        let mut environment = self.configuration_environment.clone().unwrap_or_default();
        if let Some(directory) = &self.config_directory {
            environment.entry(configuration_keys(&self.provider)[0].into()).or_insert(directory.clone());
        }
        Ok((arguments, environment))
    }

    pub fn fork(&self) -> io::Result<(Vec<String>, BTreeMap<String, String>)> {
        let (resume, environment) = self.resume()?;
        self.check_fork_support(&resume[0], &environment, Duration::from_secs(8))?;
        let mut arguments = vec![resume[0].clone()];
        match self.provider.as_str() {
            "claude" => arguments.extend(["--resume".into(), self.session_id.clone(), "--fork-session".into()]),
            "codex" => arguments.extend(["fork".into(), self.session_id.clone()]),
            "opencode" => arguments.extend(["--session".into(), self.session_id.clone(), "--fork".into()]),
            "pi" => arguments.extend(["--fork".into(), self.session_file.clone().unwrap()]),
            _ => return Err(invalid("Unsupported provider")),
        }
        Ok((arguments, environment))
    }

    pub fn accepts_fork(&self, identity: &Self) -> bool {
        self.provider == identity.provider
            && (if self.provider == "opencode" { self.session_id != identity.session_id }
                else { !self.session_id.eq_ignore_ascii_case(&identity.session_id) })
            && self.working_directory == identity.working_directory
            && self.config_directory.as_ref().is_none_or(|directory| identity.config_directory.as_ref() == Some(directory))
            && self.configuration_environment.as_ref().is_none_or(|values| values.iter().all(|(key, value)|
                identity.configuration_environment.as_ref().and_then(|environment| environment.get(key)) == Some(value)))
            && (self.provider != "pi" || identity.session_file.is_some() && self.session_file != identity.session_file)
    }

    fn check_fork_support(&self, executable: &str, environment: &BTreeMap<String, String>, timeout: Duration) -> io::Result<()> {
        let mut command = Command::new(executable);
        if self.provider == "codex" { command.arg("fork"); }
        for key in configuration_keys(&self.provider) { command.env_remove(key); }
        let mut child = command.arg("--help").envs(environment).env_remove("CODEX_THREAD_ID")
            .current_dir(&self.working_directory).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
        let (sender, receiver) = mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        for stream in [Box::new(stdout) as Box<dyn Read + Send>, Box::new(stderr)] {
            let sender = sender.clone();
            std::thread::spawn(move || {
                let mut bytes = Vec::new();
                let result = stream.take(65_537).read_to_end(&mut bytes).map(|_| bytes);
                let _ = sender.send(result);
            });
        }
        drop(sender);
        let deadline = Instant::now() + timeout;
        let result = (|| {
            loop {
                if let Some(status) = child.try_wait()? {
                    if !status.success() { return Err(invalid("The provider CLI could not confirm native fork support; check its installation and fork command or option")); }
                    break;
                }
                if Instant::now() >= deadline { return Err(invalid("Checking the provider's native fork support timed out")); }
                std::thread::sleep(Duration::from_millis(20));
            }
            let mut output = Vec::new();
            for _ in 0..2 {
                let bytes = receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()))
                    .map_err(|_| invalid("Checking the provider's native fork support timed out"))??;
                output.extend(bytes);
                output.push(b'\n');
                if output.len() > 65_536 { return Err(invalid("The provider's fork help exceeded the output limit")); }
            }
            if !supports_native_fork(&self.provider, &String::from_utf8_lossy(&output)) {
                return Err(invalid("The provider CLI does not advertise native fork support; update its installation"));
            }
            Ok(())
        })();
        let _ = child.kill();
        let _ = child.wait();
        result
    }
}

fn supports_native_fork(provider: &str, help: &str) -> bool {
    match provider {
        "codex" => help.contains("Usage: codex fork") && help.contains("SESSION_ID"),
        "claude" => help.split_whitespace().any(|word| word == "--fork-session"),
        "opencode" | "pi" => help.split_whitespace().any(|word| word == "--fork"),
        _ => false,
    }
}

pub fn configuration_keys(provider: &str) -> &'static [&'static str] {
    match provider {
        "claude" => &["CLAUDE_CONFIG_DIR"], "codex" => &["CODEX_HOME"], "pi" => &["PI_CODING_AGENT_DIR"],
        "opencode" => &["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG"],
        _ => &[],
    }
}

fn executable(name: &str) -> io::Result<String> {
    let paths = std::env::var_os("PATH").ok_or_else(|| invalid("PATH is unavailable"))?;
    for directory in std::env::split_paths(&paths) {
        let path = directory.join(name);
        if !path.is_file() || path.metadata()?.mode() & 0o111 == 0 { continue; }
        return path.to_str().map(str::to_owned).ok_or_else(|| invalid("Provider executable must be UTF-8"));
    }
    Err(invalid(format!("{name} is not installed on this host")))
}

fn absolute_path(path: &str) -> bool {
    Path::new(path).is_absolute() && valid_text(path, 4096)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub identity: Identity,
    pub project: String,
    #[serde(rename = "remoteSessionID")]
    pub remote_session_id: String,
    pub started_at: f64,
    pub updated_at: f64,
    pub ended_at: Option<f64>,
    pub title: Option<String>,
}

pub struct History {
    path: PathBuf,
    records: Mutex<Vec<Conversation>>,
}

impl History {
    pub fn open(state: &Path) -> io::Result<Arc<Self>> {
        prepare_state(state)?;
        let path = state.join("conversations.json");
        let records = match private_read(&path) {
            Ok(bytes) => {
                let values: Vec<Conversation> = serde_json::from_slice(&bytes).map_err(invalid)?;
                if values.len() > MAX_CONVERSATIONS { return Err(invalid("Remote conversation history exceeds its record limit")); }
                let mut valid = Vec::<Conversation>::new();
                for mut record in values {
                    if record.identity.validate().is_err() || !is_uuid(&record.remote_session_id)
                        || !absolute_path(&record.project) || !record.started_at.is_finite() || !record.updated_at.is_finite()
                        || record.started_at < 0.0 || record.updated_at < record.started_at
                        || record.ended_at.is_some_and(|at| !at.is_finite() || at < record.started_at)
                        || valid.iter().any(|previous| previous.identity == record.identity) { continue; }
                    if record.ended_at.is_none() { record.ended_at = Some(record.updated_at); }
                    record.title = record.title.filter(|text| valid_text(text, 256)).map(|text| neutralize(&text));
                    valid.push(record);
                }
                valid
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        Ok(Arc::new(Self { path, records: Mutex::new(records) }))
    }

    pub fn list(&self, project: &str) -> Vec<Conversation> {
        self.records.lock().unwrap().iter().filter(|record| record.project == project).cloned().collect()
    }

    pub fn projects(&self) -> Vec<String> {
        self.records.lock().unwrap().iter().map(|record| record.project.clone()).collect()
    }

    pub fn note(&self, identity: Identity, project: &str, session: &str) -> io::Result<()> {
        identity.validate()?;
        let now = timestamp();
        let mut records = self.records.lock().unwrap();
        let existing = records.iter().position(|record| record.identity == identity);
        let previous = existing.map(|index| records.remove(index));
        records.insert(0, Conversation {
            identity, project: project.into(), remote_session_id: session.into(),
            started_at: previous.as_ref().map_or(now, |record| record.started_at), updated_at: now,
            ended_at: None, title: previous.and_then(|record| record.title),
        });
        records.truncate(MAX_CONVERSATIONS);
        private_write(&self.path, &serde_json::to_vec(&*records).map_err(invalid)?)
    }

    pub fn ended(&self, identity: &Identity, session: &str) -> io::Result<()> {
        let mut records = self.records.lock().unwrap();
        let Some(record) = records.iter_mut().find(|record| record.identity == *identity && record.remote_session_id == session) else { return Ok(()) };
        if record.ended_at.is_some() { return Ok(()); }
        record.updated_at = timestamp();
        record.ended_at = Some(record.updated_at);
        private_write(&self.path, &serde_json::to_vec(&*records).map_err(invalid)?)
    }

    pub fn find(&self, project: &str, provider: &str, session: &str) -> io::Result<Conversation> {
        self.records.lock().unwrap().iter().find(|record| record.project == project
            && record.identity.provider == provider && record.identity.session_id == session).cloned()
            .ok_or_else(|| invalid("Conversation is not in this remote project"))
    }
}

pub fn timestamp() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }

fn private_read(path: &Path) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC).open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o777 != 0o600 {
        return Err(invalid("Remote conversations must be an owner-only 0600 file"));
    }
    bounded_read(file)
}

fn bounded_read(file: File) -> io::Result<Vec<u8>> {
    if file.metadata()?.len() > MAX_BYTES { return Err(invalid("Remote conversation history exceeds 2 MiB")); }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BYTES { return Err(invalid("Remote conversation history exceeds 2 MiB")); }
    Ok(bytes)
}

fn private_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if bytes.len() as u64 > MAX_BYTES { return Err(invalid("Remote conversation history exceeds 2 MiB")); }
    let temporary = path.with_file_name(format!(".conversations-{}", new_id()?));
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(temporary); }
    result
}

#[cfg(test)]
mod fork_tests {
    use super::*;

    #[test]
    fn native_fork_help_requires_exact_command_or_option() {
        assert!(supports_native_fork("codex", "Usage: codex fork [OPTIONS] [SESSION_ID]"));
        assert!(!supports_native_fork("codex", "Usage: codex resume [SESSION_ID]"));
        assert!(supports_native_fork("claude", "Options:\n --fork-session Use a new session ID"));
        assert!(!supports_native_fork("claude", "Options:\n --resume [id]"));
        for provider in ["pi", "opencode"] {
            assert!(supports_native_fork(provider, " --fork <path|id>"));
            assert!(!supports_native_fork(provider, " --fork-other <path|id>"));
        }
    }

    #[test]
    fn fork_identity_requires_independent_id_and_original_scope() {
        let source = Identity { provider: "claude".into(), session_id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa".into(),
            working_directory: "/tmp/project".into(), config_directory: Some("/tmp/profile".into()),
            session_file: None, alias: None, configuration_environment: None };
        let mut fork = source.clone();
        assert!(!source.accepts_fork(&fork));
        fork.session_id = source.session_id.to_uppercase();
        assert!(!source.accepts_fork(&fork));
        fork.session_id = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb".into();
        assert!(source.accepts_fork(&fork));
        fork.working_directory = "/tmp/other".into();
        assert!(!source.accepts_fork(&fork));
        fork.working_directory = source.working_directory.clone();
        fork.config_directory = None;
        assert!(!source.accepts_fork(&fork));
        let source = Identity { provider: "pi".into(), session_file: Some("/tmp/source.jsonl".into()), ..source };
        let mut fork = Identity { session_id: fork.session_id, ..source.clone() };
        assert!(!source.accepts_fork(&fork));
        fork.session_file = Some("/tmp/fork.jsonl".into());
        assert!(source.accepts_fork(&fork));
    }
}
