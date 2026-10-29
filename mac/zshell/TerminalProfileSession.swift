import AppKit

nonisolated enum TerminalProfileSelection: Equatable {
    case automatic
    case original
    case profile(UUID)
}

extension TerminalSession {
    var terminalProfileContext: TerminalProfileContext {
        if let connection = remoteConnection {
            guard remoteStatus?.state == .connected else { return .init() }
            var context = remoteStatus?.profileContext ?? .init()
            // Older servers have no process metadata. Only the configured
            // connection target is known; relay PIDs describe this Mac.
            switch try? connection.host.endpoint() {
            case .ssh(let endpoint):
                context.hostAlias = endpoint.host
                if context.host == nil { context.host = endpoint.host }
                if context.user == nil { context.user = endpoint.user }
            case .tailscale(let host, _):
                context.hostAlias = host
                if context.host == nil { context.host = host }
            case nil:
                break
            }
            return context
        }
        if case .ssh(let endpoint, _, _) = remotePasteTarget {
            return .init(host: endpoint.host, user: endpoint.user)
        }
        if remotePasteTarget == .unavailable { return .init() }
        let pid = surface.foregroundPid ?? shellPid
        return .init(
            host: ProcessInfo.processInfo.hostName,
            user: pid.flatMap(processEffectiveUser(pid:)),
            directory: foregroundDirectoryPath ?? currentDirectoryPath,
            program: pid.flatMap(processExecutablePath(pid:)),
            hostAlias: "localhost"
        )
    }
}

@MainActor
final class TerminalProfileMenuTarget: NSObject {
    weak var session: TerminalSession?

    func menuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Terminal Profiles"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: parent.title)
        menu.autoenablesItems = false
        let automatic = item(String(localized: "Automatic"), #selector(selectAutomatic))
        automatic.state = session?.terminalProfileSelection == .automatic ? .on : .off
        menu.addItem(automatic)
        let original = item(String(localized: "Original Settings"), #selector(selectOriginal))
        original.state = session?.terminalProfileSelection == .original ? .on : .off
        menu.addItem(original)
        menu.addItem(.separator())
        for profile in AppSettings.shared.terminalProfiles {
            let entry = item(profile.name, #selector(selectProfile(_:)))
            entry.representedObject = profile.id.uuidString
            entry.state = session?.activeTerminalProfileID == profile.id ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Manage Terminal Profiles…"), #selector(manageProfiles)))
        parent.submenu = menu
        return parent
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectAutomatic() { session?.selectTerminalProfile(.automatic) }
    @objc private func selectOriginal() { session?.selectTerminalProfile(.original) }
    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        session?.selectTerminalProfile(.profile(id))
    }
    @objc private func manageProfiles() {
        TerminalProfileEditor.show(relativeTo: session?.surface.window)
    }
}
