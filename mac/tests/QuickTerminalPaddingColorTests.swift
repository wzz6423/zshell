import AppKit
import Carbon.HIToolbox
import Darwin
import IOSurface
@testable import GhosttyTerminal
@testable import zshell

@MainActor
enum QuickTerminalPaddingColorTests {
    private final class WorkspaceLifetime {
        weak var view: QuickTerminalWorkspaceView?
    }

    private static var checks = 0

    static func run() throws {
        setbuf(stdout, nil)
        let visible = ProcessInfo.processInfo.environment["ZSHELL_PADDING_TEST_VISIBLE"] == "1"
        if !visible { QuickTerminalOffscreen.install() }
        let app = PaddingApplication.shared as! PaddingApplication
        app.setActivationPolicy(visible ? .accessory : .prohibited)
        if visible { app.activate() }
        let backend = CommandLine.arguments[1]
        let fixture = CommandLine.arguments[2]
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
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.preserveTerminalSessions = false
        settings.copyOnSelect = false
        settings.cursorBlinking = false
        settings.fontFamily = "Menlo"
        settings.fontSize = 13
        settings.terminalLineHeight = 1
        settings.terminalBackgroundOpacity = 1
        settings.terminalBackgroundBlur = false
        settings.quickTerminalOpacity = 0.5
        settings.quickTerminalEnabled = true
        settings.quickTerminalShortcut = QuickTerminalShortcut(
            keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | optionKey | shiftKey)
        )
        settings.terminalStartupProgram = "/usr/bin/python3"
        settings.terminalStartupArguments = [fixture, directory.path, "--per-process"]
            .map(TerminalSession.shellQuote).joined(separator: " ")
        TerminalFont.registerBundledFonts()
        let overlay = GlobalTerminalOverlay.shared
        overlay.start()
        defer { overlay.stop(); pump(0.2) }

        func quickWindow() -> NSWindow? {
            app.windows.first { $0.isVisible && String(describing: type(of: $0)) == "GlobalTerminalOverlayWindow" }
        }
        func state(_ session: TerminalSession) -> [String: Any]? {
            guard let pid = session.shellPid,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid)/frame.json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func settled(_ session: TerminalSession) -> Bool {
            guard let state = state(session), let generation = state["generation"] as? Int,
                  let grid = session.surface.readVisibleSnapshot() else { return false }
            return session.title == "PADDING_READY_\(generation)"
                && grid.columns == state["columns"] as? Int && grid.rows.count == state["rows"] as? Int
        }
        func draw(_ command: String, in sessions: [TerminalSession]) throws {
            let generations = sessions.map { state($0)?["generation"] as? Int ?? 0 }
            for session in sessions { send(command, to: session.surface) }
            try wait("\(backend) Quick Terminal fixture draws \(command)") {
                zip(sessions, generations).allSatisfy { session, generation in
                    (state(session)?["generation"] as? Int ?? 0) > generation && settled(session)
                }
            }
            pump(0.08)
        }
        func pin(_ window: NSWindow) throws {
            guard let content = window.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                      $0.action.map(NSStringFromSelector) == "pinPressed"
                  }) else { throw NSError(domain: "Native pin control missing", code: 1) }
            if button.toolTip == "Pin quick terminal" { button.performClick(nil) }
            try check(button.toolTip == "Unpin quick terminal", "\(backend) native Quick Terminal pin control applies")
            window.delegate?.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: window))
            pump(0.05)
            try check(window.isVisible, "\(backend) pinned Quick Terminal remains visible after focus loss")
        }
        func splitWorkspace() throws -> (NSWindow, PaneTab) {
            guard let window = quickWindow() else { throw NSError(domain: "Quick Terminal window missing", code: 1) }
            try pin(window)
            overlay.split(toward: .right)
            pump(0.08)
            overlay.split(toward: .bottom)
            window.setContentSize(CGSize(width: 903.5, height: 533.5))
            window.contentView?.layoutSubtreeIfNeeded()
            pump(0.15)
            guard let tab = overlay.workspace, tab.sessions.count == 3 else {
                throw NSError(domain: "Three production Quick Terminal panes required", code: 1)
            }
            for session in tab.sessions {
                (session.surface as? ZshellTerminalView)?.core.onMouseShapeChange = { _ in }
            }
            try wait("\(backend) three Quick Terminal PTYs and grids settle") { tab.sessions.allSatisfy(settled) }
            return (window, tab)
        }
        func verifyPolicies(_ tab: PaneTab, stage: String, automaticVertical: Bool) throws {
            let sessions = tab.sessions
            let identities = sessions.map { ObjectIdentifier($0.surface) }
            let pids = sessions.map { state($0)?["pid"] as? Int }
            let grids = sessions.map { $0.surface.readVisibleSnapshot() }
            for policy in [.background, .extend, .always, .background, .always, .extend] as [TerminalPaddingColor] {
                settings.terminalPaddingColor = policy
                try wait("\(backend) \(stage) \(policy.rawValue) updates every pinned split") {
                    sessions.allSatisfy { matches($0.surface, policy: policy, automaticVertical: automaticVertical) }
                }
                for (index, session) in sessions.enumerated() {
                    let view = session.surface
                    guard let grid = view.readVisibleSnapshot() else { throw NSError(domain: "Quick grid missing", code: 1) }
                    let image = try pixels(view)
                    try check(ObjectIdentifier(view) == identities[index] && state(session)?["pid"] as? Int == pids[index],
                              "\(backend) \(stage) \(policy.rawValue) pane \(index) keeps its surface and PTY")
                    try check(grid == grids[index], "\(backend) \(stage) \(policy.rawValue) pane \(index) keeps its grid")
                    let plain = CGPoint(x: grid.origin.x + 4.5 * grid.cellSize.width, y: grid.origin.y + 1.5 * grid.cellSize.height)
                    try check(abs(Int(image.at(plain, in: view.bounds.size)[3]) - 128) <= 2,
                              "\(backend) \(stage) \(policy.rawValue) pane \(index) keeps Quick Terminal opacity")
                    try check((view.layer?.sublayers?.count ?? 0) <= 4,
                              "\(backend) \(stage) \(policy.rawValue) pane \(index) keeps compositor layers bounded")
                    if let evidence {
                        try image.png(to: evidence.appendingPathComponent("\(backend)-quick-\(stage)-\(index)-\(policy.rawValue).png"))
                    }
                }
            }
        }

        for mode in [QuickTerminalMode.fresh, .reuse] {
            let lifetime = WorkspaceLifetime()
            try autoreleasepool {
                settings.quickTerminalMode = mode
                settings.terminalPaddingColor = .extend
                overlay.toggle()
                try wait("\(backend) \(mode.rawValue) Quick Terminal appears") { quickWindow() != nil }
                var (window, tab) = try splitWorkspace()
                lifetime.view = window.contentView.flatMap { descendants($0).compactMap { $0 as? QuickTerminalWorkspaceView }.first }
                try draw("m", in: tab.sessions)
                try verifyPolicies(tab, stage: mode.rawValue, automaticVertical: false)
                if mode == .fresh, let duration = ProcessInfo.processInfo.environment["ZSHELL_PADDING_TEST_HOLD_SECONDS"].flatMap(Double.init), duration > 0 {
                    print("PADDING_QUICK_READY backend=\(backend) pid=\(getpid()) home=\(directory.path)")
                    pump(duration)
                }
                let oldTab = tab
                let oldPIDs = tab.sessions.compactMap(\.shellPid)
                let oldSurfaces = tab.sessions.map { ObjectIdentifier($0.surface) }
                overlay.toggle()
                try wait("\(backend) \(mode.rawValue) Quick Terminal hides") { quickWindow() == nil }
                if mode == .fresh {
                    try check(overlay.workspace == nil, "\(backend) fresh dismissal releases its workspace")
                    try wait("\(backend) fresh dismissal terminates its fixture PTYs") { oldPIDs.allSatisfy { kill($0, 0) != 0 } }
                } else {
                    try check(overlay.workspace === tab, "\(backend) reusable dismissal retains its workspace")
                }
                settings.terminalPaddingColor = .background
                pump(0.08)
                overlay.toggle()
                try wait("\(backend) \(mode.rawValue) Quick Terminal reopens") { quickWindow() != nil }
                if mode == .fresh {
                    (window, tab) = try splitWorkspace()
                    try check(tab !== oldTab && tab.sessions.map { ObjectIdentifier($0.surface) } != oldSurfaces,
                              "\(backend) fresh reopening creates new split surfaces")
                    lifetime.view = window.contentView.flatMap { descendants($0).compactMap { $0 as? QuickTerminalWorkspaceView }.first }
                } else {
                    guard let reopened = quickWindow() else { throw NSError(domain: "Reusable window missing", code: 1) }
                    window = reopened
                    try pin(window)
                    try wait("\(backend) reusable grids settle after reopening") { tab.sessions.allSatisfy(settled) }
                    try check(overlay.workspace === tab && tab.sessions.compactMap(\.shellPid) == oldPIDs
                              && tab.sessions.map { ObjectIdentifier($0.surface) } == oldSurfaces,
                              "\(backend) reusable reopening keeps every split and PTY")
                }
                try draw("q", in: tab.sessions)
                try verifyPolicies(tab, stage: "\(mode.rawValue)-reopened", automaticVertical: true)
                for session in tab.sessions { try selectEdge(in: session.surface, application: app) }
                for policy in TerminalPaddingColor.allCases {
                    settings.terminalPaddingColor = policy
                    pump(0.12)
                    for session in tab.sessions {
                        let view = session.surface
                        let image = try pixels(view)
                        let grid = view.readVisibleSnapshot()!
                        let selected = CGPoint(x: grid.origin.x + grid.cellSize.width * 0.1,
                                               y: grid.origin.y + grid.cellSize.height * 0.1)
                        try check(view.hasSelection && image.at(selected, in: view.bounds.size)[3] == 255,
                                  "\(backend) \(mode.rawValue) \(policy.rawValue) preserves opaque mouse selection")
                        let alpha = image.at(CGPoint(x: 2, y: 2), in: view.bounds.size)[3]
                        try check(policy == .background ? abs(Int(alpha) - 128) <= 2 : alpha == 255,
                                  "\(backend) \(mode.rawValue) \(policy.rawValue) selection padding follows policy")
                    }
                }
                let inputs = tab.sessions.map { $0.surface as! any NSTextInputClient }
                for input in inputs {
                    input.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                let carets = inputs.map { $0.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) }
                for policy in TerminalPaddingColor.allCases {
                    settings.terminalPaddingColor = policy
                    pump(0.12)
                    for (index, input) in inputs.enumerated() {
                        try check(input.hasMarkedText() && input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == carets[index],
                                  "\(backend) \(mode.rawValue) \(policy.rawValue) preserves Chinese IME and candidate anchor")
                    }
                }
                for input in inputs { input.unmarkText() }
                if !visible {
                    try check(QuickTerminalOffscreen.isSafe(), "\(backend) \(mode.rawValue) pinned integration stays offscreen without input capture")
                }
                while overlay.workspace != nil { overlay.closeFocusedPane(); pump(0.05) }
                try check(overlay.allSessions.isEmpty, "\(backend) closing every Quick Terminal pane removes its sessions")
            }
            try wait("\(backend) \(mode.rawValue) closing releases the settings observer owner") { lifetime.view == nil }
            settings.terminalPaddingColor = .background
            pump(0.08)
            try check(lifetime.view == nil && overlay.allSessions.isEmpty,
                      "\(backend) closed workspace cannot be retained by later settings changes")
        }
        print("Quick Terminal padding color tests passed: \(backend), \(checks) checks (production pinned fresh/reuse splits, PTYs, pixels, settings)")
    }

    private static func pixels(_ view: any TerminalBackendSurface) throws -> PaddingPixels {
        guard let layer = view.layer, let contents = layer.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            throw NSError(domain: "Quick Terminal has no retained IOSurface", code: 1)
        }
        return try PaddingPixels(compositing: layer, size: view.bounds.size,
                                 scale: view.window?.backingScaleFactor ?? 2,
                                 colorSpace: CGColorSpace(name: view is ZshellTerminalView ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!)
    }

    private static func matches(_ view: any TerminalBackendSurface, policy: TerminalPaddingColor, automaticVertical: Bool) -> Bool {
        guard let grid = view.readVisibleSnapshot(), let image = try? pixels(view) else { return false }
        let size = view.bounds.size
        let left = grid.origin.x + grid.cellSize.width * 0.5
        let right = grid.origin.x + (CGFloat(grid.columns) - 0.5) * grid.cellSize.width
        let top = grid.origin.y + grid.cellSize.height * 0.5
        let bottom = grid.origin.y + (CGFloat(grid.rows.count) - 0.5) * grid.cellSize.height
        let middle = grid.origin.y + grid.cellSize.height * 1.5
        let pairs = [
            (CGPoint(x: 2, y: middle), CGPoint(x: left, y: middle)),
            (CGPoint(x: size.width - 2, y: middle), CGPoint(x: right, y: middle)),
            (CGPoint(x: right, y: 2), CGPoint(x: right, y: top)),
            (CGPoint(x: right, y: size.height - 2), CGPoint(x: right, y: bottom)),
            (CGPoint(x: size.width - 2, y: 2), CGPoint(x: right, y: top)),
            (CGPoint(x: size.width - 2, y: size.height - 2), CGPoint(x: right, y: bottom)),
        ]
        let plain = image.at(CGPoint(x: grid.origin.x + grid.cellSize.width * 4.5, y: middle), in: size)
        return pairs.enumerated().allSatisfy { index, pair in
            let extends = policy == .always || policy == .extend && (index < 2 || automaticVertical)
            let expected = extends ? image.at(pair.1, in: size) : plain
            return zip(image.at(pair.0, in: size), expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
        }
    }

    private static func selectEdge(in view: any TerminalBackendSurface, application: PaddingApplication) throws {
        guard let window = view.window, let grid = view.readVisibleSnapshot() else {
            throw NSError(domain: "Selection fixture missing", code: 1)
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
            return NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil), modifierFlags: [.shift],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let end = CGPoint(x: grid.origin.x + grid.cellSize.width * 4.9, y: grid.origin.y + grid.cellSize.height * 0.5)
        let down = mouse(.leftMouseDown, at: CGPoint(x: grid.origin.x + 0.1, y: grid.origin.y + 0.1))
        let drag = mouse(.leftMouseDragged, at: end), up = mouse(.leftMouseUp, at: end)
        application.inputEvent = down
        view.mouseDown(with: down)
        application.inputEvent = drag
        view.mouseDragged(with: drag)
        application.inputEvent = up
        view.mouseUp(with: up)
        application.inputEvent = nil
        try wait("production Quick Terminal mouse selection appears") { view.hasSelection }
    }

    private static func send(_ text: String, to view: any TerminalBackendSurface) {
        if let ghostty = view as? ZshellTerminalView {
            ghostty.performBindingAction("text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined())
        } else { view.sendText(text) }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
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
