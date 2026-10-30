use serde::Serialize;
use std::ffi::CStr;

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileContext {
    pub host: Option<String>,
    pub user: Option<String>,
    pub directory: Option<String>,
    pub program: Option<String>,
}

pub fn snapshot(pid: i32) -> ProfileContext {
    ProfileContext {
        host: hostname(),
        user: effective_user(pid),
        directory: working_directory(pid),
        program: crate::agent_process::process(pid).map(|process| process.executable),
    }
}

fn hostname() -> Option<String> {
    let mut buffer = [0i8; 256];
    if unsafe { libc::gethostname(buffer.as_mut_ptr(), buffer.len() - 1) } != 0 { return None; }
    unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_str().ok().map(str::to_owned)
}

fn effective_user(pid: i32) -> Option<String> {
    let uid = effective_uid(pid)?;
    let mut account = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut buffer = [0i8; 16 * 1024];
    let mut result = std::ptr::null_mut();
    if unsafe { libc::getpwuid_r(uid, &mut account, buffer.as_mut_ptr(), buffer.len(), &mut result) } != 0
        || result.is_null() || account.pw_name.is_null() { return None; }
    unsafe { CStr::from_ptr(account.pw_name) }.to_str().ok().map(str::to_owned)
}

#[cfg(target_os = "macos")]
fn effective_uid(pid: i32) -> Option<libc::uid_t> {
    if pid <= 1 { return None; }
    let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
    let size = std::mem::size_of_val(&info) as i32;
    (unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) } == size)
        .then_some(info.pbi_uid)
}

#[cfg(target_os = "linux")]
fn effective_uid(pid: i32) -> Option<libc::uid_t> {
    use std::io::Read;
    if pid <= 1 { return None; }
    let mut text = String::new();
    std::fs::File::open(format!("/proc/{pid}/status")).ok()?.take(64 * 1024).read_to_string(&mut text).ok()?;
    text.lines().find(|line| line.starts_with("Uid:"))?.split_whitespace().nth(2)?.parse().ok()
}

#[cfg(target_os = "macos")]
fn working_directory(pid: i32) -> Option<String> {
    if pid <= 1 { return None; }
    let mut info = unsafe { std::mem::zeroed::<libc::proc_vnodepathinfo>() };
    let size = std::mem::size_of_val(&info) as i32;
    if unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, (&mut info as *mut libc::proc_vnodepathinfo).cast(), size) } != size { return None; }
    unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) }.to_str().ok().filter(|path| !path.is_empty()).map(str::to_owned)
}

#[cfg(target_os = "linux")]
fn working_directory(pid: i32) -> Option<String> {
    if pid <= 1 { return None; }
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?.to_str().filter(|path| path.len() <= 4096).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_kernel_metadata_without_environment_or_title() {
        let context = snapshot(std::process::id() as i32);
        assert!(context.host.as_ref().is_some_and(|host| !host.is_empty()));
        assert!(context.user.as_ref().is_some_and(|user| !user.is_empty()));
        assert_eq!(context.directory.as_deref(), std::env::current_dir().unwrap().to_str());
        assert!(context.program.as_ref().is_some_and(|program| program.starts_with('/')));
        let invalid = snapshot(-1);
        assert!(invalid.user.is_none() && invalid.directory.is_none() && invalid.program.is_none());
    }
}
