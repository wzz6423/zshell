import AppKit

@MainActor
private final class InputFixture {
    var text = Array("0123456789abcdefghij")
    var cursor = 20
    var controls: [String] = []
    var acknowledge = true
    lazy var editor = TerminalAIInputEditor(
        readSnapshot: { [unowned self] in snapshot },
        sendControl: { [unowned self] in send($0) },
        clearHighlight: {}
    )

    var snapshot: TerminalAIInputSnapshot {
        TerminalAIInputSnapshot(
            processID: 1, columns: 80,
            lines: [String(repeating: "─", count: 80), "❯ " + String(text), String(repeating: "─", count: 80)],
            cursorRow: 1, cursorPrefix: "❯ " + String(text.prefix(cursor))
        )!
    }

    func click(_ offset: Int) {
        let caret = TerminalAIInputCaret(row: 0, offset: offset)
        editor.beginPointer(at: caret, in: snapshot)
        editor.endPointer(at: caret, in: snapshot, dragged: false)
    }

    func select(_ range: Range<Int>) {
        editor.beginPointer(at: TerminalAIInputCaret(row: 0, offset: range.lowerBound), in: snapshot)
        editor.endPointer(at: TerminalAIInputCaret(row: 0, offset: range.upperBound), in: snapshot, dragged: true)
    }

    func selectBackward(_ range: Range<Int>) {
        editor.beginPointer(at: TerminalAIInputCaret(row: 0, offset: range.upperBound), in: snapshot)
        editor.endPointer(at: TerminalAIInputCaret(row: 0, offset: range.lowerBound), in: snapshot, dragged: true)
    }

    func insert(_ value: String) {
        if editor.deferWhileBusy({ [unowned self] in insert(value) }) { return }
        if editor.replaceSelection(then: { [unowned self] in insert(value) }) { return }
        send(value)
    }

    private func send(_ value: String) {
        controls.append(value)
        guard acknowledge else { return }
        // A PTY acknowledges input later, after the next gesture may arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [self] in
            var remainder = value[...]
            while !remainder.isEmpty {
                if remainder.hasPrefix("\u{1b}[D") {
                    cursor = max(0, cursor - 1)
                    remainder = remainder.dropFirst(3)
                } else if remainder.hasPrefix("\u{1b}[C") {
                    cursor = min(text.count, cursor + 1)
                    remainder = remainder.dropFirst(3)
                } else if remainder.hasPrefix("\u{1b}[3~") {
                    if cursor < text.count { text.remove(at: cursor) }
                    remainder = remainder.dropFirst(4)
                } else if remainder.first == "\u{05}" {
                    cursor = text.count
                    remainder = remainder.dropFirst()
                } else {
                    text.insert(remainder.removeFirst(), at: cursor)
                    cursor += 1
                }
            }
        }
    }

    func settle() {
        let deadline = Date().addingTimeInterval(1.2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while editor.isBusy && Date() < deadline
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(!editor.isBusy, "Cursor operation did not complete")
    }
}

@main
struct TerminalAIInputTests {
    @MainActor static func main() {
        do {
            let rule = String(repeating: "─", count: 100)
            var lines = Array(repeating: "", count: 30)
            lines[26] = rule
            lines[27] = "❯\u{a0}0123456789abcdefghij"
            lines[28] = rule
            lines[29] = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
            let snapshot = TerminalAIInputSnapshot(
                processID: 1, columns: 100, lines: lines,
                cursorRow: 27, cursorPrefix: lines[27]
            )
            precondition(snapshot?.firstRow == 27)
            precondition(snapshot?.rows == ["0123456789abcdefghij"])
            precondition(snapshot?.cursor == TerminalAIInputCaret(row: 0, offset: 20))
            precondition(TerminalAIInputSnapshot(
                processID: 1, columns: 100, lines: lines,
                cursorRow: 29, cursorPrefix: "  "
            ) == nil)
            print("PASS: real Claude NBSP frame recognizes the input caret and rejects a footer caret")
        }
        do {
            let fixture = InputFixture()
            fixture.click(5)
            fixture.insert("X")
            fixture.settle()
            precondition(String(fixture.text) == "01234X56789abcdefghij")
            print("PASS: immediate typing waits for cursor acknowledgement")
        }
        do {
            let fixture = InputFixture()
            fixture.click(5)
            fixture.click(12)
            fixture.click(3)
            fixture.insert("XY")
            fixture.settle()
            precondition(String(fixture.text) == "012XY3456789abcdefghij")
            print("PASS: consecutive clicks use acknowledged positions and preserve typing")
        }
        do {
            let fixture = InputFixture()
            fixture.click(5)
            fixture.select(2..<8)
            fixture.insert("voice")
            fixture.settle()
            precondition(String(fixture.text) == "01voice89abcdefghij")
            print("PASS: a drag during movement replaces exactly the selected range")
        }
        do {
            let fixture = InputFixture()
            fixture.select(3..<7)
            fixture.insert("X")
            fixture.click(10)
            fixture.settle()
            precondition(String(fixture.text) == "012X789abcdefghij")
            print("PASS: a new gesture does not cancel a pending replacement")
        }
        do {
            let fixture = InputFixture()
            fixture.click(5)
            fixture.text = Array("another prompt")
            fixture.cursor = fixture.text.count
            fixture.settle()
            precondition(!fixture.controls.contains { $0.contains("\u{1b}[3~") })
            print("PASS: changed input never triggers a stale deletion")
        }
        do {
            let fixture = InputFixture()
            fixture.acknowledge = false
            fixture.click(5)
            fixture.insert("voice")
            fixture.settle()
            precondition(fixture.controls.last == "voice")
            print("PASS: cursor timeout does not swallow deferred input")
        }
        do {
            let fixture = InputFixture()
            fixture.selectBackward(2..<8)
            fixture.insert("voice")
            fixture.settle()
            precondition(String(fixture.text) == "01voice89abcdefghij")
            print("PASS: a right-to-left drag replaces the same range as a forward drag")
        }
        do {
            let fixture = InputFixture()
            fixture.text = Array("零一二三四五六七八九")
            fixture.cursor = fixture.text.count
            fixture.select(2..<8)
            fixture.insert("语音")
            fixture.settle()
            precondition(String(fixture.text) == "零一语音八九")
            print("PASS: replacing a wide-character selection counts glyphs, not cells")
        }
        do {
            let fixture = InputFixture()
            fixture.select(3..<7)
            fixture.text = Array("a completely different prompt")
            fixture.cursor = fixture.text.count
            fixture.insert("Z")
            fixture.settle()
            precondition(!fixture.controls.contains { $0.contains("\u{1b}[3~") })
            precondition(fixture.controls.contains("Z"))
            print("PASS: a selection over changed input inserts without deleting")
        }
    }
}
