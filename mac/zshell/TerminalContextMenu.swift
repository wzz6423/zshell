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
        let menu = make(for: surface, linkTarget: linkTarget)
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: surface)
        } else {
            menu.popUp(positioning: menu.items.first, at: NSPoint(x: 12, y: surface.bounds.maxY - 12), in: surface)
        }
    }

    static func make(for surface: any TerminalBackendSurface, linkTarget: TerminalLinkTarget?) -> NSMenu {
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
