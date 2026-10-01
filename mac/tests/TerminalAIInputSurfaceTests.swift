import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor
private final class InputTestApplication: NSApplication {
    var textInputEvent: NSEvent?
    override var currentEvent: NSEvent? { textInputEvent ?? super.currentEvent }
}

@MainActor
private final class InputTestWindow: NSWindow {
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
struct TerminalAIInputSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let app = InputTestApplication.shared as! InputTestApplication
        let backend = CommandLine.arguments[1]
        let fixture = CommandLine.arguments[2]
        let launch = TerminalLaunch(
            program: "/usr/bin/python3", arguments: [fixture],
            commandLine: "/usr/bin/python3 '" + fixture.replacingOccurrences(of: "'", with: "'\\''") + "'",
            interactiveShell: nil, workingDirectory: NSTemporaryDirectory(),
            environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"]
        )
        let view: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        let window = InputTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        defer {
            view.setSurfaceVisible(false)
            view.detach()
            window.contentView = nil
        }

        func lines() -> [String] {
            if let ghostty = view as? ZshellTerminalView {
                return ghostty.readViewportTextSnapshot()?.lines ?? []
            }
            return (view.readVisibleText(maxLines: 100, maxColumns: 1000) ?? "").components(separatedBy: "\n")
        }

        func inputRow() -> Int? {
            let rows = lines()
            return rows.indices.first {
                $0 > 0 && (rows[$0].hasPrefix("❯ ") || rows[$0].hasPrefix("❯\u{a0}"))
                    && rows[$0 - 1].hasPrefix("────")
            }
        }

        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else {
                view.sendText(text)
            }
        }

        func mouse(
            _ type: NSEvent.EventType, _ offset: Int, row relativeRow: Int = 0,
            clickCount: Int = 1
        ) {
            let row = inputRow()! + relativeRow
            let location: CGPoint
            if let ghostty = view as? ZshellTerminalView {
                let snapshot = ghostty.readViewportTextSnapshot()!
                location = CGPoint(
                    x: snapshot.origin.x + (CGFloat(offset + 2) + 0.1) * snapshot.cellSize.width,
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
                    x: 10 + (CGFloat(offset + 2) + 0.1) * metrics.cellWidth,
                    y: view.bounds.height - 8 - (CGFloat(row) + 0.5) * metrics.cellHeight
                )
            }
            let event = NSEvent.mouseEvent(
                with: type, location: view.convert(location, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
            )!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseDragged(with: event)
            }
        }

        func select() {
            mouse(.leftMouseDown, 2)
            mouse(.leftMouseDragged, 8)
            mouse(.leftMouseUp, 8)
        }

        func click(_ offset: Int) {
            mouse(.leftMouseDown, offset)
            mouse(.leftMouseUp, offset)
        }

        func commitText(_ text: String, composing: Bool = false) {
            // Ghostty commits text only while AppKit is dispatching an event.
            app.textInputEvent = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0
            )
            defer { app.textInputEvent = nil }
            let client = view as! any NSTextInputClient
            if composing {
                client.setMarkedText("zi", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        func key(_ text: String = "x", code: UInt16 = 7) {
            view.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
            )!)
        }

        func redraw() {
            control("\u{14}")
            // The fixture holds DEC 2026 open for 100 ms, including the full
            // input repaint. Deliver the gesture before that frame commits.
            pump(0.025)
        }

        var failures = 0
        func verify(_ expected: String, _ label: String, reset: Bool = true) {
            func inputText() -> String? {
                inputRow().map { row in
                    lines()[row...].prefix { !$0.hasPrefix("────") }
                        .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                        .joined(separator: "\n")
                }
            }
            let deadline = Date().addingTimeInterval(3.5)
            while inputText() != expected && Date() < deadline { pump(0.01) }
            pump(0.05)
            let actual = inputText()
            let passed = actual == expected
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(backend) \(label): \(actual ?? "missing input")")
            if reset {
                control("\u{12}")
                pump(0.1)
            }
        }

        func verifyMouseReports(_ expected: Range<Int>, _ label: String, inputOnly: Bool = false) {
            pump(0.15)
            let prefix = inputOnly ? "Mouse input reports: " : "Mouse reports: "
            let count = lines().first { $0.hasPrefix(prefix) }
                .flatMap { Int($0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) }
            let passed = count.map { expected.contains($0) } ?? false
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(backend) \(label): \(count.map(String.init) ?? "missing counter")")
        }

        func verifyEarlyInput(captured: Bool) {
            let pasteboard = NSPasteboard.general
            let previousClipboard = pasteboard.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
            let copyOnSelect = AppSettings.shared.copyOnSelect
            AppSettings.shared.copyOnSelect = true
            defer {
                AppSettings.shared.copyOnSelect = copyOnSelect
                pasteboard.clearContents()
                pasteboard.writeObjects(previousClipboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
            for reverse in [false, true] {
                for action in ["key", "Backspace", "Delete", "insertText", "IME", "paste", "accessibility"] {
                    if captured { control("\u{15}"); pump(0.1) }
                    pasteboard.clearContents()
                    pasteboard.setString("paste", forType: .string)
                    mouse(.leftMouseDown, reverse ? 8 : 2)
                    mouse(.leftMouseDragged, reverse ? 2 : 8, clickCount: 0)
                    let replacement: String
                    switch action {
                    case "Backspace": key("\u{7f}", code: 51); replacement = ""
                    case "Delete": key("\u{f728}", code: 117); replacement = ""
                    case "insertText":
                        commitText("字")
                        replacement = "字"
                    case "IME":
                        commitText("字", composing: true)
                        replacement = "字"
                    case "paste":
                        if let ghostty = view as? ZshellTerminalView { ghostty.paste(nil) }
                        else if let alacritty = view as? AlacrittyTerminalView { alacritty.paste(nil) }
                        replacement = "paste"
                    case "accessibility": view.setAccessibilitySelectedText("voice"); replacement = "voice"
                    default: key(); replacement = "x"
                    }
                    let label = "capture=\(captured) \(reverse ? "reverse" : "forward") \(action) before release"
                    verify("01\(replacement)89abcdefghij", label, reset: false)
                    if let ghostty = view as? ZshellTerminalView {
                        let cleared = !ghostty.hasSelection
                        if !cleared { failures += 1 }
                        print("\(cleared ? "PASS" : "FAIL"): \(backend) \(label) clears native highlight")
                    }
                    mouse(.leftMouseDragged, 12, clickCount: 0)
                    mouse(.leftMouseUp, 14, clickCount: 0)
                    key("z", code: 6)
                    verify("01\(replacement)z89abcdefghij", "\(label) ignores delayed pointer events")
                    let clipboardPreserved = pasteboard.string(forType: .string) == "paste"
                    if !clipboardPreserved { failures += 1 }
                    print("\(clipboardPreserved ? "PASS" : "FAIL"): \(backend) \(label) preserves clipboard")
                    if captured { verifyMouseReports(0..<1, "\(label) stays local", inputOnly: true) }
                }
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while inputRow() == nil && Date() < deadline { pump(0.01) }
        guard inputRow() != nil else { throw NSError(domain: "TerminalInputStartup", code: 1) }

        select()
        key()
        verify("01x89abcdefghij", "ordinary drag replacement")

        verifyEarlyInput(captured: false)

        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 5, clickCount: 0)
        mouse(.leftMouseUp, 8, clickCount: 0)
        key()
        verify("01x89abcdefghij", "normal release uses its final position")

        mouse(.leftMouseDown, 5)
        key()
        mouse(.leftMouseUp, 5, clickCount: 0)
        verify("0123456789abcdefghijx", "typing during a click does not create an editable selection")

        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 8)
        mouse(.leftMouseDragged, 8, row: -1, clickCount: 0)
        key()
        mouse(.leftMouseUp, 8, row: -1, clickCount: 0)
        verify("0123456789abcdefghijx", "leaving the input cancels the editable drag")

        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 5)
        view.setAccessibilitySelectedText("")
        mouse(.leftMouseDragged, 8, clickCount: 0)
        mouse(.leftMouseUp, 8, clickCount: 0)
        key()
        verify("01x89abcdefghij", "empty accessibility input leaves the drag active")

        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 8)
        window.makeFirstResponder(nil)
        view.setAccessibilitySelectedText("unfocused")
        mouse(.leftMouseDragged, 12, clickCount: 0)
        mouse(.leftMouseUp, 14, clickCount: 0)
        verify("0123456789abcdefghij", "focus loss rejects accessibility input", reset: false)
        window.makeFirstResponder(view)
        key()
        verify("0123456789abcdefghijx", "focus loss cancels the editable drag")

        redraw()
        select()
        pump(0.15)
        key()
        verify("01x89abcdefghij", "drag during redraw, type after redraw")

        select()
        redraw()
        key()
        verify("01x89abcdefghij", "type during redraw with an existing selection")

        redraw()
        select()
        key("\u{7f}", code: 51)
        verify("0189abcdefghij", "drag and Backspace during redraw")

        redraw()
        click(5)
        key()
        verify("01234x56789abcdefghij", "click and type during redraw")

        redraw()
        click(5)
        click(12)
        click(3)
        key()
        verify("012x3456789abcdefghij", "consecutive clicks during redraw")

        redraw()
        select()
        view.setAccessibilitySelectedText("voice")
        verify("01voice89abcdefghij", "accessibility insertion during redraw")

        control("\u{0e}")
        pump(0.1)
        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 4, row: 1)
        mouse(.leftMouseUp, 4, row: 1)
        key()
        verify("fixnd line\nthird line", "replacement across an erased continuation prefix")

        control("\u{0e}")
        pump(0.1)
        mouse(.leftMouseDown, 0, row: 1)
        mouse(.leftMouseDragged, 6, row: 1)
        mouse(.leftMouseUp, 6, row: 1)
        key()
        verify("first line\nx line\nthird line", "selection starting at a continuation row")

        control("\u{0f}")
        pump(0.1)
        mouse(.leftMouseDown, 2)
        mouse(.leftMouseDragged, 2, row: 2)
        mouse(.leftMouseUp, 2, row: 2)
        key()
        verify("fixird line", "selection across an empty row")

        control("\u{10}")
        pump(0.1)
        mouse(.leftMouseDown, 3)
        mouse(.leftMouseDragged, 5)
        mouse(.leftMouseUp, 5)
        key()
        verify("ab xd", "selection starting inside erased spaces")

        control("\u{11}")
        pump(0.1)
        mouse(.leftMouseDown, 5)
        mouse(.leftMouseDragged, 7)
        mouse(.leftMouseUp, 7)
        key()
        verify("中文 xd", "erased spaces after wide characters")

        control("\u{15}")
        pump(0.1)
        select()
        key()
        verify("01x89abcdefghij", "Claude mouse-reporting input replacement")
        verifyMouseReports(0..<1, "AI drag does not also send native mouse input", inputOnly: true)

        verifyEarlyInput(captured: true)

        control("\u{15}")
        pump(0.1)
        select()
        key("\u{7f}", code: 51)
        verify("0189abcdefghij", "Claude mouse-reporting Backspace removes selection")
        verifyMouseReports(0..<1, "AI Backspace drag stays local", inputOnly: true)

        control("\u{15}")
        pump(0.1)
        select()
        key("\u{f728}", code: 117)
        verify("0189abcdefghij", "Claude mouse-reporting Delete removes selection")
        verifyMouseReports(0..<1, "AI Delete drag stays local", inputOnly: true)

        control("\u{15}")
        pump(0.1)
        select()
        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString("paste", forType: .string)
        if let ghostty = view as? ZshellTerminalView { ghostty.paste(nil) }
        else if let alacritty = view as? AlacrittyTerminalView { alacritty.paste(nil) }
        pasteboard.clearContents()
        pasteboard.writeObjects(previousClipboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        })
        verify("01paste89abcdefghij", "Claude mouse-reporting paste replaces selection")
        verifyMouseReports(0..<1, "AI paste drag stays local", inputOnly: true)

        control("\u{15}")
        pump(0.1)
        click(5)
        key()
        verify("01234x56789abcdefghij", "Claude mouse-reporting click and type")
        verifyMouseReports(0..<1, "AI click does not also send native mouse input", inputOnly: true)

        mouse(.leftMouseDown, 2, row: -1)
        mouse(.leftMouseDragged, 8, row: -1)
        mouse(.leftMouseUp, 8, row: -1)
        verifyMouseReports(1..<Int.max, "mouse reporting remains enabled outside the AI input")
        verifyMouseReports(1..<Int.max, "native mouse input remains enabled outside the AI input", inputOnly: true)

        if failures > 0 { throw NSError(domain: "TerminalInputFailures", code: failures) }
    }
}
