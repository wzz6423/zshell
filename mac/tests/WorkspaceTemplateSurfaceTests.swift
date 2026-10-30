import AppKit
import Darwin
import Foundation
import WebKit
@testable import zshell

@main @MainActor
struct WorkspaceTemplateSurfaceTests {
    static var checks = 0

    static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw failure(label) }
        checks += 1
        print("PASS \(label)")
    }

    static func failure(_ label: String) -> NSError {
        NSError(domain: "WorkspaceTemplateSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    static func wait(_ label: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if condition() { return }
            pump(0.025)
        }
        throw failure(label)
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let offscreen = ProcessInfo.processInfo.environment["ZSHELL_TEMPLATE_TEST_VISIBLE"] != "1"
        if offscreen { QuickTerminalOffscreen.install() }
        let backend = CommandLine.arguments[1]
        let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let address = CommandLine.arguments[3]
        let resultDirectory = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        AppLocalization.apply(.english)
        precondition(AppSettings.configURL.path.hasPrefix(home.path))
        precondition(!AppSettings.shared.aiEnabled)
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        let manager = TerminalManager()
        let source = manager.selectedProject!
        for content in source.tabs.flatMap(\.allContents) { source.closeContent(content, confirmWorktree: false, recordClosedSession: false) }
        let sourceRoot = home.appendingPathComponent("source", isDirectory: true)
        let targetRoot = home.appendingPathComponent("target", isDirectory: true)
        for root in [sourceRoot, targetRoot] {
            for path in ["api", "web", "repo"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
        }
        source.customDirectory = sourceRoot.path
        source.customName = "Source project"
        var windows: [NSWindow] = []
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.identifier = NSUserInterfaceItemIdentifier("main-template-fixture")
        host.orderFront(nil)
        manager.attach(to: host)
        windows.append(host)
        var completed = false
        defer {
            if !completed {
                for project in manager.projects {
                    for session in project.sessions {
                        print("DIAGNOSTIC \(backend): exited=\(session.hasExited) text=\(text(session).debugDescription)")
                    }
                }
            }
            WorkspaceTemplateController.shared.close(ifOwnedBy: manager)
            manager.projects.forEach { $0.terminateAll() }
            pump(0.2)
            windows.forEach { $0.contentView = nil; $0.orderOut(nil) }
            manager.windowClosed()
        }

        func mount(_ session: TerminalSession) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
                                            styleMask: [.titled], backing: .buffered, defer: false)
            let surface = session.surface
            surface.frame = window.contentView!.bounds
            window.contentView = surface
            surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
            window.makeFirstResponder(surface)
            surface.setSurfaceVisible(true)
            windows.append(window)
        }

        func text(_ session: TerminalSession) -> String {
            session.surface.readVisibleText(maxLines: 80, maxColumns: 200) ?? ""
        }

        let first = source.newSession(directory: sourceRoot.appendingPathComponent("api").path,
            commandArguments: ["sh", "-c", "printf 'SOURCE_START\\n'; exec /bin/sh -i"],
            usesConfiguredStartupCommand: false)!
        let workTab = source.selectedTab!
        let second = source.newSession(directory: sourceRoot.appendingPathComponent("web").path,
            launchSettings: TerminalLaunchSettings(initializationCommand: "printf 'SOURCE_INIT\\n'"),
            usesConfiguredStartupCommand: false)!
        let secondTab = source.detachTabForTransfer(id: source.selectedTabID!)!
        let secondPane = secondTab.allPanes[0]
        let browser = source.newBrowserTab(initialURL: address + "/docs?token=PRIVATE_SOURCE#auth", initialFocus: .none)
        let browserTab = source.detachTabForTransfer(id: source.selectedTabID!)!
        let browserPane = browserTab.allPanes[0]
        source.selectedTabID = workTab.id
        workTab.layout = .split(PaneSplit(axis: .horizontal, fraction: 0.65,
            first: workTab.layout, second: .split(PaneSplit(axis: .vertical, fraction: 0.3,
                first: .pane(secondPane), second: .pane(browserPane)))))
        workTab.customName = "Development"
        workTab.focusedPaneID = secondPane.id
        mount(first)
        mount(second)
        try wait("source terminal started") { first.shellPid != nil && text(first).contains("SOURCE_START") }
        try wait("source initialization ran") { text(second).contains("SOURCE_INIT") }
        try wait("source browser loaded") { browser.title == "Template fixture" && !browser.isLoading }
        var storageWritten = false
        var storageError: Error?
        browser.webView.evaluateJavaScript("localStorage.setItem('fixture-auth', 'PRIVATE_STORAGE')") { _, error in
            storageError = error
            storageWritten = true
        }
        try wait("source browser storage initialized") { storageWritten }
        if let storageError { throw storageError }
        first.sendCommand("printf 'PRIVATE_SCROLLBACK\\n'\r")
        try wait("source scrollback was written") { text(first).contains("PRIVATE_SCROLLBACK") }
        let originalPID = first.shellPid!
        let originalIDs = Set(source.sessions.map(\.id))
        let filePath = sourceRoot.appendingPathComponent("unsaved.txt")
        try "ORIGINAL_DISK".write(to: filePath, atomically: true, encoding: .utf8)
        source.openFile(filePath.path, behavior: .pinned)
        let fileTab = source.selectedTab!
        guard case .file(let file) = fileTab.focusedContent! else { throw failure("file fixture missing") }
        try wait("source editor loaded") { if case .text = file.content { return file.text == "ORIGINAL_DISK" }; return false }
        file.text = "UNSAVED_PRIVATE_EDIT"
        file.refreshDirtyState()
        let diff = DiffTab(repoRoot: sourceRoot.path, path: "unsaved.txt", staged: false, untracked: true, origPath: nil)
        source.append(PaneTab(content: .diff(diff)))
        source.selectedTabID = workTab.id
        let agentIdentity = AgentConversationIdentity(provider: .codex, sessionID: UUID().uuidString,
                                                       workingDirectory: sourceRoot.path)!
        first.recordAgentConversation(agentIdentity, processID: nil)
        second.recordAgentConversation(agentIdentity, processID: nil)
        let agentTemplate = try WorkspaceTemplate.capture(project: source, name: "Agent project")
        try check(agentTemplate.tabs[0].terminals[0].program == nil,
                  "capture omits direct startup arguments after an agent identity is detected")
        try check(agentTemplate.tabs[0].terminals[1].initializationCommand == nil,
                  "capture omits initialization commands after an agent identity is detected")
        let agentJSON = String(data: try agentTemplate.encoded(), encoding: .utf8)!
        try check(!agentJSON.contains(agentIdentity.sessionID), "capture omits the detected agent identity")
        first.recordAgentConversation(nil, processID: nil)
        second.recordAgentConversation(nil, processID: nil)
        let captured = try WorkspaceTemplate.capture(project: source, name: "Shared Development")
        let data = try captured.encoded()
        let encoded = String(data: data, encoding: .utf8)!
        try check(captured.tabs.count == 3 && captured.simplifiedPaneCount == 2, "capture keeps tabs and clearly simplifies editor/diff leaves")
        try check(captured.tabs[0].terminals[0].program == "sh", "capture preserves a PATH-based startup program")
        try check(captured.tabs[0].focusedPaneIndex == 1, "capture retains focused pane position")
        for secret in ["PRIVATE_SCROLLBACK", "PRIVATE_SOURCE", "PRIVATE_STORAGE", "UNSAVED_PRIVATE_EDIT", first.id.uuidString,
                       "terminalID", "historyKey", "agentResume", "remoteSessionID", "credentialID"] {
            try check(!encoded.contains(secret), "export excludes private runtime value \(secret.hasPrefix("PRIVATE") ? "fixture state" : secret)")
        }
        try check(file.text == "UNSAVED_PRIVATE_EDIT" && file.isDirty, "capture preserves unsaved source editor contents")
        let sourceDisk = try String(contentsOf: filePath, encoding: .utf8)
        try check(sourceDisk == "ORIGINAL_DISK", "capture does not save the source file")
        let store = WorkspaceTemplateStore(url: home.appendingPathComponent("templates/library.json"))
        let entryID = try store.add(captured)
        let shareURL = home.appendingPathComponent("shared-template.json")
        try store.exportTemplate(entryID, to: shareURL)
        let importedID = try store.importTemplate(from: shareURL)
        var ready = store.entries.first { $0.id == importedID }!.template
        ready.tabs[0].terminals[0].arguments = ["-c", "printf 'APPLIED_START\\n'; printf '%s\\n' \"$PWD\"; : > applied-sentinel; exec /bin/sh -i"]
        ready.tabs[0].terminals[1].initializationCommand = "printf 'APPLIED_INIT\\n'; : > initialization-sentinel"
        try store.update(importedID, template: ready)
        let sentinel = targetRoot.appendingPathComponent("api/applied-sentinel")
        try check(!FileManager.default.fileExists(atPath: sentinel.path), "saving, exporting, importing and editing do not execute commands")
        let projectCount = manager.projects.count
        var unavailable = ready
        unavailable.tabs[0].terminals[0].program = "/missing/template-program"
        do { _ = try manager.applyWorkspaceTemplate(unavailable, projectRoot: targetRoot.path); throw failure("invalid apply succeeded") }
        catch WorkspaceTemplateError.programNotExecutable { }
        try check(manager.projects.count == projectCount && !FileManager.default.fileExists(atPath: sentinel.path), "failed preflight creates no project and runs no command")
        AppSettings.shared.terminalStartupProgram = "/bin/sh"
        AppSettings.shared.terminalStartupArguments = "-c ': > GLOBAL_STARTUP_SENTINEL; exec /bin/sh -i'"
        let applied = try manager.applyWorkspaceTemplate(ready, projectRoot: targetRoot.path)
        applied.sessions.forEach(mount)
        try wait("applied startup program did not execute") { FileManager.default.fileExists(atPath: sentinel.path) && text(applied.sessions[0]).contains("APPLIED_START") }
        try wait("applied initialization command did not execute") {
            FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("web/initialization-sentinel").path)
                && text(applied.sessions[1]).contains("APPLIED_INIT")
        }
        try check(applied.tabs.count == 3 && applied.sessions.count == 4, "application creates all terminal leaves and converted editor/diff leaves")
        try check(Set(applied.sessions.map(\.id)).isDisjoint(with: originalIDs), "template creates fresh terminal identities")
        try check(applied.sessions.allSatisfy { !$0.reconnectedToPersistentPTY && $0.agentResume == nil && $0.worktree == nil }, "template never reconnects a running PTY or copies agent/worktree ownership")
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        try check(resolved(applied.sessions[0].currentDirectoryPath) == resolved(targetRoot.appendingPathComponent("api").path)
                  && resolved(applied.sessions[1].currentDirectoryPath) == resolved(targetRoot.appendingPathComponent("web").path), "real PTYs start in remapped project-relative directories")
        try check(applied.sessions.dropFirst(2).allSatisfy { resolved($0.currentDirectoryPath) == resolved(targetRoot.path) }, "converted editor and diff panes start at the target root")
        try check(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("GLOBAL_STARTUP_SENTINEL").path), "unlisted global startup commands are not applied to template terminals")
        try check(first.shellPid == originalPID && !first.hasExited && text(first).contains("PRIVATE_SCROLLBACK"), "applying leaves the source PTY and scrollback alive")
        try check(source.tabs.contains { $0 === fileTab } && file.isDirty, "applying keeps source tabs and unsaved edits")
        if case .split(let outer) = applied.tabs[0].layout, case .split(let inner) = outer.second {
            try check(outer.axis == .horizontal && outer.fraction == 0.65 && inner.axis == .vertical && inner.fraction == 0.3, "actual pane tree retains nested split axes and weights")
            let geometry = applied.tabs[0].layout.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 4)
            try check(geometry.panes.count == 3 && geometry.panes[0].frame.width > geometry.panes[1].frame.width
                      && geometry.panes[1].frame.height < geometry.panes[2].frame.height, "existing pane geometry honors template weights")
        } else { throw failure("nested split tree missing") }
        try check(applied.selectedTabID == applied.tabs[0].id && applied.tabs[0].focusedPaneID == applied.tabs[0].allPanes[1].id, "application restores selected tab and focused pane")
        let restoredBrowser = applied.tabs[0].browsers[0]
        try wait("applied browser page did not load") { restoredBrowser.title == "Template fixture" && !restoredBrowser.isLoading }
        try check(restoredBrowser.webView.url?.absoluteString == address + "/docs", "real browser opens the captured public page")

        let controller = WorkspaceTemplateController(store: store)
        let menu = NSMenu()
        for title in ["Zshell", "File"] { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = NSMenu(title: title); menu.addItem(item) }
        controller.installMenu(in: menu)
        controller.installMenu(in: menu)
        try check(menu.items[1].submenu!.items.filter { $0.identifier?.rawValue == "zshell-workspace-templates-menu" }.count == 1,
                  "AppKit menu installation is idempotent inside File")
        controller.show(for: manager)
        pump(0.2)
        let panel = host.childWindows!.first { $0.identifier?.rawValue == "workspace-templates" }!
        let views = descendants(panel.contentView!)
        let table = views.compactMap { $0 as? NSTableView }.first!
        let rootField = views.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        let applyButton = views.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Apply Template") }!
        try check(table.numberOfRows == 2 && applyButton.isEnabled, "native manager presents template selection and a usable apply action")
        rootField.stringValue = targetRoot.path + "/missing"
        applyButton.performClick(nil)
        pump(0.1)
        try check(manager.projects.count == projectCount + 1 && views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("unavailable") },
                  "invalid directory displays an AppKit error and keeps the manager open")
        rootField.stringValue = targetRoot.path
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            controller.installMenu(in: menu)
            pump(0.03)
            panel.contentView!.layoutSubtreeIfNeeded()
            try check(panel.title == String(localized: "Workspace Templates") && !panel.title.isEmpty,
                      "native template window refreshes \(language.rawValue) labels")
        }
        AppLocalization.apply(.english)
        pump(0.1)
        panel.setContentSize(NSSize(width: 760, height: 500))
        panel.contentView!.layoutSubtreeIfNeeded()
        let snapshotViews = descendants(panel.contentView!)
        try check(snapshotViews.compactMap { $0 as? NSButton }.allSatisfy { !$0.hasAmbiguousLayout && $0.frame.width > 0 && $0.frame.height > 0 },
                  "management buttons have concrete frames at minimum window width")
        try check(rootField.frame.width > 300, "the project root field uses the full detail column")
        if let bitmap = panel.contentView!.bitmapImageRepForCachingDisplay(in: panel.contentView!.bounds) {
            panel.contentView!.cacheDisplay(in: panel.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: resultDirectory.appendingPathComponent("templates-\(backend).png"))
        }
        controller.close(ifOwnedBy: manager)
        try check(!panel.isVisible && panel.parent == nil, "closing management releases its host window relationship")
        if offscreen { try check(QuickTerminalOffscreen.isSafe(), "fixture windows stay offscreen without taking application focus") }
        completed = true
        print("Workspace template surfaces \(backend): \(checks) passed, 0 failed")
    }
}
