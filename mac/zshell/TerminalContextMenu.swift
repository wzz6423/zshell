import AppKit

@MainActor
enum TerminalContextMenu {
    static func handleRightClick(
        for surface: any TerminalBackendSurface, event: NSEvent, linkTarget: TerminalLinkTarget?
    ) {
        let forceMenu = event.type != .rightMouseDown
            || !event.modifierFlags.intersection([.shift, .command, .control]).isEmpty
        let action: TerminalRightClickAction = forceMenu ? .contextMenu : AppSettings.shared.terminalRightClickAction
        switch action {
        case .contextMenu:
            show(for: surface, event: event, linkTarget: linkTarget)
        case .paste:
            NSApp.sendAction(#selector(NSText.paste(_:)), to: surface, from: nil)
        case .copyOrPaste:
            NSApp.sendAction(
                surface.hasSelection ? #selector(NSText.copy(_:)) : #selector(NSText.paste(_:)),
                to: surface, from: nil
            )
        }
    }

    static func show(
        for surface: any TerminalBackendSurface, event: NSEvent? = nil, linkTarget: TerminalLinkTarget? = nil
    ) {
        let menu = make(for: surface, event: event, linkTarget: linkTarget)
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: surface)
        } else {
            menu.popUp(positioning: menu.items.first, at: NSPoint(x: 12, y: surface.bounds.maxY - 12), in: surface)
        }
    }

    static func make(
        for surface: any TerminalBackendSurface, event: NSEvent? = nil, linkTarget: TerminalLinkTarget?
    ) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (String(localized: "Copy"), #selector(NSText.copy(_:))),
            (String(localized: "Paste"), #selector(NSText.paste(_:))),
            (String(localized: "Select All"), NSSelectorFromString("selectAll:")),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = surface
            menu.addItem(item)
        }
        if let upload = surface.events?.terminalFileUploadMenuItem { menu.addItem(upload) }
        if let event, let location = surface.commandLocation(for: event),
           surface.commandRegion(at: location) != nil {
            menu.addItem(.separator())
            TerminalCommandBlockMenuTarget(surface: surface, location: location).items().forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(surface.commandRouting.contextMenuItem())
        TerminalHintMenu.shared.items(for: surface).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(surface.splitTarget.quickCommandMenuItem())
        menu.addItem(surface.splitTarget.profileMenuTarget.menuItem())
        if let linkTarget {
            menu.addItem(.separator())
            switch linkTarget {
            case .url(let url):
                surface.splitTarget.browserMenuItems(initialURL: url.absoluteString).forEach(menu.addItem)
            case .file(let url):
                surface.splitTarget.fileMenuItems(path: url.path).forEach(menu.addItem)
            }
        }
        menu.addItem(.separator())
        surface.splitTarget.menuItems().forEach(menu.addItem)
        return menu
    }
}

@MainActor
private final class TerminalCommandBlockMenuTarget: NSObject, NSMenuItemValidation {
    private weak var surface: (any TerminalBackendSurface)?
    private let location: TerminalCommandOutputLocation

    init(surface: any TerminalBackendSurface, location: TerminalCommandOutputLocation) {
        self.surface = surface
        self.location = location
    }

    func items() -> [NSMenuItem] {
        var actions: [(String, String, Selector)] = [
            ("zshell-copy-command", String(localized: "Copy Command"), #selector(copyCommand(_:))),
            ("zshell-copy-command-output", String(localized: "Copy Output"), #selector(copyOutput(_:))),
            ("zshell-copy-command-block", String(localized: "Copy Command Block"), #selector(copyBlock(_:))),
            ("zshell-select-command-output", String(localized: "Select Command Output"), #selector(selectOutput(_:))),
        ]
        if let entry = insertionEntry(), TerminalCommandHistoryActions.canInsert(entry) {
            actions.append(("zshell-insert-command", String(localized: "Insert at Prompt"), #selector(insertCommand(_:))))
        }
        return actions.map { identifier, title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.identifier = .init(identifier)
            item.target = self
            // NSMenuItem does not retain its target; retain the clicked block
            // independently of focus changes and subsequent terminal output.
            item.representedObject = self
            item.isEnabled = validateMenuItem(item)
            return item
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let surface, let region = surface.commandRegion(at: location) else { return false }
        switch menuItem.action {
        case #selector(copyOutput(_:)), #selector(selectOutput(_:)):
            return region.outputStart < region.outputEnd
        case #selector(insertCommand(_:)):
            return insertionEntry().map(TerminalCommandHistoryActions.canInsert) ?? false
        default:
            return true
        }
    }

    @objc private func copyCommand(_ sender: NSMenuItem) { copy(.command) }
    @objc private func copyOutput(_ sender: NSMenuItem) { copy(.output) }
    @objc private func copyBlock(_ sender: NSMenuItem) { copy(.wholeBlock) }

    private func copy(_ part: TerminalCommandTextPart) {
        guard let surface, surface.commandRegion(at: location) != nil,
              let text = surface.commandText(at: location, part: part), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let surface, let region = surface.commandRegion(at: location),
              region.outputStart < region.outputEnd else { return }
        surface.selectCommand(at: location)
    }

    @objc private func insertCommand(_ sender: NSMenuItem) {
        guard let entry = insertionEntry() else { return }
        TerminalCommandHistoryActions.insert(entry)
    }

    private func insertionEntry() -> TerminalCommandHistoryEntry? {
        guard let surface, surface.commandRegion(at: location) != nil,
              let session = surface.events as? TerminalSession, session.surface === surface,
              let record = surface.commandRecords.first(where: { $0.outputLocation == location }) else { return nil }
        return .init(record: record, terminalID: session.id)
    }
}
