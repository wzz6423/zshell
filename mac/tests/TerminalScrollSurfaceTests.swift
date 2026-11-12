import AppKit
import GhosttyTerminal
@testable import zshell

@MainActor
private final class ScrollWindow: NSWindow {
    var pointer = NSPoint(x: 80, y: 150)
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

// NSEvent has no constructor for subpixel, NaN, or infinite scroll deltas.
private final class FractionalScrollEvent: NSEvent {
    var x: Double = 0
    var y: Double = 0
    var precise = false
    var momentum: NSEvent.Phase = []
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var locationInWindow: NSPoint { NSPoint(x: 80, y: 150) }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

@main
@MainActor
struct TerminalScrollSurfaceTests {
    private static var checks = 0
    private static func pump(_ duration: TimeInterval = 0.06) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "TerminalScroll", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
        print("PASS \(message)")
    }

    private static func wait(_ message: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(8)
        while !condition(), Date() < end { pump(0.02) }
        try check(condition(), message)
    }

    private static func event(x: Double = 0, y: Double, precise: Bool, momentum: NSEvent.Phase = []) -> NSEvent {
        if x.isFinite, y.isFinite, x.rounded() == x, y.rounded() == y, abs(x) < 100_000, abs(y) < 100_000 {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                             wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
            if precise {
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
            } else {
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y)
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x)
            }
            cg.location = CGPoint(x: 80, y: 150)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.contains(.began) ? 1 : momentum.contains(.changed) ? 2 : momentum.contains(.ended) ? 3 : 0)
            let result = NSEvent(cgEvent: cg)!
            precondition(result.scrollingDeltaX == x && result.scrollingDeltaY == y && result.hasPreciseScrollingDeltas == precise)
            return result
        }
        let result = FractionalScrollEvent()
        result.x = x
        result.y = y
        result.precise = precise
        result.momentum = momentum
        return result
    }

    static func main() throws {
        setbuf(stdout, nil)
        let hold = ProcessInfo.processInfo.environment["ZSHELL_SCROLL_TEST_HOLD"] == "1"
        NSApplication.shared.setActivationPolicy(hold ? .regular : .prohibited)
        let backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let python = CommandLine.arguments[3]
        let fixture = CommandLine.arguments[4]
        let directory = root.appendingPathComponent("consumer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.mouseScrollMultiplier = 1
        settings.trackpadScrollMultiplier = 1
        settings.preserveTerminalSessions = false
        settings.copyOnSelect = false
        let session = TerminalSession(initialDirectory: root.path,
            commandArguments: [python, fixture, directory.path], allowsPersistence: false)
        let surface = session.surface
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let window = ScrollWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 640, height: 320),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        let pointer = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 80, y: 150),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        surface.mouseMoved(with: pointer)
        defer {
            session.terminate()
            pump(0.15)
            window.contentView = nil
            window.close()
        }
        func text() -> String { surface.readVisibleText(maxLines: 200, maxColumns: 1000) ?? "" }
        try wait("\(backend) real PTY starts", { FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path) && text().contains("SCROLL_READY") })
        try check(AppSettings.configURL.path.hasPrefix(root.path), "settings remain in the disposable home")
        if hold {
            window.title = "Scroll controls — \(backend)"
            window.setFrameOrigin(NSPoint(x: 60, y: 80))
            window.makeKeyAndOrderFront(nil)
            SettingsWindowController.shared.show(category: .terminal)
            print("HOLD \(backend): HOME=\(root.path), fixture=\(directory.path)")
            NSApp.run()
            return
        }
        if ProcessInfo.processInfo.environment["ZSHELL_SCROLL_TEST_LAYOUT"] == "1" {
            try settingsLayout()
        }

        func command(_ operation: String, _ value: String = "") throws {
            let id = UUID().uuidString
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "operation": operation, "value": value])
            try data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
            try wait("\(backend) fixture \(operation) \(value)", {
                (try? String(contentsOf: directory.appendingPathComponent("ack"), encoding: .utf8)) == id
            })
            pump()
            surface.mouseMoved(with: pointer)
        }
        func firstRow() throws -> Int {
            let rows = text().components(separatedBy: .newlines)
            guard let row = rows.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ROW-") }),
                  let number = Int(row.trimmingCharacters(in: .whitespaces).dropFirst(4)) else {
                throw NSError(domain: "MissingNumberedRow", code: 1, userInfo: [NSLocalizedDescriptionKey: text()])
            }
            return number
        }
        func resetPosition() { surface.scroll(toFraction: 1); pump() }
        func scroll(_ events: [NSEvent]) {
            for event in events {
                surface.scrollWheel(with: event)
                // AppKit dispatches successive wheel events across runloop turns.
                pump(0.015)
            }
            pump(0.12)
        }
        func rowsMoved(_ events: [NSEvent]) throws -> Int {
            resetPosition()
            let start = try firstRow()
            scroll(events)
            return start - (try firstRow())
        }
        let cell = try {
            // Ghostty's grid is in pixels. Precise NSEvent deltas are points,
            // so one visible cell is cell size divided by the backing scale.
            // Alacritty's snapshot cellSize is already in points.
            if let ghostty = surface as? ZshellTerminalView, let grid = ghostty.viewportGridMetrics {
                let scale = Double(window.backingScaleFactor)
                let resolved = scale.isFinite && scale > 0 ? scale : 1
                return CGSize(width: Double(grid.cellWidthPixels) / resolved,
                              height: Double(grid.cellHeightPixels) / resolved)
            }
            guard let snapshot = surface.readVisibleSnapshot() else { throw NSError(domain: "MissingGrid", code: 1) }
            return snapshot.cellSize
        }()
        let wheelRows = backend == "ghostty" ? 3 : 1
        for factor in [0.1, 0.5, 1.0, 2.0, 10.0] {
            settings.mouseScrollMultiplier = factor
            settings.trackpadScrollMultiplier = 1
            pump()
            let moved = try rowsMoved(Array(repeating: event(y: 1, precise: false), count: 10))
            try check(moved == Int((Double(10 * wheelRows) * factor).rounded()), "\(backend) wheel \(factor) moves \(moved) rows")
            try check(try rowsMoved([event(y: cell.height * 2, precise: true)]) == 2,
                      "\(backend) mouse value leaves trackpad independent")
            settings.mouseScrollMultiplier = 1
            settings.trackpadScrollMultiplier = factor
            pump()
            let pixels = Array(repeating: event(y: cell.height, precise: true), count: 10)
            let preciseMoved = try rowsMoved(pixels)
            try check(preciseMoved == Int((10 * factor).rounded()), "\(backend) trackpad \(factor) moves \(preciseMoved) rows")
            try check(try rowsMoved([event(y: 1, precise: false)]) == wheelRows,
                      "\(backend) trackpad value leaves wheel independent")
        }
        settings.mouseScrollMultiplier = 1
        settings.trackpadScrollMultiplier = 1
        pump()
        try check(try rowsMoved([event(x: 2, y: 0, precise: false)]) == 0, "\(backend) horizontal wheel never scrolls vertically")
        try check(try rowsMoved([event(x: cell.width * 3, y: 0, precise: true)]) == 0, "\(backend) horizontal trackpad never scrolls vertically")
        let fractional = [0.35, 0.25, 0.6, 0.8].map { event(y: cell.height * $0, precise: true) }
        try check(try rowsMoved(fractional) == 2, "\(backend) precise fractional rows survive whole-row crossings")
        let momentum = [event(y: cell.height, precise: true, momentum: .began),
                        event(y: cell.height * 2, precise: true, momentum: .changed),
                        event(y: 0, precise: true, momentum: .ended)]
        try check(try rowsMoved(momentum) == 3, "\(backend) real momentum events keep their distance")
        settings.mouseScrollMultiplier = 0.5
        settings.trackpadScrollMultiplier = 0.5
        pump()
        let halfMomentum = [event(y: cell.height, precise: true, momentum: .began),
                            event(y: 0, precise: true, momentum: .ended),
                            event(y: cell.height, precise: true, momentum: .began)]
        try check(try rowsMoved(halfMomentum) == 1, "\(backend) fractional momentum remainder survives zero phase events")
        settings.mouseScrollMultiplier = 1
        settings.trackpadScrollMultiplier = 1
        pump()

        resetPosition()
        let configuration = settings.serializedConfig()
            .replacingOccurrences(of: "terminal.mouse-scroll-multiplier = 1\n", with: "")
            .replacingOccurrences(of: "terminal.trackpad-scroll-multiplier = 1\n", with: "")
            + "terminal.mouse-scroll-multiplier = 2\nterminal.trackpad-scroll-multiplier = 0.5\n"
        try configuration.write(to: AppSettings.configURL, atomically: true, encoding: .utf8)
        try wait("\(backend) external config reaches open surface", {
            settings.mouseScrollMultiplier == 2 && settings.trackpadScrollMultiplier == 0.5
        })
        pump()
        try check(try rowsMoved([event(y: 1, precise: false)]) == wheelRows * 2,
                  "\(backend) reloaded wheel speed applies without recreating the PTY")
        try check(try rowsMoved([event(y: cell.height * 2, precise: true)]) == 1,
                  "\(backend) reloaded trackpad speed applies to the same surface")
        settings.mouseScrollMultiplier = 1
        settings.trackpadScrollMultiplier = 1
        pump()

        if let ghostty = surface as? ZshellTerminalView {
            try nativeDefaultComparison(ghostty: ghostty, python: python, fixture: fixture,
                                        root: root, actual: rowsMoved)
        }
        var selectionDistances: [Int] = []
        for factor in [0.1, 10.0] {
            settings.mouseScrollMultiplier = factor
            settings.trackpadScrollMultiplier = factor
            pump()
            resetPosition()
            let start = try firstRow()
            window.pointer = NSPoint(x: 80, y: 200)
            surface.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: window.pointer,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            window.pointer = NSPoint(x: 80, y: surface.bounds.height + 10)
            surface.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: window.pointer,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            pump(0.2)
            surface.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: window.pointer,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
            let moved = start - (try firstRow())
            selectionDistances.append(moved)
            try check(moved >= 3, "\(backend) selection autoscroll stays active at \(factor): \(moved) rows")
        }
        try check(abs(selectionDistances[0] - selectionDistances[1]) <= 3,
                  "\(backend) selection autoscroll keeps its speed across device multipliers: \(selectionDistances)")
        func input() throws -> Data { try Data(contentsOf: directory.appendingPathComponent("input")) }
        func reports(_ data: Data) -> [Int] {
            let text = String(decoding: data, as: UTF8.self)
            return text.components(separatedBy: "\u{1b}[<").dropFirst().compactMap {
                $0.split(separator: ";").first.flatMap { Int($0) }
            }
        }
        for mode in ["alternate", "application", "mouse", "legacy"] {
            try command("mode", mode)
            for factor in [0.1, 1.0, 10.0] {
                settings.mouseScrollMultiplier = factor
                settings.trackpadScrollMultiplier = 1
                pump()
                try command("clear")
                scroll(Array(repeating: event(y: 1, precise: false), count: 10))
                let bytes = try input()
                let count = Int((Double(10 * wheelRows) * factor).rounded())
                if mode == "mouse" {
                    try check(reports(bytes) == Array(repeating: 64, count: count), "\(backend) SGR wheel \(factor) delivers \(count) up reports")
                } else if mode == "legacy" {
                    try check(bytes.count == count * 6 && stride(from: 0, to: bytes.count, by: 6).allSatisfy { bytes[$0 + 2] == 77 && bytes[$0 + 3] == 96 },
                              "\(backend) legacy wheel \(factor) delivers \(count) reports")
                } else {
                    let sequence = mode == "application" ? "\u{1b}OA" : "\u{1b}[A"
                    try check(bytes == Data(String(repeating: sequence, count: count).utf8), "\(backend) \(mode) wheel \(factor) delivers \(count) cursor keys")
                }
                settings.mouseScrollMultiplier = 1
                settings.trackpadScrollMultiplier = factor
                pump()
                try command("clear")
                scroll(Array(repeating: event(y: cell.height, precise: true), count: 10))
                let trackpad = try input()
                let trackpadCount = Int((10 * factor).rounded())
                if mode == "mouse" {
                    try check(reports(trackpad) == Array(repeating: 64, count: trackpadCount), "\(backend) SGR trackpad \(factor) delivers \(trackpadCount) reports")
                } else if mode == "legacy" {
                    try check(trackpad.count == trackpadCount * 6, "\(backend) legacy trackpad \(factor) delivers \(trackpadCount) reports")
                } else {
                    let sequence = mode == "application" ? "\u{1b}OA" : "\u{1b}[A"
                    try check(trackpad == Data(String(repeating: sequence, count: trackpadCount).utf8), "\(backend) \(mode) trackpad \(factor) delivers \(trackpadCount) cursor keys")
                }
            }
        }
        try command("mode", "mouse")
        for factor in [0.1, 1.0, 10.0] {
            settings.mouseScrollMultiplier = factor
            settings.trackpadScrollMultiplier = factor
            pump()
            try command("clear")
            scroll(Array(repeating: event(x: 1, y: 0, precise: false), count: 10))
            try check(reports(try input()) == Array(repeating: 66, count: Int((10 * factor).rounded())), "\(backend) horizontal wheel \(factor) stays on horizontal protocol")
            try command("clear")
            scroll(Array(repeating: event(x: -cell.width, y: 0, precise: true), count: 10))
            let horizontal = reports(try input())
            try check(horizontal == Array(repeating: 67, count: Int((10 * factor).rounded())), "\(backend) horizontal trackpad \(factor) preserves direction: \(horizontal)")
        }
        for factor in [0.1, 1.0, 10.0] {
            settings.mouseScrollMultiplier = factor
            settings.trackpadScrollMultiplier = factor
            pump()
            try command("clear")
            try check(surface.sendApplicationScroll(lines: 2), "\(backend) automation scroll dispatches")
            pump(0.12)
            try check(reports(try input()) == Array(repeating: 64, count: 2 * wheelRows), "\(backend) automation ignores both device multipliers")
        }
        settings.mouseScrollMultiplier = 1
        settings.trackpadScrollMultiplier = 1
        pump()
        try command("clear")
        scroll([event(y: -1, precise: false), event(y: -cell.height, precise: true)])
        try check(reports(try input()) == Array(repeating: 65, count: wheelRows + 1),
                  "\(backend) both devices preserve downward direction")
        settings.mouseScrollMultiplier = 10
        settings.trackpadScrollMultiplier = 10
        pump()
        for precise in [false, true] {
            try command("clear")
            scroll([event(x: .nan, y: .infinity, precise: precise), event(x: -.infinity, y: .nan, precise: precise)])
            try check(try input().isEmpty, "\(backend) nonfinite deltas never reach application protocols")
            try command("clear")
            scroll([event(x: Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude, precise: precise)])
            let values = reports(try input())
            try check(values.count <= 100 && Set(values).isSubset(of: [65, 66]), "\(backend) huge deltas stay bounded without overflowing")
            try command("clear")
            scroll([event(y: 0, precise: precise)])
            try check(try input().isEmpty, "\(backend) bounded bursts leave no whole-row backlog")
        }
        try check(!NSApp.isActive && !window.isVisible, "fixture remains offscreen without taking focus")
        print("TerminalScroll \(backend): \(checks) production checks passed")
    }

    private static func nativeDefaultComparison(ghostty: ZshellTerminalView, python: String, fixture: String,
                                               root: URL, actual: ([NSEvent]) throws -> Int) throws {
        let directory = root.appendingPathComponent("native")
        let args = [python, fixture, directory.path]
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        guard let controller = ghostty.ghosttyController else { throw NSError(domain: "MissingController", code: 1) }
        let configuration = controller.renderedConfig.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("command =") && !$0.hasPrefix("mouse-scroll-multiplier =") }
            .joined(separator: "\n") + "\ncommand = \(args.map(quote).joined(separator: " "))\n"
        let baselineController = TerminalController(configSource: .generated(configuration))
        let baseline = AppTerminalView(frame: ghostty.frame)
        baseline.controller = baselineController
        baseline.configuration = TerminalSurfaceOptions(workingDirectory: root.path,
            envVars: ["HOME": root.path, "CFFIXED_USER_HOME": root.path, "ZDOTDIR": root.path])
        let window = ScrollWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 640, height: 320),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = baseline
        baseline.setSurfaceVisible(true)
        defer { baseline.controller = nil; window.contentView = nil; window.close(); pump() }
        func text() -> String { baseline.readViewportText(maxLines: 100, maxColumns: 1000) ?? "" }
        try wait("native default Ghostty PTY starts", { text().contains("SCROLL_READY") })
        func row() throws -> Int {
            guard let line = text().components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ROW-") }),
                  let row = Int(line.trimmingCharacters(in: .whitespaces).dropFirst(4)) else { throw NSError(domain: "MissingNativeRow", code: 1) }
            return row
        }
        let pixelHeight = Double(baseline.viewportGridMetrics!.cellHeightPixels)
        let scale = Double(ghostty.window?.backingScaleFactor ?? 1)
        let resolved = scale.isFinite && scale > 0 ? scale : 1
        // Stock Ghostty still consumes pixels. Zshell receives the point-cell
        // distance AppKit reports, which the scale conversion turns back into
        // that same pixel distance.
        let pointHeight = pixelHeight / resolved
        let comparisons: [(zshell: [NSEvent], native: [NSEvent])] = [
            (
                [event(y: 1, precise: false), event(y: -1, precise: false), event(y: 2, precise: false)],
                [event(y: 1, precise: false), event(y: -1, precise: false), event(y: 2, precise: false)]
            ),
            (
                [event(y: 0.125, precise: false), event(y: 0.125, precise: false), event(y: 1.5, precise: false)],
                [event(y: 0.125, precise: false), event(y: 0.125, precise: false), event(y: 1.5, precise: false)]
            ),
            (
                [event(y: pointHeight * 0.3, precise: true), event(y: pointHeight * 0.7, precise: true), event(y: pointHeight * 1.5, precise: true)],
                [event(y: pixelHeight * 0.3, precise: true), event(y: pixelHeight * 0.7, precise: true), event(y: pixelHeight * 1.5, precise: true)]
            ),
            (
                [event(y: pointHeight, precise: true, momentum: .began), event(y: pointHeight * 2, precise: true, momentum: .changed), event(y: 0, precise: true, momentum: .ended)],
                [event(y: pixelHeight, precise: true, momentum: .began), event(y: pixelHeight * 2, precise: true, momentum: .changed), event(y: 0, precise: true, momentum: .ended)]
            ),
        ]
        for comparison in comparisons {
            baseline.performBindingAction("scroll_to_bottom")
            pump()
            let start = try row()
            for event in comparison.native { baseline.scrollWheel(with: event) }
            pump(0.12)
            let expected = start - (try row())
            try check(try actual(comparison.zshell) == expected, "default Ghostty matches native event sequence: \(expected) rows")
        }
    }

    private static func settingsLayout() throws {
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let pane = SettingsTerminalPane()
            pane.setCategory(.terminal)
            let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 660, height: 460),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            var rows: [SettingsSliderRow] = []
            func visit(_ view: NSView) {
                if let row = view as? SettingsSliderRow { rows.append(row) }
                for child in view.subviews { visit(child) }
            }
            visit(pane.view)
            let titles = [String(localized: "Mouse wheel"), String(localized: "Trackpad")]
            let targets = rows.filter { row in
                row.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
                    .contains { titles.contains($0.stringValue) }
            }
            try check(targets.count == 2, "\(language) settings exposes both native scrolling rows")
            for title in titles {
                try check(pane.revealSearchResult(title, in: String(localized: "Scrolling")),
                          "\(language) search reveals \(title)")
            }
            for width in [480.0, 660.0, 900.0] {
                window.setContentSize(NSSize(width: width, height: 460))
                for factor in [0.1, 1.0, 10.0] {
                    AppSettings.shared.mouseScrollMultiplier = factor
                    AppSettings.shared.trackpadScrollMultiplier = factor
                    pane.syncFromSettings()
                    pane.view.layoutSubtreeIfNeeded()
                    for row in targets {
                        let controls = row.subviews.flatMap(\.subviews)
                        let slider = controls.compactMap { $0 as? NSSlider }.first!
                        let stepper = controls.compactMap { $0 as? NSStepper }.first!
                        try check(slider.doubleValue == factor && stepper.doubleValue == factor
                                  && slider.accessibilityLabel() != nil && stepper.accessibilityLabel() != nil,
                                  "\(language) \(width) \(factor) native controls and accessibility are synchronized")
                        for label in controls.compactMap({ $0 as? NSTextField }) {
                            let size = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000))
                            try check(label.frame.width + 1 >= size.width && label.frame.height + 1 >= size.height,
                                      "\(language) \(width) \(factor) label fits: \(label.stringValue)")
                        }
                        slider.doubleValue = 0.5
                        try check(slider.sendAction(slider.action!, to: slider.target), "native slider dispatches its setting action")
                        row.setValue(factor)
                    }
                }
            }
            window.contentViewController = nil
            window.close()
        }
        AppLocalization.apply(.english)
        AppSettings.shared.mouseScrollMultiplier = 1
        AppSettings.shared.trackpadScrollMultiplier = 1
        pump()
    }
}
