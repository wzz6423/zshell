//
//  FinderService.swift
//  zshell
//

import AppKit

/// Provides Zshell's Finder service. The advertised menu item lives in
/// Info.plist; AppKit forwards matching service requests to this object.
@MainActor
final class ZshellApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppSettings is first initialized from SwiftUI's App.init(), where
        // NSApp may not exist yet. Reapply the saved overrides once AppKit is
        // ready, before SwiftUI creates the first window.
        AppSettings.shared.applyAppearance()
        AppSettings.shared.applyApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        WindowScreenConstraint.shared.start()
        restoreTerminalMenus()
        AppMenuLocalization.shared.start(applicationDelegate: self)
        GlobalTerminalOverlay.shared.start()
        ApplicationPresenceController.shared.start()
    }

    func restoreTerminalMenus() {
        installTerminalEnvironmentMenu()
        installEndAllSessionsMenu()
    }

    private func installTerminalEnvironmentMenu() {
        guard let mainMenu = NSApp.mainMenu,
              !mainMenu.items.contains(where: { item in
                  item.submenu?.items.contains(where: { $0.action == #selector(toggleQuickTerminal) }) == true
              }) else { return }
        let title = String(localized: "Terminal")
        let submenu = NSMenu(title: title)
        let worktree = NSMenuItem(title: AppCommand.newSessionInWorktree.title,
                                 action: #selector(newSessionInWorktree), keyEquivalent: "t")
        worktree.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(worktree)
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(
            title: String(localized: "Quick Terminal"),
            action: #selector(toggleQuickTerminal),
            keyEquivalent: ""
        ))
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(
            title: String(localized: "Project Terminal Environment…"),
            action: #selector(editProjectTerminalEnvironment),
            keyEquivalent: ""
        ))
        submenu.addItem(NSMenuItem(
            title: String(localized: "Tab Terminal Environment…"),
            action: #selector(editTabTerminalEnvironment),
            keyEquivalent: ""
        ))
        submenu.items.forEach { $0.target = self }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }

    private func installEndAllSessionsMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              !menu.items.contains(where: { $0.action == #selector(quitAndEndAllSessions) }) else { return }
        let item = NSMenuItem(
            title: String(localized: "Quit and End All Sessions"),
            action: #selector(quitAndEndAllSessions), keyEquivalent: ""
        )
        item.target = self
        let index = menu.items.firstIndex { $0.action == #selector(NSApplication.terminate(_:)) } ?? menu.items.count
        menu.insertItem(item, at: index)
    }

    @objc private func quitAndEndAllSessions() {
        TerminalManager.prepareForApplicationQuit(endAll: true)
        NSApp.terminate(nil)
    }

    @objc private func toggleQuickTerminal() {
        GlobalTerminalOverlay.shared.toggle()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationPresenceController.shared.prepareForTermination()
        TerminalManager.prepareForApplicationQuit()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        TerminalManager.showWorkspace()
        return false
    }

    @objc private func editProjectTerminalEnvironment() {
        guard let project = TerminalManager.activeWindowManager?.selectedProject else {
            NSSound.beep()
            return
        }
        TerminalEnvironmentEditorController.show(project: project)
    }

    @objc private func newSessionInWorktree() {
        TerminalManager.activeWindowManager?.promptForWorktreeSession()
    }

    @objc private func editTabTerminalEnvironment() {
        guard let project = TerminalManager.activeWindowManager?.selectedProject,
              let tab = project.selectedTab else {
            NSSound.beep()
            return
        }
        TerminalEnvironmentEditorController.show(project: project, tab: tab)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newSessionInWorktree):
            TerminalManager.activeWindowManager?.selectedProject?.isRemote == false
        case #selector(editProjectTerminalEnvironment):
            TerminalManager.activeWindowManager?.selectedProject != nil
        case #selector(editTabTerminalEnvironment):
            TerminalManager.activeWindowManager?.selectedProject?.selectedTab != nil
        default:
            true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowScreenConstraint.shared.stop()
        ApplicationPresenceController.shared.stop()
        GlobalTerminalOverlay.shared.stop()
    }

    /// Opens every directory Finder placed on the service pasteboard as a
    /// project in the active Zshell window.
    @objc func openInZshell(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = String(localized: "Select one or more folders to open in Zshell.") as NSString
            return
        }

        NSApp.activate()
        TerminalManager.openDirectories(directories)
    }

    static func directories(from pasteboard: NSPasteboard) -> [String] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        var candidates = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []

        if candidates.isEmpty,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            candidates = urls.map(\.path)
        }

        if candidates.isEmpty, let text = pasteboard.string(forType: .string) {
            candidates = text.split(whereSeparator: \.isNewline).map(String.init)
        }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let directory = normalizedDirectory(candidate),
                  seen.insert(directory).inserted else { return nil }
            return directory
        }
    }

    static func normalizedDirectory(_ candidate: String) -> String? {
        let path: String
        if let url = URL(string: candidate), url.isFileURL {
            path = url.path
        } else {
            path = (candidate as NSString).expandingTildeInPath
        }

        let standardized = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return standardized
    }
}
