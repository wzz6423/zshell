import AppKit
import GhosttyTerminal
@testable import zshell

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
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
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
                $0 > 0 && rows[$0].hasPrefix("❯ ") && rows[$0 - 1].hasPrefix("────")
            }
        }

        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else {
                view.sendText(text)
            }
        }

        func mouse(_ type: NSEvent.EventType, _ offset: Int, row relativeRow: Int = 0) {
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
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
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
        func verify(_ expected: String, _ label: String) {
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
            control("\u{12}")
            pump(0.1)
        }

        let deadline = Date().addingTimeInterval(5)
        while inputRow() == nil && Date() < deadline { pump(0.01) }
        guard inputRow() != nil else { throw NSError(domain: "TerminalInputStartup", code: 1) }

        select()
        key()
        verify("01x89abcdefghij", "ordinary drag replacement")

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

        if failures > 0 { throw NSError(domain: "TerminalInputFailures", code: failures) }
    }
}
