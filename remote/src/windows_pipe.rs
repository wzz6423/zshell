use crate::protocol::invalid;
use crate::transport::Stream;
use crate::windows::{process_sid, wide, Handle, Security};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{self, Read, Write};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Pipes::*;
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::System::IO::*;

struct Shared {
    handle: Handle,
    closed: AtomicBool,
    read_ms: AtomicU32,
    write_ms: AtomicU32,
}

#[derive(Clone)]
pub struct Pipe(Arc<Shared>);

impl Pipe {
    pub fn peer_pid(&self) -> Option<i32> {
        let mut pid = 0;
        (unsafe { GetNamedPipeClientProcessId(self.0.handle.0, &mut pid) } != 0
            && pid > 1
            && pid <= i32::MAX as u32)
            .then_some(pid as i32)
    }
    fn from_handle(handle: Handle) -> Self {
        Self(Arc::new(Shared {
            handle,
            closed: AtomicBool::new(false),
            read_ms: AtomicU32::new(10_000),
            write_ms: AtomicU32::new(10_000),
        }))
    }

    pub fn connect(state: &Path) -> io::Result<Self> {
        let name = pipe_name(state)?;
        let name = wide(name);
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                ptr::null_mut(),
            )
        };
        let handle = if handle == INVALID_HANDLE_VALUE {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) {
                return Err(error);
            }
            if unsafe { WaitNamedPipeW(name.as_ptr(), 2_000) } == 0 {
                return Err(io::Error::last_os_error());
            }
            let handle = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    ptr::null(),
                    OPEN_EXISTING,
                    FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                    ptr::null_mut(),
                )
            };
            if handle == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }
            Handle(handle)
        } else {
            Handle(handle)
        };
        verify_peer(handle.0, false)?;
        Ok(Self::from_handle(handle))
    }

    pub fn deadlines(&self, read: Duration, write: Duration) {
        self.0.read_ms.store(
            read.as_millis().clamp(1, u32::MAX as u128 - 1) as u32,
            Ordering::Release,
        );
        self.0.write_ms.store(
            write.as_millis().clamp(1, u32::MAX as u128 - 1) as u32,
            Ordering::Release,
        );
    }

    pub fn shutdown(&self) {
        self.0.closed.store(true, Ordering::Release);
        unsafe {
            CancelIoEx(self.0.handle.0, ptr::null());
        }
    }

    fn transfer(&self, buffer: *mut u8, count: usize, read: bool) -> io::Result<usize> {
        if count == 0 {
            return Ok(0);
        }
        if self.0.closed.load(Ordering::Acquire) {
            return if read {
                Ok(0)
            } else {
                Err(io::ErrorKind::BrokenPipe.into())
            };
        }
        let event = event()?;
        let mut operation: OVERLAPPED = unsafe { std::mem::zeroed() };
        operation.hEvent = event.0;
        let mut transferred = 0;
        let started = unsafe {
            if read {
                ReadFile(
                    self.0.handle.0,
                    buffer,
                    count.min(u32::MAX as usize) as u32,
                    &mut transferred,
                    &mut operation,
                )
            } else {
                WriteFile(
                    self.0.handle.0,
                    buffer.cast_const(),
                    count.min(u32::MAX as usize) as u32,
                    &mut transferred,
                    &mut operation,
                )
            }
        };
        if started == 0 {
            let error = io::Error::last_os_error();
            if read && error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
                return Ok(0);
            }
            if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
                return Err(error);
            }
            // Shutdown may have cancelled before this operation was submitted.
            // Cancel the pending operation too before waiting on its buffer.
            if self.0.closed.load(Ordering::Acquire) {
                unsafe {
                    CancelIoEx(self.0.handle.0, &operation);
                }
            }
            let timeout = if read {
                &self.0.read_ms
            } else {
                &self.0.write_ms
            }
            .load(Ordering::Acquire);
            let result = complete(self.0.handle.0, &mut operation, timeout);
            if read
                && result
                    .as_ref()
                    .err()
                    .is_some_and(|e| e.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32))
            {
                return Ok(0);
            }
            return result;
        }
        Ok(transferred as usize)
    }

    // ConPTY's endpoints must use synchronous handles. The host endpoint is
    // overlapped so a stalled process cannot hold a session writer forever.
    pub fn conpty_pair() -> io::Result<(Self, Handle)> {
        let name = format!(r"\\.\pipe\zshell-conpty-{}", crate::protocol::new_id()?);
        let server = create(&name, true)?;
        let name = wide(name);
        let client = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                ptr::null_mut(),
            )
        };
        if client == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let client = Handle(client);
        accept(&server)?;
        verify_peer(server.0, true)?;
        verify_peer(client.0, false)?;
        Ok((Self::from_handle(server), client))
    }
}

impl Read for Pipe {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.transfer(bytes.as_mut_ptr(), bytes.len(), true)
    }
}
impl Write for Pipe {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.transfer(bytes.as_ptr().cast_mut(), bytes.len(), false)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn pipe_name(state: &Path) -> io::Result<String> {
    let owner = process_sid(unsafe { GetCurrentProcessId() })?;
    let mut hash = DefaultHasher::new();
    std::fs::canonicalize(state)?
        .to_string_lossy()
        .to_lowercase()
        .hash(&mut hash);
    Ok(format!(
        r"\\.\pipe\zshell-remote-{owner}-{:016x}",
        hash.finish()
    ))
}

fn create(name: &str, first: bool) -> io::Result<Handle> {
    let security = Security::private(false)?;
    let name = wide(name);
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX
                | FILE_FLAG_OVERLAPPED
                | if first {
                    FILE_FLAG_FIRST_PIPE_INSTANCE
                } else {
                    0
                },
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            2_000,
            &security.attributes(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    Ok(Handle(handle))
}

fn event() -> io::Result<Handle> {
    let handle = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
    if handle.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(Handle(handle))
    }
}

fn complete(handle: HANDLE, operation: &mut OVERLAPPED, timeout: u32) -> io::Result<usize> {
    let wait = unsafe { WaitForSingleObject(operation.hEvent, timeout) };
    let mut transferred = 0;
    if wait != WAIT_OBJECT_0 {
        let error = if wait == WAIT_TIMEOUT {
            io::Error::new(io::ErrorKind::TimedOut, "Remote pipe operation timed out")
        } else {
            io::Error::last_os_error()
        };
        // The OVERLAPPED and caller buffer must outlive cancellation.
        unsafe {
            CancelIoEx(handle, operation);
            GetOverlappedResult(handle, operation, &mut transferred, 1);
        }
        return Err(error);
    }
    if unsafe { GetOverlappedResult(handle, operation, &mut transferred, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(transferred as usize)
}

fn accept(handle: &Handle) -> io::Result<()> {
    let event = event()?;
    let mut operation: OVERLAPPED = unsafe { std::mem::zeroed() };
    operation.hEvent = event.0;
    if unsafe { ConnectNamedPipe(handle.0, &mut operation) } != 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(code) if code == ERROR_PIPE_CONNECTED as i32 => Ok(()),
        Some(code) if code == ERROR_IO_PENDING as i32 => {
            complete(handle.0, &mut operation, INFINITE).map(|_| ())
        }
        _ => Err(error),
    }
}

fn verify_peer(handle: HANDLE, server: bool) -> io::Result<()> {
    let mut pid = 0;
    let result = unsafe {
        if server {
            GetNamedPipeClientProcessId(handle, &mut pid)
        } else {
            GetNamedPipeServerProcessId(handle, &mut pid)
        }
    };
    if result == 0 {
        return Err(io::Error::last_os_error());
    }
    if process_sid(pid)? != process_sid(unsafe { GetCurrentProcessId() })? {
        return Err(invalid("Remote pipe belongs to a different Windows user"));
    }
    Ok(())
}

pub struct LocalListener {
    name: String,
    pending: Option<Handle>,
}
impl LocalListener {
    pub fn bind(state: &Path) -> io::Result<Self> {
        let name = pipe_name(state)?;
        let pending = Some(create(&name, true)?);
        Ok(Self { name, pending })
    }
    pub fn accept(&mut self) -> io::Result<Stream> {
        loop {
            let handle = self.pending.take().unwrap();
            let connected = accept(&handle);
            self.pending = Some(create(&self.name, false)?);
            if let Err(error) = connected {
                // A client may close before ConnectNamedPipe observes it.
                // That abandoned instance must not stop the daemon's listener.
                if error.raw_os_error().is_some_and(|code| {
                    code == ERROR_NO_DATA as i32 || code == ERROR_BROKEN_PIPE as i32
                }) {
                    continue;
                }
                return Err(error);
            }
            if verify_peer(handle.0, true).is_ok() {
                return Ok(Stream::Pipe(Pipe::from_handle(handle)));
            }
        }
    }
}
