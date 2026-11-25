import AppKit

@MainActor
final class TerminalCommandBookmarkController: NSObject, NSMenuDelegate {
    static let shared = TerminalCommandBookmarkController()

    func menuItem(for surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation) -> NSMenuItem? {
        guard let session = surface.events as? TerminalSession, session.surface === surface,
            !session.hasExited, !session.commandBookmarks.isClosed,
            let record = surface.commandRecords.first(where: { $0.outputLocation == location }),
            let bookmark = TerminalCommandBookmark(record: record), surface.commandRegion(at: location) != nil
        else { return nil }
        return TerminalCommandBookmarkMenuTarget(session: session, bookmark: bookmark).toggleItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let session = focusedSession()
        let records = session?.surface.commandRecords ?? []
        session?.commandBookmarks.reconcile(records)
        guard let session, !session.commandBookmarks.entries.isEmpty else {
            let item = NSMenuItem(title: String(localized: "No Bookmarks"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for bookmark in session.commandBookmarks.entries.reversed() {
            guard let record = byID[bookmark.id] else { continue }
            let target = TerminalCommandBookmarkMenuTarget(session: session, bookmark: bookmark)
            let title = record.command.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\t", with: " ")
            let item = NSMenuItem(title: String(title.prefix(100)), action: nil, keyEquivalent: "")
            item.identifier = .init("zshell-command-bookmark-" + bookmark.id.uuidString)
            item.toolTip = record.command
            let actions = NSMenu(title: item.title)
            target.navigationItems().forEach(actions.addItem)
            item.submenu = actions
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(TerminalCommandBookmarkMenuTarget(session: session).clearItem())
    }

    private func focusedSession() -> TerminalSession? {
        guard let window = NSApp.keyWindow else { return nil }
        if let session = GlobalTerminalOverlay.shared.focusedPromptQueueSession,
            !session.hasExited, !session.commandBookmarks.isClosed, session.surface.window === window
        {
            return session
        }
        guard let manager = TerminalManager.activeWindowManager, manager.presentationWindow === window,
            case .session(let session)? = manager.selectedProject?.focusedContent,
            !session.hasExited, !session.commandBookmarks.isClosed, session.surface.window === window
        else { return nil }
        return session
    }
}

@MainActor
private final class TerminalCommandBookmarkMenuTarget: NSObject, NSMenuItemValidation {
    private weak var session: TerminalSession?
    private let sessionID: UUID
    private let bookmark: TerminalCommandBookmark?

    init(session: TerminalSession, bookmark: TerminalCommandBookmark? = nil) {
        self.session = session
        sessionID = session.id
        self.bookmark = bookmark
    }

    func toggleItem() -> NSMenuItem {
        item("zshell-toggle-command-bookmark", title: String(localized: "Bookmark Command"), action: #selector(toggleBookmark(_:)))
    }

    func navigationItems() -> [NSMenuItem] {
        [
            item("zshell-reveal-command-bookmark", title: String(localized: "Show Output"), action: #selector(revealBookmark(_:))),
            item("zshell-remove-command-bookmark", title: String(localized: "Remove Bookmark"), action: #selector(removeBookmark(_:))),
        ]
    }

    func clearItem() -> NSMenuItem {
        item("zshell-clear-command-bookmarks", title: String(localized: "Clear Bookmarks"), action: #selector(clearBookmarks(_:)))
    }

    private func item(_ identifier: String, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.identifier = .init(identifier)
        item.target = self
        // Menu actions keep their original session and block even if focus
        // changes while AppKit is tracking the menu.
        item.representedObject = self
        item.isEnabled = validateMenuItem(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let session = liveSession() else { return false }
        switch menuItem.action {
        case #selector(clearBookmarks(_:)):
            return !session.commandBookmarks.entries.isEmpty
        case #selector(removeBookmark(_:)):
            return bookmark.map(session.commandBookmarks.contains) ?? false
        case #selector(toggleBookmark(_:)):
            let isBookmarked = bookmark.map(session.commandBookmarks.contains) ?? false
            menuItem.title = isBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark Command")
            return liveRecord(in: session) != nil
        case #selector(revealBookmark(_:)):
            return bookmark.map(session.commandBookmarks.contains) == true && liveRecord(in: session) != nil && canFocus(session)
        default:
            return false
        }
    }

    private func liveSession() -> TerminalSession? {
        guard let session, session.id == sessionID, !session.hasExited, !session.commandBookmarks.isClosed,
            (session.surface.events as? TerminalSession) === session
        else { return nil }
        return session
    }

    private func liveRecord(in session: TerminalSession) -> TerminalCommandRecord? {
        guard let bookmark,
            let record = session.surface.commandRecords.first(where: { $0.id == bookmark.id && $0.outputLocation == bookmark.location }),
            session.surface.commandRegion(at: bookmark.location) != nil
        else { return nil }
        return record
    }

    private func canFocus(_ session: TerminalSession) -> Bool {
        if ZshellAutomationRouter.context(forSession: sessionID)?.session === session { return true }
        let overlay = GlobalTerminalOverlay.shared
        return overlay.notificationPane(for: sessionID)?.session === session && overlay.canRevealNotification(sessionID: sessionID)
    }

    @objc private func toggleBookmark(_ sender: NSMenuItem) {
        guard let session = liveSession(), liveRecord(in: session) != nil, let bookmark else { return }
        session.commandBookmarks.toggle(bookmark)
        _ = validateMenuItem(sender)
    }

    @objc private func revealBookmark(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let session = liveSession(), let bookmark,
            let record = liveRecord(in: session)
        else { return }
        if ZshellAutomationRouter.context(forSession: sessionID)?.session === session {
            guard TerminalCommandHistoryActions.focusOrigin(.init(record: record, terminalID: sessionID)) else { return }
        } else {
            guard GlobalTerminalOverlay.shared.revealNotification(sessionID: sessionID) else { return }
        }
        // Showing a parked pane can resize its grid and restore the live
        // viewport. Resolve the token only after that presentation pass.
        DispatchQueue.main.async { [weak session, sessionID] in
            guard let session, session.id == sessionID, !session.hasExited,
                !session.commandBookmarks.isClosed, session.commandBookmarks.contains(bookmark),
                let window = session.surface.window, window.isVisible,
                session.surface.commandRecords.contains(where: { $0.id == bookmark.id && $0.outputLocation == bookmark.location })
            else { return }
            if let context = ZshellAutomationRouter.context(forSession: sessionID), context.session === session {
                guard context.manager.selectedProjectID == context.project.id,
                    context.project.selectedTabID == context.tab.id,
                    context.tab.focusedPaneID == context.pane.id,
                    context.manager.presentationWindow === window
                else { return }
            } else {
                guard let match = GlobalTerminalOverlay.shared.notificationPane(for: sessionID), match.session === session,
                    match.tab.focusedPaneID == match.pane.id,
                    GlobalTerminalOverlay.shared.workspace === match.tab
                else { return }
            }
            session.surface.revealCommand(at: bookmark.location)
        }
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let session = liveSession(), let bookmark else { return }
        session.commandBookmarks.remove(bookmark)
    }

    @objc private func clearBookmarks(_ sender: NSMenuItem) { liveSession()?.commandBookmarks.clear() }
}
