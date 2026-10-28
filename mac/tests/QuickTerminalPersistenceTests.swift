import AppKit
import Carbon.HIToolbox
import Darwin
@testable import zshell

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct QuickTerminalPersistenceTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        let offscreen = ProcessInfo.processInfo.environment["ZSHELL_QUICK_TEST_OFFSCREEN"] == "1"
        if offscreen { QuickTerminalOffscreen.install() }
        let app = NSApplication.shared
        app.setActivationPolicy(offscreen ? .prohibited : .accessory)
        // A run-loop timer lets Combine's main-queue deliveries execute while
        // wait() pumps AppKit; nested pumping inside a GCD callback cannot.
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                do { try run(); exit(0) }
                catch {
                    fputs("FAIL \(error)\n", stderr)
                    exit(1)
                }
            }
        }
        app.run()
        fputs("FAIL test application stopped before completion\n", stderr)
        exit(1)
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        let backend = CommandLine.arguments[1]
        let phase = CommandLine.arguments[2]
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let offscreen = ProcessInfo.processInfo.environment["ZSHELL_QUICK_TEST_OFFSCREEN"] == "1"
        let app = NSApplication.shared
        if !offscreen { app.activate() }
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "alacritty" ? .alacritty : .libghostty
        settings.preserveTerminalSessions = phase != "local"
        settings.quickTerminalShortcut = QuickTerminalShortcut(
            keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | optionKey | shiftKey)
        )
        let delegate = ZshellApplicationDelegate()
        func makeMenu() {
            let main = NSMenu()
            let item = NSMenuItem()
            item.submenu = NSMenu()
            item.submenu?.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            if phase == "menu-lifecycle" {
                let services = NSMenu(title: "Services")
                let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
                servicesItem.submenu = services
                item.submenu?.addItem(servicesItem)
                app.servicesMenu = services
            }
            main.addItem(item)
            app.mainMenu = main
        }
        makeMenu()
        AppMenuLocalization.shared.start(applicationDelegate: delegate)
        let overlay = GlobalTerminalOverlay.shared
        overlay.start()
        defer {
            overlay.prepareForApplicationQuit(preserve: false, endAll: true)
            overlay.stop()
            pump(0.4)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            pump(0.05)
        }
        if phase == "menu-lifecycle" {
            var changes = 0
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didChangeItemNotification,
                                                                  object: nil, queue: nil) { _ in changes += 1 }
            let started = Date()
            pump(0.5)
            NotificationCenter.default.removeObserver(observer)
            print("MENU_LIFECYCLE changes=\(changes) elapsed=\(Date().timeIntervalSince(started))")
            overlay.stop()
            try check(changes < 20, "menu refresh settles without feeding its own observer")
            return
        }

        let stateURL = root.appendingPathComponent("state")
        let checkURL = root.appendingPathComponent("check")
        func savedSessionID() -> UUID? {
            func first(_ node: SessionSnapshot.ProjectSnapshot.LayoutSnapshot) -> UUID? {
                switch node {
                case .pane(let pane): return pane.terminalID
                case .split(_, _, let left, _): return first(left)
                }
            }
            return SessionStore.loadQuickTerminalWorkspace().flatMap { first($0.layout) }
        }
        func splitMetadata() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("split.json"))) as! [String: Any]
        }
        func read(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func alive(_ value: String) -> Bool { Int32(value).map { kill($0, 0) == 0 } ?? false }
        func quickWindow() -> NSWindow? {
            app.windows.first { $0.isVisible && String(describing: type(of: $0)) == "GlobalTerminalOverlayWindow" }
        }
        func surface(in view: NSView?) -> (any TerminalBackendSurface)? {
            if let terminal = view as? any TerminalBackendSurface { return terminal }
            for child in view?.subviews ?? [] {
                if let result = surface(in: child) { return result }
            }
            return nil
        }
        func descendants(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { descendants($0) }
        }
        func menuItems() -> [NSMenuItem] {
            func flatten(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
            }
            return app.mainMenu.map(flatten) ?? []
        }
        func menuToggle() throws {
            let item = try require(menuItems().first { $0.action.map(NSStringFromSelector) == "toggleQuickTerminal" }, "native Quick Terminal menu")
            _ = app.sendAction(try require(item.action, "menu action"), to: item.target, from: item)
        }
        func carbonToggle() throws {
            var event: EventRef?
            try check(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  0, 0, &event) == noErr, "Carbon hotkey event created")
            let value = try require(event, "Carbon event")
            defer { ReleaseEvent(value) }
            var identifier = EventHotKeyID(signature: OSType(0x4B45524F), id: 1)
            try check(SetEventParameter(value, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                       &identifier) == noErr, "Carbon hotkey identity set")
            try check(SendEventToEventTarget(value, GetApplicationEventTarget()) == noErr,
                      "registered Carbon hotkey callback receives the event")
            pump(0.2)
        }
        func send(_ command: String, to terminal: any TerminalBackendSurface) {
            terminal.sendText(command)
            terminal.sendEnter()
        }
        func capture(_ terminal: any TerminalBackendSurface, to url: URL) throws -> [String] {
            try? FileManager.default.removeItem(at: url)
            send("printf '%s\\n%s\\n%s\\n' $$ \"$ZQ_TOKEN\" \"$ZQ_JOB\" > \(TerminalSession.shellQuote(url.path))", to: terminal)
            try wait("shell state written") { read(url).count == 3 }
            return read(url)
        }
        func repeatedToggleRegression(_ expectedWindow: NSWindow, _ tab: PaneTab) throws {
            if expectedWindow.isVisible { overlay.toggle() }
            let ids = tab.sessions.map(\.id)
            let surfaces = tab.sessions.map { ObjectIdentifier($0.surface) }
            let pids = tab.sessions.compactMap(\.shellPid)
            let focus = tab.focusedPaneID
            func resources() -> [Int] {
                let views = app.windows.flatMap { descendants($0.contentView) }
                func layers(_ layer: CALayer?) -> [CALayer] {
                    guard let layer else { return [] }
                    return [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
                }
                return [app.windows.count, Set(views.map(ObjectIdentifier.init)).count,
                        Set(views.flatMap { layers($0.layer).map(ObjectIdentifier.init) }).count]
            }
            var baseline: [Int]?
            var final: [Int] = []
            for iteration in 1...10 {
                try autoreleasepool {
                    let showStart = DispatchTime.now().uptimeNanoseconds
                    overlay.toggle()
                    let showMS = Double(DispatchTime.now().uptimeNanoseconds - showStart) / 1_000_000
                    pump(0.025)
                    guard overlay.workspace === tab, quickWindow() === expectedWindow,
                          tab.sessions.map(\.id) == ids,
                          tab.sessions.map({ ObjectIdentifier($0.surface) }) == surfaces,
                          tab.sessions.compactMap(\.shellPid) == pids,
                          tab.focusedPaneID == focus else {
                        throw CheckFailure(description: "repeated toggle changed workspace, renderer, PID or focus")
                    }
                    let hideStart = DispatchTime.now().uptimeNanoseconds
                    overlay.toggle()
                    let hideMS = Double(DispatchTime.now().uptimeNanoseconds - hideStart) / 1_000_000
                    pump(0.025)
                    final = resources()
                    if baseline == nil { baseline = final }
                    print("TOGGLE_METRIC backend=\(backend) phase=\(phase) cycle=\(iteration) showMS=\(showMS) hideMS=\(hideMS) windows=\(final[0]) views=\(final[1]) layers=\(final[2]) pids=\(pids)")
                }
            }
            try check(zip(final, baseline!).allSatisfy { $0 <= $1 }, "ten toggles do not grow window, view or layer counts")
            try check(pids.allSatisfy { kill($0, 0) == 0 }, "ten toggles keep every shell PID alive")
            if offscreen { try check(QuickTerminalOffscreen.isSafe(), "repeated toggles remain strictly offscreen") }
        }

        if phase == "split-skip" {
            let metadata = try splitMetadata()
            let processes = metadata["pids"] as! [String]
            try check(processes.allSatisfy(alive), "all split shells survive GUI exit")
            TerminalManager.prepareForApplicationQuit()
            overlay.stop()
            UserDefaults.standard.synchronize()
            try check(SessionStore.loadQuickTerminalWorkspace() != nil, "unopened split layout survives another normal Quit")
            return
        }
        if phase == "skip-reopen" {
            let old = read(stateURL)
            try check(old.count == 3 && alive(old[0]) && alive(old[2]), "daemon shell and job survive first GUI exit")
            let id = savedSessionID()
            TerminalManager.prepareForApplicationQuit()
            overlay.stop()
            UserDefaults.standard.synchronize()
            try check(id != nil && savedSessionID() == id, "quitting before reopening retains the quick terminal identity")
            return
        }

        try menuToggle()
        try wait("quick terminal appears") { quickWindow() != nil }
        let window = try require(quickWindow(), "quick terminal window")
        let terminal = try require(surface(in: window.contentView), "real backend surface")
        let otherWindow = QuickTerminalFocusFixtureWindow(contentRect: NSRect(x: -20000, y: -20000, width: 80, height: 80),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.title = "Quick Terminal focus fixture"
        otherWindow.ignoresMouseEvents = true
        defer { otherWindow.close() }
        pump(0.6)
        if offscreen {
            // Offscreen ordering intentionally invokes the production screen
            // constraint. Let that geometry settle before comparing layouts.
            for _ in 0..<2 { overlay.toggle(); try menuToggle(); pump(0.1) }
            try check(QuickTerminalOffscreen.isSafe(), "test panels stay offscreen without focus or mouse capture")
        }
        func transferFocusAway() {
            otherWindow.makeKeyAndOrderFront(nil)
            if offscreen {
                window.delegate?.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: window))
            }
        }

        if phase == "split-create" || phase == "split-restore-end-all" {
            if phase == "split-create" {
                overlay.split(toward: .right)
                pump(0.2)
                overlay.split(toward: .bottom)
                pump(0.2)
            }
            let tab = try require(overlay.workspace, "split workspace")
            try check(tab.sessions.count == 3, "three real terminal panes share the quick workspace")
            let sessions = tab.sessions
            if phase == "split-create", case .split(let outer) = tab.layout,
               case .split(let inner) = outer.second {
                tab.layout = tab.layout.settingFraction(of: outer.id, to: 0.33)
                    .settingFraction(of: inner.id, to: 0.65)
                tab.focusedPaneID = tab.allPanes[1].id
            }
            pump(0.2)
            let nativeSplits = descendants(window.contentView).compactMap { $0 as? NSSplitView }
            try check(nativeSplits.count == 2 && nativeSplits.contains(where: \.isVertical)
                      && nativeSplits.contains(where: { !$0.isVertical }), "nested splits use native NSSplitView on both axes")
            var states: [[String]] = []
            for (index, session) in sessions.enumerated() {
                let url = root.appendingPathComponent("pane-\(index)")
                if phase == "split-create" {
                    send("ZQ_TOKEN=split_\(index); sleep 240 & ZQ_JOB=$!", to: session.surface)
                }
                states.append(try capture(session.surface, to: url))
            }
            let ids = sessions.map { $0.id.uuidString }
            if phase == "split-create" {
                let metadata: [String: Any] = [
                    "ids": ids, "states": states, "pids": states.map { $0[0] },
                    "jobs": states.map { $0[2] }, "focused": tab.focusedPane?.content.id.uuidString ?? "",
                ]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("split.json"))
            } else {
                let metadata = try splitMetadata()
                try check(ids == metadata["ids"] as! [String] && states == metadata["states"] as! [[String]],
                          "all split IDs, shell PIDs, variables and jobs reconnect across GUI processes")
                try check(tab.focusedPane?.content.id.uuidString == metadata["focused"] as? String,
                          "focused split pane restores across GUI processes")
            }
            if case .split(let outer) = tab.layout, case .split(let inner) = outer.second {
                print("SPLIT_RATIOS outer=\(outer.fraction) inner=\(inner.fraction)")
                try check(abs(outer.fraction - 0.33) < 0.01 && abs(inner.fraction - 0.65) < 0.01,
                          "nested split ratios stay in the pane tree")
                for view in nativeSplits {
                    let available = (view.isVertical ? view.bounds.width : view.bounds.height) - view.dividerThickness
                    let first = try require(view.arrangedSubviews.first, "native split first child")
                    let actual = (view.isVertical ? first.frame.width : first.frame.height) / available
                    try check(abs(actual - (view.isVertical ? 0.33 : 0.65)) < 0.02,
                              "native divider positions match the saved ratios")
                }
            } else { throw CheckFailure(description: "nested split tree") }
            let originalFrame = window.frame
            for size in [NSSize(width: originalFrame.width * 0.8, height: originalFrame.height * 0.85),
                         originalFrame.size] {
                window.setFrame(NSRect(origin: originalFrame.origin, size: size), display: false)
                window.contentView?.layoutSubtreeIfNeeded()
                pump(0.15)
                for view in nativeSplits {
                    let available = (view.isVertical ? view.bounds.width : view.bounds.height) - view.dividerThickness
                    let first = try require(view.arrangedSubviews.first, "resized split first child")
                    let actual = (view.isVertical ? first.frame.width : first.frame.height) / available
                    try check(abs(actual - (view.isVertical ? 0.33 : 0.65)) < 0.02,
                              "window resize preserves both nested divider ratios")
                    for child in view.arrangedSubviews {
                        let crossOrigin = view.isVertical ? child.frame.minY : child.frame.minX
                        let crossSize = view.isVertical ? child.frame.height : child.frame.width
                        let expectedSize = view.isVertical ? view.bounds.height : view.bounds.width
                        try check(abs(crossOrigin) < 1 && abs(crossSize - expectedSize) < 1,
                                  "resized panes fill the split view across the divider axis")
                    }
                }
            }
            let focused = tab.focusedPaneID
            overlay.toggle()
            try menuToggle()
            pump(0.2)
            print("SPLIT_FOCUS before=\(focused) after=\(tab.focusedPaneID) sameTab=\(overlay.workspace === tab) mode=\(settings.quickTerminalMode.rawValue)")
            try check(overlay.workspace === tab, "hide/show retains the split workspace")
            try check(tab.focusedPaneID == focused, "hide/show retains focused pane")
            try check(states.flatMap { [$0[0], $0[2]] }.allSatisfy(alive), "every hidden split shell and job keeps running")
            try repeatedToggleRegression(window, tab)
            TerminalManager.prepareForApplicationQuit(endAll: phase == "split-restore-end-all")
            overlay.stop()
            UserDefaults.standard.synchronize()
            if phase == "split-create" {
                try check(states.flatMap { [$0[0], $0[2]] }.allSatisfy(alive), "normal Quit preserves every reusable split job")
            } else {
                try wait("End All terminates every hidden split shell and job") {
                    states.flatMap { [$0[0], $0[2]] }.allSatisfy { !alive($0) }
                }
                try check(SessionStore.loadQuickTerminalWorkspace() == nil, "End All clears the complete split snapshot")
            }
            print("SPLIT_STATE \(backend) \(phase) ids=\(ids) states=\(states)")
            return
        }

        if phase == "modes" {
            let reusable = try require(overlay.workspace, "reusable workspace")
            send("ZQ_TOKEN=reusable_mode; sleep 240 & ZQ_JOB=$!", to: terminal)
            let state = try capture(terminal, to: stateURL)
            overlay.split(toward: .right)
            pump(0.2)
            overlay.toggle()
            settings.quickTerminalMode = .fresh
            try menuToggle()
            pump(0.3)
            let fresh = try require(overlay.workspace, "fresh workspace")
            try check(fresh !== reusable && fresh.sessions.count == 1,
                      "fresh mode starts one pane without restoring the reusable split layout")
            try check(alive(state[0]) && alive(state[2]), "switching modes keeps the parked reusable shell and job")
            overlay.split(toward: .bottom)
            pump(0.2)
            let freshPIDs = try fresh.sessions.enumerated().map { index, session in
                let url = root.appendingPathComponent("fresh-mode-\(index)")
                send("printf '%s\\n%s\\n' $$ \"$HISTFILE\" > \(TerminalSession.shellQuote(url.path))", to: session.surface)
                try wait("fresh pane starts with normal shell configuration") { read(url).count == 2 }
                try check(read(url)[1] == root.appendingPathComponent("normal-shell-history").path,
                          "fresh mode keeps the configured HISTFILE")
                return read(url)[0]
            }
            settings.quickTerminalMode = .reuse
            overlay.toggle()
            try wait("hiding fresh workspace ends every transient pane") { freshPIDs.allSatisfy { !alive($0) } }
            try menuToggle()
            pump(0.2)
            try check(overlay.workspace === reusable && reusable.sessions.count == 2,
                      "switching back resumes the original reusable split workspace")
            try check(try capture(reusable.sessions[0].surface, to: checkURL) == state,
                      "mode switching retains original PID, variable and job")
            settings.quickTerminalMode = .fresh
            overlay.toggle()
            try menuToggle()
            pump(0.3)
            let next = try require(overlay.workspace, "next fresh workspace")
            try check(next !== fresh && next.sessions.count == 1,
                      "each fresh opening discards previous transient split layout")
            let empty = root.appendingPathComponent("fresh-empty")
            send("printf '<%s>\\n' \"$ZQ_TOKEN\" > \(TerminalSession.shellQuote(empty.path))", to: next.sessions[0].surface)
            try wait("fresh shell state is empty") { read(empty) == ["<>"] }
            try check((try String(contentsOf: root.appendingPathComponent("normal-shell-history"), encoding: .utf8))
                .contains("NORMAL_HISTORY_MARKER"), "fresh mode leaves existing command history intact")
            overlay.toggle()
            TerminalManager.prepareForApplicationQuit(endAll: true)
            overlay.stop()
            try wait("End All also ends the parked reusable workspace") { !alive(state[0]) && !alive(state[2]) }
            try check(SessionStore.loadQuickTerminalWorkspace() == nil, "fresh mode writes no replacement workspace snapshot")
            return
        }

        if phase == "relay-reconnect" {
            let previous = try require(overlay.workspace?.sessions.first, "relay session")
            send("ZQ_TOKEN=relay_reconnect; sleep 240 & ZQ_JOB=$!", to: previous.surface)
            let state = try capture(previous.surface, to: stateURL)
            let listing = Process()
            let output = Pipe()
            listing.executableURL = URL(fileURLWithPath: "/bin/ps")
            listing.arguments = ["-axo", "pid=,ppid=,command="]
            listing.standardOutput = output
            try listing.run()
            let processes = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            listing.waitUntilExit()
            let records = processes.split(separator: "\n").compactMap { line -> (pid: pid_t, parent: pid_t, command: String)? in
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
                return (pid, parent, String(fields[2]))
            }
            let parents = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0.parent) })
            func belongsToFixture(_ pid: pid_t) -> Bool {
                var ancestor = pid
                var visited = Set<pid_t>()
                while ancestor != getpid(), visited.insert(ancestor).inserted {
                    guard let parent = parents[ancestor], parent > 1 else { return false }
                    ancestor = parent
                }
                return ancestor == getpid()
            }
            // Ghostty 的启动器会多包一层进程，按父链和会话 ID 锁定本测试的 relay。
            let relayCommand = "\(CommandLine.arguments[0]) \(PTYMuxCommandLine.relayArgument) \(previous.id.uuidString)"
            let relays = records.filter { $0.command == relayCommand && belongsToFixture($0.pid) }
            try check(relays.count == 1, "exactly one renderer relay belongs to this fixture and session")
            let relayPID = try require(relays.first?.pid, "own renderer relay process")
            try check(kill(relayPID, SIGKILL) == 0, "only this renderer relay is stopped")
            try wait("renderer notices relay loss") { previous.hasExited }
            try check(alive(state[0]) && alive(state[2]), "relay loss leaves daemon shell and background job alive")
            overlay.toggle()
            try menuToggle()
            pump(0.3)
            let replacement = try require(overlay.workspace?.sessions.first, "reconnected session")
            try check(replacement !== previous && replacement.id == previous.id,
                      "relay reconnection preserves terminal identity with a new renderer")
            try check(descendants(window.contentView).contains { $0 === replacement.surface },
                      "new renderer is actually mounted despite the stable terminal ID")
            try check(try capture(replacement.surface, to: checkURL) == state,
                      "reconnected renderer reaches the original live shell, variable and job")
            TerminalManager.prepareForApplicationQuit(endAll: true)
            overlay.stop()
            try wait("End All cleans the reconnected shell and job") { !alive(state[0]) && !alive(state[2]) }
            return
        }

        if phase == "restore-end-all" {
            let old = read(stateURL)
            let current = try capture(terminal, to: checkURL)
            try check(current == old && alive(current[2]), "independent GUI process reconnects to identical shell PID, variable and background job")
            overlay.toggle()
            TerminalManager.prepareForApplicationQuit(endAll: true)
            overlay.stop()
            UserDefaults.standard.synchronize()
            try wait("Quit and End All Sessions ends hidden shell and background job") { !alive(old[0]) && !alive(old[2]) }
            try check(SessionStore.loadQuickTerminalWorkspace() == nil, "End All clears quick terminal restoration")
            return
        }

        if phase == "fresh-after-end-all" {
            let url = root.appendingPathComponent("fresh")
            send("printf '%s\\n' $$ > \(TerminalSession.shellQuote(url.path))", to: terminal)
            try wait("fresh shell starts after End All") { read(url).count == 1 }
            try check(read(url)[0] != read(stateURL)[0], "End All does not resurrect a terminated shell")
            let endedPID = read(url)[0]
            send("exit", to: terminal)
            try wait("persistent shell can end naturally") { !alive(endedPID) }
            pump(0.2)
            if window.isVisible { overlay.toggle() }
            try menuToggle()
            try wait("persistent terminal can reopen after shell exit") { quickWindow() != nil }
            let reopened = try require(quickWindow(), "reopened persistent terminal")
            try check(reopened !== window, "ended persistent shell gets a fresh surface")
            TerminalManager.prepareForApplicationQuit(endAll: true)
            overlay.stop()
            pump(0.5)
            return
        }

        let hiddenOutput = root.appendingPathComponent("hidden-output")
        send("ZQ_TOKEN=quick_\(backend); sleep 240 & ZQ_JOB=$!; (sleep 0.4; printf hidden > \(TerminalSession.shellQuote(hiddenOutput.path))) &", to: terminal)
        let before = try capture(terminal, to: stateURL)
        print("STATE backend=\(backend) phase=\(phase) guiPID=\(getpid()) shellPID=\(before[0]) variable=\(before[1]) jobPID=\(before[2])")
        if !offscreen { window.setFrame(window.frame.insetBy(dx: 20, dy: 15), display: false) }
        let frame = window.frame
        overlay.toggle()
        try check(!window.isVisible && alive(before[0]) && alive(before[2]), "toggle hides without killing the shell or background job")
        try wait("hidden shell keeps running") { FileManager.default.fileExists(atPath: hiddenOutput.path) }
        try carbonToggle()
        try check(quickWindow() === window, "show reuses the same window")
        try check(surface(in: window.contentView) === terminal, "show reuses the same backend surface")
        // Offscreen placement forces the display-migration resize on every
        // show. Size retention needs a real on-screen center and visible QA.
        if !offscreen {
            try check(abs(window.frame.width - frame.width) < 1 && abs(window.frame.height - frame.height) < 1,
                      "show keeps the window size: before=\(frame.size), after=\(window.frame.size)")
        }
        try check(try capture(terminal, to: checkURL) == before, "shell PID, variable and background job survive hide/show")

        let pin = try require(descendants(window.contentView).compactMap { $0 as? NSButton }
            .first { $0.toolTip == "Pin quick terminal" }, "existing pin button")
        pin.performClick(nil)
        transferFocusAway()
        pump(0.1)
        try check(window.isVisible, "pin keeps the terminal visible after focus loss")
        overlay.toggle()
        try menuToggle()
        pump(0.2)
        try check(pin.toolTip == "Unpin quick terminal", "pin state survives hide/show")
        pin.performClick(nil)

        if !offscreen {
        let adjustments = try require(descendants(window.contentView).compactMap { $0 as? NSButton }
            .first { $0.toolTip == String(localized: "Temporary terminal settings") }, "existing adjustments button")
        func opacitySlider() -> NSSlider? {
            app.windows.flatMap { descendants($0.contentView) }.compactMap { $0 as? NSSlider }
                .first { $0.accessibilityLabel() == String(localized: "Temporary terminal opacity") }
        }
        func settingsPopover() -> NSPopover? {
            Mirror(reflecting: window).children.first { $0.label == "settingsPopover" }?.value as? NSPopover
        }
        adjustments.performClick(nil)
        pump(0.1)
        // An offscreen Core Animation transition has no displayed frame to
        // complete against. Keep this fixture's popover close deterministic.
        if offscreen { settingsPopover()?.animates = false }
        let opacity = try require(opacitySlider(), "existing opacity slider")
        opacity.doubleValue = 0.7
        _ = opacity.sendAction(opacity.action, to: opacity.target)
        overlay.toggle()
        try wait("settings close with the hidden terminal") { settingsPopover()?.isShown != true }
        try menuToggle()
        pump(0.2)
        adjustments.performClick(nil)
        pump(0.1)
        try check(try require(opacitySlider(), "reopened opacity slider").doubleValue == 0.7,
                  "temporary opacity survives hide/show")
        overlay.toggle()
        try wait("settings finish closing before focus transfer") { settingsPopover()?.isShown != true }
        try menuToggle()
        pump(0.2)
        }

        let escape = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)
        ), "Escape event")
        window.sendEvent(escape)
        try check(!window.isVisible && alive(before[0]), "Escape hides the live session")
        try menuToggle()
        pump(0.2)
        transferFocusAway()
        pump(0.4)
        try wait("losing focus hides unpinned terminal") { !window.isVisible }
        try check(alive(before[0]) && alive(before[2]), "focus loss keeps the shell and job")

        // Rebuild the menu just as SwiftUI does after workspace changes.
        makeMenu()
        pump(0.2)
        try check(menuItems().filter { $0.action.map(NSStringFromSelector) == "toggleQuickTerminal" }.count == 1, "native menu is restored once after rebuilding")
        try check(menuItems().filter { $0.action.map(NSStringFromSelector) == "quitAndEndAllSessions" }.count == 1, "End All menu survives rebuilding")
        try repeatedToggleRegression(window, try require(overlay.workspace, "reused workspace for repeated toggles"))

        if phase == "preserve" {
            TerminalManager.prepareForApplicationQuit()
            overlay.stop()
            UserDefaults.standard.synchronize()
            pump(0.3)
            try check(alive(before[0]) && alive(before[2]) && savedSessionID() != nil, "normal Quit retains hidden daemon shell, background job and identity")
            return
        }

        try menuToggle()
        pump(0.2)
        send("kill $ZQ_JOB; wait 2>/dev/null; exit", to: terminal)
        try wait("natural shell exit dismisses terminal") { !window.isVisible && !alive(before[0]) }
        try menuToggle()
        try wait("terminal can reopen after shell exit") { quickWindow() != nil }
        let replacement = try require(quickWindow(), "replacement window")
        try check(replacement !== window, "exited terminal creates a fresh window")
        let freshSurface = try require(surface(in: replacement.contentView), "replacement surface")
        let freshURL = root.appendingPathComponent("fresh")
        send("printf '%s\\n' $$ > \(TerminalSession.shellQuote(freshURL.path))", to: freshSurface)
        try wait("replacement shell starts") { read(freshURL).count == 1 }
        let freshPID = read(freshURL)[0]
        TerminalManager.prepareForApplicationQuit()
        overlay.stop()
        try wait("normal Quit ends a nonpersistent quick terminal") { !alive(freshPID) }
        try check(SessionStore.loadQuickTerminalWorkspace() != nil, "reuse keeps layout while nonpersistent processes end")
        print("PASS \(backend) \(phase)")
    }

    @MainActor private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor private static func wait(_ name: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { pump(0.02) }
        try check(condition(), name)
    }

    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CheckFailure(description: name) }
        return value
    }

    private static func check(_ passed: Bool, _ name: String) throws {
        guard passed else { throw CheckFailure(description: name) }
        print("PASS \(name)")
    }
}
