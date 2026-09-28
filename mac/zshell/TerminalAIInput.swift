//
//  TerminalAIInput.swift
//  zshell
//

import AppKit

struct TerminalAIInputCaret: Equatable, Comparable {
    let row: Int
    let offset: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// Claude's input is drawn inside two rules; its transcript and dialogs must
/// never become editable just because the foreground process is an agent.
struct TerminalAIInputSnapshot {
    let processID: pid_t
    let columns: Int
    let firstRow: Int
    let rows: [String]
    let cursor: TerminalAIInputCaret

    init?(
        processID: pid_t, columns: Int, lines: [String],
        cursorRow: Int, cursorPrefix: String
    ) {
        guard lines.indices.contains(cursorRow), columns >= 10,
              let firstRow = (0...cursorRow).last(where: {
                  lines[$0].hasPrefix("❯ ") || lines[$0].hasPrefix("❯\u{a0}")
              }), firstRow > 0,
              Self.isRule(lines[firstRow - 1], columns: columns),
              let bottom = ((firstRow + 1)..<lines.count).first(where: {
                  Self.isRule(lines[$0], columns: columns)
              }), cursorRow < bottom,
              cursorPrefix.count >= 2,
              !lines.contains(where: { $0.contains("-- NORMAL --") || $0.contains("-- VISUAL") })
        else { return nil }

        let inputLines = Array(lines[firstRow..<bottom])
        guard inputLines.dropFirst().allSatisfy({ $0.hasPrefix("  ") }),
              !inputLines.contains(where: {
                  $0.contains("[Pasted text") || $0.contains("[Image")
              })
        else { return nil }
        let rows = inputLines.map { line in
            var text = String(line.dropFirst(2))
            while text.last == " " { text.removeLast() }
            return text
        }
        guard rows.reduce(0, { $0 + $1.count }) <= TerminalAIInputEditor.maxCursorSteps
        else { return nil }
        self.processID = processID
        self.columns = columns
        self.firstRow = firstRow
        self.rows = rows
        cursor = TerminalAIInputCaret(row: cursorRow - firstRow, offset: cursorPrefix.count - 2)
    }

    func caret(viewportRow: Int, prefix: String) -> TerminalAIInputCaret? {
        let row = viewportRow - firstRow
        guard rows.indices.contains(row), prefix.count >= 2 else { return nil }
        return TerminalAIInputCaret(
            row: row, offset: min(prefix.count - 2, TerminalAIInputEditor.maxCursorSteps)
        )
    }

    func containsSameInput(as other: Self) -> Bool {
        processID == other.processID && columns == other.columns && rows == other.rows
    }

    private static func isRule(_ line: String, columns: Int) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count >= max(10, columns - 2) && text.allSatisfy { $0 == "─" }
    }
}

/// Terminal cells cannot distinguish a newline from a TUI's own wrapping.
/// Measure a selection with non-destructive cursor keys before sending Delete,
/// checking every row transition against the unchanged input and live caret.
@MainActor
final class TerminalAIInputEditor {
    nonisolated static let maxCursorSteps = 4096

    private struct Selection {
        let snapshot: TerminalAIInputSnapshot
        let start: TerminalAIInputCaret
        let end: TerminalAIInputCaret
    }

    private let readSnapshot: () -> TerminalAIInputSnapshot?
    private let sendControl: (String) -> Void
    private let clearHighlight: () -> Void
    private var drag: (snapshot: TerminalAIInputSnapshot, caret: TerminalAIInputCaret)?
    private var selection: Selection?
    private var timer: Timer?
    private var deferredInput: [() -> Void] = []
    private var recoveryInput: (() -> Void)?
    private var rowEnds: [Int: Int] = [:]
    private var operationDeadline: TimeInterval = 0
    private(set) var isBusy = false
    var hasSelection: Bool { selection != nil }

    init(
        readSnapshot: @escaping () -> TerminalAIInputSnapshot?,
        sendControl: @escaping (String) -> Void,
        clearHighlight: @escaping () -> Void
    ) {
        self.readSnapshot = readSnapshot
        self.sendControl = sendControl
        self.clearHighlight = clearHighlight
    }

    deinit { timer?.invalidate() }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isBusy = false
        drag = nil
        selection = nil
        deferredInput.removeAll()
        recoveryInput = nil
        rowEnds.removeAll()
    }

    func beginPointer(at caret: TerminalAIInputCaret?, in snapshot: TerminalAIInputSnapshot?) {
        selection = nil
        drag = nil
        guard let caret, let snapshot else { return }
        drag = (snapshot, caret)
    }

    func endPointer(at caret: TerminalAIInputCaret?, in snapshot: TerminalAIInputSnapshot?, dragged: Bool) {
        defer { drag = nil }
        guard let drag, let caret, let snapshot,
              snapshot.containsSameInput(as: drag.snapshot)
        else { return }
        // Sent cursor keys cannot be cancelled. Finish their acknowledgement
        // before measuring another gesture against the terminal's live caret.
        if deferWhileBusy({ [weak self] in
            self?.applyPointer(from: drag.caret, to: caret, in: snapshot, dragged: dragged)
        }) { return }
        applyPointer(from: drag.caret, to: caret, in: snapshot, dragged: dragged)
    }

    private func applyPointer(
        from anchor: TerminalAIInputCaret, to caret: TerminalAIInputCaret,
        in expected: TerminalAIInputSnapshot, dragged: Bool
    ) {
        guard let snapshot = readSnapshot(), snapshot.containsSameInput(as: expected) else { return }
        if dragged {
            guard caret != anchor else { return }
            selection = Selection(
                snapshot: snapshot,
                start: min(caret, anchor), end: max(caret, anchor)
            )
        } else {
            beginOperation()
            if caret.row == snapshot.rows.count - 1, snapshot.rows[caret.row].isEmpty {
                move(to: TerminalAIInputCaret(row: caret.row, offset: 0), in: snapshot) { [weak self] _ in
                    self?.sendControl(String(repeating: "\u{1b}[C", count: caret.offset))
                    self?.finish()
                }
                return
            }
            resolve(caret, in: snapshot) { [weak self] target in
                self?.move(to: target, in: snapshot) { [weak self] _ in self?.finish() }
            }
        }
    }

    func handleKeyDown(_ event: NSEvent, replay: @escaping () -> Void) -> Bool {
        if deferWhileBusy(replay) { return true }
        guard selection != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            return replaceSelection(then: {})
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            return false
        }
        if modifiers.isEmpty, let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !((0xf700...0xf8ff).contains($0.value)) }) {
            return replaceSelection(then: replay)
        }
        if !modifiers.isEmpty || [36, 48, 53, 76, 115, 116, 119, 121, 123, 124, 125, 126]
            .contains(Int(event.keyCode)) {
            selection = nil
        }
        return false
    }

    func deferWhileBusy(_ replay: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        deferredInput.append(replay)
        return true
    }

    @discardableResult
    func replaceSelection(then insert: @escaping () -> Void) -> Bool {
        guard let selection else { return false }
        self.selection = nil
        guard let current = readSnapshot(), current.containsSameInput(as: selection.snapshot) else { return false }
        beginOperation(recoveryInput: insert)
        if selection.end.row == current.rows.count - 1, current.rows[selection.end.row].isEmpty {
            let endStart = TerminalAIInputCaret(row: selection.end.row, offset: 0)
            if selection.start.row == selection.end.row {
                move(to: endStart, in: current) { [weak self] _ in
                    self?.sendControl(String(repeating: "\u{1b}[C", count: selection.start.offset))
                    self?.delete(selection.end.offset - selection.start.offset, then: insert)
                }
            } else {
                resolve(selection.start, in: current) { [weak self] start in
                    self?.move(to: endStart, in: current) { [weak self] positioned in
                        self?.measureBack(to: start, in: positioned, count: 0) { [weak self] count in
                            // At an all-blank buffer tail, extra Delete keys
                            // clamp at EOF and cannot consume unselected text.
                            self?.delete(count + selection.end.offset, then: insert)
                        }
                    }
                }
            }
            return true
        }
        resolve(selection.end, in: current) { [weak self] end in
            self?.resolve(selection.start, in: current) { [weak self] start in
                self?.move(to: end, in: current) { [weak self] positioned in
                    self?.measureBack(to: start, in: positioned, count: 0) { [weak self] count in
                        self?.delete(count, then: insert)
                    }
                }
            }
        }
        return true
    }

    private func delete(_ count: Int, then insert: () -> Void) {
        guard count <= Self.maxCursorSteps else { fail(); return }
        clearHighlight()
        sendControl(String(repeating: "\u{1b}[3~", count: count))
        finish(then: insert)
    }

    private func beginOperation(recoveryInput: (() -> Void)? = nil) {
        isBusy = true
        self.recoveryInput = recoveryInput
        rowEnds.removeAll()
        operationDeadline = ProcessInfo.processInfo.systemUptime + 3
    }

    /// Padding and typed spaces have identical cells. Only probe ambiguous
    /// row ends; Ctrl-E reveals the logical line end without changing input.
    private func resolve(
        _ target: TerminalAIInputCaret, in expected: TerminalAIInputSnapshot,
        completion: @escaping (TerminalAIInputCaret) -> Void
    ) {
        if let end = rowEnds[target.row] {
            completion(TerminalAIInputCaret(row: target.row, offset: min(target.offset, end)))
            return
        }
        guard target.offset > max(
            expected.rows[target.row].count,
            target.row == expected.cursor.row ? expected.cursor.offset : 0
        ) else { completion(target); return }

        let start = TerminalAIInputCaret(row: target.row, offset: 0)
        move(to: start, in: expected) { [weak self] positioned in
            guard let self else { return }
            self.sendControl("\u{05}")
            let unchanged: (() -> Void)? = expected.rows[target.row].isEmpty ? { [weak self] in
                // An empty logical line makes Ctrl-E a no-op. Cross its
                // newline and come back so the PTY still acknowledges a move.
                guard let self, target.row + 1 < expected.rows.count else { self?.fail(); return }
                let next = TerminalAIInputCaret(row: target.row + 1, offset: 0)
                self.sendControl("\u{1b}[C")
                self.waitForCursor(in: positioned, matching: { $0 == next }) { [weak self] crossed in
                    guard let self else { return }
                    self.sendControl("\u{1b}[D")
                    self.waitForCursor(in: crossed, matching: { $0.row == target.row }) { [weak self] end in
                        self?.rowEnds[target.row] = end.cursor.offset
                        completion(TerminalAIInputCaret(row: target.row, offset: min(target.offset, end.cursor.offset)))
                    }
                }
            } : nil
            self.waitForCursor(in: positioned, onUnchanged: unchanged, matching: { $0 > start }) { [weak self] lineEnd in
                guard let self else { return }
                self.rowEnds[lineEnd.cursor.row] = lineEnd.cursor.offset
                if lineEnd.cursor.row == target.row {
                    completion(TerminalAIInputCaret(
                        row: target.row, offset: min(target.offset, lineEnd.cursor.offset)
                    ))
                    return
                }

                // Ctrl-E crossed this row, so its boundary is a soft wrap.
                // Left from the next row skips that boundary and one glyph.
                let nextRow = TerminalAIInputCaret(row: target.row + 1, offset: 0)
                self.move(to: nextRow, in: expected) { [weak self] positioned in
                    guard let self else { return }
                    self.sendControl("\u{1b}[D")
                    self.waitForCursor(in: positioned, matching: { $0 < nextRow }) { [weak self] previous in
                        guard let self, previous.cursor.row == target.row else { self?.fail(); return }
                        let end = previous.cursor.offset + 1
                        self.rowEnds[target.row] = end
                        completion(TerminalAIInputCaret(row: target.row, offset: min(target.offset, end)))
                    }
                }
            }
        }
    }

    private func move(
        to target: TerminalAIInputCaret, in expected: TerminalAIInputSnapshot,
        completion: @escaping (TerminalAIInputSnapshot) -> Void
    ) {
        guard let current = readSnapshot(), current.containsSameInput(as: expected) else {
            fail()
            return
        }
        guard current.cursor != target else {
            completion(current)
            return
        }
        let vertical = target.row - current.cursor.row
        let horizontal = target.offset - current.cursor.offset
        let distance = abs(vertical == 0 ? horizontal : vertical)
        guard distance <= Self.maxCursorSteps else { fail(); return }
        let key = vertical == 0
            ? (horizontal > 0 ? "\u{1b}[C" : "\u{1b}[D")
            : (vertical > 0 ? "\u{1b}[B" : "\u{1b}[A")
        sendControl(String(repeating: key, count: distance))
        waitForCursor(in: expected, matching: {
            if vertical != 0 { return $0.row == target.row }
            return $0 == target || (
                horizontal > 0 && target.offset >= expected.rows[target.row].count
                    && $0 == TerminalAIInputCaret(row: target.row + 1, offset: 0)
            )
        }) { [weak self] current in
            if vertical == 0 { completion(current) }
            else { self?.move(to: target, in: expected, completion: completion) }
        }
    }

    private func measureBack(
        to target: TerminalAIInputCaret, in current: TerminalAIInputSnapshot,
        count: Int, completion: @escaping (Int) -> Void
    ) {
        guard current.cursor != target else { completion(count); return }
        guard current.cursor > target, count < Self.maxCursorSteps else { fail(); return }
        let steps: Int
        let destination: TerminalAIInputCaret?
        if current.cursor.row == target.row {
            steps = current.cursor.offset - target.offset
            destination = target
        } else if current.cursor.offset > 0 {
            steps = current.cursor.offset
            destination = TerminalAIInputCaret(row: current.cursor.row, offset: 0)
        } else {
            steps = 1
            destination = nil
        }
        guard count + steps <= Self.maxCursorSteps else { fail(); return }
        sendControl(String(repeating: "\u{1b}[D", count: steps))
        waitForCursor(in: current, matching: { caret in
            if let destination { return caret == destination }
            return caret < current.cursor
        }) { [weak self] next in
            if destination == nil, next.cursor < target,
               target.offset >= current.rows[target.row].count,
               current.cursor == TerminalAIInputCaret(row: target.row + 1, offset: 0) {
                // A soft wrap has no character at the preceding row's end.
                // The probe crossed it; put back that one non-selected glyph.
                self?.sendControl("\u{1b}[C")
                self?.waitForCursor(in: current, matching: { $0 == current.cursor }) { _ in
                    completion(count)
                }
                return
            }
            self?.measureBack(to: target, in: next, count: count + steps, completion: completion)
        }
    }

    private func waitForCursor(
        in expected: TerminalAIInputSnapshot,
        onUnchanged: (() -> Void)? = nil,
        matching predicate: @escaping (TerminalAIInputCaret) -> Bool,
        completion: @escaping (TerminalAIInputSnapshot) -> Void
    ) {
        let deadline = min(operationDeadline, ProcessInfo.processInfo.systemUptime + 0.75)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isBusy else { timer.invalidate(); return }
                let current = self.readSnapshot()
                if let current, current.containsSameInput(as: expected),
                   predicate(current.cursor) {
                    timer.invalidate()
                    self.timer = nil
                    completion(current)
                } else if ProcessInfo.processInfo.systemUptime >= deadline {
                    if let current, current.containsSameInput(as: expected),
                       current.cursor == expected.cursor, let onUnchanged {
                        timer.invalidate()
                        self.timer = nil
                        onUnchanged()
                    } else {
                        self.fail()
                    }
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish(then completion: () -> Void = {}) {
        timer?.invalidate()
        timer = nil
        isBusy = false
        recoveryInput = nil
        rowEnds.removeAll()
        completion()
        while !isBusy, !deferredInput.isEmpty {
            deferredInput.removeFirst()()
        }
    }

    private func fail() {
        let recovery = recoveryInput
        drag = nil
        selection = nil
        clearHighlight()
        // Cursor measurement must never swallow the text that triggered it
        // or the keys received while the PTY was catching up.
        finish { recovery?() }
        NSSound.beep()
    }
}
