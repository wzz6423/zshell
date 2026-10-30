import AppKit

@MainActor
final class TerminalHintMenu: NSObject, NSMenuItemValidation {
    static let shared = TerminalHintMenu()
    private var shortcutMonitor: Any?

    func install(in mainMenu: NSMenu) {
        guard let menu = mainMenu.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.action.map(NSStringFromSelector) == "toggleQuickTerminal" }
        }) else { return }
        for item in items(for: nil) {
            if let existing = menu.items.first(where: { $0.identifier == item.identifier }) {
                if existing.title != item.title { existing.title = item.title }
            } else { menu.addItem(item) }
        }
        installShortcutMonitor()
    }

    func items(for surface: (any TerminalBackendSurface)?) -> [NSMenuItem] {
        let copy = NSMenuItem(title: String(localized: "Copy Terminal Hint…"), action: #selector(copyHint(_:)), keyEquivalent: surface == nil ? "h" : "")
        copy.identifier = .init("zshell-copy-terminal-hint")
        copy.keyEquivalentModifierMask = [.command, .shift]
        let open = NSMenuItem(title: String(localized: "Open Terminal Hint…"), action: #selector(openHint(_:)), keyEquivalent: surface == nil ? "h" : "")
        open.identifier = .init("zshell-open-terminal-hint")
        open.keyEquivalentModifierMask = [.command, .option]
        for item in [copy, open] {
            item.target = self
            // Context menus belong to the clicked pane, even if the menu's
            // tracking temporarily moves keyboard focus elsewhere.
            item.representedObject = surface
        }
        return [copy, open]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { surface(for: menuItem) != nil }
    @objc private func copyHint(_ sender: NSMenuItem) { surface(for: sender)?.hintMode.present(action: .copy) }
    @objc private func openHint(_ sender: NSMenuItem) { surface(for: sender)?.hintMode.present(action: .open) }

    private func surface(for item: NSMenuItem) -> (any TerminalBackendSurface)? {
        if let surface = item.representedObject as? any TerminalBackendSurface { return surface }
        return NSApp.keyWindow?.firstResponder as? any TerminalBackendSurface
    }

    private func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        // AppKit's Hide Others owns Cmd-Option-H before menu equivalents.
        // Resolve hint chords only while the terminal accepts workspace commands.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            assumeMainActor {
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard event.charactersIgnoringModifiers?.lowercased() == "h",
                      flags == [.command, .shift] || flags == [.command, .option],
                      let surface = (event.window ?? NSApp.keyWindow)?.firstResponder as? any TerminalBackendSurface,
                      !surface.commandRouting.blocksCommands else { return event }
                surface.hintMode.present(action: flags.contains(.shift) ? .copy : .open, triggeredBy: event)
                return surface.hintMode.isPresented ? nil : event
            }
        }
    }
}
