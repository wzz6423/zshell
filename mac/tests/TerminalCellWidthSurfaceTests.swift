import AppKit
import CoreText
import Metal
@testable import GhosttyTerminal
@testable import zshell

@MainActor
private final class CellWidthApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
}

@MainActor
private final class CellWidthWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class CellWidthEvents: TerminalBackendEvents {
    let terminalPromptSelectionIsReady = false
    let terminalPromptQueueIsReady = false
    var cellSizes: [CGSize] = []
    var findNeedle: String?
    func terminalDidChangeTitle(_ title: String) {}
    func terminalDidChangeWorkingDirectory(_ path: String) {}
    func terminalDidChangeCellSize(_ size: CGSize) { cellSizes.append(size) }
    func terminalDidRingBell() {}
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {}
    func terminalDidClose(processAlive: Bool) {}
    func terminalDidRequestDesktopNotification(title: String, body: String) {}
    func terminalDidRequestOpenURL(_ url: String) {}
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? { nil }
    func terminalDidScroll(_ position: TerminalScrollPosition) {}
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) { request.deny() }
    func terminalDidBeginFind(needle: String) { findNeedle = needle }
    func terminalDidEndFind() {}
    func terminalDidUpdateFindTotal(_ total: Int?) {}
    func terminalDidUpdateFindSelected(_ selected: Int?) {}
}

@main
struct TerminalCellWidthSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let app = CellWidthApplication.shared as! CellWidthApplication
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let backend = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let settings = AppSettings.shared
        let featuresEnabled = CommandLine.arguments.contains("--font-features")
        settings.fontFamily = featuresEnabled ? "" : "Menlo"
        if featuresEnabled {
            settings.fontFeatures = "ss01, zero=1"
            settings.fontLigatures = true
        }
        settings.fontSize = 13
        settings.terminalLineHeight = 1
        settings.terminalCellWidth = 1
        settings.copyOnSelect = false
        settings.terminalTextHints = true
        TerminalFont.registerBundledFonts()
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: message, code: 1) }
            checks += 1
            print("PASS \(backend): \(message)")
        }
        func pump(_ duration: TimeInterval = 0.025) {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(6)
            while !condition(), Date() < deadline { pump() }
            try check(condition(), message)
        }
        func json(_ name: String) -> Any? {
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(name + ".json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes)
        }
        func size() -> [String: Int]? { json("size") as? [String: Int] }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let fixture = CommandLine.arguments[2]
        let launch = TerminalLaunch(
            program: "/usr/bin/python3", arguments: [fixture, directory.path],
            commandLine: "/usr/bin/python3 \(quoted(fixture)) \(quoted(directory.path))",
            interactiveShell: nil, workingDirectory: directory.path,
            environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"]
        )
        let view: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        let events = CellWidthEvents()
        view.events = events
        if let ghostty = view as? ZshellTerminalView {
            ghostty.core.onMouseShapeChange = { _ in }
        }
        let window = CellWidthWindow(
            contentRect: QuickTerminalOffscreen.frame(NSRect(x: 0, y: 0, width: 820, height: 420)),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 420)
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        let mode = (view as? ZshellTerminalView)?.hintMode ?? (view as! AlacrittyTerminalView).hintMode
        func control(_ text: String) {
            if let ghostty = view as? ZshellTerminalView {
                ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
            } else { view.sendText(text) }
        }
        defer {
            mode.dismiss(restoringFocus: false)
            control("\u{4}")
            pump(0.1)
            view.setSurfaceVisible(false)
            view.detach()
            window.contentView = nil
            window.close()
        }
        func settled() -> Bool {
            guard let geometry = size(), let generation = geometry["generation"],
                  let snapshot = view.readVisibleSnapshot() else { return false }
            return snapshot.columns == geometry["columns"]
                && snapshot.rows.count == geometry["rows"]
                && snapshot.rows.contains { $0.text.contains("READY_CW_\(generation)") }
        }
        func snapshot() throws -> TerminalViewportSnapshot {
            guard let result = view.readVisibleSnapshot() else { throw NSError(domain: "missing viewport", code: 1) }
            return result
        }
        func pointer(_ type: NSEvent.EventType, snapshot: TerminalViewportSnapshot,
                     row: Int, column: Int, half: CGFloat) -> NSEvent {
            let top = snapshot.origin.y + (CGFloat(row) + 0.5) * snapshot.cellSize.height
            let local = NSPoint(x: snapshot.origin.x + (CGFloat(column) + half) * snapshot.cellSize.width,
                                y: view.isFlipped ? top : view.bounds.height - top)
            return NSEvent.mouseEvent(
                with: type, location: view.convert(local, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func sendPointer(_ event: NSEvent) {
            app.inputEvent = event
            switch event.type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
            app.inputEvent = nil
            pump()
        }
        func verifySelection(_ snapshot: TerminalViewportSnapshot) throws {
            mode.dismiss()
            events.findNeedle = nil
            sendPointer(pointer(.leftMouseDown, snapshot: snapshot, row: 2, column: 0, half: 0.1))
            sendPointer(pointer(.leftMouseDragged, snapshot: snapshot, row: 2, column: 8, half: 0.9))
            sendPointer(pointer(.leftMouseUp, snapshot: snapshot, row: 2, column: 8, half: 0.9))
            try check(view.hasSelection, "adjusted grid pointer drag creates selection")
            view.findSelection()
            try wait("selection resolves the same nine ASCII cells") { events.findNeedle == "SELECT_ME" }
            view.endFind()
        }
        func verifyGeometry(_ snapshot: TerminalViewportSnapshot) throws {
            try check(size()?["columns"] == snapshot.columns && size()?["rows"] == snapshot.rows.count,
                      "real PTY rows and columns match rendered metrics")
            let row = snapshot.rows[0]
            let cjk = (row.text as NSString).range(of: "中")
            let emoji = (row.text as NSString).range(of: "😀")
            try check(row.columns(for: cjk) == 1..<3 && row.columns(for: emoji) == 3..<5,
                      "CJK and emoji retain two columns after spacing changes")
            let combining = (row.text as NSString).range(of: "e\u{301}")
            try check(row.columns(for: combining) == 5..<6, "combining text retains one column")
            guard let client = view as? any NSTextInputClient else { throw NSError(domain: "missing IME client", code: 1) }
            let screenRect = client.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let localRect = view.convert(window.convertFromScreen(screenRect), from: nil)
            // Ghostty returns a zero-width anchor at the cell center; Alacritty returns the cell rect.
            let caretColumn: CGFloat = backend == "ghostty" ? 9.5 : 9
            try check(abs(localRect.minX - (snapshot.origin.x + caretColumn * snapshot.cellSize.width)) < 1,
                      "logical cursor and IME anchor use the adjusted column width")
            try check(abs(localRect.width - (backend == "ghostty" ? 0 : snapshot.cellSize.width)) < 1,
                      "IME caret retains the backend's native geometry")
            try verifySelection(snapshot)
        }

        try wait("raw PTY reaches a settled production surface", settled)
        let native = try snapshot()
        try verifyGeometry(native)
        for multiplier in [0.75, 1.25, 2.0] {
            mode.present(action: .copy)
            try wait("real hint overlay has labels") { !mode.hints.isEmpty }
            let oldSize = size()!
            settings.terminalCellWidth = multiplier
            view.applyAppearance()
            try wait("width change sends SIGWINCH and repaints the same PTY") {
                (size()?["resizeCount"] ?? 0) > oldSize["resizeCount"]! && settled()
            }
            let changed = try snapshot()
            try check(multiplier < 1 ? changed.columns > native.columns : changed.columns < native.columns,
                      "\(Int(multiplier * 100))% changes the real column count")
            try check(changed.cellSize.height == native.cellSize.height, "column spacing preserves row height")
            try check(events.cellSizes.last == changed.cellSize, "session cell-size event uses rendered metrics")
            try wait("active keyboard hints follow the new geometry") {
                mode.snapshot?.cellSize == changed.cellSize && mode.snapshot?.columns == changed.columns && !mode.hints.isEmpty
            }
            guard let hint = mode.hints.first(where: { $0.value == "https://example.com/width" }),
                  let fragment = hint.fragments.first else { throw NSError(domain: "missing URL hint", code: 1) }
            let rect = changed.rect(row: fragment.row, columns: fragment.columns)
            try check(rect.minX == changed.origin.x + 7 * changed.cellSize.width,
                      "hint rectangle shares the Unicode grid's adjusted coordinates")
            try verifyGeometry(changed)
        }
        settings.terminalCellWidth = 1
        view.applyAppearance()
        try wait("restoring 100% restores native column count and glyph metrics") {
            settled() && view.readVisibleSnapshot()?.cellSize == native.cellSize
                && view.readVisibleSnapshot()?.columns == native.columns
        }
        settings.fontSize = 19
        settings.terminalCellWidth = 1.5
        view.applyAppearance()
        try wait("font zoom and column spacing resize the existing PTY", settled)
        let zoomed = try snapshot()
        try check(zoomed.cellSize.width > native.cellSize.width && zoomed.cellSize.height > native.cellSize.height,
                  "font zoom composes with column spacing")
        try verifyGeometry(zoomed)
        control("m")
        try wait("raw fixture enables SGR mouse reporting") {
            settled() && view.readVisibleSnapshot()?.rows.contains { $0.text.contains("MOUSE_ON") } == true
        }
        let mouseGrid = try snapshot()
        sendPointer(pointer(.leftMouseDown, snapshot: mouseGrid, row: 2, column: 4, half: 0.25))
        sendPointer(pointer(.leftMouseUp, snapshot: mouseGrid, row: 2, column: 4, half: 0.25))
        try wait("terminal mouse reports use adjusted grid columns") {
            guard let reports = json("mouse") as? [[Any]] else { return false }
            return reports.contains { ($0[0] as? Int) == 0 && ($0[1] as? Int) == 5 && ($0[2] as? Int) == 3 }
        }
        control("n")
        try wait("raw fixture releases mouse reporting", settled)

        if backend == "alacritty" {
            guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Metal unavailable", code: 1) }
            func metrics(_ width: CGFloat) -> AlacrittyMetrics {
                AlacrittyMetrics(family: "Menlo", fallbackFamily: "PingFang SC", size: 13,
                                 fontThicken: false, fontThickenStrength: 255, lineHeight: 1, cellWidth: width)
            }
            let base = metrics(1)
            let expanded = metrics(2)
            try check(base.regular == expanded.regular && base.bold == expanded.bold
                      && base.italic == expanded.italic && base.boldItalic == expanded.boldItalic,
                      "column spacing preserves all font faces and fallback descriptors")
            for scale: CGFloat in [1, 2] {
                guard let atlas = TerminalGlyphAtlas(device: device, metrics: base, scale: scale) else {
                    throw NSError(domain: "glyph atlas unavailable", code: 1)
                }
                let key = TerminalGlyphAtlas.Key(content: .scalar(0x4E2D), bold: false, italic: false)
                guard let original = atlas.entry(for: key) else { throw NSError(domain: "missing CJK fallback glyph", code: 1) }
                let generation = atlas.generation
                try check(atlas.reset(metrics: expanded, scale: scale) && atlas.generation > generation,
                          "\(Int(scale))x glyph atlas invalidates changed cell geometry")
                guard let changed = atlas.entry(for: key) else { throw NSError(domain: "missing reset CJK glyph", code: 1) }
                try check(original.size == changed.size && original.bearing == changed.bearing,
                          "\(Int(scale))x glyph pixels retain font size and fallback after spacing change")
            }
        }
        try check(QuickTerminalOffscreen.isSafe(), "production probes stay hidden and preserve desktop focus")
        print("Cell width \(backend): \(checks) assertions passed")
    }
}
