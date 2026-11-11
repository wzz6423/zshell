import AppKit
import Foundation
import IOSurface
@testable import GhosttyTerminal
@testable import zshell

@MainActor
final class PaddingApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
}

@MainActor
private final class PaddingWindow: NSWindow {
    var fixtureKey = true
    override var isKeyWindow: Bool { fixtureKey }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct PaddingPixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    func at(_ point: CGPoint, in size: CGSize) -> [UInt8] {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width) / size.width)))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height) / size.height)))
        let offset = y * bytesPerRow + x * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    func png(to url: URL) throws {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Could not encode terminal pixels", code: 1)
        }
        try data.write(to: url)
    }

    init(compositing layer: CALayer, size: CGSize, scale: CGFloat, colorSpace: CGColorSpace) throws {
        width = Int((size.width * scale).rounded())
        height = Int((size.height * scale).rounded())
        bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let data = context.data else { throw NSError(domain: "Missing compositor", code: 1) }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        bytes = Data(bytes: data, count: bytesPerRow * height)
    }
}

@main
@MainActor
struct TerminalPaddingColorSurfaceTests {
    private static var checks = 0

    static func main() {
        do {
            if CommandLine.arguments.last == "quick-terminal" { try QuickTerminalPaddingColorTests.run() }
            else { try run() }
        }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        let app = PaddingApplication.shared as! PaddingApplication
        app.setActivationPolicy(.prohibited)
        let backend = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard ["/tmp/zshell-padding-probe-", "/private/tmp/zshell-padding-probe-"]
            .contains(where: FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix) else {
            throw NSError(domain: "Disposable HOME is required", code: 1)
        }
        let evidence = CommandLine.arguments[4].isEmpty ? nil
            : URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        let settings = AppSettings.shared
        settings.language = .english
        settings.fontFamily = "Menlo"
        settings.fontSize = 13
        settings.terminalLineHeight = 1
        settings.cursorBlinking = false
        settings.copyOnSelect = false
        settings.terminalPaddingColor = .background
        settings.terminalBackgroundBlur = false
        settings.terminalBackgroundOpacity = 1
        TerminalFont.registerBundledFonts()
        let fixture = CommandLine.arguments[2]
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.preserveTerminalSessions = false
        let manager = TerminalManager()
        for project in manager.projects { manager.close(project) }
        manager.newSession(directory: directory.path, commandArguments: ["/usr/bin/python3", fixture, directory.path])
        guard let session = manager.selectedProject?.selectedSession else {
            throw NSError(domain: "Manager fixture session missing", code: 1)
        }
        let view = session.surface
        if let ghostty = view as? ZshellTerminalView { ghostty.core.onMouseShapeChange = { _ in } }
        let window = PaddingWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 820, height: 420),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 420)
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        defer {
            send("\u{4}", to: view)
            pump(0.1)
            view.setSurfaceVisible(false)
            view.detach()
            for project in manager.projects { manager.close(project) }
            window.contentView = nil
            window.close()
        }
        func state() -> [String: Any]? {
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("frame.json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        func settled() -> Bool {
            guard let state = state(), let generation = state["generation"] as? Int,
                  let grid = view.readVisibleSnapshot() else { return false }
            return session.title == "PADDING_READY_\(generation)"
                && grid.columns == state["columns"] as? Int && grid.rows.count == state["rows"] as? Int
        }
        func draw(_ command: String) throws {
            let previous = state()?["generation"] as? Int ?? 0
            send(command, to: view)
            try wait("PTY fixture presents \(command)") {
                (state()?["generation"] as? Int ?? 0) > previous && settled()
            }
        }
        func pixels(refresh: Bool = true) throws -> PaddingPixels {
            if refresh, let ghostty = view as? ZshellTerminalView {
                ghostty.surface?.draw()
                ghostty.didRender()
                pump(0.03)
            } else if refresh {
                // Re-freeze the latest drawable without reapplying settings,
                // so these pixels also prove the manager publisher updated it.
                window.fixtureKey = true
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                pump(0.03)
                window.fixtureKey = false
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                pump(0.03)
            }
            guard let layer = view.layer,
                  let contents = layer.presentation()?.contents ?? layer.contents else {
                throw NSError(domain: "\(backend) has no retained terminal image", code: 1)
            }
            guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
                throw NSError(domain: "\(backend) did not render an IOSurface", code: 1)
            }
            return try PaddingPixels(compositing: layer, size: view.bounds.size,
                                     scale: window.backingScaleFactor,
                                     colorSpace: CGColorSpace(name: backend == "ghostty" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!)
        }
        func grid() throws -> TerminalViewportSnapshot {
            guard let result = view.readVisibleSnapshot() else { throw NSError(domain: "Missing viewport", code: 1) }
            return result
        }
        func sample(_ pixels: PaddingPixels, _ point: CGPoint) -> [UInt8] { pixels.at(point, in: view.bounds.size) }
        func edgePoints(_ grid: TerminalViewportSnapshot) -> [(CGPoint, CGPoint)] {
            let width = view.bounds.width, height = view.bounds.height
            let left = grid.origin.x + grid.cellSize.width / 2
            let right = grid.origin.x + (CGFloat(grid.columns) - 0.5) * grid.cellSize.width
            let top = grid.origin.y + grid.cellSize.height / 2
            let bottom = grid.origin.y + (CGFloat(grid.rows.count) - 0.5) * grid.cellSize.height
            let middle = grid.origin.y + 1.5 * grid.cellSize.height
            return [
                (CGPoint(x: 2, y: middle), CGPoint(x: left, y: middle)),
                (CGPoint(x: width - 2, y: middle), CGPoint(x: right, y: middle)),
                (CGPoint(x: left, y: 2), CGPoint(x: left, y: top)),
                (CGPoint(x: right, y: 2), CGPoint(x: right, y: top)),
                (CGPoint(x: left, y: height - 2), CGPoint(x: left, y: bottom)),
                (CGPoint(x: right, y: height - 2), CGPoint(x: right, y: bottom)),
                (CGPoint(x: 2, y: 2), CGPoint(x: left, y: top)),
                (CGPoint(x: width - 2, y: 2), CGPoint(x: right, y: top)),
                (CGPoint(x: 2, y: height - 2), CGPoint(x: left, y: bottom)),
                (CGPoint(x: width - 2, y: height - 2), CGPoint(x: right, y: bottom)),
            ]
        }
        func verify(_ mode: TerminalPaddingColor, automaticVertical: Bool, name: String,
                    applyManually: Bool = true) throws {
            settings.terminalPaddingColor = mode
            if applyManually { view.applyAppearance() }
            pump(0.05)
            let current = try grid()
            let image = try pixels(refresh: applyManually)
            if let evidence {
                try image.png(to: evidence.appendingPathComponent("\(backend)-\(name)-\(mode.rawValue).png"))
            }
            print("DIAGNOSTIC \(backend) \(name) \(mode.rawValue) grid=\(current.columns)x\(current.rows.count) origin=\(current.origin) cell=\(current.cellSize) image=\(image.width)x\(image.height)")
            let plain = sample(image, CGPoint(x: current.origin.x + 4.5 * current.cellSize.width,
                                              y: current.origin.y + 1.5 * current.cellSize.height))
            for (index, pair) in edgePoints(current).enumerated() {
                let extends = mode == .always || (mode == .extend && (index < 2 || automaticVertical))
                let expected = extends ? sample(image, pair.1) : plain
                let actual = sample(image, pair.0)
                try check(close(actual, expected), "\(backend) \(name) \(mode.rawValue) edge \(index) = \(actual), expected \(expected)")
            }
        }
        try wait("\(backend) production PTY and grid settle", settled)
        _ = try pixels()
        let fixturePID = state()?["pid"] as? Int
        let identity = ObjectIdentifier(view)
        for mode in [.always, .background, .extend, .background, .always] as [TerminalPaddingColor] {
            try verify(mode, automaticVertical: true, name: "manager-live", applyManually: false)
            try check(ObjectIdentifier(session.surface) == identity && state()?["pid"] as? Int == fixturePID,
                      "\(backend) settings publisher preserves surface and PTY identity")
        }
        for mode in [.background, .extend, .always, .background, .always, .extend] as [TerminalPaddingColor] {
            settings.terminalPaddingColor = mode
        }
        pump(0.15)
        try verify(.extend, automaticVertical: true, name: "rapid-final", applyManually: false)
        try check(session.surface.foregroundPid != nil && state()?["pid"] as? Int == fixturePID,
                  "\(backend) rapid settings changes keep fixture alive")
        for mode in TerminalPaddingColor.allCases { try verify(mode, automaticVertical: true, name: "solid") }
        for (command, name, extends) in [
            ("m", "mixed", false), ("b", "blank", true), ("p", "powerline", false),
            ("o", "prompt", false), ("c", "continuation", true), ("i", "input-continuation", true),
            ("f", "fish-output", true), ("a", "alternate", true), ("v", "inverse", true),
        ] {
            try draw(command)
            // Continuation marks only the bottom row; top remains a normal colored row.
            if command == "c" || command == "i" || command == "a" {
                try verify(.background, automaticVertical: false, name: name)
                try verify(.always, automaticVertical: true, name: name)
                settings.terminalPaddingColor = .extend
                view.applyAppearance()
                let current = try grid(), image = try pixels()
                let pairs = edgePoints(current)
                let plain = sample(image, CGPoint(x: current.origin.x + 4.5 * current.cellSize.width,
                                                  y: current.origin.y + 1.5 * current.cellSize.height))
                for (index, pair) in pairs.enumerated() {
                    let blocked = command == "a" ? [2, 3, 6, 7].contains(index) : [4, 5, 8, 9].contains(index)
                    let expected = blocked ? plain : sample(image, pair.1)
                    try check(close(sample(image, pair.0), expected), "\(backend) \(name) automatic edge \(index)")
                }
            } else {
                for mode in TerminalPaddingColor.allCases { try verify(mode, automaticVertical: extends, name: name) }
            }
        }
        try draw("d")
        settings.terminalPaddingColor = .always
        view.setBackgroundOpacity(0.5)
        view.applyAppearance()
        let transparent = try pixels(), geometry = try grid()
        let untouched = sample(transparent, CGPoint(x: 2, y: 2))
        print("DIAGNOSTIC \(backend) translucent padding=\(untouched) layerBackground=\(String(describing: view.layer?.backgroundColor))")
        try check(abs(Int(untouched[3]) - 128) <= 2, "\(backend) default padding alpha remains 0.5")
        try draw("s")
        let opaque = try pixels()
        try check(sample(opaque, CGPoint(x: 2, y: 2))[3] == 255, "\(backend) explicit edge background stays opaque")
        let themeCell = sample(opaque, CGPoint(x: geometry.origin.x + 4.5 * geometry.cellSize.width,
                                             y: geometry.origin.y + 1.5 * geometry.cellSize.height))
        try check(abs(Int(themeCell[3]) - 128) <= 2, "\(backend) untouched cell exposes one transparent clear")
        try draw("v")
        let inverse = try pixels()
        try check(sample(inverse, CGPoint(x: 2, y: 2))[3] == 255, "\(backend) inverse edge background stays opaque")
        settings.terminalPaddingColor = .background
        view.applyAppearance()
        pump(0.15)
        view.setBackgroundOpacity(0.5)
        let backgroundAlpha = try pixels()
        print("DIAGNOSTIC \(backend) background padding=\(sample(backgroundAlpha, CGPoint(x: 2, y: 2)))")
        try check(abs(Int(sample(backgroundAlpha, CGPoint(x: 2, y: 2))[3]) - 128) <= 2,
                  "\(backend) background policy composites alpha only once")

        try draw("s")
        view.setBackgroundOpacity(1)
        view.applyAppearance()
        pump(0.15)
        for (size, width) in [
            (CGSize(width: 823.5, height: 423.5), 1.0),
            (CGSize(width: 807, height: 431), 1.0),
            (CGSize(width: 823.5, height: 423.5), 0.75),
            (CGSize(width: 807, height: 431), 1.5),
        ] {
            settings.terminalCellWidth = width
            window.setContentSize(size)
            view.setFrameSize(size)
            try wait("\(backend) fractional resize and \(width) cell width update PTY grid", settled)
            settings.terminalPaddingColor = .always
            view.applyAppearance()
            pump(0.15)
            let before = try pixels()
            let metrics = try grid()
            let input = view as! any NSTextInputClient
            let caret = input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            settings.terminalPaddingColor = .background
            view.applyAppearance()
            pump(0.15)
            let after = try pixels()
            try check(input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == caret,
                      "\(backend) padding switch preserves IME/cursor geometry after resize")
            let cellY = metrics.origin.y + 1.5 * metrics.cellSize.height
            for column in [0, 1, metrics.columns - 2, metrics.columns - 1] {
                let point = CGPoint(x: metrics.origin.x + (CGFloat(column) + 0.5) * metrics.cellSize.width, y: cellY)
                try check(close(sample(before, point), sample(after, point)),
                          "\(backend) fractional resize preserves edge cell \(column)")
            }
            try check(!close(sample(before, CGPoint(x: 2, y: cellY)), sample(after, CGPoint(x: 2, y: cellY))),
                      "\(backend) resized background border replaces extension")
        }
        settings.terminalCellWidth = 1
        pump(0.15)
        try wait("\(backend) native width restores after padding geometry checks", settled)

        for theme in ["Dracula", Theme.defaultDarkThemeName] {
            settings.themeDark = theme
            settings.themeLight = theme
            pump(0.2)
            let themed = try pixels()
            let current = try grid()
            let plain = CGPoint(x: current.origin.x + 4.5 * current.cellSize.width,
                                y: current.origin.y + 1.5 * current.cellSize.height)
            print("DIAGNOSTIC \(backend) theme=\(theme) border=\(sample(themed, CGPoint(x: 2, y: 2))) cell=\(sample(themed, plain)) dynamic=\(String(describing: (view as? ZshellTerminalView)?.reportedBackgroundColor))")
            try check(close(sample(themed, CGPoint(x: 2, y: 2)), sample(themed, plain)),
                      "\(backend) background padding follows live theme \(theme)")
        }
        settings.themeLight = Theme.defaultLightThemeName


        if let ghostty = view as? ZshellTerminalView {
            for _ in 0..<3 {
                view.setSurfaceVisible(false)
                pump(0.025)
                view.setSurfaceVisible(true)
                pump(0.15)
                try verify(.background, automaticVertical: false, name: "unpark")
                try check((ghostty.layer?.sublayers?.count ?? 0) <= 4,
                          "Ghostty unpark keeps compositor layers bounded")
            }
            try draw("y")
            let changed = try pixels()
            let current = try grid()
            let middle = CGPoint(x: current.origin.x + 4.5 * current.cellSize.width,
                                 y: current.origin.y + 1.5 * current.cellSize.height)
            try check(close(sample(changed, CGPoint(x: 2, y: 2)), sample(changed, middle)),
                      "Ghostty background padding follows OSC 11 default color")
            try check(ghostty.reportedBackgroundColor != nil, "Ghostty OSC 11 callback reached production helper")
            try draw("z")
            let reset = try pixels()
            try check(ghostty.reportedBackgroundColor != nil && close(sample(reset, CGPoint(x: 2, y: 2)), sample(reset, middle)),
                      "Ghostty OSC 111 padding matches the engine default")
            settings.themeDark = "Dracula"
            settings.themeLight = "Dracula"
            pump(0.2)
            let resetTheme = try pixels()
            try check(close(sample(resetTheme, CGPoint(x: 2, y: 2)), sample(resetTheme, middle)),
                      "Ghostty theme change after OSC 111 keeps padding aligned with resolved background")
            for mode in [.always, .extend, .background] as [TerminalPaddingColor] {
                settings.terminalPaddingColor = mode
                pump(0.15)
            }
            let resetSwitch = try pixels()
            try check(close(sample(resetSwitch, CGPoint(x: 2, y: 2)), sample(resetSwitch, middle)),
                      "Ghostty live padding switches retain OSC 111 resolved color")
            settings.themeDark = Theme.defaultDarkThemeName
            settings.themeLight = Theme.defaultLightThemeName
            pump(0.2)
            let baseline = try pixels()
            ghostty.terminalDidReportProgress(state: .set, percent: 100)
            ghostty.layoutSubtreeIfNeeded()
            pump(0.2)
            let progress = try pixels()
            try check(!close(sample(baseline, CGPoint(x: 20, y: 1)), sample(progress, CGPoint(x: 20, y: 1))),
                      "Ghostty background compositor preserves OSC 9 progress bar")
            ghostty.terminalDidReportProgress(state: .remove, percent: nil)
        } else {
            view.setSurfaceVisible(false)
            view.setSurfaceVisible(true)
            pump(0.15)
            try verify(.background, automaticVertical: false, name: "unpark")
        }

        try draw("s")
        let input = view as! any NSTextInputClient
        input.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(input.hasMarkedText(), "\(backend) production IME preedit starts")
        let markedCaret = input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        for mode in TerminalPaddingColor.allCases {
            settings.terminalPaddingColor = mode
            view.applyAppearance()
            pump(0.1)
            try check(input.hasMarkedText() && input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == markedCaret,
                      "\(backend) \(mode.rawValue) preserves marked text and candidate anchor")
        }
        input.unmarkText()
        try draw("q")
        let selectedGeometry = try grid()
        let selectedPoint = CGPoint(x: selectedGeometry.origin.x + selectedGeometry.cellSize.width * 0.1,
                                    y: selectedGeometry.origin.y + selectedGeometry.cellSize.height * 0.1)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "Missing synthetic mouse event", code: 1)
            }
            return event
        }
        let down = try mouse(.leftMouseDown, at: CGPoint(x: selectedGeometry.origin.x + 0.1,
                                                       y: selectedGeometry.origin.y + 0.1))
        let upPoint = CGPoint(x: selectedGeometry.origin.x + selectedGeometry.cellSize.width * 4.9,
                              y: selectedGeometry.origin.y + selectedGeometry.cellSize.height * 0.5)
        let drag = try mouse(.leftMouseDragged, at: upPoint), up = try mouse(.leftMouseUp, at: upPoint)
        app.inputEvent = down
        view.mouseDown(with: down)
        app.inputEvent = drag
        view.mouseDragged(with: drag)
        app.inputEvent = up
        view.mouseUp(with: up)
        app.inputEvent = nil
        try wait("\(backend) mouse selects original edge cells") { view.hasSelection }
        if let ghostty = view as? ZshellTerminalView {
            try check(ghostty.selectedText?.contains("SELEC") == true,
                      "Ghostty mouse selection matches original grid coordinates")
        }
        for mode in TerminalPaddingColor.allCases {
            settings.terminalPaddingColor = mode
            view.applyAppearance()
            pump(0.1)
            view.setBackgroundOpacity(0.5)
            let selected = try pixels()
            try check(view.hasSelection && sample(selected, selectedPoint)[3] == 255,
                      "\(backend) \(mode.rawValue) preserves opaque selection")
            let border = sample(selected, CGPoint(x: 2, y: 2))
            try check(mode == .background ? abs(Int(border[3]) - 128) <= 2 : border[3] == 255,
                      "\(backend) \(mode.rawValue) selection padding follows policy")
        }
        try verifySettingsLayout(settings, backend: backend, evidence: evidence)
        try verifyEditor(directory: directory, backend: backend)
        try check(!NSApp.isActive && !window.isVisible && window.frame.maxX < 0 && window.frame.maxY < 0,
                  "\(backend) all acceptance windows remain hidden and offscreen")
        print("Padding color surface tests passed: \(backend), \(checks) checks (production dylib, PTY, IOSurface, settings)")
    }

    private static func verifyEditor(directory: URL, backend: String) throws {
        let url = directory.appendingPathComponent("padding-editor.swift")
        try "let padding = \"background\"\n".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path)
        try wait("\(backend) editor fixture loads") { !file.text.isEmpty }
        let editor = SourceEditorController(file: file, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                            palette: .theme(dark: true), wrapLines: true, isFocused: false,
                                            onFocused: {}, onSplit: { _ in })
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = editor.scrollView
        editor.scrollView.layoutSubtreeIfNeeded()
        pump(0.2)
        try check(SyntaxHighlighting.plugin(for: url.path) != nil && editor.scrollView.documentView?.window === window,
                  "\(backend) production source editor mounts with Neon assets and grammar")
    }

    private static func verifySettingsLayout(_ settings: AppSettings, backend: String, evidence: URL?) throws {
        for language in AppLanguage.allCases where language != .system {
            settings.language = language
            let pane = SettingsAppearancePane()
            pane.setCategory(.appearance)
            let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 600, height: 660),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            defer { window.contentViewController = nil; window.close() }
            pane.view.frame = NSRect(x: 0, y: 0, width: 600, height: 660)
            pane.view.layoutSubtreeIfNeeded()
            guard let popup = descendants(pane.view).compactMap({ $0 as? SettingsPopUpButton<TerminalPaddingColor> }).first else {
                throw NSError(domain: "Padding popup missing in \(language.rawValue)", code: 1)
            }
            try check(popup.itemTitles == TerminalPaddingColor.allCases.map(\.title), "\(backend) \(language.rawValue) popup titles use current translations")
            for (index, mode) in TerminalPaddingColor.allCases.enumerated() {
                popup.selectItem(at: index)
                _ = popup.sendAction(popup.action, to: popup.target)
                try check(settings.terminalPaddingColor == mode, "\(backend) \(language.rawValue) native popup selects \(mode.rawValue)")
            }
            var ancestor: NSView? = popup
            while ancestor != nil && !(ancestor is SettingsRow) { ancestor = ancestor?.superview }
            guard let row = ancestor else { throw NSError(domain: "Padding row missing", code: 1) }
            row.layoutSubtreeIfNeeded()
            let controls = descendants(row)
            let icons = controls.compactMap { $0 as? SettingsIconView }
            try check(icons.count == 1 && abs(icons[0].bounds.width - icons[0].bounds.height) < 0.5,
                      "\(backend) \(language.rawValue) padding icon is one system-colored square")
            for label in controls.compactMap({ $0 as? NSTextField }) {
                let frame = label.convert(label.bounds, to: row)
                let control = popup.convert(popup.bounds, to: row)
                try check(frame.width > 30 && frame.height > 10 && !frame.intersects(control),
                          "\(backend) \(language.rawValue) wrapping label stays clear of popup")
            }
            try check(pane.revealSearchResult(String(localized: "Padding color"), in: String(localized: "Background")),
                      "\(backend) \(language.rawValue) settings search reveals padding row")
            if let evidence, [AppLanguage.english, .simplifiedChinese, .german, .arabic].contains(language),
               let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
                row.cacheDisplay(in: row.bounds, to: bitmap)
                if let bytes = bitmap.representation(using: .png, properties: [:]) {
                    try bytes.write(to: evidence.appendingPathComponent("\(backend)-settings-\(language.rawValue).png"))
                }
            }
        }
        settings.language = .english
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func close(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
    }
    private static func send(_ text: String, to view: any TerminalBackendSurface) {
        if let ghostty = view as? ZshellTerminalView {
            ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { view.sendText(text) }
    }
    private static func pump(_ duration: TimeInterval = 0.025) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { pump() }
        try check(condition(), message)
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: message, code: 1) }
        checks += 1
        print("PASS: \(message)")
    }
}
