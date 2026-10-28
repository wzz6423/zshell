use crate::protocol::invalid;
use serde_json::Value;
use std::fs::OpenOptions;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, TcpStream};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub enum Stream {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl Stream {
    pub fn peer_pid(&self) -> Option<i32> {
        match self {
            Self::Unix(stream) => peer_pid(stream.as_raw_fd()).ok(),
            Self::Tcp(_) => None,
        }
    }
    pub fn try_clone(&self) -> io::Result<Self> {
        match self {
            Self::Unix(s) => s.try_clone().map(Self::Unix),
            Self::Tcp(s) => s.try_clone().map(Self::Tcp),
        }
    }
    pub fn shutdown(&self) {
        match self {
            Self::Unix(s) => {
                let _ = s.shutdown(Shutdown::Both);
            }
            Self::Tcp(s) => {
                let _ = s.shutdown(Shutdown::Both);
            }
        }
    }
    pub fn shutdown_write(&self) {
        match self {
            Self::Unix(s) => {
                let _ = s.shutdown(Shutdown::Write);
            }
            Self::Tcp(s) => {
                let _ = s.shutdown(Shutdown::Write);
            }
        }
    }
    pub fn deadlines(&self, read: Duration, write: Duration) -> io::Result<()> {
        match self {
            Self::Unix(s) => {
                s.set_read_timeout(Some(read))?;
                s.set_write_timeout(Some(write))
            }
            Self::Tcp(s) => {
                s.set_nodelay(true)?;
                s.set_read_timeout(Some(read))?;
                s.set_write_timeout(Some(write))
            }
        }
    }
}

impl Read for Stream {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Unix(s) => s.read(b),
            Self::Tcp(s) => s.read(b),
        }
    }
}
impl Write for Stream {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        match self {
            Self::Unix(s) => s.write(b),
            Self::Tcp(s) => s.write(b),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Unix(s) => s.flush(),
            Self::Tcp(s) => s.flush(),
        }
    }
}

pub fn expand_path(path: &str) -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| invalid("HOME is unavailable"))?;
    Ok(if path == "~" {
        home
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(path)
    })
}

pub fn project_path(path: &str) -> io::Result<String> {
    if path.len() > 16_384 || path.contains('\0') {
        return Err(invalid("Invalid project directory"));
    }
    let path = fs::canonicalize(expand_path(path)?)?;
    if !path.is_dir() {
        return Err(invalid("Project is not a directory"));
    }
    shell_path(&path)
}

pub fn shell_path(path: &Path) -> io::Result<String> {
    let text = path
        .to_str()
        .ok_or_else(|| invalid("Path must be valid UTF-8"))?;
    Ok(text.to_owned())
}

pub fn prepare_state(path: &Path) -> io::Result<()> {
    if !path.exists() {
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(invalid(
            "Remote state must be an owner-only 0700 directory, without symlinks",
        ));
    }
    Ok(())
}

pub fn lock_state(path: &Path) -> io::Result<File> {
    prepare_state(path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path.join("daemon.lock"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
    {
        return Err(invalid(
            "Remote daemon lock must be an owner-only 0600 file",
        ));
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

pub fn remove_stale_socket(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.file_type().is_socket() && metadata.uid() == unsafe { libc::geteuid() } =>
        {
            fs::remove_file(path)
        }
        Ok(_) => Err(invalid(
            "Refusing to replace a non-socket or another user's socket",
        )),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn same_user(stream: &UnixStream) -> bool {
    peer_uid(stream.as_raw_fd()).ok() == Some(unsafe { libc::geteuid() })
}

pub fn connect_control(state: &Path) -> io::Result<Stream> {
    let path = state.join("control.sock");
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
    {
        return Err(invalid(
            "Remote control socket must be an owner-only 0600 socket",
        ));
    }
    let stream = UnixStream::connect(path)?;
    if !same_user(&stream) {
        return Err(invalid("Remote daemon belongs to a different user"));
    }
    Ok(Stream::Unix(stream))
}

pub struct LocalListener(UnixListener);
impl LocalListener {
    pub fn bind(state: &Path) -> io::Result<Self> {
        let path = state.join("control.sock");
        remove_stale_socket(&path)?;
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        Ok(Self(listener))
    }
    pub fn accept(&mut self) -> io::Result<Stream> {
        loop {
            let (stream, _) = self.0.accept()?;
            if same_user(&stream) {
                return Ok(Stream::Unix(stream));
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn peer_pid(fd: RawFd) -> io::Result<i32> {
    let mut pid = 0i32;
    let mut size = std::mem::size_of_val(&pid) as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            fd,
            0,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut i32).cast(),
            &mut size,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if pid <= 1 {
        return Err(invalid("Invalid local peer process"));
    }
    Ok(pid)
}

#[cfg(target_os = "linux")]
fn peer_pid(fd: RawFd) -> io::Result<i32> {
    let mut credentials = unsafe { std::mem::zeroed::<libc::ucred>() };
    let mut size = std::mem::size_of_val(&credentials) as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut size,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(credentials.pid)
}

#[cfg(target_os = "macos")]
fn peer_uid(fd: RawFd) -> io::Result<u32> {
    let mut uid = 0;
    let mut gid = 0;
    if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } != 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(uid)
    }
}

#[cfg(target_os = "linux")]
fn peer_uid(fd: RawFd) -> io::Result<u32> {
    let mut credentials = unsafe { std::mem::zeroed::<libc::ucred>() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credentials as *mut _ as *mut _,
            &mut length,
        )
    } != 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(credentials.uid)
    }
}

pub fn is_tailnet(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let b = ip.octets();
            b[0] == 100 && (64..=127).contains(&b[1])
        }
        IpAddr::V6(ip) => ip.octets()[..6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0],
    }
}

pub struct TailnetPolicy {
    pub executable: PathBuf,
    pub allow: Vec<String>,
}

pub fn tailscale_executable() -> PathBuf {
    let paths = std::env::var_os("PATH")
        .map(|path| {
            std::env::split_paths(&path)
                .map(|directory| directory.join("tailscale"))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    paths
        .into_iter()
        .chain([
            PathBuf::from("/opt/homebrew/bin/tailscale"),
            PathBuf::from("/usr/local/bin/tailscale"),
            PathBuf::from("/usr/bin/tailscale"),
            PathBuf::from("/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        ])
        .find(|path| {
            path.metadata()
                .is_ok_and(|metadata| metadata.is_file() && metadata.mode() & 0o111 != 0)
        })
        .unwrap_or_else(|| PathBuf::from("tailscale"))
}

impl TailnetPolicy {
    pub fn addresses(&self) -> io::Result<Vec<IpAddr>> {
        let status = self.command(&["status", "--json"])?;
        if status["BackendState"] != "Running" {
            return Err(invalid("Tailscale is not connected"));
        }
        let addresses = status["Self"]["TailscaleIPs"]
            .as_array()
            .ok_or_else(|| invalid("Tailscale is not connected"))?;
        let ips: Vec<IpAddr> = addresses
            .iter()
            .filter_map(Value::as_str)
            .filter_map(|ip| ip.parse().ok())
            .filter(|ip| is_tailnet(*ip))
            .collect();
        if ips.is_empty() {
            return Err(invalid("Tailscale has no private address"));
        }
        Ok(ips)
    }

    pub fn authorize(&self, peer: std::net::SocketAddr) -> io::Result<()> {
        if !is_tailnet(peer.ip()) {
            return Err(invalid("Only Tailscale peers may connect"));
        }
        let status = self.command(&["status", "--json"])?;
        if status["BackendState"] != "Running" {
            return Err(invalid("Tailscale is not connected"));
        }
        if status["Self"]["TailscaleIPs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .any(|s| s.parse::<IpAddr>().ok() == Some(peer.ip()))
        {
            // Whois identifies this machine's owner, not the local process UID.
            // Same-machine clients must use the peer-credential-checked socket.
            return Err(invalid(
                "Use SSH or the Unix socket for a client on this machine",
            ));
        }
        let who = self.command(&["whois", "--json", &peer.to_string()])?;
        if !who["Node"].is_object() {
            return Err(invalid("Tailscale peer has no device identity"));
        }
        let login = who["UserProfile"]["LoginName"]
            .as_str()
            .ok_or_else(|| invalid("Tailscale peer has no user identity"))?;
        let owner_id = status["Self"]["UserID"].as_u64().map(|id| id.to_string());
        let self_tagged = status["Self"]["Tags"]
            .as_array()
            .is_some_and(|tags| !tags.is_empty());
        let owner = if self_tagged {
            None
        } else {
            owner_id
                .as_deref()
                .and_then(|id| status["User"][id]["LoginName"].as_str())
        };
        let tagged = who["Node"]["Tags"]
            .as_array()
            .is_some_and(|tags| !tags.is_empty());
        if login.is_empty()
            || tagged
            || !(owner == Some(login) || self.allow.iter().any(|allowed| allowed == login))
        {
            return Err(invalid(
                "Tailscale peer is not the machine owner or an allowed user",
            ));
        }
        Ok(())
    }

    fn command(&self, args: &[&str]) -> io::Result<Value> {
        let mut child = Command::new(&self.executable)
            .args(args)
            .env("TAILSCALE_BE_CLI", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child.stdout.take().unwrap();
        let reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout
                .take(2 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes)
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait()? {
                let bytes = reader
                    .join()
                    .map_err(|_| invalid("Tailscale output reader failed"))??;
                if !status.success() || bytes.len() > 2 * 1024 * 1024 {
                    return Err(invalid("Tailscale identity lookup failed"));
                }
                return serde_json::from_slice(&bytes).map_err(invalid);
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(invalid("Tailscale identity lookup timed out"));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::new_id;

    #[test]
    fn state_rejects_symlinks_and_shared_permissions() {
        let path =
            std::env::temp_dir().join(format!("zshell-remote-permissions-{}", new_id().unwrap()));
        prepare_state(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(prepare_state(&path).is_err());
        let link = path.with_extension("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(prepare_state(&link).is_err());
        fs::remove_file(link).unwrap();
        fs::remove_dir(path).unwrap();
    }

    #[test]
    fn tailnet_ranges_and_local_peer_credentials() {
        assert!(is_tailnet("100.64.0.1".parse().unwrap()));
        assert!(is_tailnet("fd7a:115c:a1e0::1".parse().unwrap()));
        for ip in ["127.0.0.1", "10.0.0.1", "100.128.0.1", "1.1.1.1", "::1"] {
            assert!(!is_tailnet(ip.parse().unwrap()));
        }
        let (first, _) = UnixStream::pair().unwrap();
        assert!(same_user(&first));
    }
}
