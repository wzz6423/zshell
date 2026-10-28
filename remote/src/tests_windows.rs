use super::*;
use crate::daemon::Daemon;
use crate::pty::{login_shell, quote_argument, Pty};
use serde_json::Value;
use std::collections::BTreeMap;
use std::os::windows::io::AsRawHandle;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Threading::*;

struct Fixture {
    root: PathBuf,
    project: PathBuf,
    daemon: Arc<Daemon>,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("zshell-windows-{}", new_id().unwrap()));
        let project = root.join("远端 project 'quoted'");
        fs::create_dir_all(&project).unwrap();
        let daemon = Daemon::new(&root.join("state")).unwrap();
        Self {
            root,
            project,
            daemon,
        }
    }
    fn request(&self, kind: &str, id: &str) -> Frame {
        let mut frame = Frame::new(kind);
        frame.project = Some(self.project.to_string_lossy().into());
        frame.session_id = Some(id.into());
        frame
    }
    fn connect(&self) -> Stream {
        let state = self.root.join(format!("connection-{}", new_id().unwrap()));
        prepare_state(&state).unwrap();
        let mut listener = LocalListener::bind(&state).unwrap();
        let daemon = self.daemon.clone();
        thread::spawn(move || {
            let _ = daemon.handle(listener.accept().unwrap());
        });
        let mut client = connect_control(&state).unwrap();
        client
            .deadlines(Duration::from_secs(10), Duration::from_secs(5))
            .unwrap();
        client_handshake(&mut client).unwrap();
        client
    }
    fn attach(&self, id: &str) -> (Stream, Vec<u8>, String) {
        let mut stream = self.connect();
        let mut request = self.request("attach", id);
        let client_id = new_id().unwrap();
        request.client_id = Some(client_id.clone());
        request.columns = Some(160);
        request.rows = Some(30);
        write_frame(&mut stream, &request).unwrap();
        assert_eq!(read_frame(&mut stream).unwrap().kind, "attached");
        let snapshot = collect(&mut stream, |frame, _| frame.kind == "snapshotEnd");
        (stream, snapshot, client_id)
    }
    fn info(&self, id: &str) -> Value {
        self.daemon.request(&self.request("get", id)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.daemon.request(&Frame::new("shutdown"));
        thread::sleep(Duration::from_millis(800));
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn collect(stream: &mut Stream, mut predicate: impl FnMut(&Frame, &[u8]) -> bool) -> Vec<u8> {
    let mut output = Vec::new();
    for _ in 0..16_384 {
        let frame = read_frame(stream).unwrap();
        assert!(frame.error.is_none(), "{frame:?}");
        if matches!(frame.kind.as_str(), "output" | "snapshot") {
            output.extend(STANDARD.decode(frame.data.as_deref().unwrap()).unwrap());
        }
        if predicate(&frame, &output) {
            return output;
        }
    }
    panic!(
        "Expected Windows output did not arrive: {:?}",
        String::from_utf8_lossy(&output)
    );
}
fn input(stream: &mut Stream, text: &str) {
    let mut frame = Frame::new("input");
    frame.data = Some(STANDARD.encode(text));
    write_frame(stream, &frame).unwrap();
}
fn wait_for(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if condition() {
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }
    assert!(condition(), "Windows operation did not complete in time");
}

#[test]
fn private_state_lock_and_named_pipe_deadlines() {
    assert_eq!(
        shell_path(std::path::Path::new(r"\\?\C:\Users\dev\image 'quoted'.png")).unwrap(),
        r"C:\Users\dev\image 'quoted'.png"
    );
    assert_eq!(
        shell_path(std::path::Path::new(r"\\?\UNC\server\share\image.png")).unwrap(),
        r"\\server\share\image.png"
    );
    let fixture = Fixture::new();
    let state = fixture.root.join("secure");
    prepare_state(&state).unwrap();
    let lock = lock_state(&state).unwrap();
    crate::windows::verify_private_handle(lock.as_raw_handle(), false).unwrap();
    assert!(lock_state(&state).is_err());
    drop(lock);
    let mut listener = LocalListener::bind(&state).unwrap();
    assert!(LocalListener::bind(&state).is_err());
    drop(connect_control(&state).unwrap());
    let next_state = state.clone();
    let connector = thread::spawn(move || connect_control(&next_state).unwrap());
    let next = listener.accept().unwrap();
    connector.join().unwrap().shutdown();
    next.shutdown();
    let mut client = connect_control(&state).unwrap();
    let server = listener.accept().unwrap();
    client
        .deadlines(Duration::from_millis(50), Duration::from_millis(50))
        .unwrap();
    assert_eq!(
        client.read(&mut [0; 1]).unwrap_err().kind(),
        io::ErrorKind::TimedOut
    );
    let close = client.try_clone().unwrap();
    client
        .deadlines(Duration::from_secs(10), Duration::from_secs(1))
        .unwrap();
    let reader = thread::spawn(move || client.read(&mut [0; 1]));
    thread::sleep(Duration::from_millis(50));
    close.shutdown();
    assert!(reader.join().unwrap().is_err());
    server.shutdown();
    for _ in 0..32 {
        let mut client = connect_control(&state).unwrap();
        let server = listener.accept().unwrap();
        client.deadlines(Duration::from_secs(1), Duration::from_secs(1)).unwrap();
        let close = client.try_clone().unwrap();
        let start = Arc::new(std::sync::Barrier::new(2));
        let started = start.clone();
        let (sent, done) = std::sync::mpsc::channel();
        let reader = thread::spawn(move || {
            started.wait();
            let _ = sent.send(client.read(&mut [0; 1]));
        });
        start.wait();
        close.shutdown();
        let result = done.recv_timeout(Duration::from_millis(500)).unwrap();
        assert!(result.is_err() || result.unwrap() == 0);
        reader.join().unwrap();
        server.shutdown();
    }
    let file = fs::File::create(state.join("inherited-file")).unwrap();
    assert!(crate::windows::verify_private_handle(file.as_raw_handle(), false).is_ok());
}

#[test]
fn conpty_disconnect_replay_ownership_and_paste() {
    let fixture = Fixture::new();
    let id = new_id().unwrap();
    let original = fixture
        .daemon
        .request(&fixture.request("create", &id))
        .unwrap();
    let pid = original["pid"].as_i64().unwrap();
    let (mut first, _, first_id) = fixture.attach(&id);
    input(&mut first, "echo WINDOW_BEFORE_MARK\r");
    collect(&mut first, |_, bytes| {
        String::from_utf8_lossy(bytes).contains("WINDOW_BEFORE_MARK")
    });
    first.shutdown();
    wait_for(|| fixture.info(&id)["clientCount"] == 0);
    let (active, replay, active_id) = fixture.attach(&id);
    assert!(String::from_utf8_lossy(&replay).contains("WINDOW_BEFORE_MARK"));
    assert_eq!(fixture.info(&id)["pid"].as_i64(), Some(pid));
    let (mut passive, _, passive_id) = fixture.attach(&id);
    input(&mut passive, "echo BAD > inactive-sentinel\r");
    write_frame(&mut passive, &Frame::new("ping")).unwrap();
    collect(&mut passive, |frame, _| frame.kind == "pong");
    assert!(!fixture.project.join("inactive-sentinel").exists());
    write_frame(&mut passive, &Frame::new("claim")).unwrap();
    collect(&mut passive, |frame, _| {
        frame.kind == "state"
            && frame
                .result
                .as_ref()
                .is_some_and(|info| info["activeClientId"] == passive_id)
    });
    let mut size = Frame::new("resize");
    size.columns = Some(120);
    size.rows = Some(35);
    write_frame(&mut passive, &size).unwrap();
    collect(&mut passive, |frame, _| {
        frame.kind == "state"
            && frame
                .result
                .as_ref()
                .is_some_and(|info| info["columns"] == 120 && info["rows"] == 35)
    });
    let mut upload = fixture.connect();
    let mut start = fixture.request("pasteStart", &id);
    start.client_id = Some(active_id.clone());
    start.paste_files = Some(vec![PasteFile {
        name: "image 'quoted'.png".into(),
        size: 3,
    }]);
    write_frame(&mut upload, &start).unwrap();
    assert!(read_frame(&mut upload).unwrap().error.is_some());
    start.client_id = Some(passive_id);
    write_frame(&mut upload, &start).unwrap();
    let response = read_frame(&mut upload).unwrap();
    assert!(response.error.is_none(), "{response:?}");
    let mut chunk = start.clone();
    chunk.kind = "pasteChunk".into();
    chunk.upload_id = Some(
        response.result.unwrap()["uploadId"]
            .as_str()
            .unwrap()
            .into(),
    );
    chunk.file_index = Some(0);
    chunk.offset = Some(0);
    chunk.data = Some(STANDARD.encode([0, 1, 255]));
    write_frame(&mut upload, &chunk).unwrap();
    assert!(read_frame(&mut upload).unwrap().error.is_none());
    chunk.kind = "pasteCommit".into();
    write_frame(&mut upload, &chunk).unwrap();
    let response = read_frame(&mut upload).unwrap();
    assert!(response.error.is_none(), "{response:?}");
    let pasted = response.result.unwrap()["paths"][0]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!pasted.starts_with(r"\\?\"));
    let path = PathBuf::from(&pasted);
    assert_eq!(fs::read(&path).unwrap(), [0, 1, 255]);
    let file = crate::windows::private_file(&path, false, false).unwrap();
    crate::windows::verify_private_handle(file.as_raw_handle(), false).unwrap();
    input(
        &mut passive,
        &format!("copy /b \"{pasted}\" \"pasted-by-shell.bin\" >nul\r"),
    );
    wait_for(|| fixture.project.join("pasted-by-shell.bin").is_file());
    assert_eq!(
        fs::read(fixture.project.join("pasted-by-shell.bin")).unwrap(),
        [0, 1, 255]
    );
    assert_ne!(first_id, active_id);
    active.shutdown();
    passive.shutdown();
    upload.shutdown();
}

// Adapted from Kero's TestConsoleCtrlC: a daemon that ignored Ctrl+C must
// reset that inherited policy before launching a ConPTY process.
#[test]
fn conpty_ctrl_c_exits_and_final_output_drains() {
    let fixture = Fixture::new();
    let ping = format!(
        "{}\\System32\\ping.exe",
        std::env::var("SystemRoot").unwrap()
    );
    let (pty, mut child) = Pty::spawn(
        &[ping, "-n".into(), "60".into(), "127.0.0.1".into()],
        fixture.project.to_str().unwrap(),
        BTreeMap::new(),
        160,
        30,
    )
    .unwrap();
    let output = pty.clone();
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let mut chunk = [0; 4096];
        while let Ok(count) = output.read(&mut chunk) {
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk[..count]);
        }
        bytes
    });
    thread::sleep(Duration::from_millis(600));
    pty.write(&[3]).unwrap();
    let wait = thread::spawn(move || child.wait());
    wait_for(|| wait.is_finished());
    let _ = wait.join().unwrap();
    wait_for(|| reader.is_finished());
    assert!(String::from_utf8_lossy(&reader.join().unwrap()).contains("127.0.0.1"));

    let id = new_id().unwrap();
    let mut request = fixture.request("create", &id);
    request.command = Some(vec![
        login_shell(),
        "/D".into(),
        "/C".into(),
        "echo WINDOWS_FINAL_OUTPUT & exit /b 7".into(),
    ]);
    fixture.daemon.request(&request).unwrap();
    wait_for(|| fixture.info(&id)["running"] == false);
    assert_eq!(fixture.info(&id)["exitCode"], 7);
    let (client, replay, _) = fixture.attach(&id);
    assert!(String::from_utf8_lossy(&replay).contains("WINDOWS_FINAL_OUTPUT"));
    client.shutdown();
}

#[test]
fn conpty_crt_arguments_unicode_environment_and_job_kill() {
    assert_eq!(quote_argument(""), "\"\"");
    assert_eq!(quote_argument("a b\\"), "\"a b\\\\\"");
    assert_eq!(quote_argument("a\"b"), "\"a\\\"b\"");
    let fixture = Fixture::new();
    let script = fixture.project.join("args.py");
    fs::write(&script, "import sys, os, json\nprint('ZSHELL_ARGS:' + json.dumps(sys.argv[1:], ensure_ascii=False, separators=(',', ':')), flush=True)\nprint('ZSHELL_ENV:' + os.environ['zshell_fixture'], flush=True)\n").unwrap();
    let python = Command::new("python")
        .args(["-c", "import sys; print(sys.executable)"])
        .output()
        .unwrap();
    let arguments = vec!["", "space argument", "quote\"here", "slash\\", "中文"];
    let command: Vec<String> =
        std::iter::once(String::from_utf8(python.stdout).unwrap().trim().into())
            .chain(std::iter::once(script.to_string_lossy().into_owned()))
            .chain(arguments.iter().map(|arg| arg.to_string()))
            .collect();
    let (pty, mut child) = Pty::spawn(
        &command,
        fixture.project.to_str().unwrap(),
        BTreeMap::from([
            ("zshell_fixture".into(), "中文 value".into()),
            ("PYTHONIOENCODING".into(), "utf-8".into()),
        ]),
        200,
        30,
    )
    .unwrap();
    let output = pty.clone();
    let reader = thread::spawn(move || {
        let mut all = Vec::new();
        let mut bytes = [0; 4096];
        while let Ok(count) = output.read(&mut bytes) {
            if count == 0 {
                break;
            }
            all.extend_from_slice(&bytes[..count]);
        }
        all
    });
    assert_eq!(child.wait(), 0);
    wait_for(|| reader.is_finished());
    let bytes = reader.join().unwrap();
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("中文 value"), "{text}");
    let values = text.split_once("ZSHELL_ARGS:").unwrap().1;
    let parsed: Vec<String> = serde_json::Deserializer::from_str(values)
        .into_iter::<Vec<String>>()
        .next()
        .unwrap()
        .unwrap();
    assert_eq!(parsed, arguments);

    let id = new_id().unwrap();
    let mut request = fixture.request("create", &id);
    request.command = Some(vec![
        login_shell(),
        "/D".into(),
        "/K".into(),
        "ping -n 60 127.0.0.1".into(),
    ]);
    fixture.daemon.request(&request).unwrap();
    let pid = fixture.info(&id)["pid"].as_u64().unwrap() as u32;
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    assert!(!process.is_null());
    fixture
        .daemon
        .request(&fixture.request("terminate", &id))
        .unwrap();
    assert_eq!(
        unsafe { WaitForSingleObject(process, 10_000) },
        WAIT_OBJECT_0
    );
    unsafe {
        CloseHandle(process);
    }
}
