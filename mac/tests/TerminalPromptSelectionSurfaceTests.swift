import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor
private final class PromptTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private func pump(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

@main
struct TerminalPromptSelectionSurfaceTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zshell-prompt-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = directory.appendingPathComponent("buffer")
        let bufferPath = "'" + buffer.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let profile = ProcessInfo.processInfo.environment["ZSHELL_TEST_ZSHRC"]
        let sourceProfile = profile.map {
            "source '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        } ?? ""
        try """
        \(sourceProfile)
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        bindkey -e
        builtin print -r -- 'OUTPUT'
        PROMPT='READY> '
        RPROMPT=''
        PS2=''
        _dump() { builtin print -rn -- "$BUFFER" >| \(bufferPath); }
        zle -N _dump
        bindkey '^T' _dump
        _reset() { BUFFER=''; CURSOR=0; }
        zle -N _reset
        bindkey '^R' _reset
        _multiline() { BUFFER=$'first line\\nsecond line'; CURSOR=${#BUFFER}; }
        zle -N _multiline
        bindkey '^N' _multiline
        _select_left() { (( REGION_ACTIVE )) || zle set-mark-command; zle backward-char; }
        zle -N _select_left
        bindkey '^[[1;2D' _select_left
        """.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        let session = TerminalSession(
            initialDirectory: directory.path,
            additionalEnvironment: ["ZDOTDIR": directory.path, "LC_ALL": "en_US.UTF-8"]
        )
        let view = session.surface
        let window = PromptTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        defer {
            session.terminate()
            pump(0.2)
            window.contentView = nil
        }

        func lines() -> [String] {
            if let ghostty = view as? ZshellTerminalView {
                return ghostty.readViewportTextSnapshot()?.lines ?? []
            }
            return (view.readVisibleText(maxLines: 100, maxColumns: 1000) ?? "").components(separatedBy: "\n")
        }

        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else {
                view.sendText(text)
            }
        }

        func mouse(_ type: NSEvent.EventType, _ offset: Int, row relativeRow: Int = 0) throws {
            guard let firstRow = lines().lastIndex(where: { $0.hasPrefix("READY> ") }) else {
                throw NSError(domain: "PromptRowMissing", code: 1)
            }
            let row = firstRow + relativeRow
            let column = offset + (relativeRow == 0 ? 7 : 0)
            let location: CGPoint
            if let ghostty = view as? ZshellTerminalView {
                let snapshot = ghostty.readViewportTextSnapshot()!
                location = CGPoint(
                    x: snapshot.origin.x + (CGFloat(column) + 0.1) * snapshot.cellSize.width,
                    y: view.bounds.height - snapshot.origin.y - (CGFloat(row) + 0.5) * snapshot.cellSize.height
                )
            } else {
                let settings = AppSettings.shared
                let metrics = AlacrittyMetrics(
                    family: settings.fontFamily, fallbackFamily: settings.fontFallbackFamily,
                    size: CGFloat(settings.fontSize), fontThicken: settings.fontThicken,
                    fontThickenStrength: settings.fontThickenStrength, lineHeight: CGFloat(settings.terminalLineHeight)
                )
                location = CGPoint(
                    x: 10 + (CGFloat(column) + 0.1) * metrics.cellWidth,
                    y: view.bounds.height - 8 - (CGFloat(row) + 0.5) * metrics.cellHeight
                )
            }
            let event = NSEvent.mouseEvent(
                with: type, location: view.convert(location, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseDragged(with: event)
            }
            pump(0.05)
        }

        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            view.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
            )!)
        }

        let deadline = Date().addingTimeInterval(5)
        while !session.terminalPromptSelectionIsReady && Date() < deadline { pump(0.01) }
        guard session.terminalPromptSelectionIsReady else {
            throw NSError(domain: "PromptStartup", code: 1)
        }
        pump(0.1)
        var failures = 0
        func verify(_ expected: String, _ label: String) throws {
            control("\u{14}")
            pump(0.1)
            let actual = try String(contentsOf: buffer, encoding: .utf8)
            let passed = actual == expected
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(backend) zsh \(label): \(actual)")
        }
        for (draft, start, end, text, code, expected, label) in [
            ("0123456789abcdefghij", 5, 5, "x", UInt16(7), "01234x56789abcdefghij", "click insertion"),
            ("0123456789abcdefghij", 2, 8, "x", UInt16(7), "01x89abcdefghij", "forward drag replacement"),
            ("0123456789abcdefghij", 8, 2, "x", UInt16(7), "01x89abcdefghij", "reverse drag replacement"),
            ("0123456789abcdefghij", 2, 8, "\u{7f}", UInt16(51), "0189abcdefghij", "drag Backspace"),
            ("0123456789abcdefghij", 2, 8, "\u{f728}", UInt16(117), "0189abcdefghij", "drag forward Delete"),
            ("零一二三四五六七八九", 4, 16, "x", UInt16(7), "零一x八九", "wide-character replacement"),
        ] {
            control("\u{12}")
            pump(0.1)
            key(draft, code: 0)
            pump(0.1)
            try mouse(.leftMouseDown, start)
            if start != end { try mouse(.leftMouseDragged, end) }
            try mouse(.leftMouseUp, end)
            key(text, code: code)
            pump(0.15)
            try verify(expected, label)
        }

        for (start, end, text, code, expected, label) in [
            (2, 8, "X", UInt16(7), "01X89abcdefghij", "Shift character replaces forward selection"),
            (8, 2, "X", UInt16(7), "01X89abcdefghij", "Shift character replaces reverse selection"),
            (8, 2, "$", UInt16(21), "01$89abcdefghij", "Shift punctuation replaces selection"),
            (8, 2, "\u{7f}", UInt16(51), "0189abcdefghij", "Shift Backspace deletes selection"),
        ] {
            control("\u{12}")
            pump(0.1)
            key("0123456789abcdefghij", code: 0)
            pump(0.1)
            try mouse(.leftMouseDown, start)
            try mouse(.leftMouseDragged, end)
            try mouse(.leftMouseUp, end)
            key(text, code: code, modifiers: .shift)
            pump(0.15)
            try verify(expected, label)
        }

        for (text, code, modifiers, expected, label) in [
            ("x", UInt16(7), NSEvent.ModifierFlags(), "01x89abcdefghij", "keyboard selection replacement"),
            ("X", UInt16(7), NSEvent.ModifierFlags.shift, "01X89abcdefghij", "keyboard selection Shift replacement"),
            ("\u{7f}", UInt16(51), NSEvent.ModifierFlags(), "0189abcdefghij", "keyboard selection Backspace"),
            ("\u{f728}", UInt16(117), NSEvent.ModifierFlags(), "0189abcdefghij", "keyboard selection forward Delete"),
        ] {
            control("\u{12}")
            pump(0.1)
            key("0123456789abcdefghij", code: 0)
            pump(0.1)
            for _ in 0..<12 { key("\u{f702}", code: 123) }
            for _ in 0..<6 { key("\u{f702}", code: 123, modifiers: .shift) }
            pump(0.1)
            key(text, code: code, modifiers: modifiers)
            pump(0.15)
            try verify(expected, label)
        }

        control("\u{12}")
        pump(0.1)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 2)
        try mouse(.leftMouseDragged, 8)
        try mouse(.leftMouseUp, 8)
        try mouse(.leftMouseDown, 5)
        try mouse(.leftMouseUp, 5)
        key("x", code: 7)
        pump(0.15)
        try verify("01234x56789abcdefghij", "click cancels an existing selection")

        control("\u{12}")
        pump(0.1)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 2)
        try mouse(.leftMouseDragged, 8)
        try mouse(.leftMouseUp, 8)
        key("\u{f702}", code: 123)
        pump(0.1)
        key("x", code: 7)
        pump(0.15)
        try verify("0123456x789abcdefghij", "cursor keys cancel an existing selection")

        control("\u{12}")
        pump(0.1)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 2)
        try mouse(.leftMouseDragged, 8)
        try mouse(.leftMouseUp, 8)
        key("c", code: 8, modifiers: .command)
        pump(0.1)
        key("x", code: 7)
        pump(0.15)
        try verify("01x89abcdefghij", "copy preserves an existing selection")

        control("\u{12}")
        pump(0.1)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 2)
        try mouse(.leftMouseDragged, 8)
        try mouse(.leftMouseUp, 8)
        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString("paste", forType: .string)
        if let ghostty = view as? ZshellTerminalView { ghostty.paste(nil) }
        else if let alacritty = view as? AlacrittyTerminalView { alacritty.paste(nil) }
        pasteboard.clearContents()
        let restoredClipboard = previousClipboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restoredClipboard)
        pump(0.15)
        try verify("01paste89abcdefghij", "paste replaces selection")

        control("\u{12}")
        pump(0.1)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 0, row: -1)
        try mouse(.leftMouseDragged, 4, row: -1)
        try mouse(.leftMouseUp, 4, row: -1)
        key("x", code: 7)
        pump(0.15)
        try verify("0123456789abcdefghijx", "output selection does not edit the prompt")

        let columns: Int
        if let ghostty = view as? ZshellTerminalView {
            columns = ghostty.readViewportTextSnapshot()!.columns
        } else {
            let settings = AppSettings.shared
            let metrics = AlacrittyMetrics(
                family: settings.fontFamily, fallbackFamily: settings.fontFallbackFamily,
                size: CGFloat(settings.fontSize), fontThicken: settings.fontThicken,
                fontThickenStrength: settings.fontThickenStrength, lineHeight: CGFloat(settings.terminalLineHeight)
            )
            columns = Int((view.bounds.width - 20) / metrics.cellWidth)
        }
        for (draft, end, expected, label) in [
            (String(repeating: "a", count: columns - 7) + "TAIL", 2, "aaxIL", "replacement across a soft wrap"),
            (String(repeating: "a", count: columns - 7) + "TAIL", 0, "aaxTAIL", "replacement ending at a soft wrap"),
            ("first line\nsecond line", 4, "fixnd line", "replacement across a newline"),
            ("first line\nsecond line", 0, "fixsecond line", "replacement ending after a newline"),
        ] {
            control("\u{12}")
            pump(0.1)
            if draft.contains("\n") { control("\u{0e}") }
            else { key(draft, code: 0) }
            pump(0.15)
            try mouse(.leftMouseDown, 2)
            try mouse(.leftMouseDragged, end, row: 1)
            try mouse(.leftMouseUp, end, row: 1)
            key("x", code: 7)
            pump(0.15)
            try verify(expected, label)
        }
        control("\u{12}")
        pump(0.1)
        key("printf 'NEXT\\n'", code: 0)
        key("\r", code: 36)
        pump(0.3)
        key("0123456789abcdefghij", code: 0)
        pump(0.1)
        try mouse(.leftMouseDown, 2)
        try mouse(.leftMouseDragged, 8)
        try mouse(.leftMouseUp, 8)
        key("x", code: 7)
        pump(0.15)
        try verify("01x89abcdefghij", "replacement after another command")
        if failures > 0 { exit(1) }
    }
}
