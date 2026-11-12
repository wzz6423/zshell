import AppKit
import Darwin
import Foundation
#if !TERMINAL_HISTORY_STORE_PROBE
@testable import zshell
#endif

private struct HistoryPersistenceFailure: Error { let message: String }

@main
@MainActor
struct TerminalHistoryPersistenceTests {
    private static var checks = 0
    private static let manager = FileManager.default

    static func main() {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        do {
            try check(fileURL.path.hasPrefix(root.path + "/"), "history uses the disposable application support directory")
            #if TERMINAL_HISTORY_STORE_PROBE
            try stores()
            try finishedCommandKeepsPrimaryHistory()
            print("Terminal history storage: \(checks) checks passed")
            #else
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            QuickTerminalOffscreen.install()
            Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
                MainActor.assumeIsolated {
                    do {
                        try surfaces(root: root, backend: CommandLine.arguments[1])
                        print("Terminal history \(CommandLine.arguments[1]): \(checks) checks passed")
                        exit(0)
                    } catch { fail(error) }
                }
            }
            app.run()
            #endif
        } catch { fail(error) }
    }

    private static var fileURL: URL {
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("zshell-dev/terminal-history.json")
    }

    private static func fail(_ error: Error) -> Never {
        fputs("Terminal history failed after \(checks) checks: \(error)\n", stderr)
        exit(1)
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HistoryPersistenceFailure(message: message) }
        checks += 1
        print("PASS \(message)")
    }

    private static func inode() throws -> ino_t {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else { throw HistoryPersistenceFailure(message: "history file is missing") }
        return metadata.st_ino
    }

    private static func read() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
    }

    private static func stores() throws {
        let parent = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try check(TerminalHistoryStore.load().isEmpty, "missing history loads empty")
        TerminalHistoryStore.save([:])
        try check(!manager.fileExists(atPath: fileURL.path), "clearing missing history succeeds")

        let text = String(repeating: "\u{1b}[31m中文 Café 👩🏽‍💻\u{1b}[0m\r\n", count: 500)
        let first = UUID().uuidString, second = UUID().uuidString
        let histories = [first: text, second: "second pane"]
        TerminalHistoryStore.save(histories)
        try check(try read() == histories, "styled Unicode history round trips")
        let originalInode = try inode()
        for _ in 0..<100 {
            TerminalHistoryStore.save(Dictionary(uniqueKeysWithValues: histories.map { ($0.key, $0.value) }))
        }
        try check(try inode() == originalInode, "layout autosaves do not replace unchanged history")
        var changed = histories
        changed[first] = text + "new output"
        TerminalHistoryStore.save(changed)
        try check(try read() == changed, "changed history under the same terminal key is written")
        TerminalHistoryStore.save(histories)
        let restoredInode = try inode()

        let loaded = TerminalHistoryStore.load()
        TerminalHistoryStore.save(loaded)
        try check(try inode() == restoredInode, "loaded history establishes the unchanged baseline")
        let decoded = try read()
        TerminalHistoryStore.save(decoded)
        try check(try inode() == restoredInode, "equal independently decoded strings do not trigger a write")
        try repeatedSaves()

        let legacyKey = UUID().uuidString
        try JSONEncoder().encode([legacyKey: text]).write(to: fileURL, options: .atomic)
        let legacy = TerminalHistoryStore.load()
        let legacyInode = try inode()
        TerminalHistoryStore.save(legacy)
        try check(try inode() == legacyInode, "legacy random history keys load without rewriting")
        TerminalHistoryStore.save([first: legacy[legacyKey]!, second: "second pane"])
        try check(try read() == histories, "stable terminal keys replace legacy keys without losing output")
        TerminalHistoryStore.save([first: text])
        try check(try read() == [first: text], "closing a pane prunes only its saved history")

        try check(geteuid() != 0 && chmod(parent.path, 0o500) == 0, "failure fixture denies writes")
        defer { chmod(parent.path, 0o700) }
        TerminalHistoryStore.save(histories)
        try check(try read() == [first: text], "a failed write preserves the previous snapshot")
        try check(chmod(parent.path, 0o700) == 0, "write permission is restored")
        TerminalHistoryStore.save(histories)
        try check(try read() == histories, "the same failed snapshot is retried after repair")

        try check(chmod(parent.path, 0o500) == 0, "clear failure fixture denies removal")
        TerminalHistoryStore.save([:])
        try check(try read() == histories, "failed clearing preserves saved history")
        try check(chmod(parent.path, 0o700) == 0, "clear permission is restored")
        TerminalHistoryStore.save([:])
        try check(!manager.fileExists(atPath: fileURL.path), "failed clearing is retried after repair")
        TerminalHistoryStore.save(histories)
        try check(try read() == histories, "history can be saved again after clearing")

        try Data("corrupt".utf8).write(to: fileURL)
        try check(TerminalHistoryStore.load().isEmpty, "corrupt history loads empty")
        TerminalHistoryStore.save(histories)
        try check(try read() == histories, "failed loading invalidates the saved baseline")
        try manager.removeItem(at: fileURL)
        try check(TerminalHistoryStore.load().isEmpty, "deleted history loads empty")
        TerminalHistoryStore.save(histories)
        try check(try read() == histories, "deleted history is recreated after loading")
    }

    #if TERMINAL_HISTORY_STORE_PROBE
    /// Screen and scrollback exports that satisfy the serializer's temp-file
    /// contract. Nil means the backend produced no file, which is how a TUI
    /// reports the hidden primary scrollback.
    private final class HistoryExportSurface: TerminalBackendSurface {
        var screenText: String?
        var scrollbackText: String?
        private var createdDirectories: [URL] = []

        func exportScreenFile() -> String? { export(screenText) }

        func exportScrollbackFile() -> String? { export(scrollbackText) }

        func cleanup() {
            for directory in createdDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private func export(_ text: String?) -> String? {
            guard let text else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zshell-history-\(UUID().uuidString)", isDirectory: true)
            let file = directory.appendingPathComponent("screen")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
                createdDirectories.append(directory)
                return file.path
            } catch {
                return nil
            }
        }
    }

    private static func finishedCommandKeepsPrimaryHistory() throws {
        let surface = HistoryExportSurface()
        defer { surface.cleanup() }
        let shell: pid_t = 4242
        let editor: pid_t = 5151
        var snapshot: String? = "PREVIOUS_LAUNCH_HISTORY"
        surface.screenText = "SHELL_COMMAND_OUTPUT\n"
        surface.scrollbackText = nil

        TerminalHistorySerializer.refreshSnapshotAfterCommandFinished(
            &snapshot,
            from: surface,
            shellPID: shell,
            foregroundPID: shell,
            maxLines: 500
        )
        try check(
            snapshot == "SHELL_COMMAND_OUTPUT",
            "command finished while the shell is foreground captures and replaces the cache"
        )

        surface.screenText = "ALTERNATE_SCREEN_TUI\n"
        TerminalHistorySerializer.refreshSnapshotAfterCommandFinished(
            &snapshot,
            from: surface,
            shellPID: shell,
            foregroundPID: editor,
            maxLines: 500
        )
        try check(
            snapshot == "SHELL_COMMAND_OUTPUT",
            "command finished while another pid is foreground keeps the previous snapshot"
        )

        let quit = TerminalHistorySerializer.liveHistorySnapshot(
            &snapshot,
            from: surface,
            shellPID: shell,
            foregroundPID: editor,
            maxLines: 500
        )
        try check(
            quit == "SHELL_COMMAND_OUTPUT"
                && quit != "ALTERNATE_SCREEN_TUI"
                && quit?.isEmpty == false,
            "quit with no scrollback export and a non-shell foreground returns that cached snapshot rather than an empty or alternate-screen capture"
        )
    }
    #endif

    private static func repeatedSaves() throws {
        let row = "\u{1b}[38;2;92;140;185m" + String(repeating: "x", count: 120) + "\u{1b}[0m\r\n"
        for panes in [32, 100] {
            let histories = Dictionary(uniqueKeysWithValues: (0..<panes).map { index in
                (UUID().uuidString, String(repeating: row + String(index), count: 500))
            })
            TerminalHistoryStore.save(histories)
            let firstInode = try inode()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 {
                TerminalHistoryStore.save(Dictionary(uniqueKeysWithValues: histories.map { ($0.key, $0.value) }))
            }
            let meanMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 100_000_000
            try check(try inode() == firstInode, "100 layout saves retain the \(panes)-pane history file")
            try check(try read() == histories, "shared cached strings retain all \(panes)-pane history contents")
            var changed = histories
            changed[histories.keys.first!]! += "changed output"
            TerminalHistoryStore.save(changed)
            try check(try read() == changed, "changing a copied history does not mutate the saved \(panes)-pane snapshot")
            print("HISTORY_SAVE_METRIC panes=\(panes) rows=500 unchangedMeanMS=\(meanMS)")
        }
    }

    #if !TERMINAL_HISTORY_STORE_PROBE
    private static func surfaces(root: URL, backend: String) throws {
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "alacritty" ? .alacritty : .libghostty
        try check(!settings.aiEnabled, "the fixture disables AI integration before launch")
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = true
        settings.quickTerminalEnabled = false
        let ids = [UUID(), UUID()]
        let oldKeys = [UUID().uuidString, UUID().uuidString]
        let text = "\u{1b}[32mHISTORY_中文_Café\u{1b}[0m\r\n"
        let histories = [oldKeys[0]: text, oldKeys[1]: "SECOND_HISTORY\r\n"]
        TerminalHistoryStore.save(histories)
        let tabs = ids.enumerated().map { index, id in
            SessionSnapshot.ProjectSnapshot.TabSnapshot(
                layout: .pane(.init(content: .session(workingDirectory: root.path), weight: 1,
                                    historyKey: oldKeys[index], terminalID: id)), focusedPaneIndex: 0)
        }
        SessionStore.save([.init(projects: [.init(customName: nil, customDirectory: root.path,
                                                 tabs: tabs, selectedTabIndex: 0)], selectedProjectIndex: 0)])

        var windows: [NSWindow] = []
        var activeManager: TerminalManager?
        func mount(_ value: TerminalManager) {
            activeManager = value
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 440),
                                styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            windows.append(host)
            value.attach(to: host)
            for session in value.projects.flatMap(\.sessions) {
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = session.surface
                session.surface.frame = NSRect(x: 0, y: 0, width: 800, height: 440)
                session.surface.setSurfaceVisible(true)
                window.orderFront(nil)
                windows.append(window)
            }
        }
        defer {
            TerminalManager.prepareForApplicationQuit(endAll: true)
            activeManager?.projects.forEach { $0.terminateAll() }
            pump(0.2)
            windows.forEach { $0.contentView = nil; $0.close() }
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        }
        let workspace = TerminalManager()
        mount(workspace)
        let project = workspace.projects[0]
        let sessions = project.sessions
        do { try wait("both restored shells start") { sessions.allSatisfy { $0.shellPid != nil } } }
        catch {
            for session in sessions {
                print("HISTORY_DIAGNOSTIC id=\(session.id) backend=\(session.backend) exited=\(session.hasExited) shellPID=\(session.shellPid.map(String.init) ?? "nil") foregroundPID=\(session.surface.foregroundPid.map(String.init) ?? "nil") attached=\(session.surface.window != nil) frame=\(session.surface.frame)")
                print("HISTORY_DIAGNOSTIC visible=\(session.surface.readVisibleText(maxLines: 10, maxColumns: 100) ?? "nil")")
            }
            throw error
        }
        pump(0.8)
        let expected = [ids[0].uuidString: histories[oldKeys[0]]!, ids[1].uuidString: histories[oldKeys[1]]!]
        try check(sessions.map(\.id) == ids && sessions.allSatisfy { $0.backend == settings.terminalBackend },
                  "the requested backend restores both saved terminal identities")
        try check(try read() == expected, "the production autosave migrates legacy keys and retains history")
        try check(historyKeys() == Set(expected.keys), "layout references stable terminal history keys")
        let originalInode = try inode()
        for index in [1, 0, 1] {
            project.selectedTabID = project.tabs[index].id
            try wait("tab selection is autosaved to the layout") {
                SessionStore.load().first?.projects.first?.selectedTabIndex == index
            }
            try check(try inode() == originalInode && historyKeys() == Set(expected.keys),
                      "switching tabs saves layout without replacing terminal history")
        }
        project.closeContent(.session(sessions[1]))
        pump(0.8)
        try check(try read() == [ids[0].uuidString: expected[ids[0].uuidString]!],
                  "closing a live pane prunes its history through autosave")

        workspace.windowClosed()
        let closedHistory = try read()
        try check(Set(closedHistory.keys) == [ids[0].uuidString] && !SessionStore.load().isEmpty,
                  "closing the last window retains its final history and layout")
        let closedInode = try inode()
        let reopened = TerminalManager()
        mount(reopened)
        try wait("the last window reopens") { reopened.projects.flatMap(\.sessions).allSatisfy { $0.shellPid != nil } }
        pump(0.8)
        try check(reopened.projects.flatMap(\.sessions).map(\.id) == [ids[0]],
                  "reopening the last window preserves terminal identities")
        try check(try inode() == closedInode && read() == closedHistory,
                  "reopened cached history does not trigger another write")
        settings.restoreTerminalHistory = false
        reopened.objectWillChange.send()
        pump(0.8)
        try check(!manager.fileExists(atPath: fileURL.path) && historyKeys().isEmpty,
                  "disabling history removes the sidecar and layout references")
        try check(QuickTerminalOffscreen.isSafe(), "backend acceptance remains offscreen without taking input")
    }

    private static func historyKeys() -> Set<String> {
        func keys(_ layout: SessionSnapshot.ProjectSnapshot.LayoutSnapshot) -> [String] {
            switch layout {
            case .pane(let pane): return pane.historyKey.map { [$0] } ?? []
            case .split(_, _, let first, let second): return keys(first) + keys(second)
            }
        }
        return Set(SessionStore.load().flatMap { $0.projects }.flatMap { $0.tabs }.flatMap { keys($0.layout) })
    }

    private static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { pump(0.01) }
        try check(condition(), message)
    }
    #endif
}
