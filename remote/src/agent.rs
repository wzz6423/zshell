// Adapted from egoist/kero internal/daemon/osc.go at
// 580bdfa8f6a43d71d145958ab76c1bbb45c465f0 (MIT). See mac/zshell/ThirdPartyNotices/Kero.txt.
use base64::{engine::general_purpose::{STANDARD, STANDARD_NO_PAD}, Engine};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_OSC: usize = 4096;
const MAX_RECORDS: usize = 64;
pub const QUERY_REPLY: &[u8] = b"\x1b]7501;?\x1b\\";

#[derive(Default)]
pub struct Scanner {
    state: u8,
    buffer: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub enum Osc {
    Body(Vec<u8>),
    Reset,
    Title(Vec<u8>),
}

impl Scanner {
    pub fn scan(&mut self, bytes: &[u8]) -> Vec<Osc> {
        let mut output = Vec::new();
        for &byte in bytes {
            match self.state {
                0 => match byte {
                    0x1b => self.state = 1,
                    0x9d => self.begin(),
                    _ => {}
                },
                1 => {
                    if byte == b']' { self.begin(); }
                    else if byte != 0x1b {
                        self.state = 0;
                        if byte == b'c' { output.push(Osc::Reset); }
                    }
                }
                2 | 3 => match byte {
                    0x07 | 0x9c => self.end(&mut output),
                    0x1b => self.state = 4,
                    _ if self.state == 2 => {
                        self.buffer.push(byte);
                        if !self.wanted() || self.buffer.len() > MAX_OSC {
                            self.state = 3;
                            self.buffer.clear();
                        }
                    }
                    _ => {}
                },
                4 => {
                    if byte == b'\\' { self.end(&mut output); }
                    else {
                        self.state = 1;
                        self.buffer.clear();
                        if byte == b']' { self.begin(); }
                        else if byte != 0x1b { self.state = 0; }
                    }
                }
                _ => unreachable!(),
            }
        }
        output
    }

    fn begin(&mut self) { self.state = 2; self.buffer.clear(); }
    fn end(&mut self, output: &mut Vec<Osc>) {
        if (self.state == 2 || self.state == 4) && !self.buffer.is_empty() && self.wanted() {
            if self.buffer.starts_with(b"0;") || self.buffer.starts_with(b"2;") {
                output.push(Osc::Title(self.buffer[2..].to_vec()));
            } else { output.push(Osc::Body(self.buffer.clone())); }
        }
        self.state = 0;
        self.buffer.clear();
    }
    fn wanted(&self) -> bool {
        [b"7501;".as_slice(), b"133;", b"9;4;", b"0;", b"2;"].iter().any(|prefix| {
            let count = self.buffer.len().min(prefix.len());
            self.buffer[..count] == prefix[..count]
        })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub state: String,
    pub app: String,
    pub message: String,
    pub title: String,
    pub kind: String,
    pub progress: Option<u8>,
    pub updated_at: u64,
}

pub enum Report { Query, Record(Record) }

pub fn parse_status(body: &str, at: u64) -> Option<Report> {
    let body = body.trim();
    if body == "?" || body.starts_with("?:") { return Some(Report::Query); }
    let mut fields = BTreeMap::new();
    for pair in body.split(':') {
        let Some((key, value)) = pair.split_once('=') else { continue };
        let (key, value) = (key.trim(), value.trim());
        if !(1..=16).contains(&key.len()) || !key.bytes().all(|b| b.is_ascii_lowercase())
            || !value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b)) { continue; }
        fields.insert(key, value);
    }
    let state = *fields.get("state")?;
    if !["idle", "working", "done", "blocked", "error", "clear"].contains(&state) { return None; }
    let id = fields.get("id").copied().unwrap_or("");
    if fields.contains_key("id") && (id.len() > 128 || id.split('/').count() > 8
        || !id.split('/').all(|segment| ascii_name(segment, 32))) { return None; }
    let text = |key: &str, encoded: usize, decoded: usize| -> Option<String> {
        let Some(value) = fields.get(key) else { return Some(String::new()) };
        if value.len() > encoded { return None; }
        let bytes = STANDARD.decode(value).or_else(|_| STANDARD_NO_PAD.decode(value)).ok()?;
        if bytes.len() > decoded { return None; }
        let text = std::str::from_utf8(&bytes).ok()?;
        if !valid_text(text, decoded) { return None; }
        Some(neutralize(text))
    };
    let app = fields.get("app").copied().filter(|name| ascii_name(name, 32)).unwrap_or("");
    let kind = fields.get("kind").copied().filter(|kind| state == "blocked"
        && ["permission", "question", "auth"].contains(kind)).unwrap_or("");
    let progress = fields.get("progress").and_then(|value| value.parse::<u8>().ok())
        .filter(|value| *value <= 100 && ["working", "blocked"].contains(&state));
    Some(Report::Record(Record {
        id: id.into(), state: state.into(), app: app.into(), kind: kind.into(), progress,
        message: text("msg", 2732, 2048)?, title: text("title", 256, 192)?, updated_at: at,
    }))
}

fn ascii_name(value: &str, limit: usize) -> bool {
    (1..=limit).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
}

pub fn valid_text(text: &str, limit: usize) -> bool {
    text.len() <= limit && text.chars().all(|c| c >= ' ' && !('\u{7f}'..='\u{9f}').contains(&c))
}

pub fn neutralize(text: &str) -> String {
    text.chars().filter(|c| !matches!(*c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
        | '\u{200b}'..='\u{200f}' | '\u{061c}' | '\u{feff}')).collect()
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub phase: String,
    pub app: String,
    pub message: String,
    pub attention: Option<String>,
    pub progress: Option<u8>,
    pub records: Vec<Record>,
    pub generation: u64,
}

#[derive(Default)]
pub struct Records {
    records: BTreeMap<String, Record>,
    generation: u64,
}

impl Records {
    pub fn replace(&mut self, records: &Records) {
        self.records = records.records.clone();
        self.generation = self.generation.wrapping_add(1);
    }
    pub fn apply(&mut self, record: Record) {
        if record.state == "clear" {
            self.records.retain(|id, _| !record.id.is_empty()
                && id != &record.id && !id.starts_with(&format!("{}/", record.id)));
        } else {
            if !self.records.contains_key(&record.id) && self.records.len() >= MAX_RECORDS {
                if let Some(oldest) = self.records.iter().min_by_key(|(_, value)| value.updated_at).map(|(id, _)| id.clone()) {
                    self.records.remove(&oldest);
                }
            }
            self.records.insert(record.id.clone(), record);
        }
        self.generation = self.generation.wrapping_add(1);
    }
    pub fn reset(&mut self) { self.records.clear(); self.generation = self.generation.wrapping_add(1); }
    pub fn drop_live(&mut self) {
        let count = self.records.len();
        self.records.retain(|_, record| !["idle", "working", "blocked"].contains(&record.state.as_str()));
        if count != self.records.len() { self.generation = self.generation.wrapping_add(1); }
    }
    pub fn dismiss_finished(&mut self) {
        let count = self.records.len();
        self.records.retain(|_, record| !["done", "error"].contains(&record.state.as_str()));
        if count != self.records.len() { self.generation = self.generation.wrapping_add(1); }
    }
    pub fn status(&self) -> Status {
        let mut records: Vec<_> = self.records.values().cloned().collect();
        for record in &mut records {
            let mut id = record.id.as_str();
            while record.app.is_empty() && !id.is_empty() {
                id = id.rsplit_once('/').map_or("", |(parent, _)| parent);
                record.app = self.records.get(id).map(|parent| parent.app.clone()).unwrap_or_default();
            }
        }
        let selected = ["blocked", "working", "error", "done", "idle"].iter()
            .find_map(|phase| records.iter().find(|record| record.state == *phase));
        let mut status = Status { phase: "idle".into(), generation: self.generation, ..Status::default() };
        if let Some(record) = selected {
            status.phase = if record.state == "error" { "blocked" } else { &record.state }.into();
            status.app = record.app.clone();
            status.message = record.message.clone();
            status.progress = record.progress;
            status.attention = match record.kind.as_str() {
                "permission" => Some("approval".into()), "question" => Some("input".into()),
                "auth" => Some("login".into()), "error" => Some("error".into()), _ if record.state == "error" => Some("error".into()), _ => None,
            };
        }
        status.records = records;
        status
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record(body: &str, at: u64) -> Record {
        match parse_status(body, at).unwrap() { Report::Record(record) => record, _ => panic!("not a record") }
    }
    #[test]
    fn scanner_matches_kero_across_reads_and_bounds() {
        let mut scanner = Scanner::default();
        let mut output = Vec::new();
        for byte in b"text\x1b]0;ignore\x07\x1b]7501;state=working\x1b\\\x1b]133;A\x07\x1bc\x9d9;4;1;50\x9c" {
            output.extend(scanner.scan(&[*byte]));
        }
        assert_eq!(output, vec![Osc::Title(b"ignore".to_vec()), Osc::Body(b"7501;state=working".to_vec()), Osc::Body(b"133;A".to_vec()),
            Osc::Reset, Osc::Body(b"9;4;1;50".to_vec())]);
        let oversized = format!("\x1b]7501;{}\x07", "a".repeat(MAX_OSC + 1));
        assert!(scanner.scan(oversized.as_bytes()).is_empty());
        assert!(scanner.buffer.len() <= MAX_OSC);
    }
    #[test]
    fn parser_reuses_kero_grammar_and_text_limits() {
        assert!(parse_status("?:anything", 1).is_some());
        assert!(parse_status("state=invalid", 1).is_none());
        assert!(parse_status("state=working:id=a//b", 1).is_none());
        assert!(parse_status("state=working:msg=bad=", 1).is_none());
        assert!(parse_status("state=working:msg=AA==", 1).is_none());
        let parsed = record(&format!("state=working:bad pair:state=blocked:id=a/b:app=codex:kind=question:progress=95:msg={}", STANDARD.encode("safe\u{202e}text")), 42);
        assert_eq!((parsed.state.as_str(), parsed.message.as_str(), parsed.progress), ("blocked", "safetext", Some(95)));
        assert_eq!(record("state=done:progress=95", 1).progress, None);
    }
    #[test]
    fn record_priority_subtrees_cap_and_acknowledgement() {
        let mut records = Records::default();
        for (body, at) in [("state=done:id=root:app=codex", 1), ("state=working:id=root/child", 2),
            ("state=error:id=error", 3), ("state=blocked:id=blocked:kind=permission", 4)] {
            records.apply(record(body, at));
        }
        let status = records.status();
        assert_eq!(status.phase, "blocked");
        assert_eq!(status.attention.as_deref(), Some("approval"));
        assert_eq!(status.records.iter().find(|r| r.id == "root/child").unwrap().app, "codex");
        records.apply(record("state=clear:id=blocked", 5));
        assert_eq!(records.status().phase, "working");
        records.drop_live();
        assert_eq!(records.status().attention.as_deref(), Some("error"));
        records.dismiss_finished();
        assert!(records.status().records.is_empty());
        for index in 0..70 { records.apply(record(&format!("state=working:id=task{index}"), index)); }
        assert_eq!(records.status().records.len(), MAX_RECORDS);
        records.apply(record("state=clear", 100));
        assert_eq!(records.status().phase, "idle");
    }
}
