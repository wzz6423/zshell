use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, Read, Write};

pub const VERSION: u32 = 1;
pub const MAGIC: &[u8; 8] = b"ZSRM0001";
pub const MAX_FRAME: usize = 256 * 1024;
pub const MAX_INPUT: usize = 256 * 1024;
pub const MAX_BACKLOG: usize = 1024 * 1024;
pub const MAX_SNAPSHOT: usize = 16 * 1024 * 1024;
pub const MAX_SESSIONS: usize = 128;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PasteFile {
    pub name: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub version: u32,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<std::collections::BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initialization_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paste_files: Option<Vec<PasteFile>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_index: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hook: Option<crate::agent_hooks::Hook>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
}

impl Frame {
    pub fn new(kind: &str) -> Self {
        Self {
            version: VERSION,
            kind: kind.into(),
            request_id: None,
            project: None,
            working_directory: None,
            session_id: None,
            client_id: None,
            command: None,
            environment: None,
            initialization_command: None,
            columns: None,
            rows: None,
            data: None,
            sequence: None,
            paste_files: None,
            upload_id: None,
            file_index: None,
            offset: None,
            hook: None,
            provider: None,
            conversation_id: None,
            result: None,
            error: None,
            exit_code: None,
        }
    }

    pub fn success(request: &Frame, value: Value) -> Self {
        let mut frame = Self::new("result");
        frame.request_id = request.request_id.clone();
        frame.result = Some(value);
        frame
    }

    pub fn failure(request: &Frame, message: impl ToString) -> Self {
        let mut frame = Self::new("error");
        frame.request_id = request.request_id.clone();
        frame.error = Some(message.to_string());
        frame
    }

    pub fn dimensions(&self) -> io::Result<(u16, u16)> {
        let columns = self.columns.unwrap_or(80);
        let rows = self.rows.unwrap_or(24);
        if columns == 0
            || columns > 512
            || rows == 0
            || rows > 256
            || u32::from(columns) * u32::from(rows) > 65_536
        {
            return Err(invalid("Invalid terminal dimensions"));
        }
        Ok((columns, rows))
    }
}

pub fn invalid(message: impl ToString) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_string())
}

pub fn read_frame(reader: &mut impl Read) -> io::Result<Frame> {
    let mut prefix = [0; 4];
    reader.read_exact(&mut prefix)?;
    let length = u32::from_be_bytes(prefix) as usize;
    if length == 0 || length > MAX_FRAME {
        return Err(invalid("Frame exceeds 256 KiB"));
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes)?;
    let frame: Frame = serde_json::from_slice(&bytes).map_err(invalid)?;
    if frame.version != VERSION {
        return Err(invalid("Incompatible remote protocol version"));
    }
    Ok(frame)
}

pub fn write_frame(writer: &mut impl Write, frame: &Frame) -> io::Result<()> {
    let bytes = serde_json::to_vec(frame).map_err(invalid)?;
    if bytes.len() > MAX_FRAME {
        return Err(invalid("Frame exceeds 256 KiB"));
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()
}

pub fn client_handshake(stream: &mut (impl Read + Write)) -> io::Result<()> {
    stream.write_all(MAGIC)?;
    let mut reply = [0; 8];
    stream.read_exact(&mut reply)?;
    if &reply != MAGIC {
        return Err(invalid("Incompatible Zshell server"));
    }
    Ok(())
}

pub fn server_handshake(stream: &mut (impl Read + Write)) -> io::Result<()> {
    let mut request = [0; 8];
    stream.read_exact(&mut request)?;
    if &request != MAGIC {
        return Err(invalid("Not a Zshell remote connection"));
    }
    stream.write_all(MAGIC)
}

pub fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

pub fn new_id() -> io::Result<String> {
    let mut bytes = [0; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    Ok(format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn rejects_unframed_browser_requests_and_large_frames() {
        assert!(server_handshake(&mut Cursor::new(b"GET / HT".to_vec())).is_err());
        assert!(read_frame(&mut Cursor::new(((MAX_FRAME + 1) as u32).to_be_bytes())).is_err());
        let mut frame = Frame::new("hello");
        frame.version = VERSION + 1;
        let mut wire = Vec::new();
        write_frame(&mut wire, &frame).unwrap();
        assert!(read_frame(&mut Cursor::new(wire)).is_err());
    }

    #[test]
    fn frame_round_trip_preserves_binary_and_unicode() {
        let mut frame = Frame::new("input");
        frame.data = Some("AAH/DQo=".into());
        frame.project = Some("/tmp/远端 project".into());
        let mut wire = Vec::new();
        write_frame(&mut wire, &frame).unwrap();
        let decoded = read_frame(&mut Cursor::new(wire)).unwrap();
        assert_eq!(decoded.data, frame.data);
        assert_eq!(decoded.project, frame.project);
        assert!(is_uuid(&new_id().unwrap()));
    }
}
