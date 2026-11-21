import AppKit
import UniformTypeIdentifiers

nonisolated private final class TerminalOutputExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: TerminalHistorySerializer.LogCapture?
    private var cancelled = false

    init(_ capture: TerminalHistorySerializer.LogCapture) { self.capture = capture }

    func cancel() -> TerminalHistorySerializer.LogCapture? {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        let capture = self.capture
        self.capture = nil
        return capture
    }

    func read() -> String? {
        lock.lock()
        let capture = self.capture
        self.capture = nil
        lock.unlock()
        return capture?.read()
    }

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class TerminalOutputExportController: NSObject, NSMenuItemValidation {
    static let shared = TerminalOutputExportController()
    private let worker = DispatchQueue(label: "sh.zshell.terminal-output-export", qos: .userInitiated)
    private let makeSavePanel: @MainActor () -> NSSavePanel
    private struct Export {
        let panel: NSSavePanel
        let job: TerminalOutputExportJob
        let observations: [NSObjectProtocol]
    }
    nonisolated private enum Failure: Sendable { case read; case write(URL, String) }
    private var exports: [ObjectIdentifier: Export] = [:]

    init(makeSavePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() }) {
        self.makeSavePanel = makeSavePanel
        super.init()
    }

    isolated deinit { for id in Array(exports.keys) { cancel(id) } }

    func menuItem(for surface: any TerminalBackendSurface) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "Save Terminal Output…"),
            action: #selector(saveTerminalOutput(_:)), keyEquivalent: "")
        item.identifier = .init("zshell-save-terminal-output")
        item.target = self
        item.representedObject = surface
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let surface = menuItem.representedObject as? any TerminalBackendSurface else { return false }
        return canSave(from: surface)
    }

    func canSave() -> Bool { canSave(in: TerminalManager.activeWindowManager) }
    func save() { save(in: TerminalManager.activeWindowManager) }

    func canSave(in manager: TerminalManager?) -> Bool {
        focusedSurface(in: manager).map(canSave(from:)) ?? false
    }
    func save(in manager: TerminalManager?) {
        if let surface = focusedSurface(in: manager) { save(from: surface) }
    }

    private func focusedSurface(in manager: TerminalManager?) -> (any TerminalBackendSurface)? {
        guard let window = NSApp.keyWindow else { return nil }
        if let manager, manager.presentationWindow === window {
            if case .session(let session)? = manager.selectedProject?.focusedContent { return session.surface }
            return nil
        }
        let responder = window.firstResponder
        var view =
            (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
            ?? responder as? NSView
        while let current = view {
            if let surface = current as? any TerminalBackendSurface { return surface }
            if let container = current as? TerminalContainerView { return container.terminal as? any TerminalBackendSurface }
            view = current.superview
        }
        return nil
    }

    func canSave(from surface: any TerminalBackendSurface) -> Bool {
        guard let window = surface.window else { return false }
        return window.attachedSheet == nil && exports[ObjectIdentifier(window)] == nil
    }

    @objc private func saveTerminalOutput(_ sender: NSMenuItem) {
        if let surface = sender.representedObject as? any TerminalBackendSurface { save(from: surface) }
    }

    func save(from surface: any TerminalBackendSurface) {
        guard canSave(from: surface), let host = surface.window else { return }
        // Bind the snapshot before presenting the panel; its completion must
        // never recapture a different pane or newer output.
        guard let capture = TerminalHistorySerializer.takeLogCapture(from: surface) else {
            present(.read, on: host)
            return
        }
        let panel = makeSavePanel()
        panel.title = String(localized: "Save Terminal Output…")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "terminal-output.txt"
        panel.canCreateDirectories = true
        let id = ObjectIdentifier(host)
        let job = TerminalOutputExportJob(capture)
        let observations = [NSWindow.willCloseNotification, NSApplication.willTerminateNotification].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: name == NSWindow.willCloseNotification ? host : nil,
                queue: .main
            ) { [weak self] _ in
                assumeMainActor { [weak self] in self?.cancel(id) }
            }
        }
        exports[id] = Export(panel: panel, job: job, observations: observations)
        panel.beginSheetModal(for: host) { [weak self, weak host] response in
            guard let self, self.exports[id]?.job === job else { return }
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else { self.cancel(id); return }
            self.worker.async { [weak self, weak host] in
                let text = job.read()
                var failure: Failure?
                if !job.isCancelled() {
                    if let text {
                        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                            failure = .write(url, error.localizedDescription)
                        }
                    } else {
                        failure = .read
                    }
                }
                let result = failure
                DispatchQueue.main.async { [weak self, weak host] in
                    guard let self, self.finish(id, job: job), !job.isCancelled(),
                        let failure = result, let host, host.isVisible
                    else { return }
                    self.present(failure, on: host)
                }
            }
        }
    }

    private func finish(_ id: ObjectIdentifier, job: TerminalOutputExportJob) -> Bool {
        guard exports[id]?.job === job, let export = exports.removeValue(forKey: id) else { return false }
        export.observations.forEach(NotificationCenter.default.removeObserver)
        return true
    }

    private func cancel(_ id: ObjectIdentifier) {
        guard let export = exports.removeValue(forKey: id) else { return }
        export.observations.forEach(NotificationCenter.default.removeObserver)
        if let capture = export.job.cancel() { worker.async { capture.discard() } }
        export.panel.cancel(nil)
    }

    private func present(_ failure: Failure, on host: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.window.identifier = .init("terminal-output-export-error")
        alert.messageText = String(localized: "Couldn’t Save Terminal Output")
        switch failure {
        case .read: alert.informativeText = String(localized: "The terminal output could not be read.")
        case let .write(url, detail):
            alert.informativeText =
                String(
                    localized: "The terminal output could not be written to “\(url.path)”.",
                    comment: "The placeholder is the chosen terminal output file's local path.") + "\n\n" + detail
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: host)
    }
}
