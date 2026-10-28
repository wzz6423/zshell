use crate::agent::{neutralize, valid_text, Record};
use crate::agent_history::{configuration_keys, timestamp, Identity};
use crate::protocol::{invalid, new_id, Frame};
use crate::{agent_process, codex_binding};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hook {
    pub provider: String,
    pub token: String,
    pub reporter_pid: i32,
    pub event: String,
    pub identity: Option<Identity>,
    pub conversation_id: Option<String>,
    pub phase: Option<String>,
    pub attention: Option<String>,
    pub task_id: Option<String>,
    pub task_title: Option<String>,
    pub reason: Option<String>,
}

impl Hook {
    pub fn record(&self, previous: &str) -> io::Result<Record> {
        if configuration_keys(&self.provider).is_empty()
            || self.task_id.as_deref().is_some_and(|text| text.is_empty() || !valid_text(text, 128))
            || self.task_title.as_deref().is_some_and(|text| !valid_text(text, 256))
            || self.reason.as_deref().is_some_and(|text| !valid_text(text, 1024)) { return Err(invalid("Invalid native Agent event")); }
        let (phase, attention) = if let Some(phase) = self.phase.as_deref() {
            if !["working", "blocked", "idle", "done"].contains(&phase) { return Err(invalid("Invalid native Agent phase")); }
            (phase, self.attention.as_deref())
        } else {
            match self.event.as_str() {
                "SessionStart" => ("idle", None),
                "UserPromptSubmit" | "PostToolUse" | "PreToolUse" | "PostCompact" | "ElicitationResult" => ("working", None),
                "PermissionRequest" => ("blocked", Some("approval")),
                "Elicitation" => ("blocked", Some("input")),
                "StopFailure" => ("blocked", Some("error")),
                "SubagentStart" => ("working", None),
                "SubagentStop" => ("done", None),
                "Stop" if ["working", "blocked"].contains(&previous) => ("done", None),
                "Stop" | "Interrupt" | "SessionEnd" => ("idle", None),
                _ => return Err(invalid("Unsupported native Agent event")),
            }
        };
        if attention.is_some_and(|text| phase != "blocked" || !["approval", "input", "login", "error"].contains(&text)) {
            return Err(invalid("Invalid native Agent attention"));
        }
        Ok(Record {
            id: self.task_id.as_ref().map(|id| format!("native/{}", id.replace('/', "_"))).unwrap_or_else(|| "native".into()),
            state: phase.into(), app: self.provider.clone(),
            message: self.reason.as_deref().map(neutralize).unwrap_or_else(|| format!("{}: {}", self.provider, self.event)),
            title: self.task_title.as_deref().map(neutralize).unwrap_or_default(),
            kind: match attention { Some("approval") => "permission", Some("input") => "question", Some("login") => "auth", Some("error") => "error", _ => "" }.into(),
            progress: None, updated_at: (timestamp() * 1000.0) as u64,
        })
    }
}

pub fn invocation(provider: &str, payload: &[u8], environment: &BTreeMap<String, String>, reporter_pid: i32) -> io::Result<Option<Frame>> {
    if configuration_keys(provider).is_empty() || payload.len() > 1024 * 1024 || reporter_pid <= 1 { return Ok(None); }
    let shared = provider == "codex" && agent_process::shared_codex_service(reporter_pid, reporter_pid).is_some();
    let token = environment.get("ZSHELL_AUTOMATION_TOKEN");
    let terminal = environment.get("ZSHELL_TERMINAL_ID");
    let project = environment.get("ZSHELL_REMOTE_PROJECT");
    if !shared && (token.is_none() || terminal.is_none() || project.is_none()) { return Ok(None); }
    let fields: Value = serde_json::from_slice(payload).map_err(invalid)?;
    let params = fields.get("params").unwrap_or(&fields);
    let event = fields.get("hook_event_name").and_then(Value::as_str).unwrap_or_else(|| {
        match fields.get("method").and_then(Value::as_str) { Some("agent.session.start") => "SessionStart", Some("agent.session.clear") => "SessionEnd", _ => "Lifecycle" }
    });
    if params.get("provider").and_then(Value::as_str).is_some_and(|reported| reported != provider) { return Ok(None); }
    let task = fields.get("agent_id").and_then(Value::as_str).filter(|id| !id.is_empty());
    if event == "SessionStart" && (task.is_some() || fields.get("parent_session_id").and_then(Value::as_str).is_some_and(|id| !id.is_empty())) { return Ok(None); }
    let identity = if event == "SessionStart" {
        if let Some(value) = params.get("identity") {
            let identity: Identity = serde_json::from_value(value.clone()).map_err(invalid)?;
            if identity.provider != provider { return Ok(None); }
            Some(identity)
        } else {
            let session = fields.get("session_id").and_then(Value::as_str).ok_or_else(|| invalid("Missing provider session ID"))?;
            if provider == "codex" && !shared && environment.get("CODEX_THREAD_ID").is_some_and(|thread| !thread.is_empty() && thread != session) { return Ok(None); }
            let home = std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| invalid("HOME is unavailable"))?;
            let key = configuration_keys(provider)[0];
            let directory = environment.get(key).map(PathBuf::from).unwrap_or_else(|| home.join(match provider {
                "claude" => ".claude", "codex" => ".codex", "pi" => ".pi/agent", _ => ".config",
            }));
            Some(Identity {
                provider: provider.into(), session_id: session.into(),
                working_directory: fields.get("cwd").and_then(Value::as_str).or(project.map(String::as_str))
                    .ok_or_else(|| invalid("Missing provider working directory"))?.into(),
                config_directory: directory.to_str().map(str::to_owned), session_file: fields.get("session_file").and_then(Value::as_str).map(str::to_owned), alias: None,
                configuration_environment: Some(environment.iter().filter(|(key, value)| configuration_keys(provider).contains(&key.as_str()) && Path::new(value).is_absolute()).map(|(k, v)| (k.clone(), v.clone())).collect()),
            })
        }
    } else { None };
    if let Some(identity) = &identity { identity.validate()?; }
    let mut phase = params.get("state").and_then(Value::as_str).map(str::to_owned);
    let mut attention = params.get("attention").and_then(Value::as_str).map(str::to_owned);
    if event == "PreToolUse" && ["AskUserQuestion", "request_user_input"].contains(&fields.get("tool_name").and_then(Value::as_str).unwrap_or("")) {
        phase = Some("blocked".into()); attention = Some("input".into());
    }
    if event == "Notification" {
        match fields.get("notification_type").and_then(Value::as_str) {
            Some("permission_prompt") => { phase = Some("blocked".into()); attention = Some("approval".into()); }
            Some("elicitation_dialog" | "agent_needs_input") => { phase = Some("blocked".into()); attention = Some("input".into()); }
            Some("auth_success") => phase = Some("idle".into()),
            _ => return Ok(None),
        }
    }
    if event == "StopFailure" && fields.get("error").and_then(Value::as_str) == Some("authentication_failed") {
        phase = Some("blocked".into()); attention = Some("login".into());
    }
    let hook = Hook { provider: provider.into(), token: token.cloned().unwrap_or_default(), reporter_pid, event: event.into(), identity,
        conversation_id: fields.get("session_id").and_then(Value::as_str).map(str::to_owned),
        phase, attention, task_id: task.map(str::to_owned), task_title: fields.get("agent_type").and_then(Value::as_str).map(str::to_owned),
        reason: params.get("reason").and_then(Value::as_str).map(str::to_owned) };
    let mut frame = Frame::new("agentHook"); frame.request_id = Some(new_id()?);
    frame.project = project.cloned(); frame.session_id = terminal.cloned(); frame.hook = Some(hook);
    Ok(Some(frame))
}

pub fn install(state: &Path) -> io::Result<Value> {
    let executable = std::env::current_exe()?;
    let state = if state.is_absolute() { state.to_path_buf() } else { std::env::current_dir()?.join(state) };
    let home = std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| invalid("HOME is unavailable"))?;
    let mut results = Vec::new();
    for provider in ["claude", "codex"] {
        let key = configuration_keys(provider)[0];
        let root = std::env::var_os(key).map(PathBuf::from).unwrap_or_else(|| home.join(format!(".{provider}")));
        fs::create_dir_all(&root)?;
        let path = root.join(if provider == "codex" { "hooks.json" } else { "settings.json" });
        let mut settings: Value = match fs::read(&path) {
            Ok(bytes) if bytes.len() <= 1024 * 1024 => serde_json::from_slice(&bytes).map_err(invalid)?,
            Ok(_) => return Err(invalid("Provider hook settings exceed 1 MiB")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => json!({}), Err(error) => return Err(error),
        };
        let object = settings.as_object_mut().ok_or_else(|| invalid("Provider settings must be a JSON object"))?;
        let hooks = object.entry("hooks").or_insert_with(|| json!({})).as_object_mut().ok_or_else(|| invalid("Provider hooks must be a JSON object"))?;
        // A managed Codex daemon may predate every terminal and inherit no pane
        // environment. The installed hook still connects only to this server.
        let command = format!("'{}' --state '{}' hook {provider}", executable.to_string_lossy().replace('\'', "'\\''"), state.to_string_lossy().replace('\'', "'\\''"));
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd", "SubagentStart", "SubagentStop", "Elicitation", "ElicitationResult", "StopFailure", "Notification", "Interrupt"] {
            if provider == "codex" && ["Elicitation", "ElicitationResult", "StopFailure", "Notification"].contains(&event) { continue; }
            if provider == "claude" && event == "Interrupt" { continue; }
            let entries = hooks.entry(event).or_insert_with(|| json!([])).as_array_mut().ok_or_else(|| invalid("Provider hook event must be an array"))?;
            entries.retain_mut(|group| {
                if let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) {
                    handlers.retain(|handler| !handler.get("command").and_then(Value::as_str).is_some_and(|text| text.contains("zshell-server") && text.ends_with(&format!(" hook {provider}"))));
                    !handlers.is_empty()
                } else { true }
            });
            entries.push(json!({"matcher": "", "hooks": [{"type": "command", "command": command}]}));
        }
        write_settings(&path, &serde_json::to_vec_pretty(&settings).map_err(invalid)?)?;
        if provider == "codex" { codex_binding::install_title(&root)?; }
        results.push(json!({"provider": provider, "path": path, "state": "installed"}));
    }
    let pi_root = std::env::var_os("PI_CODING_AGENT_DIR").map(PathBuf::from).unwrap_or_else(|| home.join(".pi/agent"));
    let pi = pi_root.join("extensions/zshell-agent-state.ts");
    install_plugin(&pi, include_str!("../../mac/zshell/AgentIntegrations/pi/zshell-agent-state.pi.txt"))?;
    results.push(json!({"provider": "pi", "path": pi, "state": "installed"}));
    let opencode_root = std::env::var_os("OPENCODE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(||
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config")).join("opencode"));
    let plugin = opencode_root.join("plugins/zshell-agent-state.js");
    install_plugin(&plugin, include_str!("../../mac/zshell/AgentIntegrations/opencode/zshell-agent-state.js"))?;
    let tui_plugin = opencode_root.join("zshell/zshell-conversation-tui.js");
    install_plugin(&tui_plugin, include_str!("../../mac/zshell/AgentIntegrations/opencode/zshell-conversation-tui.js"))?;
    let settings = ["tui.jsonc", "tui.json"].iter().map(|name| opencode_root.join(name)).find(|path| path.exists()).unwrap_or_else(|| opencode_root.join("tui.json"));
    let original = fs::read(&settings).unwrap_or_else(|_| b"{}".to_vec());
    if original.len() > 1024 * 1024 { return Err(invalid("OpenCode TUI settings exceed 1 MiB")); }
    let spec = file_url(&tui_plugin)?;
    let updated = append_jsonc_plugin(&original, &spec)?;
    if updated != original { write_settings(&settings, &updated)?; }
    results.push(json!({"provider": "opencode", "path": tui_plugin, "state": "installed"}));
    Ok(json!({"providers": results}))
}

fn install_plugin(path: &Path, source: &str) -> io::Result<()> {
    fs::create_dir_all(path.parent().ok_or_else(|| invalid("Missing plugin directory"))?)?;
    if path.exists() {
        let current = fs::read(path)?;
        if current == source.as_bytes() { return Ok(()); }
        // A modified owned plugin is still user data; do not replace it.
        return Err(invalid(format!("Zshell's integration at {} has local changes", path.display())));
    }
    write_settings(path, source.as_bytes())
}

fn file_url(path: &Path) -> io::Result<String> {
    let text = path.to_str().ok_or_else(|| invalid("Plugin path must be UTF-8"))?;
    let mut url = if text.starts_with('/') { "file://".to_owned() } else { "file:///".to_owned() };
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"/:._~-".contains(&byte) { url.push(byte as char); }
        else { url.push_str(&format!("%{byte:02X}")); }
    }
    Ok(url)
}

fn append_jsonc_plugin(bytes: &[u8], spec: &str) -> io::Result<Vec<u8>> {
    let mut tokens = Vec::<(usize, usize, u8)>::new();
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if byte.is_ascii_whitespace() { index += 1; continue; }
        if byte == b'/' && bytes.get(index + 1) == Some(&b'/') {
            index += 2; while index < bytes.len() && bytes[index] != b'\n' { index += 1; } continue;
        }
        if byte == b'/' && bytes.get(index + 1) == Some(&b'*') {
            index += 2; while index + 1 < bytes.len() && &bytes[index..index + 2] != b"*/" { index += 1; }
            if index + 1 >= bytes.len() { return Err(invalid("Invalid OpenCode JSONC comment")); } index += 2; continue;
        }
        let start = index;
        index += 1;
        if byte == b'"' {
            while index < bytes.len() && bytes[index] != b'"' { index += if bytes[index] == b'\\' { 2 } else { 1 }; }
            if index >= bytes.len() { return Err(invalid("Invalid OpenCode JSONC string")); } index += 1;
        } else if !b"{}[]:,".contains(&byte) {
            while index < bytes.len() && !bytes[index].is_ascii_whitespace() && !b"{}[]:,/".contains(&bytes[index]) { index += 1; }
        }
        tokens.push((start, index, byte));
    }
    if tokens.first().map(|t| t.2) != Some(b'{') || tokens.last().map(|t| t.2) != Some(b'}') { return Err(invalid("OpenCode TUI settings must be a JSON object")); }
    let encoded = serde_json::to_vec(spec).map_err(invalid)?;
    let mut depth = 0;
    let mut property = None;
    for (position, token) in tokens.iter().enumerate() {
        if token.2 == b'"' && depth == 1 && serde_json::from_slice::<String>(&bytes[token.0..token.1]).ok().as_deref() == Some("plugin") {
            if property.is_some() { return Err(invalid("Duplicate OpenCode plugin property")); }
            property = Some(position);
        }
        if b"{[".contains(&token.2) { depth += 1; } else if b"}]".contains(&token.2) { depth -= 1; }
    }
    let (offset, insertion) = if let Some(position) = property {
        if tokens.get(position + 1).map(|t| t.2) != Some(b':') || tokens.get(position + 2).map(|t| t.2) != Some(b'[') { return Err(invalid("OpenCode plugin must be an array")); }
        let start = position + 2;
        let mut depth = 1;
        let mut close = start + 1;
        while close < tokens.len() && depth > 0 {
            if b"{[".contains(&tokens[close].2) { depth += 1; }
            else if b"}]".contains(&tokens[close].2) { depth -= 1; }
            if depth == 0 { break; }
            if tokens[close].2 == b'"' && serde_json::from_slice::<String>(&bytes[tokens[close].0..tokens[close].1]).ok().as_deref() == Some(spec) { return Ok(bytes.into()); }
            close += 1;
        }
        if close >= tokens.len() { return Err(invalid("Invalid OpenCode plugin array")); }
        let comma = if close != start + 1 && tokens[close - 1].2 != b',' { "," } else { "" };
        (tokens[close].0, [comma.as_bytes(), b"\n    ", &encoded, b"\n"].concat())
    } else {
        let close = tokens.len() - 1;
        let comma = if close != 1 && tokens[close - 1].2 != b',' { "," } else { "" };
        (tokens[close].0, [comma.as_bytes(), b"\n  \"plugin\": [", &encoded, b"]\n"].concat())
    };
    Ok([&bytes[..offset], &insertion, &bytes[offset..]].concat())
}

pub(crate) fn write_settings(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) { return Err(invalid("Refusing to replace symlinked provider hook settings")); }
    let staging = path.with_file_name(format!(".zshell-hooks-{}", new_id()?));
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&staging)?;
        file.write_all(bytes)?; file.sync_all()?; drop(file);
        { if let Ok(metadata) = fs::metadata(path) { fs::set_permissions(&staging, fs::Permissions::from_mode(metadata.permissions().mode() & 0o777))?; } fs::rename(&staging, path)?; }
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(staging); }
    result
}

pub fn read_payload() -> io::Result<Vec<u8>> {
    let mut payload = Vec::new(); io::stdin().take(1024 * 1024 + 1).read_to_end(&mut payload)?;
    if payload.len() > 1024 * 1024 { return Err(invalid("Agent hook payload exceeds 1 MiB")); }
    Ok(payload)
}
