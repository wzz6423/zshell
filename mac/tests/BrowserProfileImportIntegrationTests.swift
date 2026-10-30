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
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        let manager = TerminalManager()
        let backend = CommandLine.arguments[1]
        let mode = CommandLine.arguments[3]
        let cookieCount = Int(CommandLine.arguments[5])!
        let serverPort = Int(CommandLine.arguments[6])!
        precondition(AppSettings.shared.terminalBackend.rawValue == backend)
        guard let surface = manager.selectedProject?.selectedSession?.surface else { throw failure("Initial terminal surface missing") }
        precondition(backend == "libghostty" ? surface is ZshellTerminalView : surface is AlacrittyTerminalView)
        manager.projects.forEach { manager.close($0) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.identifier = NSUserInterfaceItemIdentifier("main-browser-import-fixture")
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        manager.attach(to: host)
        let endpoint = try SSHEndpoint(host: "127.0.0.1", port: Int(CommandLine.arguments[4])!)
        let remote = mode.hasPrefix("remote-")
        var project: Project?
        var neighbor: Project?
        if mode != "no-project" {
            let destination = Project(fallbackName: "Import fixture", manager: manager,
                                      location: remote ? .ssh(endpoint: endpoint, remoteDirectory: nil) : .local,
                                      createInitialSession: false)
            project = destination
            manager.projects.append(destination)
            manager.selectedProjectID = destination.id
        }
        if remote {
            let other = Project(fallbackName: "Other remote fixture", manager: manager,
                                location: .ssh(endpoint: endpoint, remoteDirectory: nil), createInitialSession: false)
            neighbor = other
            manager.projects.append(other)
        }
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
        let access = try button("Allow Access", in: panel)
        precondition(!access.isHidden && popup.numberOfItems == 1)
        precondition(descendants(panel.contentView).contains { ($0 as? NSTextField)?.stringValue == "To read Google Chrome data, choose Allow Access, then Open." })
        let preview = try button("Preview", in: panel)
        let importButton = try button("Import", in: panel)
        precondition(!importButton.isEnabled)
        preview.performClick(nil)
        _ = try waitValue("Preview completion") { importButton.isEnabled ? true : nil }
        let text = try waitValue("Preview content") { descendants(panel.contentView).compactMap { $0 as? NSTextView }.first }
        precondition(text.string.contains("Cookies: \(cookieCount)") && text.string.contains("History: 1") && text.string.contains("Open tabs: 2"))
        precondition(!text.string.contains("fixture-secret"))
        let destinationStore = project?.browserDataStore
        if remote {
            precondition(project?.tabs.isEmpty == true)
            check(try cookies(in: destinationStore!).isEmpty)
            check(try cookies(in: neighbor!.browserDataStore).isEmpty)
            check(try cookies(in: .default()).isEmpty)
        }
        let observer = CookieCloseObserver {
            if mode == "remote-close-writing", let project, !importButton.isEnabled {
                manager.close(project)
                return true
            }
            return false
        }
        if mode == "remote-close-writing" { destinationStore!.httpCookieStore.add(observer) }
        defer { destinationStore?.httpCookieStore.remove(observer) }
        importButton.performClick(nil)
        if mode == "remote-switch" {
            manager.selectedProjectID = neighbor!.id
        } else if mode == "remote-close-before" {
            manager.close(project!)
        } else if mode == "no-project" {
            project = manager.selectedProject
            precondition(project != nil && !project!.isRemote)
            let other = Project(fallbackName: "Later remote fixture", manager: manager,
                                location: .ssh(endpoint: endpoint, remoteDirectory: nil), createInitialSession: false)
            neighbor = other
            manager.projects.append(other)
            manager.selectedProjectID = other.id
        }
        if mode.hasPrefix("remote-close-") {
            _ = try waitValue("Closed destination report") { text.string.contains("The destination project is no longer available.") ? true : nil }
            precondition(importButton.isEnabled == false && preview.isEnabled)
            precondition(manager.selectedProjectID == neighbor!.id && manager.projects.count == 1)
            precondition(neighbor!.tabs.isEmpty && project!.tabs.isEmpty)
            check(try cookies(in: neighbor!.browserDataStore).isEmpty)
            check(try cookies(in: .default()).isEmpty)
            let written = try cookies(in: destinationStore!).count
            precondition(mode == "remote-close-before" ? written == 0 : observer.didClose && written > 0 && written < cookieCount)
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            check(try cookies(in: destinationStore!).count == written)
            print("PASS \(backend) \(mode): closed project stopped import after \(written) writes; neighboring and local stores remained empty")
            return
        }
        _ = try waitValue("Import completion") { text.string.contains("Tabs opened: 2") ? true : nil }
        precondition(text.string.contains("Cookies imported: \(cookieCount), skipped: 0"))
        precondition(text.string.contains("History imported: 1, skipped: 0"))
        let history = try BrowserImportedHistoryStore.load()
        precondition(history.count == 1 && history[0].title == "History fixture")
        let permissions = try FileManager.default.attributesOfItem(atPath: BrowserImportedHistoryStore.file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let urls = try waitValue("Opened tab order") {
            let urls = project!.tabs.flatMap(\.browsers).compactMap(\.snapshotURL)
            return urls.count == 2 ? urls : nil
        }
        precondition(urls[0].hasSuffix("/fixture") && urls[1].hasSuffix("/fixture-second"))
        for browser in project!.tabs.flatMap(\.browsers) {
            _ = try waitValue("Imported page load") {
                browser.errorMessage == nil && browser.webView.title == "Fixture" && !browser.navigationIsLoading ? true : nil
            }
        }
        if remote {
            let stored = try cookies(in: project!.browserDataStore)
            precondition(stored.count == cookieCount)
            precondition(stored.contains { $0.name == "fixture_localhost" && $0.domain == BrowserRemoteRouting.aliasHost && $0.isHTTPOnly })
            precondition(stored.contains { $0.name == "fixture_login" && $0.domain == "127-0-0-1." + BrowserRemoteRouting.aliasHost })
            precondition(stored.contains { $0.name == "fixture_loopback2" && $0.domain == "127-0-0-2." + BrowserRemoteRouting.aliasHost })
            precondition(stored.contains { $0.name == "fixture_public" && $0.domain == ".example.test" })
            precondition(stored.contains { $0.name == "__Host-fixture_secure" && $0.domain == BrowserRemoteRouting.aliasHost && $0.isSecure && $0.isHTTPOnly && $0.sameSitePolicy?.rawValue.lowercased() == "none" })
            precondition(manager.selectedProjectID == neighbor!.id && neighbor!.tabs.isEmpty)
            check(try cookies(in: neighbor!.browserDataStore).isEmpty)
            check(try cookies(in: .default()).isEmpty)
            let local = Project(fallbackName: "Local isolation fixture", manager: manager, createInitialSession: false)
            manager.projects.append(local)
            let localBrowser = local.newBrowserTab(initialURL: "http://127.0.0.1:\(serverPort)/isolation-local", initialFocus: .none, focus: false)
            _ = try waitValue("Isolated local page load") { localBrowser.webView.title == "Fixture" && !localBrowser.navigationIsLoading ? true : nil }
            check(try cookies(in: local.browserDataStore).isEmpty)
        } else {
            let shared = Project(fallbackName: "Shared local fixture", manager: manager, createInitialSession: false)
            check(try cookies(in: shared.browserDataStore).contains { $0.name == "fixture_login" && $0.value == "fixture-secret" && $0.domain == "127.0.0.1" })
            if let neighbor {
                precondition(neighbor.tabs.isEmpty && manager.selectedProjectID == neighbor.id)
                check(try cookies(in: neighbor.browserDataStore).isEmpty)
            }
        }
        print("PASS \(backend) \(mode): AppKit menu/preview/import, pinned project store, Cookie attributes, private history and session tabs")
    }

    @MainActor private static func cookies(in dataStore: WKWebsiteDataStore) throws -> [HTTPCookie] {
        var result: [HTTPCookie]?
        dataStore.httpCookieStore.getAllCookies { result = $0 }
        return try waitValue("Cookie store read") { result }
    }

    private static func check(_ condition: Bool) { precondition(condition) }

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

@MainActor
private final class CookieCloseObserver: NSObject, WKHTTPCookieStoreObserver {
    private let close: () -> Bool
    private(set) var didClose = false

    init(close: @escaping () -> Bool) { self.close = close }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        if !didClose { didClose = close() }
    }
}
