import AppKit

@MainActor
final class TerminalReadOnlyController: NSObject, NSMenuItemValidation {
    static let shared = TerminalReadOnlyController()
    static let didChange = Notification.Name("zshell.terminalReadOnlyDidChange")

    static var rejectionMessage: String {
        String(localized: "This terminal is read only. Unlock it before sending input.")
    }

    func menuItem(for surface: (any TerminalBackendSurface)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Read Only"), action: #selector(toggleReadOnly(_:)), keyEquivalent: "")
        item.identifier = .init("terminal-read-only")
        item.target = self
        item.representedObject = surface
        item.isEnabled = validateMenuItem(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let surface = surface(for: menuItem)
        menuItem.state = surface?.isReadOnly == true ? .on : .off
        return surface != nil
    }

    @objc private func toggleReadOnly(_ sender: NSMenuItem) {
        guard let surface = surface(for: sender) else { return }
        surface.isReadOnly.toggle()
        sender.state = surface.isReadOnly ? .on : .off
    }

    func surface(for item: NSMenuItem) -> (any TerminalBackendSurface)? {
        if let surface = item.representedObject as? any TerminalBackendSurface { return surface }
        guard let window = NSApp.keyWindow else { return nil }
        var view = window.firstResponder as? NSView
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        while let current = view {
            if let surface = current as? any TerminalBackendSurface { return surface }
            if let container = current as? TerminalContainerView,
                let surface = container.terminal as? any TerminalBackendSurface, surface.window === window
            {
                return surface
            }
            view = current.superview
        }
        if let session = GlobalTerminalOverlay.shared.focusedPromptQueueSession, session.surface.window === window {
            return session.surface
        }
        if case .session(let session)? = TerminalManager.activeWindowManager?.selectedProject?.focusedContent,
            session.find.isPresented, session.surface.window === window
        {
            return session.surface
        }
        return nil
    }
}
