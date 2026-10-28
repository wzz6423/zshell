// Process evidence follows Kero's proc_{darwin,linux}.go at
// 580bdfa8f6a43d71d145958ab76c1bbb45c465f0 (MIT), with Zshell's root-agent checks.
use std::collections::HashSet;
#[cfg(target_os = "linux")]
use std::io::Read;

#[derive(Clone, Debug)]
pub struct Process {
    pub parent: i32,
    pub group: i32,
    pub started: u64,
    pub executable: String,
    pub arguments: Vec<String>,
}

pub fn root_agent(peer: i32, reporter: i32, shell: i32, foreground: Option<i32>, provider: &str) -> Option<i32> {
    if peer <= 1 || reporter <= 1 || shell <= 1 || (peer != reporter && process(peer)?.parent != reporter) { return None; }
    let mut current = peer;
    let mut seen = HashSet::new();
    let mut root: Option<(i32, i32)> = None;
    for _ in 0..64 {
        if current <= 1 || !seen.insert(current) { return None; }
        let evidence = process(current)?;
        if is_shared_codex(&evidence) { return None; }
        if let Some(kind) = recognize(&evidence) {
            if kind != provider { return None; }
            if let Some((_, group)) = root {
                if !is_codex_launcher(&evidence) || evidence.group != group { return None; }
            } else { root = Some((current, evidence.group)); }
        }
        if current == shell {
            let (pid, group) = root?;
            if foreground.is_some_and(|foreground| pid != foreground && group != foreground) { return None; }
            return Some(pid);
        }
        let parent = process(evidence.parent)?;
        if parent.started > evidence.started { return None; }
        current = evidence.parent;
    }
    None
}

pub fn is_shared_codex(process: &Process) -> bool {
    recognize(process) == Some("codex") && process.arguments.iter().any(|argument| argument == "app-server")
        && process.arguments.iter().any(|argument| argument == "--managed-daemon")
}

pub fn shared_codex_service(peer: i32, reporter: i32) -> Option<(i32, u64)> {
    if peer <= 1 || (peer != reporter && process(peer)?.parent != reporter) { return None; }
    let mut current = peer;
    let mut seen = HashSet::new();
    for _ in 0..64 {
        if current <= 1 || !seen.insert(current) { return None; }
        let evidence = process(current)?;
        if is_shared_codex(&evidence) { return Some((current, evidence.started)); }
        if recognize(&evidence).is_some() { return None; }
        let parent = process(evidence.parent)?;
        if parent.started > evidence.started { return None; }
        current = evidence.parent;
    }
    None
}

pub fn foreground_agent(shell: i32, foreground: Option<i32>, provider: &str) -> Option<(i32, u64)> {
    let foreground = foreground?;
    let pid = root_agent(foreground, foreground, shell, Some(foreground), provider)?;
    Some((pid, process(pid)?.started))
}

pub fn recognize(process: &Process) -> Option<&'static str> {
    let name = |text: &str| -> Option<&'static str> {
        let name = text.rsplit('/').next()?.to_ascii_lowercase();
        let name = name.strip_suffix(".js").unwrap_or(&name);
        match name { "claude" => Some("claude"), "codex" => Some("codex"), "pi" => Some("pi"), "opencode" => Some("opencode"), _ => None }
    };
    if let Some(provider) = process.arguments.first().and_then(|argument| name(argument)).or_else(|| name(&process.executable)) { return Some(provider); }
    let executable_name = process.executable.rsplit('/').next()?.to_ascii_lowercase();
    let executable = executable_name.as_str();
    if !["node", "nodejs", "bun", "sh", "bash", "zsh", "python"].contains(&executable)
        && !executable.starts_with("python3") { return None; }
    // A shell's inline command is prose, not its executable identity.
    if ["sh", "bash", "zsh"].contains(&executable)
        && process.arguments.iter().skip(1).any(|argument| argument.starts_with('-') && argument.contains('c')) { return None; }
    let script = process.arguments.iter().skip(1).take(8).find(|argument| !argument.starts_with('-') && argument.as_str() != "run")?;
    if let Some(provider) = name(script) { return Some(provider); }
    [("/@openai/codex/", "codex"), ("/@anthropic-ai/claude-code/", "claude"),
        ("/pi-coding-agent/", "pi"), ("/opencode-ai/", "opencode")].into_iter()
        .find_map(|(path, provider)| script.contains(path).then_some(provider))
}

fn is_codex_launcher(process: &Process) -> bool {
    let executable = process.executable.rsplit('/').next().unwrap_or("");
    ["node", "nodejs", "bun"].contains(&executable)
        && process.arguments.get(1).is_some_and(|script| script.ends_with("/@openai/codex/bin/codex.js"))
}

#[cfg(target_os = "macos")]
pub fn process(pid: i32) -> Option<Process> {
    if pid <= 1 { return None; }
    let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
    let size = std::mem::size_of_val(&info) as i32;
    if unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) } != size
        || info.pbi_status == 5 { return None; }
    let mut path = [0u8; 4096];
    let length = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if length <= 0 { return None; }
    let executable = String::from_utf8(path.split(|b| *b == 0).next()?.to_vec()).ok()?;
    let mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut bytes = vec![0u8; 128 * 1024];
    let mut length = bytes.len();
    let mut arguments = Vec::new();
    if unsafe { libc::sysctl(mib.as_ptr().cast_mut(), mib.len() as u32, bytes.as_mut_ptr().cast(), &mut length, std::ptr::null_mut(), 0) } == 0 && length >= 4 {
        bytes.truncate(length);
        let argc = i32::from_ne_bytes(bytes[..4].try_into().ok()?).clamp(0, 512) as usize;
        let mut cursor = 4 + bytes[4..].iter().position(|b| *b == 0)?;
        while cursor < bytes.len() && bytes[cursor] == 0 { cursor += 1; }
        arguments = bytes[cursor..].split(|b| *b == 0).take(argc).map(|part| String::from_utf8_lossy(part).into_owned()).collect();
    }
    Some(Process { parent: info.pbi_ppid as i32, group: info.pbi_pgid as i32,
        started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, executable, arguments })
}

#[cfg(target_os = "linux")]
pub fn process(pid: i32) -> Option<Process> {
    if pid <= 1 { return None; }
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields: Vec<_> = stat[stat.rfind(')')? + 1..].split_whitespace().collect();
    if fields.len() < 20 || fields[0] == "Z" { return None; }
    let mut bytes = Vec::new();
    std::fs::File::open(format!("/proc/{pid}/cmdline")).ok()?.take(128 * 1024).read_to_end(&mut bytes).ok()?;
    let arguments = bytes.split(|b| *b == 0).filter(|part| !part.is_empty()).map(|part| String::from_utf8_lossy(part).into_owned()).collect();
    Some(Process { parent: fields[1].parse().ok()?, group: fields[2].parse().ok()?, started: fields[19].parse().ok()?,
        executable: std::fs::read_link(format!("/proc/{pid}/exe")).ok()?.to_str()?.into(), arguments })
}
