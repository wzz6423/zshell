import AppKit
import WebKit
@testable import zshell

@main
struct BrowserProfileImportIntegrationTests {
    @MainActor static func main() throws {
        let expectedHome = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
        precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == expectedHome)
        precondition(AgentUsagePaths.applicationSupportDirectory.standardizedFileURL.path.hasPrefix(expectedHome + "/"))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AppLocalization.apply(.english)
        let manager = TerminalManager()
        let backend = CommandLine.arguments[1]
        precondition(AppSettings.shared.terminalBackend.rawValue == backend)
        guard let surface = manager.selectedProject?.selectedSession?.surface else { throw failure("Initial terminal surface missing") }
        precondition(backend == "libghostty" ? surface is ZshellTerminalView : surface is AlacrittyTerminalView)
        manager.projects.forEach { manager.close($0) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.identifier = NSUserInterfaceItemIdentifier("main-browser-import-fixture")
        host.makeKeyAndOrderFront(nil)
        manager.attach(to: host)
        let project = Project(fallbackName: "Import fixture", manager: manager, createInitialSession: false)
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        defer {
            manager.projects.forEach { manager.close($0) }
            host.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        let menu = NSMenu()
        let browserItem = NSMenuItem(title: "Browser", action: nil, keyEquivalent: "")
        browserItem.submenu = NSMenu(title: "Browser")
        menu.addItem(browserItem)
        BrowserProfileImportController.shared.installMenu(in: menu)
        guard let item = browserItem.submenu?.items.first(where: { $0.identifier?.rawValue == "browser-profile-import" }),
              let action = item.action else { throw failure("Import menu was not installed") }
        app.sendAction(action, to: item.target, from: item)
        let panel = try waitValue("Import window") { app.windows.compactMap { $0 as? NSPanel }.first { $0.title == "Browser Data Import" && $0.isVisible } }
        let popup = try waitValue("Profile discovery") { descendants(panel.contentView).compactMap { $0 as? NSPopUpButton }.first { $0.numberOfItems > 0 } }
        precondition(popup.titleOfSelectedItem?.contains("Fixture Firefox") == true)
        let access = try button("Allow Access…", in: panel)
        precondition(!access.isHidden && popup.numberOfItems == 1)
        precondition(descendants(panel.contentView).contains { ($0 as? NSTextField)?.stringValue == "To read Google Chrome data, choose Allow Access…, then Open." })
        let preview = try button("Preview", in: panel)
        let importButton = try button("Import", in: panel)
        precondition(!importButton.isEnabled)
        preview.performClick(nil)
        _ = try waitValue("Preview completion") { importButton.isEnabled ? true : nil }
        let text = try waitValue("Preview content") { descendants(panel.contentView).compactMap { $0 as? NSTextView }.first }
        precondition(text.string.contains("Cookies: 1") && text.string.contains("History: 1") && text.string.contains("Open tabs: 2"))
        precondition(!text.string.contains("fixture-secret"))
        importButton.performClick(nil)
        _ = try waitValue("Import completion") { text.string.contains("Tabs opened: 2") ? true : nil }
        precondition(text.string.contains("Cookies imported: 1, skipped: 0"))
        precondition(text.string.contains("History imported: 1, skipped: 0"))
        let history = try BrowserImportedHistoryStore.load()
        precondition(history.count == 1 && history[0].title == "History fixture")
        let mode = try FileManager.default.attributesOfItem(atPath: BrowserImportedHistoryStore.file.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600)
        let urls = try waitValue("Opened tab order") {
            let urls = project.tabs.flatMap(\.browsers).compactMap(\.snapshotURL)
            return urls.count == 2 ? urls : nil
        }
        precondition(urls[0].hasSuffix("/fixture") && urls[1].hasSuffix("/fixture-second"))
        let browser = project.tabs.flatMap(\.browsers)[0]
        _ = try waitValue("Local page load") {
            browser.webView.title == "Fixture" && !browser.webView.isLoading ? true : nil
        }
        print("AppKit menu, preview, cookie write, private history and session tab passed")
    }

    @MainActor private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private static func button(_ title: String, in panel: NSPanel) throws -> NSButton {
        guard let button = descendants(panel.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            throw failure("Missing button: \(title)")
        }
        return button
    }

    @MainActor private static func waitValue<T>(_ label: String, _ body: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let value = body() { return value }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        throw failure("Timed out waiting for \(label)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BrowserProfileImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
