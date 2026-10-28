use crate::protocol::invalid;
use crate::windows::{wide, Handle};
use crate::windows_pipe::Pipe;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{mem, ptr};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Console::*;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Threading::*;

// ConPTY lifecycle and resize ordering follow Kero's pty_windows.go
// (580bdfa8f6a43d71d145958ab76c1bbb45c465f0); see third-party notices.
struct Console {
    handle: HPCON,
    columns: u16,
    rows: u16,
}

pub struct Pty {
    console: Mutex<Console>,
    input: Pipe,
    output: Pipe,
    job: Handle,
    pid: i32,
}

pub struct PtyChild {
    process: Handle,
    pty: Arc<Pty>,
}

impl PtyChild {
    pub fn wait(&mut self) -> i32 {
        unsafe {
            WaitForSingleObject(self.process.0, INFINITE);
        }
        let mut code = 1;
        unsafe {
            GetExitCodeProcess(self.process.0, &mut code);
        }
        unsafe {
            TerminateJobObject(self.pty.job.0, code);
        }
        self.pty.close_console();
        code as i32
    }
}

struct Attributes {
    storage: Vec<usize>,
    initialized: bool,
}
impl Drop for Attributes {
    fn drop(&mut self) {
        if self.initialized {
            unsafe {
                DeleteProcThreadAttributeList(self.storage.as_mut_ptr().cast());
            }
        }
    }
}

impl Pty {
    pub fn spawn(
        command: &[String],
        project: &str,
        environment: BTreeMap<String, String>,
        columns: u16,
        rows: u16,
    ) -> io::Result<(Arc<Self>, PtyChild)> {
        let (input, in_read) = Pipe::conpty_pair()?;
        let (output, out_write) = Pipe::conpty_pair()?;
        input.deadlines(Duration::from_secs(10), Duration::from_secs(2));
        output.deadlines(
            Duration::from_millis(u32::MAX as u64 - 1),
            Duration::from_secs(2),
        );
        let mut console = 0;
        let result = unsafe {
            CreatePseudoConsole(
                COORD {
                    X: columns as i16,
                    Y: rows as i16,
                },
                in_read.0,
                out_write.0,
                0,
                &mut console,
            )
        };
        if result < 0 {
            return Err(io::Error::from_raw_os_error(result));
        }
        drop(in_read);
        drop(out_write);
        let job = Handle(unsafe { CreateJobObjectW(ptr::null(), ptr::null()) });
        if job.0.is_null() {
            unsafe {
                ClosePseudoConsole(console);
            }
            return Err(io::Error::last_os_error());
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            unsafe {
                ClosePseudoConsole(console);
            }
            return Err(io::Error::last_os_error());
        }
        let pty = Arc::new(Self {
            console: Mutex::new(Console {
                handle: console,
                columns,
                rows,
            }),
            input,
            output,
            job,
            pid: 0,
        });
        let mut bytes = 0;
        unsafe {
            InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut bytes);
        }
        let mut attributes = Attributes {
            storage: vec![0; bytes.div_ceil(mem::size_of::<usize>())],
            initialized: false,
        };
        if unsafe {
            InitializeProcThreadAttributeList(
                attributes.storage.as_mut_ptr().cast(),
                1,
                0,
                &mut bytes,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        attributes.initialized = true;
        if unsafe {
            UpdateProcThreadAttribute(
                attributes.storage.as_mut_ptr().cast(),
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                console as *const _,
                mem::size_of_val(&console),
                ptr::null_mut(),
                ptr::null(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut startup: STARTUPINFOEXW = unsafe { mem::zeroed() };
        startup.StartupInfo.cb = mem::size_of::<STARTUPINFOEXW>() as u32;
        // A background daemon's inherited handles point at its log. ConPTY
        // supplies the console handles when those inherited handles are invalid.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
        startup.lpAttributeList = attributes.storage.as_mut_ptr().cast();
        let application = wide(&command[0]);
        let mut argv = wide(
            command
                .iter()
                .map(|arg| quote_argument(arg))
                .collect::<Vec<_>>()
                .join(" "),
        );
        let directory = wide(project);
        let mut env: BTreeMap<String, (String, String)> = std::env::vars()
            .filter(|(key, _)| !key.to_ascii_uppercase().starts_with("ZSHELL_"))
            .map(|(key, value)| (key.to_ascii_uppercase(), (key, value)))
            .collect();
        for (key, value) in environment {
            env.insert(key.to_ascii_uppercase(), (key, value));
        }
        for (key, value) in [
            ("TERM", "xterm-256color"),
            ("COLORTERM", "truecolor"),
            ("TERM_PROGRAM", "ghostty"),
        ] {
            env.insert(key.into(), (key.into(), value.into()));
        }
        let mut block: Vec<u16> = env
            .values()
            .flat_map(|(key, value)| wide(format!("{key}={value}")))
            .collect();
        block.push(0);
        let mut info: PROCESS_INFORMATION = unsafe { mem::zeroed() };
        unsafe {
            SetConsoleCtrlHandler(None, 0);
        }
        if unsafe {
            CreateProcessW(
                application.as_ptr(),
                argv.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
                block.as_ptr().cast(),
                directory.as_ptr(),
                &startup.StartupInfo,
                &mut info,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let process = Handle(info.hProcess);
        let thread = Handle(info.hThread);
        if unsafe { AssignProcessToJobObject(pty.job.0, process.0) } == 0 {
            unsafe {
                TerminateProcess(process.0, 1);
            }
            return Err(io::Error::last_os_error());
        }
        if unsafe { ResumeThread(thread.0) } == u32::MAX {
            unsafe {
                TerminateProcess(process.0, 1);
            }
            return Err(io::Error::last_os_error());
        }
        let mut pty = pty;
        Arc::get_mut(&mut pty).unwrap().pid = info.dwProcessId as i32;
        Ok((pty.clone(), PtyChild { process, pty }))
    }
    pub fn pid(&self) -> i32 {
        self.pid
    }
    pub fn foreground_pid(&self) -> Option<i32> {
        None
    }
    pub fn owns_process(&self, pid: i32) -> bool {
        let process =
            Handle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) });
        if process.0.is_null() {
            return false;
        }
        let mut member = 0;
        unsafe { IsProcessInJob(process.0, self.job.0, &mut member) != 0 && member != 0 }
    }
    pub fn write(&self, bytes: &[u8]) -> io::Result<()> {
        self.input.clone().write_all(bytes)
    }
    pub fn read(&self, bytes: &mut [u8]) -> io::Result<usize> {
        match self.output.clone().read(bytes) {
            Err(error) if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) => Ok(0),
            result => result,
        }
    }
    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        let mut console = self.console.lock().unwrap();
        if console.handle == 0 {
            return Err(invalid("Remote pseudo console has exited"));
        }
        // ConPTY anchors rows differently from the emulator when both dimensions
        // change together. Apply width before height, as Kero does.
        if columns != console.columns && rows != console.rows {
            let result = unsafe {
                ResizePseudoConsole(
                    console.handle,
                    COORD {
                        X: columns as i16,
                        Y: console.rows as i16,
                    },
                )
            };
            if result < 0 {
                return Err(io::Error::from_raw_os_error(result));
            }
            console.columns = columns;
        }
        let result = unsafe {
            ResizePseudoConsole(
                console.handle,
                COORD {
                    X: columns as i16,
                    Y: rows as i16,
                },
            )
        };
        if result >= 0 {
            console.columns = columns;
            console.rows = rows;
        }
        if result < 0 {
            Err(io::Error::from_raw_os_error(result))
        } else {
            Ok(())
        }
    }
    pub fn terminate(&self, force: bool) {
        if force {
            self.input.shutdown();
            unsafe {
                TerminateJobObject(self.job.0, 1);
            }
        } else {
            let mut input = self.input.clone();
            std::thread::spawn(move || {
                let _ = input.write_all(&[3]);
            });
        }
    }
    fn close_console(&self) {
        let console = std::mem::replace(&mut self.console.lock().unwrap().handle, 0);
        if console != 0 {
            self.input.shutdown();
            // Windows before 24H2 waits for the output reader during close.
            // Keep draining on the existing reader while close runs separately.
            std::thread::spawn(move || unsafe {
                ClosePseudoConsole(console);
            });
        }
    }
}

pub fn default_command(initialization: Option<&str>) -> Vec<String> {
    let mut command = vec![login_shell(), "/D".into()];
    if let Some(initialization) = initialization {
        command.extend(["/K".into(), initialization.into()]);
    }
    command
}
impl Drop for Pty {
    fn drop(&mut self) {
        self.close_console();
    }
}

pub fn login_shell() -> String {
    std::env::var("COMSPEC")
        .ok()
        .filter(|path| std::path::Path::new(path).is_absolute())
        .unwrap_or_else(|| {
            format!(
                "{}\\System32\\cmd.exe",
                std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into())
            )
        })
}

pub fn quote_argument(value: &str) -> String {
    if !value.is_empty() && !value.chars().any(|ch| ch.is_whitespace() || ch == '"') {
        return value.into();
    }
    let mut result = String::from("\"");
    let mut slashes = 0;
    for ch in value.chars() {
        if ch == '\\' {
            slashes += 1;
            continue;
        }
        if ch == '"' {
            result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
        } else {
            result.extend(std::iter::repeat_n('\\', slashes));
        }
        result.push(ch);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}
