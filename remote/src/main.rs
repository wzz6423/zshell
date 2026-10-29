#![cfg(any(target_os = "macos", target_os = "linux"))]

mod agent;
mod agent_history;
mod agent_hooks;
mod agent_process;
mod codex_binding;
mod daemon;
mod paste;
mod protocol;
mod pty;
mod session;
mod shell_completions;
mod terminal;
mod transport;

use base64::{engine::general_purpose::STANDARD, Engine};
use protocol::*;
#[cfg(test)]
use std::fs;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::fd::FromRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
#[cfg(test)]
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use transport::*;

static WINDOW_CHANGED: AtomicBool = AtomicBool::new(false);

fn main() {
    let result = run();
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("zshell-server: {error}");
            std::process::exit(1);
        }
    }
}

struct Options {
    args: Vec<String>,
    state: PathBuf,
    project: Option<String>,
    session: Option<String>,
    tcp: Option<String>,
    listen: Option<u16>,
    tailscale: PathBuf,
    allow: Vec<String>,
}

impl Options {
    fn parse() -> io::Result<Self> {
        let mut args: Vec<String> = std::env::args().skip(1).collect();
        let state = take_option(&mut args, "--state")?
            .or_else(|| std::env::var("ZSHELL_REMOTE_STATE").ok())
            .unwrap_or_else(|| "~/.local/state/zshell-remote".into());
        let project = take_option(&mut args, "--project")?;
        let session = take_option(&mut args, "--session")?;
        let tcp = take_option(&mut args, "--tcp")?;
        let listen = take_option(&mut args, "--listen")?
            .map(|value| {
                value
                    .strip_prefix("tailscale://:")
                    .ok_or_else(|| invalid("Listen must be tailscale://:PORT"))?
                    .parse::<u16>()
                    .map_err(invalid)
                    .and_then(|port| {
                        if port == 0 {
                            Err(invalid("Port must be 1–65535"))
                        } else {
                            Ok(port)
                        }
                    })
            })
            .transpose()?;
        let tailscale = take_option(&mut args, "--tailscale")?
            .map(PathBuf::from)
            .unwrap_or_else(tailscale_executable);
        let mut allow = Vec::new();
        while let Some(user) = take_option(&mut args, "--allow-user")? {
            if user.is_empty() || user == "*" || user.contains(char::is_whitespace) {
                return Err(invalid("Allow users by their exact Tailscale login"));
            }
            allow.push(user);
        }
        Ok(Self {
            args,
            state: expand_path(&state)?,
            project,
            session,
            tcp,
            listen,
            tailscale,
            allow,
        })
    }
}

fn take_option(args: &mut Vec<String>, option: &str) -> io::Result<Option<String>> {
    let end = args
        .iter()
        .position(|arg| arg == "--")
        .unwrap_or(args.len());
    let Some(index) = args[..end].iter().position(|arg| arg == option) else {
        return Ok(None);
    };
    if index + 1 >= end {
        return Err(invalid(format!("{option} requires a value")));
    }
    args.remove(index);
    Ok(Some(args.remove(index)))
}

fn run() -> io::Result<i32> {
    let options = Options::parse()?;
    let command = options.args.first().map(String::as_str).unwrap_or("help");
    if command == "--licenses" {
        print!(
            "{}",
            include_str!("../../mac/zshell/ThirdPartyNotices/Kero.txt")
        );
        print!("{}", include_str!("../../mac/zshell/ShellIntegration/TerminalCompletions/SOURCES.txt"));
        print!("{}", include_str!("../../mac/zshell/ShellIntegration/TerminalCompletions/LICENSE-zsh-autosuggestions.txt"));
        print!("{}", include_str!("../../mac/zshell/ShellIntegration/TerminalCompletions/LICENSE-zsh-completions.txt"));
        return Ok(0);
    }
    if matches!(command, "version" | "--version") {
        let version = serde_json::json!({"version": env!("CARGO_PKG_VERSION"), "protocolVersion": VERSION,
            "platform": std::env::consts::OS, "architecture": std::env::consts::ARCH});
        if options.args.iter().any(|argument| argument == "--json") {
            println!("{version}");
        } else {
            println!(
                "zshell-server {} ({} {})",
                env!("CARGO_PKG_VERSION"),
                std::env::consts::OS,
                std::env::consts::ARCH
            );
        }
        return Ok(0);
    }
    if command == "help" || command == "--help" {
        println!("Zshell remote server (macOS / Linux)\n\nUsage: zshell-server COMMAND [--state PATH] [--project PATH] [--session UUID]\n\n  serve       Run the PTY daemon in the foreground\n  start       Start an owner-only daemon in the background\n  bridge      SSH stdio bridge; starts the daemon when needed\n  status      Inspect a running daemon without starting it\n  projects    List the daemon's project directories\n  list        List sessions in --project\n  create      Create a persistent shell; optional --session UUID and -- /absolute/program args\n  attach      Attach to --session in --project; Ctrl-] detaches\n  terminate   End --session and all its jobs in --project\n  stop        End all remote sessions and stop this daemon\n\nserve --listen tailscale://:7373 [--allow-user alice@example.com]\nClients can add --tcp devbox:7373 for a Tailscale connection.\nAll session operations require their project directory. SSH keeps ~/.ssh/config and agent authentication.");
        return Ok(0);
    }
    match command {
        "agent-hooks" if options.args.get(1).map(String::as_str) == Some("install") => {
            println!("{}", agent_hooks::install(&options.state)?);
            return Ok(0);
        }
        "hook" => {
            let provider = options.args.get(1).map(String::as_str).unwrap_or("");
            if std::env::var("ZSHELL_AUTOMATION").ok().as_deref() != Some("1")
                && !(provider == "codex"
                    && agent_process::shared_codex_service(
                        std::process::id() as i32,
                        std::process::id() as i32,
                    )
                    .is_some())
            {
                return Ok(0);
            }
            let payload = agent_hooks::read_payload()?;
            let environment = std::env::vars().collect();
            let Some(frame) = agent_hooks::invocation(
                provider,
                &payload,
                &environment,
                std::process::id() as i32,
            )?
            else {
                return Ok(0);
            };
            // Hooks never start a daemon or fall back to a different host.
            let mut stream = connect_local(&options.state, false)?;
            stream.deadlines(Duration::from_secs(3), Duration::from_secs(3))?;
            client_handshake(&mut stream)?;
            write_frame(&mut stream, &frame)?;
            let response = read_frame(&mut stream)?;
            if let Some(error) = response.error {
                return Err(invalid(error));
            }
            return Ok(0);
        }
        "serve" => {
            daemon::Daemon::serve(
                &options.state,
                options.listen,
                options.tailscale,
                options.allow,
            )?;
            return Ok(0);
        }
        "start" => {
            let _ = connect_local(&options.state, true)?;
            println!("Remote daemon is running");
            return Ok(0);
        }
        "bridge" => {
            bridge(&options.state)?;
            return Ok(0);
        }
        _ => {}
    }
    let mut stream = if let Some(address) = &options.tcp {
        connect_tailnet(address)?
    } else {
        connect_local(&options.state, !matches!(command, "status" | "stop"))?
    };
    stream.deadlines(Duration::from_secs(10), Duration::from_secs(10))?;
    client_handshake(&mut stream)?;
    let method = match command {
        "status" => "hello",
        "stop" => "shutdown",
        "projects" | "list" | "create" | "terminate" => command,
        "attach" => return attach(stream, &options),
        _ => return Err(invalid("Unknown command; use zshell-server help")),
    };
    let mut request = Frame::new(method);
    request.request_id = Some(new_id()?);
    request.project = options.project.clone();
    request.session_id = options.session.clone();
    if command == "create" {
        request.session_id = Some(options.session.clone().unwrap_or(new_id()?));
        if let Some(index) = options.args.iter().position(|arg| arg == "--") {
            request.command = Some(options.args[index + 1..].to_vec());
        }
    }
    write_frame(&mut stream, &request)?;
    let response = read_frame(&mut stream)?;
    if let Some(error) = response.error {
        return Err(invalid(error));
    }
    if response.request_id != request.request_id {
        return Err(invalid("Mismatched remote response"));
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&response.result).map_err(invalid)?
    );
    Ok(0)
}

fn connect_local(state: &Path, start: bool) -> io::Result<Stream> {
    prepare_state(state)?;
    let connect = || connect_control(state);
    if let Ok(stream) = connect() {
        return Ok(stream);
    }
    if !start {
        return connect();
    }
    let log = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(state.join("daemon.log"))?;
    if log.metadata()?.uid() != unsafe { libc::geteuid() }
        || log.metadata()?.mode() & 0o777 != 0o600
    {
        return Err(invalid("Remote daemon log must be an owner-only 0600 file"));
    }
    let mut launch = Command::new(std::env::current_exe()?);
    launch
        .arg("serve")
        .arg("--state")
        .arg(state)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(log));
    unsafe {
        launch.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = launch.spawn()?;
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Ok(stream) = connect() {
            return Ok(stream);
        }
        if let Some(status) = child.try_wait()? {
            if !status.success() {
                return Err(invalid(
                    "Remote daemon could not start; inspect its private daemon.log",
                ));
            }
        }
        if Instant::now() >= deadline {
            return Err(invalid("Remote daemon startup timed out"));
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn connect_tailnet(address: &str) -> io::Result<Stream> {
    let addresses: Vec<_> = address
        .to_socket_addrs()?
        .filter(|address| is_tailnet(address.ip()))
        .collect();
    if addresses.is_empty() {
        return Err(invalid(
            "The host must resolve to a Tailscale private address",
        ));
    }
    let mut error = invalid("Could not connect to the Tailscale host");
    for address in addresses {
        match TcpStream::connect_timeout(&address, Duration::from_secs(10)) {
            Ok(stream) => return Ok(Stream::Tcp(stream)),
            Err(e) => error = e,
        }
    }
    Err(error)
}

fn bridge(state: &Path) -> io::Result<()> {
    let stream = connect_local(state, true)?;
    let mut output = stream.try_clone()?;
    let mut input = stream;
    let close = input.try_clone()?;
    thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut input);
        close.shutdown_write();
    });
    // Stdout's line buffer would withhold a binary handshake until a newline.
    let mut stdout = unbuffered_stdout()?;
    io::copy(&mut output, &mut stdout)?;
    Ok(())
}

fn unbuffered_stdout() -> io::Result<File> {
    let descriptor = unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_DUPFD_CLOEXEC, 0) };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

struct RawTerminal(Option<libc::termios>);
impl RawTerminal {
    fn new() -> io::Result<Self> {
        if unsafe { libc::isatty(0) } != 1 {
            return Ok(Self(None));
        }
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(0, &mut original) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(Some(original)))
    }
}
impl Drop for RawTerminal {
    fn drop(&mut self) {
        if let Some(original) = &self.0 {
            unsafe {
                libc::tcsetattr(0, libc::TCSANOW, original);
            }
        }
    }
}

fn dimensions() -> (u16, u16) {
    let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
    unsafe {
        libc::ioctl(0, libc::TIOCGWINSZ as _, &mut size);
    }
    (size.ws_col.clamp(1, 512), size.ws_row.clamp(1, 128))
}

fn attach(mut stream: Stream, options: &Options) -> io::Result<i32> {
    let _raw = RawTerminal::new()?;
    let (columns, rows) = dimensions();
    let mut request = Frame::new("attach");
    request.project = options.project.clone();
    request.session_id = options.session.clone();
    request.client_id = Some(new_id()?);
    request.columns = Some(columns);
    request.rows = Some(rows);
    write_frame(&mut stream, &request)?;
    let response = read_frame(&mut stream)?;
    if let Some(error) = response.error {
        return Err(invalid(error));
    }
    if response.kind != "attached" {
        return Err(invalid("Server did not attach the session"));
    }
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    write_frame(&mut *writer.lock().unwrap(), &Frame::new("claim"))?;
    extern "C" fn resized(_: libc::c_int) {
        WINDOW_CHANGED.store(true, Ordering::Relaxed);
    }
    unsafe {
        libc::signal(libc::SIGWINCH, resized as *const () as _);
    }
    let input_writer = writer.clone();
    thread::spawn(move || {
        let mut buffer = [0; 8192];
        while let Ok(count) = io::stdin().read(&mut buffer) {
            if count == 0 || buffer[..count].contains(&0x1d) {
                let _ = write_frame(&mut *input_writer.lock().unwrap(), &Frame::new("detach"));
                break;
            }
            let mut frame = Frame::new("input");
            frame.data = Some(STANDARD.encode(&buffer[..count]));
            if write_frame(&mut *input_writer.lock().unwrap(), &frame).is_err() {
                break;
            }
        }
    });
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(1));
        let mut frame = Frame::new("ping");
        if WINDOW_CHANGED.swap(false, Ordering::Relaxed) {
            let (columns, rows) = dimensions();
            frame.kind = "resize".into();
            frame.columns = Some(columns);
            frame.rows = Some(rows);
        }
        if write_frame(&mut *writer.lock().unwrap(), &frame).is_err() {
            break;
        }
    });
    stream.deadlines(Duration::from_secs(15), Duration::from_secs(10))?;
    loop {
        let frame = match read_frame(&mut stream) {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(0),
            Err(error) => return Err(error),
        };
        if let Some(error) = frame.error {
            return Err(invalid(error));
        }
        if matches!(frame.kind.as_str(), "snapshot" | "output") {
            let bytes = STANDARD
                .decode(frame.data.unwrap_or_default())
                .map_err(invalid)?;
            io::stdout().write_all(&bytes)?;
            io::stdout().flush()?;
        }
        if frame.kind == "exited" {
            return Ok(frame.exit_code.unwrap_or(1));
        }
    }
}

#[cfg(test)]
mod tests;
