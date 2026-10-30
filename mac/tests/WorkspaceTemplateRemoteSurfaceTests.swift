import AppKit
import Darwin
import Foundation
@testable import zshell

@main @MainActor
struct WorkspaceTemplateRemoteSurfaceTests {
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
        NSError(domain: "WorkspaceTemplateRemoteSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    static func wait(_ label: String, timeout: TimeInterval = 20, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            pump(0.025)
        }
        throw failure(label)
    }

    static func awaiting<T>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await operation()) } catch { result = .failure(error) }
        }
        try wait("asynchronous operation finished", timeout: 40) { result != nil }
        return try result!.get()
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func main() {
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        do { try run() }
        catch { fputs("Remote workspace template surface failed: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let offscreen = ProcessInfo.processInfo.environment["ZSHELL_TEMPLATE_TEST_VISIBLE"] != "1"
        if offscreen { QuickTerminalOffscreen.install() }
        let backend = CommandLine.arguments[1]
        let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let address = CommandLine.arguments[3]
        let serverPath = CommandLine.arguments[4]
        let remoteHome = URL(fileURLWithPath: CommandLine.arguments[5], isDirectory: true)
        let resultDirectory = URL(fileURLWithPath: CommandLine.arguments[6], isDirectory: true)
        AppLocalization.apply(.english)
        precondition(AppSettings.configURL.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path))
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        let host = try RemoteHost(name: "Template SSH fixture", address: address, serverPath: serverPath)
        try RemoteHostStore.shared.save(host)
        let sourceDirectory = remoteHome.appendingPathComponent("source-\(backend)").path
        let targetDirectory = remoteHome.appendingPathComponent("target-\(backend)").path
        for path in [sourceDirectory, targetDirectory] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }

        let manager = TerminalManager()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main-remote-template-fixture")
        window.orderFront(nil)
        manager.attach(to: window)
        var windows = [window]
        var completed = false
        defer {
            if !completed {
                for project in manager.projects {
                    for session in project.sessions {
                        print("DIAGNOSTIC \(backend): status=\(String(describing: session.remoteStatus)) text=\(text(session).debugDescription)")
                    }
                }
            }
            WorkspaceTemplateController.shared.close(ifOwnedBy: manager)
            manager.projects.forEach { $0.terminateAll() }
            pump(0.3)
            if let listings = try? RemoteHostClient.catalog(host: host) {
                for listing in listings {
                    for session in listing.sessions {
                        if let id = UUID(uuidString: session.sessionId) {
                            try? RemoteHostClient.terminate(host: host, directory: listing.directory, sessionID: id)
                        }
                    }
                }
            }
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

        func remoteIDs(_ project: Project) -> Set<UUID> { Set(project.sessions.compactMap { $0.remoteConnection?.sessionID }) }

        let source = manager.sharedProject(host: host, directory: sourceDirectory)
        let first = source.newSession(commandArguments: ["/bin/sh", "-c", "printf 'SOURCE_REMOTE\\n'; exec /bin/sh -i"],
                                      usesConfiguredStartupCommand: false)!
        let second = source.newSession(launchSettings: TerminalLaunchSettings(initializationCommand: "printf 'SOURCE_INIT\\n'"),
                                       usesConfiguredStartupCommand: false)!
        mount(first)
        mount(second)
        try wait("source remote program ran") { text(first).contains("SOURCE_REMOTE") }
        try wait("source remote initialization ran") { text(second).contains("SOURCE_INIT") }
        let sourceIDs = remoteIDs(source)
        try check(WorkspaceTemplate.canCapture(source), "projects on a saved remote host can be saved as templates")
        let captured = try WorkspaceTemplate.capture(project: source, name: "Remote development")
        let json = String(data: try captured.encoded(), encoding: .utf8)!
        try check(captured.remote == .init(host: host.name, directory: sourceDirectory), "capture records the saved host name and remote directory")
        let capturedDirectories = captured.tabs.flatMap { WorkspaceTemplate.contents(in: $0.layout) }.map { content -> String? in
            if case .session(let directory) = content { return directory }
            return nil
        }
        try check(capturedDirectories == [".", "."],
                  "every captured remote terminal starts in the remote directory")
        try check(captured.tabs[0].terminals[0].argv == ["/bin/sh", "-c", "printf 'SOURCE_REMOTE\\n'; exec /bin/sh -i"]
                  && captured.tabs[1].terminals[0].initializationCommand == "printf 'SOURCE_INIT\\n'",
                  "capture keeps remote startup programs and initialization commands")
        for secret in [address, serverPath, host.id.uuidString, "remoteSessionID", "serverPath"]
            + sourceIDs.flatMap({ [$0.uuidString, $0.uuidString.lowercased()] }) {
            try check(!json.contains(secret), "remote export excludes runtime value \(secret.count > 20 ? "identity" : secret)")
        }

        var ready = try WorkspaceTemplate.decode(Data(json.utf8))
        ready.tabs[0].terminals[0].arguments = ["-c", "printf 'REMOTE_APPLIED\\n'; : > applied-sentinel; exec /bin/sh -i"]
        ready.tabs[1].terminals[0].initializationCommand = "printf 'REMOTE_INIT\\n'; : > initialization-sentinel"
        let projectCount = manager.projects.count
        do { _ = try awaiting { try await manager.applyRemoteWorkspaceTemplate(ready, host: host, directory: "relative/path") }; throw failure("relative remote directory applied") }
        catch WorkspaceTemplateError.invalidRemote { }
        do { _ = try awaiting { try await manager.applyRemoteWorkspaceTemplate(ready, host: host, directory: targetDirectory + "/missing") }; throw failure("missing remote directory applied") }
        catch let error as WorkspaceTemplateError { throw error }
        catch { }
        try check(manager.projects.count == projectCount, "invalid or unavailable remote directories create no project")

        // Template panes keep their saved commands even when a host profile
        // configures a startup program.
        var profile = TerminalProfile(name: "Remote template fixture")
        profile.directory = "*/target-\(backend)"
        profile.startupProgram = "/usr/bin/touch"
        profile.startupArguments = targetDirectory + "/profile-startup-sentinel"
        AppSettings.shared.terminalProfiles = [profile]
        let homeRelative = "~/" + (targetDirectory as NSString).lastPathComponent
        let applied = try awaiting { try await manager.applyRemoteWorkspaceTemplate(ready, host: host, directory: homeRelative) }
        applied.sessions.forEach(mount)
        let canonicalTarget = realpath(targetDirectory, nil).map { path in defer { free(path) }; return String(cString: path) } ?? targetDirectory
        try check(applied.sharedHost?.id == host.id && applied.remoteDirectory == canonicalTarget,
                  "application creates a shared project at the host's canonical directory")
        try wait("applied remote program ran") {
            text(applied.sessions[0]).contains("REMOTE_APPLIED")
                && FileManager.default.fileExists(atPath: targetDirectory + "/applied-sentinel")
        }
        try wait("applied remote initialization ran") {
            text(applied.sessions[1]).contains("REMOTE_INIT")
                && FileManager.default.fileExists(atPath: targetDirectory + "/initialization-sentinel")
        }
        try check(!FileManager.default.fileExists(atPath: targetDirectory + "/profile-startup-sentinel"),
                  "a host profile's startup program never replaces template commands")
        AppSettings.shared.terminalProfiles = []
        let appliedIDs = remoteIDs(applied)
        try check(applied.tabs.count == 2 && appliedIDs.count == 2 && appliedIDs.isDisjoint(with: sourceIDs),
                  "application starts new remote sessions instead of reconnecting saved ones")
        let catalogIDs = Set(try RemoteHostClient.catalog(host: host).first { $0.directory == canonicalTarget }?.sessions
            .compactMap { UUID(uuidString: $0.sessionId) } ?? [])
        try check(catalogIDs == appliedIDs, "the preflight session is reused by its pane, so the host runs exactly one session per terminal")
        try check(!first.hasExited && text(first).contains("SOURCE_REMOTE"), "applying leaves the source remote session alive")

        let again = try awaiting { try await manager.applyRemoteWorkspaceTemplate(ready, host: host, directory: canonicalTarget) }
        try check(again !== applied && again.remoteDirectory == canonicalTarget && remoteIDs(again).isDisjoint(with: appliedIDs),
                  "applying twice creates another project with its own new sessions")
        let before = manager.projects.map { remoteIDs($0) }
        try manager.synchronizeRemoteHost(host, projects: try RemoteHostClient.catalog(host: host))
        let after = manager.projects.map { remoteIDs($0) }
        let attached = after.flatMap { $0 }
        try check(after.count == before.count && Array(after.prefix(before.count)) == before && attached.count == Set(attached).count,
                  "host synchronization never attaches a template session twice")

        let store = WorkspaceTemplateStore(url: home.appendingPathComponent("templates/library.json"))
        var missingHost = ready
        missingHost.name = "Missing host"
        missingHost.remote?.host = "Retired host"
        let readyID = try store.add(ready)
        let missingID = try store.add(missingHost)
        let localID = try store.add(WorkspaceTemplate(name: "Local", tabs: [.init(layout: .pane(.init(content: .session(workingDirectory: "."), weight: 1)),
                                                                                  focusedPaneIndex: 0, terminals: [.init(paneIndex: 0)])], selectedTabIndex: 0))
        let controller = WorkspaceTemplateController(store: store)
        controller.show(for: manager)
        pump(0.2)
        let panel = window.childWindows!.first { $0.identifier?.rawValue == "workspace-templates" }!
        let table = descendants(panel.contentView!).compactMap { $0 as? NSTableView }.first!
        func select(_ id: UUID) {
            table.selectRowIndexes(IndexSet(integer: store.entries.firstIndex { $0.id == id }!), byExtendingSelection: false)
            pump(0.1)
        }
        func views() -> [NSView] { descendants(panel.contentView!) }
        select(readyID)
        let popup = views().compactMap { $0 as? NSPopUpButton }.first!
        let directoryField = views().compactMap { $0 as? NSTextField }.first { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }!
        try check(popup.titleOfSelectedItem == host.name && directoryField.stringValue == sourceDirectory,
                  "the template window preselects the saved host and remote directory")
        try check(!views().contains { ($0 as? NSButton)?.title == String(localized: "Choose") && !$0.isHiddenOrHasHiddenAncestor },
                  "remote templates hide the local project root chooser")
        select(localID)
        try check(popup.isHiddenOrHasHiddenAncestor && views().contains { ($0 as? NSButton)?.title == String(localized: "Choose") && !$0.isHiddenOrHasHiddenAncestor },
                  "local templates show the project root chooser instead of the host picker")
        select(readyID)
        panel.contentView!.layoutSubtreeIfNeeded()
        try check(!popup.isHiddenOrHasHiddenAncestor && directoryField.frame.width > 300 && popup.frame.width > 300 && !directoryField.hasAmbiguousLayout,
                  "remote host and directory controls keep full width after switching template kinds")
        select(missingID)
        let status = views().compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Retired host") }
        try check(popup.titleOfSelectedItem == String(localized: "Choose a Saved Host") && status != nil,
                  "a missing saved host asks the user to choose one")
        let applyButton = views().compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Apply Template") }!
        let count = manager.projects.count
        applyButton.performClick(nil)
        pump(0.2)
        try check(manager.projects.count == count && panel.isVisible, "applying without a saved host creates no project")
        if let bitmap = panel.contentView!.bitmapImageRepForCachingDisplay(in: panel.contentView!.bounds) {
            panel.contentView!.cacheDisplay(in: panel.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: resultDirectory.appendingPathComponent("remote-template-\(backend).png"))
        }
        popup.selectItem(withTitle: host.name)
        directoryField.stringValue = canonicalTarget
        applyButton.performClick(nil)
        try wait("window applies the remote template with the chosen host") { manager.projects.count == count + 1 && !panel.isVisible }
        let chosen = manager.projects.last!
        try check(chosen.sharedHost?.id == host.id && chosen.customName == "Missing host" && chosen.remoteDirectory == canonicalTarget,
                  "the chosen saved host replaces the missing one")
        if offscreen { try check(QuickTerminalOffscreen.isSafe(), "fixture windows stay offscreen without taking application focus") }
        completed = true
        print("Remote workspace template surfaces \(backend): \(checks) passed, 0 failed")
    }
}
