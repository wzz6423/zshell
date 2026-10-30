import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor
private final class CompletionTestApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
}

@MainActor
private final class CompletionTestWindow: NSWindow {
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
struct TerminalCompletionSurfaceTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = CompletionTestApplication.shared as! CompletionTestApplication
        let backend = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zshell-completion-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dump = directory.appendingPathComponent("buffer")
        let sentinel = directory.appendingPathComponent("executed")
        let tuiResult = directory.appendingPathComponent("tui-input")
        let tui = directory.appendingPathComponent("tui.py")
        func quote(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try """
        bindkey -e
        PROMPT='READY> '; RPROMPT=''; HISTFILE=/dev/null
        autoload -Uz compinit; compinit -D -i
        _fixture() { compadd alpha bravo; }; compdef _fixture zfixture
        zfixture() { print ran >| \(quote(sentinel)); }
        _dump() { print -rn -- "$BUFFER"$'\\0'"$POSTDISPLAY" >| \(quote(dump)); }
        zle -N _dump; bindkey '^T' _dump
        """.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try """
        import os, termios, tty
        fd = 0
        saved = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            os.write(1, b'\\x1b[?1049hTUI_READY')
            value = os.read(fd, 1)
            with open(\(String(reflecting: tuiResult.path)), 'wb') as output:
                output.write(value)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            os.write(1, b'\\x1b[?1049l')
        """.write(to: tui, atomically: true, encoding: .utf8)

        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.shellCompletions = true
        let session = TerminalSession(initialDirectory: directory.path,
            additionalEnvironment: ["ZDOTDIR": directory.path, "LC_ALL": "en_US.UTF-8"])
        let view = session.surface
        let window = CompletionTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        defer {
            session.terminate()
            pump(0.2)
            window.contentView = nil
        }

        func lines() -> String {
            if let ghostty = view as? ZshellTerminalView {
                return (ghostty.readViewportTextSnapshot()?.lines ?? []).joined(separator: "\n")
            }
            return view.readVisibleText(maxLines: 100, maxColumns: 1000) ?? ""
        }
        func wait(_ label: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(6)
            while !condition(), Date() < deadline { pump(0.02) }
            guard condition() else {
                fputs("FAIL: \(backend) \(label)\n\(lines())\n", stderr)
                throw NSError(domain: label, code: 1)
            }
            print("PASS: \(backend) \(label)")
        }
        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else { view.sendText(text) }
        }
        func key(_ text: String, code: UInt16) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
            )!
            app.inputEvent = event
            defer { app.inputEvent = nil }
            view.keyDown(with: event)
        }
        func state() throws -> [String] {
            try? FileManager.default.removeItem(at: dump)
            control("\u{14}")
            try wait("read shell input", { FileManager.default.fileExists(atPath: dump.path) })
            return try String(contentsOf: dump, encoding: .utf8).components(separatedBy: "\0")
        }

        try wait("shell starts", { session.terminalPromptSelectionIsReady && lines().contains("READY>") })
        key("zfixture ", code: 0)
        try wait("inline completion visible", { lines().contains("zfixture alpha") })
        let suggestion = try state()
        guard suggestion == ["zfixture ", "alpha"] else { throw NSError(domain: "InlineState", code: 1) }
        key("\t", code: 48)
        try wait("completion menu visible", { lines().contains("bravo") })
        key("\u{f703}", code: 124)
        key("\r", code: 36)
        guard try state().first == "zfixture bravo " else { throw NSError(domain: "MenuSelection", code: 1) }
        guard !FileManager.default.fileExists(atPath: sentinel.path) else { throw NSError(domain: "ExecutedCompletion", code: 1) }
        print("PASS: \(backend) keyboard selection does not execute")

        control("\u{15}")
        key("zfixture ", code: 0)
        try wait("suggestion returns", { lines().contains("zfixture alpha") })
        key("\t", code: 48)
        try wait("menu returns", { lines().contains("bravo") })
        key("\u{1b}", code: 53)
        guard try state().first == "zfixture " else { throw NSError(domain: "MenuCancellation", code: 1) }
        print("PASS: \(backend) menu cancellation preserves input")

        control("\u{15}")
        key("/usr/bin/python3 \(quote(tui))", code: 0)
        key("\r", code: 36)
        try wait("full-screen program starts", { lines().contains("TUI_READY") })
        key("\t", code: 48)
        try wait("full-screen program receives Tab", { FileManager.default.fileExists(atPath: tuiResult.path) })
        guard try Data(contentsOf: tuiResult) == Data([9]) else { throw NSError(domain: "TUIInput", code: 1) }
    }
}
