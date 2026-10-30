use super::*;
use crate::daemon::Daemon;
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;

struct Fixture {
    daemon: Arc<Daemon>,
    root: PathBuf,
    project: PathBuf,
    other: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("zshell-remote-test-{}", new_id().unwrap()));
        let project = root.join("远端 project");
        let other = root.join("other");
        fs::create_dir_all(&project).unwrap();
        fs::create_dir(&other).unwrap();
        Self {
            daemon: Daemon::new(&root.join("state")).unwrap(),
            root,
            project,
            other,
        }
    }

    fn request(&self, kind: &str, id: &str) -> Frame {
        let mut frame = Frame::new(kind);
        frame.project = Some(self.project.to_str().unwrap().into());
        frame.session_id = Some(id.into());
        frame
    }

    fn create(&self, id: &str, command: Vec<&str>) -> Value {
        let mut frame = self.request("create", id);
        frame.command = Some(command.into_iter().map(str::to_owned).collect());
        self.daemon.request(&frame).unwrap()
    }

    fn attach(&self, id: &str, columns: u16, rows: u16) -> (Stream, Vec<u8>, String) {
        let (client, server) = UnixStream::pair().unwrap();
        let daemon = self.daemon.clone();
        thread::spawn(move || {
            let _ = daemon.handle(Stream::Unix(server));
        });
        let mut stream = Stream::Unix(client);
        stream
            .deadlines(Duration::from_secs(4), Duration::from_secs(4))
            .unwrap();
        client_handshake(&mut stream).unwrap();
        let mut request = self.request("attach", id);
        let client_id = new_id().unwrap();
        request.client_id = Some(client_id.clone());
        request.columns = Some(columns);
        request.rows = Some(rows);
        write_frame(&mut stream, &request).unwrap();
        let attached = read_frame(&mut stream).unwrap();
        assert_eq!(attached.kind, "attached", "{attached:?}");
        let snapshot = collect_until(&mut stream, |frame, _| frame.kind == "snapshotEnd");
        (stream, snapshot, client_id)
    }

    fn get(&self, id: &str) -> Value {
        self.daemon.request(&self.request("get", id)).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.daemon.request(&Frame::new("shutdown"));
        thread::sleep(Duration::from_millis(650));
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn collect_until(stream: &mut Stream, mut predicate: impl FnMut(&Frame, &[u8]) -> bool) -> Vec<u8> {
    let mut output = Vec::new();
    for _ in 0..16384 {
        let frame = read_frame(stream).unwrap();
        if matches!(frame.kind.as_str(), "snapshot" | "output") {
            output.extend(
                STANDARD
                    .decode(frame.data.as_deref().unwrap_or(""))
                    .unwrap(),
            );
        }
        assert!(frame.error.is_none(), "{frame:?}");
        if predicate(&frame, &output) {
            return output;
        }
    }
    panic!(
        "Expected remote output did not arrive after {} bytes",
        output.len()
    );
}

fn input(stream: &mut Stream, text: &str) {
    let mut frame = Frame::new("input");
    frame.data = Some(STANDARD.encode(text));
    write_frame(stream, &frame).unwrap();
}

#[test]
fn zsh_completions_use_remote_pty_and_clean_up_after_exit() {
    if !crate::pty::login_shell().ends_with("/zsh") {
        eprintln!("Skipping zsh completion session test: login shell is not zsh");
        return;
    }
    let fixture = Fixture::new();
    let home = fixture.root.join("shell ' home");
    fs::create_dir(&home).unwrap();
    let dump = home.join("buffer");
    let sentinel = home.join("executed");
    let quote = |path: &Path| format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"));
    let config = format!(
        "bindkey -e; PROMPT='READY> '; RPROMPT=''; HISTFILE=/dev/null\n\
         autoload -Uz compinit; compinit -D -i\n\
         _fixture() {{ compadd alpha bravo; }}; compdef _fixture zfixture\n\
         zfixture() {{ print ran >| {}; }}\n\
         _dump() {{ print -rn -- \"$BUFFER\" >| {}; }}; zle -N _dump; bindkey '^T' _dump\n",
        quote(&sentinel), quote(&dump)
    );
    fs::write(home.join(".zshrc"), &config).unwrap();
    let id = new_id().unwrap();
    let mut request = fixture.request("create", &id);
    request.shell_completions = Some(true);
    request.environment = Some([
        ("HOME".into(), home.to_string_lossy().into_owned()),
        ("ZDOTDIR".into(), home.to_string_lossy().into_owned()),
        ("LC_ALL".into(), "en_US.UTF-8".into()),
    ].into());
    fixture.daemon.request(&request).unwrap();
    let state = fixture.root.join("state");
    let integration = fs::read_dir(&state).unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.file_name().unwrap().to_string_lossy().starts_with("shell-completions-"))
        .expect("private completion integration exists while the shell is running");
    assert_eq!(fs::metadata(&integration).unwrap().permissions().mode() & 0o777, 0o700);

    let (mut active, snapshot, _) = fixture.attach(&id, 80, 24);
    if !String::from_utf8_lossy(&snapshot).contains("READY> ") {
        collect_until(&mut active, |_, output| String::from_utf8_lossy(output).contains("READY> "));
    }
    input(&mut active, "zfixture ");
    collect_until(&mut active, |_, output| String::from_utf8_lossy(output).contains("alpha"));
    let (mut inactive, _, _) = fixture.attach(&id, 80, 24);
    input(&mut inactive, "UNWANTED");
    write_frame(&mut inactive, &Frame::new("ping")).unwrap();
    collect_until(&mut inactive, |frame, _| frame.kind == "pong");
    input(&mut active, "\t");
    collect_until(&mut active, |_, output| String::from_utf8_lossy(output).contains("bravo"));
    input(&mut active, "\u{1b}[C\r\u{14}");
    let deadline = Instant::now() + Duration::from_secs(4);
    while !dump.exists() && Instant::now() < deadline { thread::sleep(Duration::from_millis(10)); }
    assert_eq!(fs::read_to_string(&dump).unwrap(), "zfixture bravo ");
    assert!(!sentinel.exists(), "accepting a completion must not execute it");
    assert_eq!(fs::read_to_string(home.join(".zshrc")).unwrap(), config);

    input(&mut active, "\u{15}exit\r");
    let deadline = Instant::now() + Duration::from_secs(4);
    while integration.exists() && Instant::now() < deadline { thread::sleep(Duration::from_millis(10)); }
    assert!(!integration.exists(), "session resources must be removed after shell exit");
    inactive.shutdown();
    active.shutdown();
}

#[test]
fn real_pty_survives_disconnect_replays_and_accepts_input() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    let original = fixture.create(&id, vec!["/bin/sh", "-i"]);
    let pid = original["pid"].as_i64().unwrap();
    let (mut first, _, _) = fixture.attach(&id, 80, 24);
    input(&mut first, "printf '\\nBEFORE_MARK\\n'; sleep 0.25; printf 'OFFLINE_MARK\\n'; sleep 0.25; printf 'AFTER_MARK\\n'\r");
    collect_until(&mut first, |_, output| {
        output
            .windows(15)
            .any(|bytes| bytes == b"\r\nBEFORE_MARK\r\n")
    });
    first.shutdown();
    thread::sleep(Duration::from_millis(650));
    assert_eq!(fixture.get(&id)["pid"].as_i64(), Some(pid));
    assert_eq!(fixture.get(&id)["running"], true);
    let (mut second, snapshot, _) = fixture.attach(&id, 80, 24);
    let snapshot = String::from_utf8_lossy(&snapshot);
    for marker in ["BEFORE_MARK", "OFFLINE_MARK", "AFTER_MARK"] {
        assert!(snapshot.contains(marker), "Missing {marker}");
    }
    input(&mut second, "printf '\\nINPUT_OK\\n'\r");
    let output = collect_until(&mut second, |_, output| {
        output.windows(12).any(|bytes| bytes == b"\r\nINPUT_OK\r\n")
    });
    assert!(output.windows(8).any(|bytes| bytes == b"INPUT_OK"));
    second.shutdown();
}

#[test]
fn two_clients_share_output_and_only_active_client_resizes_or_types() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let (mut first, _, first_id) = fixture.attach(&id, 80, 24);
    let (mut second, _, second_id) = fixture.attach(&id, 100, 30);
    assert_eq!(fixture.get(&id)["clientCount"], 2);
    assert_eq!(fixture.get(&id)["columns"], 80);
    let mut resize = Frame::new("resize");
    resize.columns = Some(120);
    resize.rows = Some(35);
    write_frame(&mut second, &resize).unwrap();
    collect_until(&mut second, |frame, _| {
        frame.kind == "state"
            && frame
                .result
                .as_ref()
                .is_some_and(|info| info["activeClientId"] == first_id)
    });
    assert_eq!(fixture.get(&id)["columns"], 80);
    input(&mut second, ": > inactive-client-sentinel\r");
    write_frame(&mut second, &Frame::new("ping")).unwrap();
    collect_until(&mut second, |frame, _| frame.kind == "pong");
    assert!(!fixture.project.join("inactive-client-sentinel").exists());
    write_frame(&mut second, &Frame::new("claim")).unwrap();
    collect_until(&mut second, |frame, _| {
        frame.kind == "state"
            && frame
                .result
                .as_ref()
                .is_some_and(|info| info["activeClientId"] == second_id)
    });
    assert_eq!(fixture.get(&id)["columns"], 120);
    assert_eq!(fixture.get(&id)["rows"], 35);
    input(&mut second, "printf '\\nSHARED_MARK\\n'; stty size\r");
    let first_output = collect_until(&mut first, |_, output| {
        output.windows(13).any(|bytes| bytes == b"SHARED_MARK\r\n")
    });
    let second_output = collect_until(&mut second, |_, output| {
        output.windows(8).any(|bytes| bytes == b"35 120\r\n")
    });
    for output in [first_output, second_output] {
        assert!(!String::from_utf8_lossy(&output).contains("SHOULD_NOT_TYPE"));
    }
    second.shutdown();
    thread::sleep(Duration::from_millis(100));
    assert_eq!(fixture.get(&id)["clientCount"], 1);
    assert_eq!(fixture.get(&id)["activeClientId"], first_id);
    assert_eq!(fixture.get(&id)["columns"], 80);
    first.shutdown();
    thread::sleep(Duration::from_millis(100));
    assert_eq!(fixture.get(&id)["clientCount"], 0);
}

#[test]
fn slow_client_is_disconnected_without_blocking_the_active_client() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let (mut fast, _, fast_id) = fixture.attach(&id, 80, 24);
    let (slow, _, _) = fixture.attach(&id, 80, 24);
    input(&mut fast, "i=0; while [ $i -lt 64 ]; do dd if=/dev/zero bs=65536 count=1 2>/dev/null; sleep 0.01; i=$((i + 1)); done; printf '\\nBACKPRESSURE_DONE\\n'\r");
    let marker = b"BACKPRESSURE_DONE\r\n";
    let output = collect_until(&mut fast, |_, output| {
        let start = output.len().saturating_sub(16 * 1024 + marker.len());
        output[start..]
            .windows(marker.len())
            .any(|bytes| bytes == marker)
    });
    assert!(output.len() >= 4 * 1024 * 1024);
    for _ in 0..20 {
        if fixture.get(&id)["clientCount"] == 1 {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(fixture.get(&id)["clientCount"], 1);
    assert_eq!(fixture.get(&id)["activeClientId"], fast_id);
    assert_eq!(fixture.get(&id)["running"], true);
    slow.shutdown();
    fast.shutdown();
}

#[test]
fn reconnecting_the_same_client_replaces_only_its_old_attachment() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let (first, _, client_id) = fixture.attach(&id, 80, 24);
    let (client, server) = UnixStream::pair().unwrap();
    let daemon = fixture.daemon.clone();
    thread::spawn(move || {
        let _ = daemon.handle(Stream::Unix(server));
    });
    let mut second = Stream::Unix(client);
    second
        .deadlines(Duration::from_secs(4), Duration::from_secs(4))
        .unwrap();
    client_handshake(&mut second).unwrap();
    let mut request = fixture.request("attach", &id);
    request.client_id = Some(client_id.clone());
    write_frame(&mut second, &request).unwrap();
    assert_eq!(read_frame(&mut second).unwrap().kind, "attached");
    collect_until(&mut second, |frame, _| frame.kind == "snapshotEnd");
    first.shutdown();
    thread::sleep(Duration::from_millis(100));
    assert_eq!(fixture.get(&id)["clientCount"], 1);
    assert_eq!(fixture.get(&id)["activeClientId"], client_id);
    input(&mut second, "printf '\\nREPLACED_OK\\n'\r");
    collect_until(&mut second, |_, output| {
        output
            .windows(15)
            .any(|bytes| bytes == b"\r\nREPLACED_OK\r\n")
    });
    second.shutdown();
}

#[test]
fn exit_status_is_preserved_for_a_later_attachment() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(
        &id,
        vec!["/bin/sh", "-c", "printf 'exit-history\\n'; exit 7"],
    );
    thread::sleep(Duration::from_millis(150));
    let (mut stream, snapshot, _) = fixture.attach(&id, 80, 24);
    assert!(String::from_utf8_lossy(&snapshot).contains("exit-history"));
    let mut code = None;
    collect_until(&mut stream, |frame, _| {
        if frame.kind == "exited" {
            code = frame.exit_code;
            true
        } else {
            false
        }
    });
    assert_eq!(code, Some(7));
    assert_eq!(fixture.get(&id)["running"], false);
    stream.shutdown();
}

#[test]
fn exited_sessions_make_room_for_new_sessions() {
    let fixture = Fixture::new();
    let watched = new_id().unwrap();
    fixture.create(&watched, vec!["/bin/sh", "-c", "exit 3"]);
    let (stream, _, _) = fixture.attach(&watched, 80, 24);
    // The oldest evictable shell leaves a child that ignores SIGHUP on its PTY.
    let survivor = fixture.root.join("survivor.pid");
    let script = format!("(trap '' HUP; exec sleep 30) & echo $! > '{}'; exit 0", survivor.display());
    let exited: Vec<_> = (1..MAX_SESSIONS)
        .map(|index| {
            let id = new_id().unwrap();
            fixture.create(&id, if index == 1 { vec!["/bin/sh", "-c", &script] } else { vec!["/bin/sh", "-c", "exit 0"] });
            id
        })
        .collect();
    let deadline = Instant::now() + Duration::from_secs(10);
    while [&watched].into_iter().chain(&exited).any(|id| fixture.get(id)["running"] == true) {
        assert!(Instant::now() < deadline, "Sessions did not exit");
        thread::sleep(Duration::from_millis(20));
    }
    let survivor: i32 = fs::read_to_string(&survivor).unwrap().trim().parse().unwrap();
    assert_eq!(unsafe { libc::kill(survivor, 0) }, 0);
    // A launch that fails after reserving a slot keeps the exited sessions.
    let mut failing = fixture.request("create", &new_id().unwrap());
    failing.command = Some(vec!["/bin/sh".into()]);
    failing.environment = Some([("ZSHELL_CLI_TOKEN".into(), "secret".into())].into());
    assert!(fixture.daemon.request(&failing).is_err());
    assert_eq!(fixture.get(&exited[0])["running"], false);
    let fresh = new_id().unwrap();
    assert_eq!(fixture.create(&fresh, vec!["/bin/sh", "-i"])["running"], true);
    assert_eq!(fixture.get(&watched)["exitCode"], 3);
    assert!(fixture.daemon.request(&fixture.request("get", &exited[0])).is_err());
    thread::sleep(Duration::from_millis(700));
    let alive = unsafe { libc::kill(survivor, 0) } == 0;
    if alive { unsafe { libc::kill(survivor, libc::SIGKILL); } }
    assert!(!alive, "An evicted session left its SIGHUP-ignoring child running");
    assert_eq!(fixture.get(&exited[1])["running"], false);
    stream.shutdown();
}

#[test]
fn concurrent_creates_spawn_one_session_per_id() {
    let fixture = Arc::new(Fixture::new());
    let id = new_id().unwrap();
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let fixture = fixture.clone();
            let id = id.clone();
            thread::spawn(move || {
                let mut frame = fixture.request("create", &id);
                frame.command = Some(vec!["/bin/sh".into(), "-i".into()]);
                fixture.daemon.request(&frame).ok().map(|info| info["pid"].as_i64())
            })
        })
        .collect();
    let pids: Vec<_> = workers.into_iter().filter_map(|worker| worker.join().unwrap()).collect();
    assert!(!pids.is_empty());
    assert!(pids.iter().all(|pid| *pid == pids[0]));
    let mut list = Frame::new("list");
    list.project = fixture.request("list", &id).project;
    assert_eq!(fixture.daemon.request(&list).unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn shutdown_rejects_new_sessions() {
    let fixture = Fixture::new();
    fixture.daemon.request(&Frame::new("shutdown")).unwrap();
    let mut create = fixture.request("create", &new_id().unwrap());
    create.command = Some(vec!["/bin/sh".into(), "-i".into()]);
    let error = fixture.daemon.request(&create).unwrap_err();
    assert!(error.to_string().contains("shutting down"));
}

#[test]
fn shutdown_ends_sessions_that_are_still_starting() {
    let mut raced = 0;
    for _ in 0..20 {
        let fixture = Arc::new(Fixture::new());
        let id = new_id().unwrap();
        let create = {
            let fixture = fixture.clone();
            let id = id.clone();
            thread::spawn(move || {
                let mut frame = fixture.request("create", &id);
                frame.command = Some(["/bin/sh", "-c", "trap '' HUP; exec sleep 5"].map(str::to_owned).to_vec());
                loop {
                    // The probe below may win the reservation for a moment.
                    if let Ok(info) = fixture.daemon.request(&frame) {
                        return info["pid"].as_i64().unwrap() as i32;
                    }
                }
            })
        };
        // A probe for the same ID reports the first create while it is spawning;
        // its relative command makes it fail fast if it wins the reservation.
        let mut probe = fixture.request("create", &id);
        probe.command = Some(vec!["sh".into()]);
        let spawning = loop {
            match fixture.daemon.request(&probe) {
                Err(error) if error.to_string().contains("still starting") => break true,
                Ok(_) => break false,
                Err(_) => thread::yield_now(),
            }
        };
        if spawning {
            fixture.daemon.request(&Frame::new("shutdown")).unwrap();
        }
        let pid = create.join().unwrap();
        if !spawning { continue; }
        raced += 1;
        thread::sleep(Duration::from_millis(700));
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        if alive { unsafe { libc::kill(pid, libc::SIGKILL); } }
        assert!(!alive, "A session that was starting during shutdown outlived it");
    }
    assert!(raced > 0);
}

#[test]
fn project_scoping_and_invalid_launches_are_rejected() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let mut request = fixture.request("get", &id);
    request.project = Some(fixture.other.to_str().unwrap().into());
    for kind in ["get", "create", "terminate"] {
        request.kind = kind.into();
        assert!(fixture.daemon.request(&request).is_err());
    }
    request.kind = "list".into();
    assert_eq!(
        fixture.daemon.request(&request).unwrap(),
        serde_json::json!([])
    );
    let mut invalid = fixture.request("create", &new_id().unwrap());
    invalid.command = Some(vec!["sh".into()]);
    assert!(fixture.daemon.request(&invalid).is_err());
    invalid.command = Some(vec!["/bin/sh".into()]);
    invalid.environment = Some([("ZSHELL_CLI_TOKEN".into(), "secret".into())].into());
    assert!(fixture.daemon.request(&invalid).is_err());
    invalid.environment = None;
    invalid.columns = Some(513);
    assert!(fixture.daemon.request(&invalid).is_err());
    let link = fixture.root.join("alias");
    std::os::unix::fs::symlink(&fixture.project, &link).unwrap();
    request.kind = "get".into();
    request.project = Some(link.to_str().unwrap().into());
    assert_eq!(fixture.daemon.request(&request).unwrap()["sessionId"], id);
}

#[test]
fn processes_lists_only_the_sessions_own_descendants() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-c", "sleep 30; exit 0"]);
    let request = fixture.request("processes", &id);
    let mut names = Vec::new();
    for _ in 0..50 {
        let result = fixture.daemon.request(&request).unwrap();
        names = result.as_array().unwrap().iter().map(|item| item["name"].as_str().unwrap().to_owned()).collect();
        if !names.is_empty() { break; }
        thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(names, ["sleep"]);
    let result = fixture.daemon.request(&request).unwrap();
    assert!(result[0]["pid"].as_i64().unwrap() > 1);
    assert!(result[0]["memoryKB"].is_u64());
    let mut other = request.clone();
    other.project = Some(fixture.other.to_str().unwrap().into());
    assert!(fixture.daemon.request(&other).is_err());
    fixture.daemon.request(&fixture.request("terminate", &id)).unwrap();
    assert!(fixture.daemon.request(&request).is_err());
}

#[cfg(target_os = "linux")]
#[test]
fn processes_report_the_full_linux_executable() {
    let fixture = Fixture::new();
    let worker = fs::canonicalize(&fixture.root).unwrap().join("long-running-process-worker");
    let id = new_id().unwrap();
    // The session copies the binary itself: a copy written here can still be
    // open in a child another test thread just forked, and exec then fails
    // with ETXTBSY. A shell is copied, not `sleep`: a multi-call coreutils
    // (uutils on Ubuntu 26.04) refuses to run under an unknown name.
    let script = format!("cp /bin/sh '{0}' && '{0}' -c \"sleep 30; exit 0\"; exit 0", worker.display());
    fixture.create(&id, vec!["/bin/sh", "-c", &script]);
    let request = fixture.request("processes", &id);
    let mut result = Value::Null;
    for _ in 0..100 {
        result = fixture.daemon.request(&request).unwrap();
        if result[0]["name"] == "long-running-process-worker" { break; }
        thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(result[0]["name"], "long-running-process-worker");
    assert_eq!(result[0]["executable"], worker.to_str().unwrap());
    fixture.daemon.request(&fixture.request("terminate", &id)).unwrap();
}

#[test]
fn tailscale_owner_allowlist_and_local_identity_boundary() {
    let root =
        std::env::temp_dir().join(format!("zshell-remote-tailnet-test-{}", new_id().unwrap()));
    fs::create_dir(&root).unwrap();
    let program = root.join("tailscale");
    let status = r#"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.1"],"UserID":42},"User":{"42":{"LoginName":"owner@example.com"}}}"#;
    let write_fake = |login: &str, tags: &str| {
        let who =
            format!(r#"{{"Node":{{"Tags":{tags}}},"UserProfile":{{"LoginName":"{login}"}}}}"#);
        fs::write(&program, format!("#!/bin/sh\ncase \"$1\" in\nstatus) printf '%s' '{status}' ;;\nwhois) printf '%s' '{who}' ;;\nesac\n")).unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        // A child another test thread forks while the write fd above is open
        // keeps it until that child execs, and exec here fails with ETXTBSY
        // meanwhile. Wait until the script can run before using it.
        for attempt in 0.. {
            match std::process::Command::new(&program).status() {
                Err(error) if error.raw_os_error() == Some(26) && attempt < 100 => {
                    thread::sleep(Duration::from_millis(20))
                }
                result => {
                    result.unwrap();
                    break;
                }
            }
        }
    };
    let mut policy = TailnetPolicy {
        executable: program.clone(),
        allow: Vec::new(),
    };
    write_fake("owner@example.com", "[]");
    assert!(policy.authorize("100.64.0.2:1234".parse().unwrap()).is_ok());
    assert!(policy
        .authorize("100.64.0.1:1234".parse().unwrap())
        .is_err());
    assert!(policy.authorize("127.0.0.1:1234".parse().unwrap()).is_err());
    write_fake("guest@example.com", "[]");
    assert!(policy
        .authorize("100.64.0.2:1234".parse().unwrap())
        .is_err());
    policy.allow.push("guest@example.com".into());
    assert!(policy.authorize("100.64.0.2:1234".parse().unwrap()).is_ok());
    write_fake("guest@example.com", "[\"tag:ci\"]");
    assert!(policy
        .authorize("100.64.0.2:1234".parse().unwrap())
        .is_err());
    fs::remove_dir_all(root).unwrap();
}

fn paste_transport(fixture: &Fixture) -> Stream {
    let (client, server) = UnixStream::pair().unwrap();
    let daemon = fixture.daemon.clone();
    thread::spawn(move || {
        let _ = daemon.handle(Stream::Unix(server));
    });
    let mut stream = Stream::Unix(client);
    stream
        .deadlines(Duration::from_secs(4), Duration::from_secs(4))
        .unwrap();
    client_handshake(&mut stream).unwrap();
    stream
}

fn paste_exchange(stream: &mut Stream, request: &Frame) -> Frame {
    write_frame(stream, request).unwrap();
    read_frame(stream).unwrap()
}

#[test]
fn file_paste_is_bound_to_active_attachment_and_project() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let (first, _, client_id) = fixture.attach(&id, 80, 24);
    let (mut second, _, second_id) = fixture.attach(&id, 80, 24);
    let mut upload = paste_transport(&fixture);
    let mut request = fixture.request("pasteStart", &id);
    request.client_id = Some(second_id.clone());
    request.paste_files = Some(vec![PasteFile {
        name: "binary.png".into(),
        size: 3,
    }]);
    assert!(paste_exchange(&mut upload, &request)
        .error
        .unwrap()
        .contains("active client"));
    request.client_id = Some(client_id.clone());
    request.project = Some(fixture.other.to_str().unwrap().into());
    assert!(paste_exchange(&mut upload, &request)
        .error
        .unwrap()
        .contains("different project"));
    request.project = Some(fixture.project.to_str().unwrap().into());
    let started = paste_exchange(&mut upload, &request);
    assert!(started.error.is_none(), "{started:?}");
    let upload_id = started.result.unwrap()["uploadId"]
        .as_str()
        .unwrap()
        .to_owned();
    let pending = fixture
        .root
        .join("state/pastes")
        .join(format!("pending-{upload_id}"));
    assert!(pending.is_dir());
    request.kind = "pasteChunk".into();
    request.upload_id = Some(upload_id);
    request.file_index = Some(0);
    request.offset = Some(0);
    request.data = Some(STANDARD.encode([0, 1, 255]));
    assert!(paste_exchange(&mut upload, &request).error.is_none());
    write_frame(&mut second, &Frame::new("claim")).unwrap();
    collect_until(&mut second, |frame, _| {
        frame.kind == "state"
            && frame
                .result
                .as_ref()
                .is_some_and(|value| value["activeClientId"] == second_id)
    });
    request.kind = "pasteCommit".into();
    assert!(paste_exchange(&mut upload, &request)
        .error
        .unwrap()
        .contains("active client"));
    assert!(!pending.exists());
    first.shutdown();
    second.shutdown();
    upload.shutdown();
}

#[test]
fn file_paste_upload_commit_and_disconnect_cleanup() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    fixture.create(&id, vec!["/bin/sh", "-i"]);
    let (client, _, client_id) = fixture.attach(&id, 80, 24);
    let mut upload = paste_transport(&fixture);
    let mut request = fixture.request("pasteStart", &id);
    request.client_id = Some(client_id);
    request.paste_files = Some(vec![PasteFile {
        name: "image 'quoted'.png".into(),
        size: 3,
    }]);
    let started = paste_exchange(&mut upload, &request);
    request.upload_id = Some(
        started.result.unwrap()["uploadId"]
            .as_str()
            .unwrap()
            .to_owned(),
    );
    request.kind = "pasteChunk".into();
    request.file_index = Some(0);
    request.offset = Some(0);
    request.data = Some(STANDARD.encode([0, 1, 255]));
    assert!(paste_exchange(&mut upload, &request).error.is_none());
    request.kind = "pasteCommit".into();
    let committed = paste_exchange(&mut upload, &request);
    assert!(committed.error.is_none(), "{committed:?}");
    let paths = committed.result.unwrap();
    let path = PathBuf::from(paths["paths"][0].as_str().unwrap());
    assert_eq!(fs::read(&path).unwrap(), [0, 1, 255]);
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    upload.shutdown();
    let mut partial = paste_transport(&fixture);
    request.kind = "pasteStart".into();
    request.upload_id = None;
    let started = paste_exchange(&mut partial, &request);
    let upload_id = started.result.unwrap()["uploadId"]
        .as_str()
        .unwrap()
        .to_owned();
    let pending = fixture
        .root
        .join("state/pastes")
        .join(format!("pending-{upload_id}"));
    assert!(pending.exists());
    partial.shutdown();
    let deadline = Instant::now() + Duration::from_secs(2);
    while pending.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(!pending.exists());
    assert!(path.exists());
    client.shutdown();
}
