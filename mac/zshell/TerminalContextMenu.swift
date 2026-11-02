import AppKit

@MainActor
enum TerminalContextMenu {
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
