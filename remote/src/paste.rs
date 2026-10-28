use crate::protocol::{invalid, is_uuid, new_id, Frame, PasteFile};
use crate::transport::{prepare_state, shell_path};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::fs::{self, File, Metadata};
#[cfg(unix)]
use std::fs::{DirBuilder, OpenOptions};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;
pub const MAX_BATCH_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_FILES: usize = 32;
pub const MAX_CHUNK_BYTES: usize = 64 * 1024;
const RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub struct PasteStore {
    root: PathBuf,
}

impl PasteStore {
    pub fn new(state: &Path) -> io::Result<Self> {
        prepare_state(state)?;
        let root = state.join("pastes");
        prepare_state(&root)?;
        let root = fs::canonicalize(root)?;
        let store = Self { root };
        store.prune(true)?;
        Ok(store)
    }

    pub fn begin(&self, files: &[PasteFile]) -> io::Result<PasteBatch> {
        if files.is_empty() || files.len() > MAX_FILES {
            return Err(invalid("Paste needs between 1 and 32 files"));
        }
        let mut total = 0_u64;
        for info in files {
            if info.name.is_empty()
                || info.name.len() > 220
                || matches!(info.name.as_str(), "." | "..")
                || info.name.contains(['/', '\\'])
                || cfg!(windows)
                    && (info.name.contains([':', '"', '<', '>', '|', '?', '*'])
                        || info.name.ends_with(['.', ' ']))
                || info.name.chars().any(char::is_control)
            {
                return Err(invalid("Invalid paste file name"));
            }
            if info.size > MAX_FILE_BYTES {
                return Err(invalid("Paste file exceeds 32 MiB"));
            }
            total = total
                .checked_add(info.size)
                .ok_or_else(|| invalid("Paste batch exceeds 64 MiB"))?;
        }
        if total > MAX_BATCH_BYTES {
            return Err(invalid("Paste batch exceeds 64 MiB"));
        }
        self.prune(false)?;
        let id = new_id()?;
        let directory = self.root.join(format!("pending-{id}"));
        private_directory(&directory)?;
        let mut batch = PasteBatch {
            id,
            directory,
            files: Vec::new(),
            committed: false,
        };
        for (index, info) in files.iter().enumerate() {
            let name = format!("{index:02}-{}", info.name);
            let file = private_file(&batch.directory.join(&name))?;
            batch.files.push(ReceivingFile {
                name,
                expected: info.size,
                received: 0,
                file: Some(file),
            });
        }
        Ok(batch)
    }

    fn prune(&self, stale_pending: bool) -> io::Result<()> {
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let metadata = fs::symlink_metadata(entry.path())?;
            if !private_metadata(&entry.path(), &metadata, true) {
                continue;
            }
            if stale_pending && name.strip_prefix("pending-").is_some_and(is_uuid) {
                fs::remove_dir_all(entry.path())?;
            } else if is_uuid(&name) {
                let Ok(marker) = fs::symlink_metadata(entry.path().join(".complete")) else {
                    continue;
                };
                if private_metadata(&entry.path().join(".complete"), &marker, false)
                    && marker
                        .modified()
                        .ok()
                        .and_then(|time| SystemTime::now().duration_since(time).ok())
                        .is_some_and(|age| age > RETENTION)
                {
                    fs::remove_dir_all(entry.path())?;
                }
            }
        }
        Ok(())
    }
}

struct ReceivingFile {
    name: String,
    expected: u64,
    received: u64,
    file: Option<File>,
}

pub struct PasteBatch {
    pub id: String,
    directory: PathBuf,
    files: Vec<ReceivingFile>,
    committed: bool,
}

impl PasteBatch {
    pub fn write(&mut self, request: &Frame) -> io::Result<Value> {
        if self.committed {
            return Err(invalid("Paste upload is already complete"));
        }
        let index = request
            .file_index
            .ok_or_else(|| invalid("A paste file index is required"))?;
        let slot = self
            .files
            .get_mut(index)
            .ok_or_else(|| invalid("Invalid paste file index"))?;
        if request.offset != Some(slot.received) {
            return Err(invalid("Unexpected paste offset"));
        }
        let encoded = request
            .data
            .as_deref()
            .ok_or_else(|| invalid("Paste data is required"))?;
        if encoded.len() > MAX_CHUNK_BYTES.div_ceil(3) * 4 {
            return Err(invalid("Paste chunk exceeds 64 KiB"));
        }
        let bytes = STANDARD.decode(encoded).map_err(invalid)?;
        if bytes.is_empty()
            || bytes.len() > MAX_CHUNK_BYTES
            || slot.received + bytes.len() as u64 > slot.expected
        {
            return Err(invalid("Paste data exceeds the declared file size"));
        }
        slot.file
            .as_mut()
            .ok_or_else(|| invalid("Paste upload has been sealed"))?
            .write_all(&bytes)?;
        slot.received += bytes.len() as u64;
        Ok(json!({ "offset": slot.received }))
    }

    pub fn prepare_commit(&mut self) -> io::Result<()> {
        if self.committed {
            return Err(invalid("Paste upload is already complete"));
        }
        if self.files.iter().any(|file| file.received != file.expected) {
            return Err(invalid("Paste upload is incomplete"));
        }
        for slot in &mut self.files {
            if let Some(file) = slot.file.take() {
                file.sync_all()?;
            }
        }
        private_file(&self.directory.join(".complete"))?.sync_all()
    }

    pub fn commit(&mut self) -> io::Result<Value> {
        let directory = self.directory.parent().unwrap().join(&self.id);
        let paths = self
            .files
            .iter()
            .map(|file| shell_path(&directory.join(&file.name)))
            .collect::<io::Result<Vec<_>>>()?;
        fs::rename(&self.directory, &directory)?;
        self.directory = directory;
        self.committed = true;
        Ok(json!({ "paths": paths }))
    }
}

impl Drop for PasteBatch {
    fn drop(&mut self) {
        self.files.clear();
        if !self.committed {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!("zshell-paste-test-{}", new_id().unwrap())))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn paste_limits_names_offsets_and_cleanup() {
        let fixture = Fixture::new();
        let store = PasteStore::new(&fixture.0).unwrap();
        for name in [
            "../escape",
            "/absolute",
            "a\\b",
            "line\nname",
            "\u{1b}escape",
            "..",
            "",
        ] {
            assert!(store
                .begin(&[PasteFile {
                    name: name.into(),
                    size: 1
                }])
                .is_err());
        }
        assert!(store
            .begin(&[PasteFile {
                name: "large".into(),
                size: MAX_FILE_BYTES + 1
            }])
            .is_err());
        assert!(store
            .begin(&vec![
                PasteFile {
                    name: "sum".into(),
                    size: MAX_FILE_BYTES
                };
                3
            ])
            .is_err());
        assert!(store
            .begin(&vec![
                PasteFile {
                    name: "count".into(),
                    size: 0
                };
                MAX_FILES + 1
            ])
            .is_err());
        let files = [
            PasteFile {
                name: "相同 'file'.png".into(),
                size: 3,
            },
            PasteFile {
                name: "相同 'file'.png".into(),
                size: 0,
            },
        ];
        let mut batch = store.begin(&files).unwrap();
        let pending = batch.directory.clone();
        assert_eq!(
            fs::metadata(&pending).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert!(batch.prepare_commit().is_err());
        let mut frame = Frame::new("pasteChunk");
        frame.file_index = Some(0);
        frame.offset = Some(1);
        frame.data = Some(STANDARD.encode([0, 1, 255]));
        assert!(batch.write(&frame).is_err());
        frame.offset = Some(0);
        frame.data = Some(STANDARD.encode([0, 1, 255, 4]));
        assert!(batch.write(&frame).is_err());
        frame.data = Some(STANDARD.encode([0, 1, 255]));
        assert_eq!(batch.write(&frame).unwrap()["offset"], 3);
        batch.prepare_commit().unwrap();
        let result = batch.commit().unwrap();
        let first = PathBuf::from(result["paths"][0].as_str().unwrap());
        let second = PathBuf::from(result["paths"][1].as_str().unwrap());
        assert_ne!(first, second);
        assert!(!pending.exists());
        assert_eq!(fs::read(&first).unwrap(), [0, 1, 255]);
        assert_eq!(
            fs::metadata(first).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(batch);
        assert!(second.exists());
        let aborted = store.begin(&files).unwrap();
        let aborted_path = aborted.directory.clone();
        drop(aborted);
        assert!(!aborted_path.exists());
    }

    #[test]
    fn paste_pruning_removes_only_expired_private_batches() {
        let fixture = Fixture::new();
        let store = PasteStore::new(&fixture.0).unwrap();
        let mut complete = store
            .begin(&[PasteFile {
                name: "empty".into(),
                size: 0,
            }])
            .unwrap();
        complete.prepare_commit().unwrap();
        complete.commit().unwrap();
        let directory = complete.directory.clone();
        let marker = OpenOptions::new()
            .write(true)
            .open(directory.join(".complete"))
            .unwrap();
        marker
            .set_times(
                fs::FileTimes::new()
                    .set_modified(SystemTime::now() - RETENTION - Duration::from_secs(1)),
            )
            .unwrap();
        let outside = fixture.0.join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("keep"), b"keep").unwrap();
        let linked = store.root.join(new_id().unwrap());
        symlink(&outside, &linked).unwrap();
        let current = store
            .begin(&[PasteFile {
                name: "current".into(),
                size: 0,
            }])
            .unwrap();
        assert!(!directory.exists());
        assert!(current.directory.exists());
        assert!(linked.symlink_metadata().unwrap().file_type().is_symlink());
        assert!(outside.join("keep").exists());
        drop(current);
    }
}

// Keep owner-only filesystem policy together so other server platforms can
// implement their native permission model without changing upload handling.
#[cfg(unix)]
fn private_directory(path: &Path) -> io::Result<()> {
    DirBuilder::new().mode(0o700).create(path)
}

#[cfg(unix)]
fn private_file(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

#[cfg(unix)]
fn private_metadata(_: &Path, metadata: &Metadata, directory: bool) -> bool {
    !metadata.file_type().is_symlink()
        && metadata.uid() == unsafe { libc::geteuid() }
        && if directory {
            metadata.is_dir() && metadata.mode() & 0o777 == 0o700
        } else {
            metadata.is_file() && metadata.mode() & 0o777 == 0o600
        }
}

#[cfg(windows)]
fn private_directory(path: &Path) -> io::Result<()> {
    if path.exists() {
        return Err(io::ErrorKind::AlreadyExists.into());
    }
    crate::windows::prepare_directory(path)
}

#[cfg(windows)]
fn private_file(path: &Path) -> io::Result<File> {
    crate::windows::private_file(path, true, false)
}

#[cfg(windows)]
fn private_metadata(path: &Path, metadata: &Metadata, directory: bool) -> bool {
    use std::os::windows::fs::MetadataExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return false;
    }
    if directory {
        crate::windows::prepare_directory(path).is_ok()
    } else {
        crate::windows::private_file(path, false, false).is_ok_and(|file| {
            crate::windows::verify_private_handle(file.as_raw_handle(), false).is_ok()
        })
    }
}
