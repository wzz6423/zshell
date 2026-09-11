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
        installTerminalEnvironmentMenu()
        GlobalTerminalOverlay.shared.start()
    }

    private func installTerminalEnvironmentMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let title = String(localized: "Terminal")
        let submenu = NSMenu(title: title)
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

    @objc private func editProjectTerminalEnvironment() {
        guard let project = TerminalManager.activeWindowManager?.selectedProject else {
            NSSound.beep()
            return
        }
        TerminalEnvironmentEditorController.show(project: project)
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
