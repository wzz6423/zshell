// Process evidence follows Kero's proc_{darwin,linux,windows}.go at
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
    #[cfg(unix)]
    let pid = {
        let foreground = foreground?;
        root_agent(foreground, foreground, shell, Some(foreground), provider)?
    };
    #[cfg(windows)]
    let pid = {
        let _ = foreground;
        let candidates: Vec<_> = windows_process_ids().into_iter().filter_map(|pid| {
            let evidence = process(pid)?;
            if recognize(&evidence) != Some(provider) || is_shared_codex(&evidence) { return None; }
            root_agent(pid, pid, shell, None, provider)
        }).collect::<HashSet<_>>().into_iter().collect();
        if candidates.len() != 1 { return None; }
        candidates[0]
    };
    Some((pid, process(pid)?.started))
}

#[cfg(windows)]
fn windows_process_ids() -> Vec<i32> {
    use crate::windows::Handle;
    use windows_sys::Win32::{Foundation::*, System::Diagnostics::ToolHelp::*};
    let snapshot = Handle(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) });
    if snapshot.0 == INVALID_HANDLE_VALUE { return Vec::new(); }
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() }; entry.dwSize = std::mem::size_of_val(&entry) as u32;
    let mut result = unsafe { Process32FirstW(snapshot.0, &mut entry) };
    let mut ids = Vec::new();
    while result != 0 {
        if entry.th32ProcessID <= i32::MAX as u32 { ids.push(entry.th32ProcessID as i32); }
        result = unsafe { Process32NextW(snapshot.0, &mut entry) };
    }
    ids
}

pub fn recognize(process: &Process) -> Option<&'static str> {
    let name = |text: &str| -> Option<&'static str> {
        let name = text.rsplit(['/', '\\']).next()?.to_ascii_lowercase();
        let name = name.strip_suffix(".exe").or_else(|| name.strip_suffix(".js")).unwrap_or(&name);
        match name { "claude" => Some("claude"), "codex" => Some("codex"), "pi" => Some("pi"), "opencode" => Some("opencode"), _ => None }
    };
    if let Some(provider) = process.arguments.first().and_then(|argument| name(argument)).or_else(|| name(&process.executable)) { return Some(provider); }
    let executable_name = process.executable.rsplit(['/', '\\']).next()?.trim_end_matches(".exe").to_ascii_lowercase();
    let executable = executable_name.as_str();
    if !["node", "nodejs", "bun", "sh", "bash", "zsh", "python"].contains(&executable)
        && !executable.starts_with("python3") { return None; }
    // A shell's inline command is prose, not its executable identity.
    if ["sh", "bash", "zsh"].contains(&executable)
        && process.arguments.iter().skip(1).any(|argument| argument.starts_with('-') && argument.contains('c')) { return None; }
    let script = process.arguments.iter().skip(1).take(8).find(|argument| !argument.starts_with('-') && argument.as_str() != "run")?;
    if let Some(provider) = name(script) { return Some(provider); }
    let normalized = script.replace('\\', "/");
    [("/@openai/codex/", "codex"), ("/@anthropic-ai/claude-code/", "claude"),
        ("/pi-coding-agent/", "pi"), ("/opencode-ai/", "opencode")].into_iter()
        .find_map(|(path, provider)| normalized.contains(path).then_some(provider))
}

fn is_codex_launcher(process: &Process) -> bool {
    let executable = process.executable.rsplit(['/', '\\']).next().unwrap_or("").trim_end_matches(".exe");
    ["node", "nodejs", "bun"].contains(&executable)
        && process.arguments.get(1).is_some_and(|script| script.replace('\\', "/").ends_with("/@openai/codex/bin/codex.js"))
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

#[cfg(windows)]
pub fn process(pid: i32) -> Option<Process> {
    use crate::windows::Handle;
    use windows_sys::Win32::{Foundation::*, System::{Diagnostics::ToolHelp::*, Threading::*}};
    if pid <= 1 { return None; }
    let handle = Handle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) });
    if handle.0.is_null() { return None; }
    let mut exit_code = 0;
    if unsafe { GetExitCodeProcess(handle.0, &mut exit_code) } == 0 || exit_code != STILL_ACTIVE as u32 { return None; }
    let mut created: FILETIME = unsafe { std::mem::zeroed() };
    let mut exited = created; let mut kernel = created; let mut user = created;
    if unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0 { return None; }
    let mut path = vec![0u16; 32768]; let mut length = path.len() as u32;
    if unsafe { QueryFullProcessImageNameW(handle.0, 0, path.as_mut_ptr(), &mut length) } == 0 { return None; }
    let snapshot = Handle(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) });
    if snapshot.0 == INVALID_HANDLE_VALUE { return None; }
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() }; entry.dwSize = std::mem::size_of_val(&entry) as u32;
    let mut result = unsafe { Process32FirstW(snapshot.0, &mut entry) };
    while result != 0 && entry.th32ProcessID != pid as u32 { result = unsafe { Process32NextW(snapshot.0, &mut entry) }; }
    if result == 0 { return None; }
    Some(Process { parent: entry.th32ParentProcessID as i32, group: 0,
        started: ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64,
        executable: String::from_utf16_lossy(&path[..length as usize]), arguments: windows_arguments(handle.0).unwrap_or_default() })
}

#[cfg(windows)]
fn windows_arguments(handle: windows_sys::Win32::Foundation::HANDLE) -> Option<Vec<String>> {
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::UI::Shell::CommandLineToArgvW;
    #[repr(C)]
    struct UnicodeString { length: u16, maximum: u16, buffer: *const u16 }
    #[link(name = "ntdll")]
    extern "system" { fn NtQueryInformationProcess(handle: HANDLE, class: u32, buffer: *mut std::ffi::c_void, size: u32, returned: *mut u32) -> i32; }
    let mut storage = vec![0usize; 512];
    let mut returned = 0;
    let result = unsafe { NtQueryInformationProcess(handle, 60, storage.as_mut_ptr().cast(), (storage.len() * std::mem::size_of::<usize>()) as u32, &mut returned) };
    if result < 0 && returned as usize > storage.len() * std::mem::size_of::<usize>() && returned <= 128 * 1024 {
        storage.resize((returned as usize).div_ceil(std::mem::size_of::<usize>()), 0);
        if unsafe { NtQueryInformationProcess(handle, 60, storage.as_mut_ptr().cast(), (storage.len() * std::mem::size_of::<usize>()) as u32, &mut returned) } < 0 { return None; }
    } else if result < 0 { return None; }
    let line = unsafe { &*storage.as_ptr().cast::<UnicodeString>() };
    let start = storage.as_ptr() as usize;
    let end = start + storage.len() * std::mem::size_of::<usize>();
    if line.buffer.is_null() || (line.buffer as usize) < start || (line.buffer as usize) + line.length as usize > end || line.length % 2 != 0 { return None; }
    let mut terminated = unsafe { std::slice::from_raw_parts(line.buffer, line.length as usize / 2) }.to_vec(); terminated.push(0);
    let mut count = 0;
    let arguments = unsafe { CommandLineToArgvW(terminated.as_ptr(), &mut count) };
    if arguments.is_null() || !(0..=512).contains(&count) { if !arguments.is_null() { unsafe { LocalFree(arguments.cast()); } } return None; }
    let mut output = Vec::new();
    for &argument in unsafe { std::slice::from_raw_parts(arguments, count as usize) } {
        let mut length = 0;
        while unsafe { *argument.add(length) } != 0 && length < 65536 { length += 1; }
        output.push(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(argument, length) }));
    }
    unsafe { LocalFree(arguments.cast()); }
    Some(output)
}
