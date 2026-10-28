// Shares CodexTitleSessionEvidence's grammar and two-way unique matching with
// mac/zshell/AgentConversationBinding.swift; prefixes only match verified full IDs.
use crate::agent::{valid_text, Records};
use crate::agent_history::Identity;
use crate::agent_hooks::Hook;
use crate::agent_process;
use crate::protocol::{invalid, is_uuid};
use crate::session::Session;
use serde_json::{json, Value};
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TitleEvidence { pub prefix: String }

impl TitleEvidence {
    pub fn parse(title: &str) -> Option<Self> {
        if !valid_text(title, 4096) { return None; }
        let bytes = title.as_bytes();
        let mut prefixes = Vec::new();
        let token_char = |byte: u8| byte.is_ascii_hexdigit() || byte == b'-' || byte == b'.';
        for start in 0..bytes.len() {
            if start > 0 && (bytes[start - 1].is_ascii_hexdigit() || bytes[start - 1] == b'-') { continue; }
            for length in [36, 32] {
                if start + length > bytes.len() { continue; }
                let token = &bytes[start..start + length];
                if start + length < bytes.len() && token_char(bytes[start + length]) { continue; }
                let count = if length == 32 { 29 } else { 36 };
                if length == 32 && &token[29..] != b"..." { continue; }
                if !(0..count).all(|index| if [8, 13, 18, 23].contains(&index) { token[index] == b'-' } else { token[index].is_ascii_hexdigit() }) { continue; }
                prefixes.push(String::from_utf8(token[..count].to_vec()).ok()?.to_ascii_lowercase());
                break;
            }
        }
        if prefixes.len() == 1 { Some(Self { prefix: prefixes.remove(0) }) } else { None }
    }
    pub fn matches(&self, full_id: &str) -> bool { is_uuid(full_id) && full_id.to_ascii_lowercase().starts_with(&self.prefix) }
}

struct Entry {
    identity: Identity,
    service: (i32, u64),
    updated: Instant,
    records: Records,
    revision: u64,
    ending: bool,
}

#[derive(Default)]
struct State { entries: Vec<Entry>, next_revision: u64 }

#[derive(Default)]
pub struct Bindings { state: Mutex<State> }

impl Bindings {
    pub fn accept(&self, hook: &Hook, peer: Option<i32>, sessions: &[Arc<Session>]) -> io::Result<()> {
        if hook.provider != "codex" { return Err(invalid("Only Codex has a shared native hook service")); }
        let service = peer.and_then(|peer| agent_process::shared_codex_service(peer, hook.reporter_pid))
            .ok_or_else(|| invalid("Shared hook requires the native Codex service process"))?;
        let mut state = self.state.lock().unwrap();
        Self::prune(&mut state.entries, sessions);
        state.next_revision = state.next_revision.wrapping_add(1);
        let revision = state.next_revision;
        let entries = &mut state.entries;
        if let Some(identity) = &hook.identity {
            identity.validate()?;
            if identity.provider != "codex" || hook.event != "SessionStart" || hook.task_id.is_some()
                || !is_uuid(&identity.session_id) { return Err(invalid("Shared binding requires a root Codex SessionStart")); }
            let record = hook.record("idle")?;
            if let Some(entry) = entries.iter_mut().find(|entry| entry.identity == *identity && entry.service == service) {
                entry.updated = Instant::now();
                entry.records.apply(record); entry.revision = revision; entry.ending = false;
            } else {
                if entries.len() == 200 { entries.remove(0); }
                let mut records = Records::default(); records.apply(record);
                entries.push(Entry { identity: identity.clone(), service, updated: Instant::now(), records, revision, ending: false });
            }
            Self::reconcile_entries(entries, sessions);
            return Ok(());
        }
        let id = hook.conversation_id.as_deref().filter(|id| is_uuid(id)).ok_or_else(|| invalid("Shared lifecycle requires the full provider conversation ID"))?;
        let candidates: Vec<_> = entries.iter().enumerate().filter(|(_, entry)| entry.service == service && entry.identity.session_id == id).map(|(index, _)| index).collect();
        if candidates.len() != 1 { return Err(invalid("Shared conversation is ambiguous or no longer bound")); }
        let entry = &mut entries[candidates[0]];
        let record = hook.record(&entry.records.status().phase)?;
        entry.records.apply(record); entry.updated = Instant::now(); entry.revision = revision;
        entry.ending = hook.event == "SessionEnd" && hook.task_id.is_none();
        Self::reconcile_entries(entries, sessions);
        entries.retain(|entry| !entry.ending);
        Ok(())
    }

    pub fn reconcile(&self, sessions: &[Arc<Session>]) {
        let mut state = self.state.lock().unwrap();
        let entries = &mut state.entries;
        Self::prune(entries, sessions);
        Self::reconcile_entries(entries, sessions);
    }

    fn reconcile_entries(entries: &[Entry], sessions: &[Arc<Session>]) {
        // Take process evidence once per pane, rather than once per ID/pane pair.
        let evidence: Vec<_> = sessions.iter().map(|session| session.codex_title_evidence()).collect();
        for (index, session) in sessions.iter().enumerate() {
            let Some(title) = &evidence[index] else { session.clear_shared_codex(); continue; };
            let matches: Vec<_> = entries.iter().filter(|entry| title.matches(&entry.identity.session_id)).collect();
            if matches.len() != 1 {
                session.clear_shared_codex();
                continue;
            }
            let entry = matches[0];
            if evidence.iter().flatten().filter(|other| other.matches(&entry.identity.session_id)).count() != 1 {
                session.clear_shared_codex(); continue;
            }
            if session.sync_shared_codex(&entry.identity, entry.service, &entry.records, entry.revision, entry.ending).is_err() {
                session.clear_shared_codex();
            }
        }
    }

    fn prune(entries: &mut Vec<Entry>, sessions: &[Arc<Session>]) {
        entries.retain(|entry| agent_process::process(entry.service.0).is_some_and(|process| process.started == entry.service.1)
            && (entry.updated.elapsed() < Duration::from_secs(30)
                || sessions.iter().any(|session| session.info().conversation.as_ref() == Some(&entry.identity))));
    }
}

/// Keep Codex's TOML parser and comment-preserving editor as the single source
/// of truth, as in mac/zshell/CodexTitleConfiguration.swift.
pub fn install_title(root: &Path) -> io::Result<()> {
    let config = root.join("config.toml");
    let original = match fs::read(&config) {
        Ok(bytes) if bytes.len() <= 1024 * 1024 => Some(bytes),
        Ok(_) => return Err(invalid("Codex configuration exceeds 1 MiB")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    let configuration = match config_request("config/read", json!({"includeLayers": true}), root) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        result => result?,
    };
    let items = configuration.pointer("/config/tui/terminal_title");
    let mut items = match items {
        None | Some(Value::Null) => vec!["activity".to_string(), "thread-name".into(), "project-name".into()],
        Some(Value::Array(items)) if items.len() <= 64 && items.iter().all(Value::is_string) =>
            items.iter().map(|item| item.as_str().unwrap().to_owned()).collect(),
        _ => return Err(invalid("Codex terminal title items must be a string array")),
    };
    if items.iter().any(|item| item == "session-id") { return Ok(()); }
    items.push("session-id".into());
    let scratch = std::env::temp_dir().join(format!("zshell-codex-title-{}", crate::protocol::new_id()?));
    fs::create_dir(&scratch)?;
    let result = (|| {
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; fs::set_permissions(&scratch, fs::Permissions::from_mode(0o700))?; }
        let path = scratch.join("config.toml");
        if let Some(original) = &original { fs::write(&path, original)?; }
        config_request("config/value/write", json!({"filePath": path, "keyPath": "tui.terminal_title", "mergeStrategy": "replace", "value": items}), &scratch)?;
        let updated = fs::read(&path)?;
        if updated.len() > 1024 * 1024 { return Err(invalid("Updated Codex configuration exceeds 1 MiB")); }
        if fs::read(&config).ok() != original { return Err(invalid("Codex configuration changed during hook installation")); }
        crate::agent_hooks::write_settings(&config, &updated)
    })();
    let _ = fs::remove_dir_all(scratch);
    result
}

fn config_request(method: &str, params: Value, root: &Path) -> io::Result<Value> {
    let mut child = Command::new("codex").args(["app-server", "--listen", "stdio://"])
        .env("CODEX_HOME", root).env_remove("CODEX_THREAD_ID")
        .current_dir(root).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut input = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout.take(2 * 1024 * 1024 + 1));
        loop {
            let mut line = Vec::new();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) => break,
                Ok(_) if line.len() <= 1024 * 1024 => { if sender.send(serde_json::from_slice::<Value>(&line).map_err(invalid)).is_err() { break; } }
                _ => break,
            }
        }
    });
    let result = (|| {
        serde_json::to_writer(&mut input, &json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "zshell", "version": "1"}}})).map_err(invalid)?;
        input.write_all(b"\n")?; input.flush()?;
        let deadline = Instant::now() + Duration::from_secs(5);
        for id in [1, 2] {
            loop {
                let response = receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()))
                    .map_err(|_| invalid("Codex terminal title configuration timed out"))??;
                if response.get("id").and_then(Value::as_u64) != Some(id) { continue; }
                let result = response.get("result").ok_or_else(|| invalid("Codex rejected terminal title configuration"))?;
                if id == 2 { return Ok(result.clone()); }
                input.write_all(b"{\"method\":\"initialized\",\"params\":{}}\n")?;
                serde_json::to_writer(&mut input, &json!({"id": 2, "method": method, "params": params})).map_err(invalid)?;
                input.write_all(b"\n")?; input.flush()?;
                break;
            }
        }
        Err(invalid("Codex did not return terminal title configuration"))
    })();
    drop(input);
    let _ = child.kill(); let _ = child.wait();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_the_shared_swift_title_vectors() {
        let first = "550e8400-e29b-41d4-a716-446655440000";
        let second = "550e8400-e29b-41d4-b716-446655440000";
        let title = format!("Fix login | project | {}...", &first[..29]);
        let evidence = TitleEvidence::parse(&title).unwrap();
        assert!(evidence.matches(first));
        assert!(!evidence.matches(second));
        assert!(evidence.matches(&format!("{}9999999", &first[..29])));
        assert!(TitleEvidence::parse(first).unwrap().matches(first));
        assert!(TitleEvidence::parse(&format!("{title} | {second}")).is_none());
        assert!(TitleEvidence::parse(&format!("\x1b{title}")).is_none());
        assert!(TitleEvidence::parse(&format!("{}...", &first[..20])).is_none());
    }
}
