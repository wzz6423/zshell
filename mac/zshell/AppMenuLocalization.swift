import AppKit
import Combine

/// SwiftUI updates app commands; AppKit owns the standard menu titles and
/// actions. Update those in place so their targets and keyboard bindings stay
/// intact. User-named project/tab items are never used as localization keys.
@MainActor
final class AppMenuLocalization: NSObject {
    static let shared = AppMenuLocalization()
    private var refreshScheduled = false
    private var shortcutObservation: AnyCancellable?
    private weak var applicationDelegate: ZshellApplicationDelegate?

    func start(applicationDelegate: ZshellApplicationDelegate) {
        self.applicationDelegate = applicationDelegate
        shortcutObservation = AppSettings.shared.$commandShortcuts.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        for name in [AppLocalization.didChange, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh), name: name, object: nil)
        }
        refresh()
    }

    @objc private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    @objc private func refresh() {
        // SwiftUI rebuilds its menu tree after workspace changes. Restore the
        // AppKit-owned commands after that reconciliation, including shortcuts.
        applicationDelegate?.restoreTerminalMenus()
        guard let menu = NSApp.mainMenu else { return }
        AgentConversationHistoryController.shared.installMenu(in: menu)
        BrowserProfileImportController.shared.installMenu(in: menu)
        let titles: [(String.LocalizationValue, String)] = [
            ("File", String(localized: "File")),
            ("Edit", String(localized: "Edit")),
            ("View", String(localized: "View")),
            ("Window", String(localized: "Window")),
            ("Help", String(localized: "Help")),
            ("Terminal", String(localized: "Terminal")),
            ("Agents", String(localized: "Agents")),
        ]
        let bundles = AppLanguage.localizationIdentifiers.compactMap {
            Bundle.main.url(forResource: $0, withExtension: "lproj").flatMap(Bundle.init(url:))
        }
        for item in menu.items {
            for (key, title) in titles where bundles.contains(where: {
                String(localized: key, bundle: $0) == item.title
            }) {
                if item.title != title { item.title = title }
                if item.submenu?.title != title { item.submenu?.title = title }
                break
            }
        }
        refreshActions(in: menu)
    }

    private func refreshActions(in menu: NSMenu) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Zshell"
        for item in menu.items {
            if let submenu = item.submenu, submenu === NSApp.servicesMenu { item.title = String(localized: "Services") }
            if let action = item.action {
                let title: String?
                switch NSStringFromSelector(action) {
                case "newSessionInWorktree":
                    title = AppCommand.newSessionInWorktree.title
                    let shortcut = AppSettings.shared.commandShortcut(for: .newSessionInWorktree)
                    if item.keyEquivalent != String(shortcut.character) { item.keyEquivalent = String(shortcut.character) }
                    if item.keyEquivalentModifierMask != shortcut.modifiers { item.keyEquivalentModifierMask = shortcut.modifiers }
                case "orderFrontStandardAboutPanel:": title = String(localized: "About \(appName)")
                case "hide:": title = String(localized: "Hide \(appName)")
                case "hideOtherApplications:": title = String(localized: "Hide Others")
                case "unhideAllApplications:": title = String(localized: "Show All")
                case "terminate:": title = String(localized: "Quit \(appName)")
                case "quitAndEndAllSessions": title = String(localized: "Quit and End All Sessions")
                case "undo:": title = String(localized: "Undo")
                case "redo:": title = String(localized: "Redo")
                case "cut:": title = String(localized: "Cut")
                case "copy:": title = String(localized: "Copy")
                case "paste:": title = String(localized: "Paste")
                case "pasteAsPlainText:": title = String(localized: "Paste and Match Style")
                case "delete:": title = String(localized: "Delete")
                case "selectAll:": title = String(localized: "Select All")
                case "performMiniaturize:": title = String(localized: "Minimize")
                case "performZoom:": title = String(localized: "Zoom")
                case "arrangeInFront:": title = String(localized: "Bring All to Front")
                case "toggleFullScreen:":
                    title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
                        ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen")
                case "editProjectTerminalEnvironment": title = String(localized: "Project Terminal Environment…")
                case "editTabTerminalEnvironment": title = String(localized: "Tab Terminal Environment…")
                case "toggleQuickTerminal": title = String(localized: "Quick Terminal")
                case "quitAndEndAllSessions": title = String(localized: "Quit and End All Sessions")
                default: title = nil
                }
                if let title, item.title != title { item.title = title }
            }
            if let submenu = item.submenu { refreshActions(in: submenu) }
        }
    }
}
