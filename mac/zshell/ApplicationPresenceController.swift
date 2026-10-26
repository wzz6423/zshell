import AppKit
import Combine

enum ApplicationPresence: String, CaseIterable {
    case dockOnly = "dock"
    case dockAndMenuBar = "dock-and-menu-bar"
    case menuBarOnly = "menu-bar"

    var showsMenuBarItem: Bool { self != .dockOnly }

    var title: String {
        switch self {
        case .dockOnly: String(localized: "Dock Only")
        case .dockAndMenuBar: String(localized: "Dock and Menu Bar")
        case .menuBarOnly: String(localized: "Menu Bar Only")
        }
    }
}

@MainActor
final class ApplicationPresenceController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = ApplicationPresenceController()

    private var statusItem: NSStatusItem?
    private var settingsObservation: AnyCancellable?
    private var windowDelegates: [ObjectIdentifier: PresenceWindowDelegate] = [:]
    private var isTerminating = false

    func start() {
        guard settingsObservation == nil else { return }
        settingsObservation = AppSettings.shared.$applicationPresence
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in self?.apply(presence) }
        apply(AppSettings.shared.applicationPresence)
    }

    func attach(to window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let proxy = windowDelegates[key], window.delegate === proxy { return }
        let proxy = PresenceWindowDelegate(window: window, original: window.delegate, owner: self)
        windowDelegates[key] = proxy
        window.delegate = proxy
    }

    func prepareForTermination() {
        isTerminating = true
    }

    func stop() {
        settingsObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        for proxy in windowDelegates.values {
            if proxy.window?.delegate === proxy { proxy.window?.delegate = proxy.original }
        }
        windowDelegates = [:]
    }

    private func apply(_ presence: ApplicationPresence) {
        // Install a way back to the workspace before removing its Dock icon.
        if presence.showsMenuBarItem, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Zshell")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "Zshell"
            item.button?.setAccessibilityLabel("Zshell")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        let policy: NSApplication.ActivationPolicy = presence == .menuBarOnly ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        if !presence.showsMenuBarItem, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    fileprivate func shouldKeepWindow(_ window: NSWindow) -> Bool {
        guard !isTerminating, AppSettings.shared.applicationPresence.showsMenuBarItem else { return false }
        windowDelegates = windowDelegates.filter { $0.value.window != nil }
        return !windowDelegates.values.contains { $0.window !== window && $0.window != nil }
    }

    fileprivate func didClose(_ window: NSWindow) {
        windowDelegates.removeValue(forKey: ObjectIdentifier(window))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(String(localized: "Open Workspace"), action: #selector(openWorkspace), to: menu)
        addItem(String(localized: "Quick Terminal"), action: #selector(toggleQuickTerminal), to: menu)
        menu.addItem(.separator())
        addItem(String(localized: "Settings…"), action: #selector(showSettings), to: menu)
        addItem(Updater.shared.updateActionTitle, action: #selector(checkForUpdates), to: menu)
        menu.addItem(.separator())
        addItem(String(localized: "Quit and End All Sessions"), action: #selector(quitAndEndAllSessions), to: menu)
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Zshell"
        addItem(String(localized: "Quit \(appName)"), action: #selector(quit), to: menu)
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates)
            || (Updater.shared.canCheckForUpdates && !Updater.shared.isUpdating)
    }

    @objc private func openWorkspace() { TerminalManager.showWorkspace() }
    @objc private func toggleQuickTerminal() { GlobalTerminalOverlay.shared.toggle() }
    @objc private func showSettings() { SettingsWindowController.shared.show() }
    @objc private func checkForUpdates() {
        NSApp.activate()
        Updater.shared.checkForUpdates()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func quitAndEndAllSessions() {
        TerminalManager.prepareForApplicationQuit(endAll: true)
        NSApp.terminate(nil)
    }
}

/// SwiftUI owns the main window delegate. Forward every other selector so its
/// restoration, sizing, fullscreen, and focus callbacks keep their owner.
@MainActor
private final class PresenceWindowDelegate: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    weak var original: NSWindowDelegate?
    private weak var owner: ApplicationPresenceController?

    init(window: NSWindow, original: NSWindowDelegate?, owner: ApplicationPresenceController) {
        self.window = window
        self.original = original
        self.owner = owner
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        guard owner?.shouldKeepWindow(sender) == true else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let window { owner?.didClose(window) }
    }
}
