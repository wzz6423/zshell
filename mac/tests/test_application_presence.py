"""Exercise production presence policy and window delegate forwarding in AppKit."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HARNESS = r'''
import AppKit
import Combine

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var applicationPresence = ApplicationPresence.dockOnly
    var quickTerminalEnabled = true
}
@MainActor enum TerminalManager {
    static var opens = 0
    static func showWorkspace() { opens += 1 }
    static func prepareForApplicationQuit(endAll: Bool = false) {}
}
@MainActor final class GlobalTerminalOverlay {
    static let shared = GlobalTerminalOverlay()
    var toggles = 0
    func toggle() { toggles += 1 }
}
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    var opens = 0
    func show() { opens += 1 }
}
@MainActor final class Updater {
    static let shared = Updater()
    var canCheckForUpdates = true
    var isUpdating = false
    var checks = 0
    var updateActionTitle = "Check for Updates…"
    func checkForUpdates() { checks += 1 }
}
@MainActor final class OriginalDelegate: NSObject, NSWindowDelegate {
    var allowsClose = true
    var closes = 0
    var resizes = 0
    func windowShouldClose(_ window: NSWindow) -> Bool { allowsClose }
    func windowWillClose(_ notification: Notification) { closes += 1 }
    func windowDidResize(_ notification: Notification) { resizes += 1 }
    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        NSSize(width: size.width + 11, height: size.height + 7)
    }
}

@main struct PresenceProbe {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    @MainActor static func makeWindow(_ owner: ApplicationPresenceController, _ delegate: OriginalDelegate) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        owner.attach(to: window)
        return window
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        let owner = ApplicationPresenceController.shared
        owner.start()
        settle()
        precondition(NSApp.activationPolicy() == .regular)

        let firstDelegate = OriginalDelegate()
        let first = makeWindow(owner, firstDelegate)
        let proxy = first.delegate!
        owner.attach(to: first)
        precondition(first.delegate === proxy)
        precondition(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        proxy.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: first))
        precondition(firstDelegate.resizes == 1)
        let adjusted = proxy.windowWillResize?(first, to: NSSize(width: 300, height: 200))
        precondition(adjusted == NSSize(width: 311, height: 207))

        AppSettings.shared.applicationPresence = .dockAndMenuBar
        settle()
        precondition(NSApp.activationPolicy() == .regular)
        let statusItem = Mirror(reflecting: owner).children
            .compactMap { $0.value as? NSStatusItem }.first!
        precondition(statusItem.isVisible)
        precondition(statusItem.button?.window?.isVisible == true)
        precondition(statusItem.button?.image?.isTemplate == true)
        precondition(proxy.windowShouldClose?(first) == false)
        precondition(firstDelegate.closes == 0)

        let secondDelegate = OriginalDelegate()
        let second = makeWindow(owner, secondDelegate)
        firstDelegate.allowsClose = false
        precondition(proxy.windowShouldClose?(first) == false)
        firstDelegate.allowsClose = true
        precondition(proxy.windowShouldClose?(first) == true)
        first.close()
        precondition(firstDelegate.closes == 1)
        precondition(second.delegate?.windowShouldClose?(second) == false)

        AppSettings.shared.applicationPresence = .menuBarOnly
        settle()
        precondition(NSApp.activationPolicy() == .accessory)
        precondition(second.delegate?.windowShouldClose?(second) == false)
        let menu = statusItem.menu!
        owner.menuNeedsUpdate(menu)
        precondition(menu.items.count == 8)
        for index in [0, 1, 3, 4] { menu.performActionForItem(at: index) }
        precondition(TerminalManager.opens == 1)
        precondition(GlobalTerminalOverlay.shared.toggles == 1)
        precondition(SettingsWindowController.shared.opens == 1)
        precondition(Updater.shared.checks == 1)
        Updater.shared.isUpdating = true
        precondition(!owner.validateMenuItem(menu.item(at: 4)!))
        Updater.shared.isUpdating = false
        Updater.shared.canCheckForUpdates = false
        precondition(!owner.validateMenuItem(menu.item(at: 4)!))
        precondition(owner.validateMenuItem(menu.item(at: 0)!))
        AppSettings.shared.quickTerminalEnabled = false
        owner.menuNeedsUpdate(menu)
        precondition(!menu.items.contains { $0.title == "Quick Terminal" })
        AppSettings.shared.quickTerminalEnabled = true
        owner.menuNeedsUpdate(menu)
        precondition(menu.items.contains { $0.title == "Quick Terminal" })

        AppSettings.shared.applicationPresence = .dockOnly
        settle()
        precondition(NSApp.activationPolicy() == .regular)
        precondition(second.delegate?.windowShouldClose?(second) == true)
        AppSettings.shared.applicationPresence = .menuBarOnly
        settle()
        owner.prepareForTermination()
        precondition(second.delegate?.windowShouldClose?(second) == true)
        owner.stop()
        precondition(second.delegate === secondDelegate)
        second.close()
        precondition(secondDelegate.closes == 1)
        print("presence policy, two-window close behavior, delegate forwarding, menu routing, update validation and quit passed")
    }
}
'''


class ApplicationPresenceTests(unittest.TestCase):
    def test_appkit_presence_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="zshell-presence-test-") as temporary:
            root = Path(temporary)
            harness = root / "Harness.swift"
            harness.write_text(HARNESS)
            binary = root / "PresenceProbe"
            compiled = subprocess.run([
                "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
                str(REPO / "mac/zshell/ApplicationPresenceController.swift"),
                str(harness), "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("delegate forwarding", result.stdout)


if __name__ == "__main__":
    unittest.main()
