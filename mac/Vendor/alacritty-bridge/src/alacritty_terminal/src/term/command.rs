use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use super::{Cell, Flags, Term, TermMode};
use crate::event::{Event, EventListener};
use crate::grid::Dimensions;
use crate::index::{Column, Line, Point};

const MAX_RECORDS: usize = 2_000;
const MAX_COMMAND_BYTES: usize = 16_384;

#[derive(Clone, Debug)]
pub struct CommandRecord {
    pub id: u64,
    pub command: String,
    pub working_directory: Option<String>,
    pub started_at_ms: u64,
    pub finished_at_ms: Option<u64>,
    pub duration_ns: Option<u64>,
    pub exit_code: Option<i32>,
    pub location_valid: bool,
    started: Instant,
}

#[derive(Clone, Copy, Debug)]
pub struct CommandRegion {
    pub prompt: Point,
    pub input: Point,
    pub output: Point,
    pub end: Point,
}

#[derive(Default)]
pub(super) struct CommandBlocks {
    pub zone: Option<(u64, u8)>,
    next_id: u64,
    pending: Option<u64>,
    active: Option<u64>,
    records: VecDeque<CommandRecord>,
    directory: Option<String>,
    revision: u64,
    pub grid_revision: u64,
    last_write: Option<Point>,
    anchors: RefCell<(u64, HashMap<u64, [Option<Point>; 4]>)>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

pub(super) fn decode_percent(value: &str, max_bytes: usize) -> Option<String> {
    if value.len() > max_bytes * 3 {
        return None;
    }
    let mut bytes = Vec::with_capacity(value.len().min(max_bytes));
    let mut input = value.as_bytes().iter().copied();
    while let Some(byte) = input.next() {
        let byte = if byte == b'%' {
            let high = char::from(input.next()?).to_digit(16)?;
            let low = char::from(input.next()?).to_digit(16)?;
            (high * 16 + low) as u8
        } else {
            byte
        };
        if bytes.len() == max_bytes {
            break;
        }
        bytes.push(byte);
    }
    // Truncate only a partial final scalar, never replace invalid command bytes.
    while std::str::from_utf8(&bytes).is_err() && !bytes.is_empty() {
        if let Err(error) = std::str::from_utf8(&bytes) {
            if error.error_len().is_some() {
                return None;
            }
        }
        bytes.pop();
    }
    String::from_utf8(bytes).ok()
}

impl<T> Term<T> {
    pub fn command_records(&self) -> &VecDeque<CommandRecord> {
        &self.command_blocks.records
    }
    pub fn command_revision(&self) -> u64 {
        self.command_blocks.revision
    }

    pub fn invalidate_command_locations(&mut self) {
        for record in &mut self.command_blocks.records {
            record.location_valid = false;
        }
        self.command_blocks.pending = None;
        self.command_blocks.zone = None;
        self.command_blocks.last_write = None;
        self.command_blocks.revision = self.command_blocks.revision.wrapping_add(1);
    }

    pub(super) fn invalidate_command_range(&mut self, start: Point, end: Point) {
        if self.mode.contains(TermMode::ALT_SCREEN) {
            return;
        }
        let key = |point: Point| (point.line, point.column);
        let ids: Vec<_> = self.command_blocks.records.iter()
            .filter(|record| record.finished_at_ms.is_some() && record.location_valid)
            .filter_map(|record| {
                let region = self.command_region(record.id)?;
                (key(start) < key(region.end) && key(end) >= key(region.prompt)).then_some(record.id)
            }).collect();
        if ids.is_empty() { return; }
        for record in &mut self.command_blocks.records {
            if ids.contains(&record.id) { record.location_valid = false; }
        }
        self.command_blocks.revision = self.command_blocks.revision.wrapping_add(1);
    }

    pub(super) fn invalidate_written_command_row(&mut self) {
        // New output is after the last completed block. Inspect old ranges
        // only when a program moves back into already completed output.
        if self.mode.contains(TermMode::ALT_SCREEN) { return; }
        let point = self.grid.cursor.point;
        let previous = self.command_blocks.last_write.replace(point);
        if previous.is_none_or(|previous| (point.line, point.column) >= (previous.line, previous.column)) { return; }
        let Some(record) = self.command_blocks.records.iter().rev()
            .find(|record| record.finished_at_ms.is_some() && record.location_valid) else { return; };
        let anchors = self.grid.cursor_cell().semantic_anchors();
        if anchors.iter().any(|&(id, kind)| id == record.id && kind == 3) { return; }
        let Some(region) = self.command_region(record.id) else { return; };
        if (point.line, point.column) < (region.end.line, region.end.column) {
            self.invalidate_command_range(point, Point::new(point.line, self.last_column()));
        }
    }

    fn command_anchor(&mut self, id: u64, kind: u8) {
        // Blank boundary cells count as occupied so native reflow retains them.
        self.grid.cursor_cell().add_semantic_anchor((id, kind));
        self.command_blocks.grid_revision = self.command_blocks.grid_revision.wrapping_add(1);
    }

    fn find_command_anchors(&self, id: u64) -> [Option<Point>; 4] {
        if self.mode.contains(TermMode::ALT_SCREEN) {
            return [None; 4];
        }
        let mut cache = self.command_blocks.anchors.borrow_mut();
        if cache.0 != self.command_blocks.grid_revision {
            cache.1.clear();
            for line in
                (-(self.grid.history_size() as i32)..self.grid.screen_lines() as i32).map(Line)
            {
                for column in (0..self.grid.columns()).map(Column) {
                    for &(block, kind) in self.grid[line][column].semantic_anchors() {
                        if kind < 4 {
                            cache.1.entry(block).or_insert([None; 4])[kind as usize] =
                                Some(Point::new(line, column));
                        }
                    }
                }
            }
            cache.0 = self.command_blocks.grid_revision;
        }
        cache.1.get(&id).copied().unwrap_or([None; 4])
    }

    pub fn command_region(&self, id: u64) -> Option<CommandRegion> {
        let record = self
            .command_blocks
            .records
            .iter()
            .find(|record| record.id == id && record.location_valid)?;
        let [prompt, input, output, end] = self.find_command_anchors(id);
        let end = if record.finished_at_ms.is_some() {
            end?
        } else {
            self.grid.cursor.point
        };
        let region = CommandRegion {
            prompt: prompt?,
            input: input?,
            output: output?,
            end,
        };
        let key = |point: Point| (point.line, point.column);
        (key(region.prompt) <= key(region.input)
            && key(region.input) <= key(region.output)
            && key(region.output) <= key(region.end))
        .then_some(region)
    }

    pub fn command_text(&self, id: u64, part: u8) -> Option<String> {
        let region = self.command_region(id)?;
        if part == 0 {
            return self
                .command_blocks
                .records
                .iter()
                .find(|record| record.id == id)
                .map(|record| record.command.clone());
        }
        let start = if part == 1 {
            region.output
        } else {
            region.prompt
        };
        let end = region.end;
        if start == end {
            return Some(String::new());
        }
        let end = if end.column.0 > 0 {
            Point::new(end.line, end.column - 1)
        } else if end.line > start.line {
            Point::new(end.line - 1, Column(self.grid.columns() - 1))
        } else {
            return Some(String::new());
        };
        Some(self.bounds_to_string(start, end))
    }

    fn input_text(&self, id: u64) -> String {
        let mut text = String::new();
        let mut previous_line: Option<Line> = None;
        for line in (-(self.grid.history_size() as i32)..self.grid.screen_lines() as i32).map(Line)
        {
            for column in (0..self.grid.columns()).map(Column) {
                let cell: &Cell = &self.grid[line][column];
                if cell.semantic_zone() != Some((id, 1)) {
                    continue;
                }
                if let Some(previous) = previous_line {
                    if previous != line
                        && !self.grid[previous][Column(self.grid.columns() - 1)]
                            .flags
                            .contains(Flags::WRAPLINE)
                    {
                        text.push('\n');
                    }
                }
                previous_line = Some(line);
                if !cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    text.push(cell.c);
                    for character in cell.zerowidth().into_iter().flatten() {
                        text.push(*character);
                    }
                }
                if text.len() >= MAX_COMMAND_BYTES {
                    return text;
                }
            }
        }
        text.trim_end_matches(['\r', '\n']).to_owned()
    }
}

impl<T: EventListener> Term<T> {
    pub(super) fn record_working_directory(&mut self, uri: &str) {
        let path = uri
            .strip_prefix("file://")
            .and_then(|value| value.find('/').map(|index| &value[index..]))
            .unwrap_or(uri);
        self.command_blocks.directory = decode_percent(path, 4_096)
            .filter(|path| path.starts_with('/') && !path.chars().any(char::is_control));
    }

    pub(super) fn record_semantic_prompt(&mut self, params: &[&[u8]]) {
        if self.mode.contains(TermMode::ALT_SCREEN) {
            return;
        }
        let Some(action) = params
            .first()
            .filter(|value| value.len() == 1)
            .map(|value| value[0])
        else {
            return;
        };
        self.command_blocks.last_write = Some(self.grid.cursor.point);
        let exit_code = if action == b'D' {
            params
                .get(1)
                .and_then(|value| std::str::from_utf8(value).ok())
                .and_then(|value| value.parse().ok())
        } else {
            None
        };
        match action {
            b'A' | b'N' => {
                let id = self.command_blocks.pending.unwrap_or_else(|| {
                    self.command_blocks.next_id =
                        self.command_blocks.next_id.wrapping_add(1).max(1);
                    self.command_blocks.next_id
                });
                self.command_blocks.pending = Some(id);
                self.command_blocks.zone = None;
                self.command_anchor(id, 0);
            }
            b'P' => {
                self.command_blocks.zone = None;
            }
            b'B' | b'I' => {
                if let Some(id) = self.command_blocks.pending {
                    self.command_anchor(id, 1);
                    self.command_blocks.zone = Some((id, 1));
                }
            }
            b'C' => {
                if self.command_blocks.active.is_some() {
                    return;
                }
                if let Some(id) = self.command_blocks.pending.take() {
                    let command = params
                        .iter()
                        .find_map(|value| {
                            std::str::from_utf8(value)
                                .ok()?
                                .strip_prefix("cmdline_url=")
                        })
                        .and_then(|value| decode_percent(value, MAX_COMMAND_BYTES))
                        .unwrap_or_else(|| self.input_text(id));
                    self.command_anchor(id, 2);
                    self.command_blocks.zone = None;
                    self.command_blocks.active = Some(id);
                    self.command_blocks.records.push_back(CommandRecord {
                        id,
                        command,
                        working_directory: self.command_blocks.directory.clone(),
                        started_at_ms: now_ms(),
                        finished_at_ms: None,
                        duration_ns: None,
                        exit_code: None,
                        location_valid: true,
                        started: Instant::now(),
                    });
                    while self.command_blocks.records.len() > MAX_RECORDS {
                        self.command_blocks.records.pop_front();
                    }
                    self.command_blocks.revision = self.command_blocks.revision.wrapping_add(1);
                    self.event_proxy.send_event(Event::CommandRecordsChanged);
                }
            }
            b'D' => {
                if let Some(id) = self.command_blocks.active.take() {
                    self.command_anchor(id, 3);
                    if let Some(record) = self
                        .command_blocks
                        .records
                        .iter_mut()
                        .find(|record| record.id == id)
                    {
                        record.finished_at_ms = Some(now_ms());
                        record.duration_ns =
                            Some(record.started.elapsed().as_nanos().min(u64::MAX as u128) as u64);
                        record.exit_code = exit_code;
                    }
                    self.command_blocks.zone = None;
                    self.command_blocks.revision = self.command_blocks.revision.wrapping_add(1);
                    self.event_proxy.send_event(Event::CommandRecordsChanged);
                }
            }
            _ => return,
        }
        if matches!(action, b'A' | b'B' | b'C' | b'D') {
            self.event_proxy
                .send_event(Event::SemanticPrompt { action, exit_code });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::VoidListener;
    use crate::term::{Config, test::TermSize};
    use crate::vte::ansi::Processor;

    fn terminal() -> (Term<VoidListener>, Processor) {
        (
            Term::new(Config::default(), &TermSize::new(24, 4), VoidListener),
            Processor::new(),
        )
    }

    #[test]
    fn metadata_uses_native_osc_boundaries_and_execution_directory() {
        let (mut term, mut parser) = terminal();
        parser.advance(&mut term, b"\x1b]7;file://localhost/tmp/first%20directory\x07\x1b]133;A\x07PROMPT> \x1b]133;B\x07echo actual\r\n\x1b]133;C;cmdline_url=printf%20%27hello%3B%E4%BD%A0%E5%A5%BD%27%0Afalse\x07result\r\n\x1b]7;file://localhost/tmp/new\x07\x1b]133;D;7\x07");
        let record = &term.command_records()[0];
        assert_eq!(record.command, "printf 'hello;你好'\nfalse");
        assert_eq!(
            record.working_directory.as_deref(),
            Some("/tmp/first directory")
        );
        assert_eq!(record.exit_code, Some(7));
        assert!(record.finished_at_ms.unwrap() >= record.started_at_ms);
        assert!(record.duration_ns.is_some());
        assert_eq!(term.command_text(record.id, 1).as_deref(), Some("result"));
    }

    #[test]
    fn location_survives_scroll_and_reflow_and_erasure_invalidates_it() {
        let (mut term, mut parser) = terminal();
        parser.advance(&mut term, b"\x1b]133;A\x07> \x1b]133;B\x07echo abcdefghijklmnop\r\n\x1b]133;C\x07abcdefghijklmnop\r\n\x1b]133;D;0\x07");
        let id = term.command_records()[0].id;
        let before = term.command_text(id, 1).unwrap();
        parser.advance(&mut term, b"one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
        assert_eq!(term.command_text(id, 1).unwrap(), before);
        for columns in [8, 40, 12, 24] {
            term.resize(TermSize::new(columns, 4));
            assert_eq!(
                term.command_text(id, 1).unwrap(),
                before,
                "columns={columns}"
            );
        }
        term.invalidate_command_locations();
        term.grid_mut().clear_history();
        assert!(term.command_region(id).is_none());
    }

    #[test]
    fn zle_prompt_redraw_keeps_pending_and_completed_boundary_cells() {
        let (mut term, mut parser) = terminal();
        parser.advance(&mut term, b"\x1b]133;A\x07\x1b[J> \x1b[K\x1b]133;B\x07echo one\r\n\x1b]133;C;cmdline_url=echo%20one\x07result\r\n\x1b]133;D;0\x07\x1b]133;A\x07\x1b[J> \x1b[K\x1b]133;B\x07");
        let id = term.command_records()[0].id;
        assert_eq!(term.command_text(id, 1).as_deref(), Some("result"));
        parser.advance(&mut term, b"echo two\r\n\x1b]133;C;cmdline_url=echo%20two\x07second\r\n\x1b]133;D;0\x07\x1b]133;A\x07\x1b[J> \x1b[K\x1b]133;B\x07");
        assert_eq!(term.command_text(id, 1).as_deref(), Some("result"));
        let second = term.command_records()[1].id;
        assert_eq!(term.command_text(second, 1).as_deref(), Some("second"));
    }

    #[test]
    fn overwritten_and_erased_output_cannot_keep_a_live_token() {
        for rewrite in [b"\x1b[2;1Hreplacement".as_slice(), b"\x1b[2;1H\x1b[2K".as_slice(), b"\x1b[2;1H\x1b[J".as_slice(), b"\x1b[2;6H\x1b[1J".as_slice()] {
            let (mut term, mut parser) = terminal();
            parser.advance(&mut term, b"\x1b]133;A\x07> \x1b]133;B\x07echo one\r\n\x1b]133;C\x07result\r\n\x1b]133;D;0\x07");
            let id = term.command_records()[0].id;
            assert!(term.command_region(id).is_some());
            parser.advance(&mut term, rewrite);
            assert!(term.command_region(id).is_none());
            assert_eq!(term.command_records()[0].command, "echo one");
        }
    }

    #[test]
    fn synchronized_updates_commit_command_boundaries_with_grid() {
        let (mut term, mut parser) = terminal();
        parser.advance(
            &mut term,
            b"\x1b[?2026h\x1b]133;A\x07> \x1b]133;B\x07false\r\n\x1b]133;C\x07\x1b]133;D;17\x07",
        );
        assert!(term.command_records().is_empty());
        parser.advance(&mut term, b"\x1b[?2026l");
        assert_eq!(term.command_records()[0].exit_code, Some(17));
    }
}
