import AppKit

nonisolated struct TerminalNextCommandNotification: Sendable {
    let request: TerminalNextCommandNotificationRequest
    let owner: ZshellAgentProcessIdentity
    let executable: String
    let arguments: [String]
    let directory: URL

    func isCurrent() -> Bool {
        owner.isAlive && processExecutablePath(pid: owner.pid) == executable && processArguments(pid: owner.pid) == arguments
            && TerminalNextCommandNotificationRequest.integrationID(in: directory, shellPID: owner.pid) == request.integrationID
    }
}

extension TerminalSession {
    var canNotifyWhenNextCommandFinishes: Bool { nextCommandNotificationContext != nil }

    private var nextCommandNotificationContext:
        (directory: URL, owner: ZshellAgentProcessIdentity, executable: String, arguments: [String], integrationID: UUID)?
    {
        guard !hasExited, !isTerminating, remoteConnection == nil, shellName == "zsh",
            let directory = commandTaskDirectoryURL?.deletingLastPathComponent(), let pid = shellPid,
            let owner = ZshellAgentProcessIdentity(pid: pid), let executable = processExecutablePath(pid: pid),
            (executable as NSString).lastPathComponent == "zsh",
            let arguments = processArguments(pid: pid),
            let integrationID = TerminalNextCommandNotificationRequest.integrationID(in: directory, shellPID: pid)
        else { return nil }
        return (directory, owner, executable, arguments, integrationID)
    }

    @discardableResult
    func armNextCommandNotification() -> Bool {
        guard let context = nextCommandNotificationContext else { return false }
        cancelNextCommandNotification()
        let request = TerminalNextCommandNotificationRequest(id: UUID(), shellPID: context.owner.pid, integrationID: context.integrationID)
        do { try request.arm(in: context.directory) } catch { return false }
        nextCommandNotification = .init(
            request: request, owner: context.owner, executable: context.executable, arguments: context.arguments,
            directory: context.directory)
        nextCommandNotificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.nextCommandNotification?.request.id == request.id else { return }
                self.observeNextCommandNotification()
            }
        }
        return true
    }

    func cancelNextCommandNotification() {
        nextCommandNotificationTask?.cancel()
        nextCommandNotificationTask = nil
        nextCommandNotificationReadID = nil
        if let directory = nextCommandNotification?.directory ?? commandTaskDirectoryURL?.deletingLastPathComponent() {
            TerminalNextCommandNotificationRequest.clear(in: directory)
        }
        nextCommandNotification = nil
    }

    func observeNextCommandNotification() {
        guard let notification = nextCommandNotification, nextCommandNotificationReadID != notification.request.id else { return }
        nextCommandNotificationReadID = notification.request.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let current = notification.isCurrent()
            let result = current ? notification.request.result(in: notification.directory) : nil
            Task { @MainActor [weak self] in
                guard let self, self.nextCommandNotificationReadID == notification.request.id else { return }
                self.nextCommandNotificationReadID = nil
                guard self.nextCommandNotification?.request.id == notification.request.id else { return }
                guard current, !self.hasExited, !self.isTerminating else { self.cancelNextCommandNotification(); return }
                guard let result else { return }
                self.cancelNextCommandNotification()
                TerminalNotificationService.shared.post(
                    message: result.message, sessionID: self.id, kind: .command,
                    eventKey: "command:\(result.command.id):\(result.command.sequence)", isFailure: result.command.exitCode != 0)
            }
        }
    }
}

@MainActor
final class TerminalNextCommandNotificationController: NSObject, NSMenuItemValidation {
    static let shared = TerminalNextCommandNotificationController()
    private final class SurfaceTarget {
        weak var surface: (any TerminalBackendSurface)?
        let sessionID: UUID?
        init(_ surface: any TerminalBackendSurface) {
            self.surface = surface
            sessionID = (surface.events as? TerminalSession)?.id
        }
    }

    func menuItem(for surface: (any TerminalBackendSurface)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(toggleNotification(_:)), keyEquivalent: "")
        item.identifier = .init("terminal-next-command-notification")
        item.target = self
        item.representedObject = surface.map(SurfaceTarget.init)
        refresh(item)
        return item
    }

    func refresh(_ item: NSMenuItem) { item.isEnabled = validateMenuItem(item) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = session(for: menuItem)
        let armed = session?.nextCommandNotification != nil
        menuItem.title =
            armed ? String(localized: "Cancel Next Command Notification") : String(localized: "Notify When Next Command Finishes")
        menuItem.state = armed ? .on : .off
        return armed || session?.canNotifyWhenNextCommandFinishes == true
    }

    @objc private func toggleNotification(_ sender: NSMenuItem) {
        guard let session = session(for: sender) else { return }
        if session.nextCommandNotification != nil {
            session.cancelNextCommandNotification()
        } else if !session.armNextCommandNotification() {
            NSSound.beep()
        }
        refresh(sender)
    }

    private func session(for item: NSMenuItem) -> TerminalSession? {
        let surface: (any TerminalBackendSurface)?
        if let target = item.representedObject as? SurfaceTarget {
            surface = target.surface
            guard (surface?.events as? TerminalSession)?.id == target.sessionID else { return nil }
        } else {
            surface = TerminalReadOnlyController.shared.surface(for: item)
        }
        guard let surface, let session = surface.events as? TerminalSession, session.surface === surface else { return nil }
        return session
    }
}
