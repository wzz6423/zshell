use serde::Serialize;
use std::collections::HashMap;
use std::io;
use std::process::{Command, Stdio};

/// One row of the app's Info panel; field names match its local `ProcessItem`.
#[derive(Debug, Serialize)]
pub struct ProcessItem {
    pub pid: i32,
    pub name: String,
    pub executable: String,
    pub cpu: f64,
    #[serde(rename = "memoryKB")]
    pub memory_kb: u64,
}

/// Everything running under `shell`, sampled the same way the app samples a
/// local pane so both lists read alike.
pub fn descendants(shell: i32) -> io::Result<Vec<ProcessItem>> {
    // `-A -o` is accepted by both BSD and procps `ps`; `comm` has no arguments,
    // so only the last column is free-form.
    let output = Command::new("ps")
        .args(["-A", "-o", "pid=,ppid=,stat=,pcpu=,rss=,comm="])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("ps failed on the remote host"));
    }
    #[allow(unused_mut)]
    let mut items = parse(&String::from_utf8_lossy(&output.stdout), shell);
    // procps `comm` is the kernel's 15-byte task name, not a path; the
    // executable comes from /proc. The name stays the task name when it is
    // not a cut-off of that file, e.g. for busybox applets or scripts.
    #[cfg(target_os = "linux")]
    for item in &mut items {
        let Ok(path) = std::fs::read_link(format!("/proc/{}/exe", item.pid)) else { continue };
        let path = path.to_string_lossy().into_owned();
        let file = path.rsplit('/').next().unwrap_or(&path);
        if file.starts_with(&item.name) {
            item.name = file.into();
        }
        item.executable = path;
    }
    Ok(items)
}

fn parse(text: &str, shell: i32) -> Vec<ProcessItem> {
    let mut items = HashMap::new();
    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let (Some(pid), Some(parent), Some(stat), Some(cpu), Some(rss)) =
            (fields.next(), fields.next(), fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let (Ok(pid), Ok(parent)) = (pid.parse::<i32>(), parent.parse::<i32>()) else {
            continue;
        };
        // Recorded before the zombie check so the walk still passes through it.
        children.entry(parent).or_default().push(pid);
        if stat.starts_with('Z') {
            continue;
        }
        let executable = fields.collect::<Vec<_>>().join(" ");
        if executable.is_empty() {
            continue;
        }
        items.insert(pid, ProcessItem {
            pid,
            name: executable.rsplit('/').next().unwrap_or(&executable).into(),
            executable,
            cpu: cpu.parse().unwrap_or(0.0),
            memory_kb: rss.parse().unwrap_or(0),
        });
    }
    // Breadth-first: the commands the user ran come before their workers.
    let mut result = Vec::new();
    let mut queue = std::collections::VecDeque::from(children.remove(&shell).unwrap_or_default());
    while let Some(pid) = queue.pop_front() {
        if let Some(item) = items.remove(&pid) {
            result.push(item);
        }
        queue.extend(children.remove(&pid).unwrap_or_default());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_live_descendants_breadth_first() {
        let sample = "  10     1 Ss    0.0  2048 /bin/zsh\n  11    10 S+    1.5  4096 /usr/bin/node\n  12    11 Z     0.0     0 <defunct>\n  13    12 R     9.0  8192 /opt/My Tools/worker\n  14    10 S     0.2  1024 sleep\n  15     1 S     0.0   512 /usr/sbin/sshd\n";
        let items = parse(sample, 10);
        let pids: Vec<_> = items.iter().map(|item| item.pid).collect();
        assert_eq!(pids, [11, 14, 13]);
        assert_eq!(items[0].name, "node");
        assert_eq!(items[0].memory_kb, 4096);
        assert_eq!(items[2].name, "worker");
        assert_eq!(items[2].executable, "/opt/My Tools/worker");
        assert!(parse(sample, 99).is_empty());
    }
}
