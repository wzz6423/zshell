import AppKit
import WebKit
@testable import zshell

@main
struct BrowserWebExtensionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var complete = false
        var failure: Error?
        Task { @MainActor in
            do { try await verify() } catch { failure = error }
            complete = true
        }
        let deadline = Date().addingTimeInterval(90)
        while !complete && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if let failure {
            let detail = failure as NSError
            fputs("\(detail.domain) \(detail.code): \(detail.localizedDescription) \(detail.userInfo)\n", stderr)
            exit(1)
        }
        guard complete else { fputs("Extension tests timed out.\n", stderr); exit(1) }
    }

    @MainActor private static func verify() async throws {
        let base = CommandLine.arguments[1]
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        try require(!home.isEmpty && AgentUsagePaths.applicationSupportDirectory.path.hasPrefix(home + "/"), "Probe must not use the user's browser storage")
        let store = BrowserWebExtensionStore.shared
        AppSettings.shared.browserContentBlocking = false
        if CommandLine.arguments.last == "persistence" {
            try require(store.entries.count == 1 && !store.entries[0].isEnabled, "Installed extension state did not survive restart")
            print("Extension installation and disabled state survive restart: passed")
            return
        }
        if CommandLine.arguments.count > 3, CommandLine.arguments[3] == "ssh" {
            try await verifySSH(fixture)
            return
        }
        if CommandLine.arguments.count > 3, ["events", "retry", "warning"].contains(CommandLine.arguments[3]) {
            try await verifyReviewBoundaries(base, fixture: fixture, mode: CommandLine.arguments[3])
            return
        }
        let malformed = fixture.appendingPathComponent("malformed")
        do { _ = try await store.prepare(malformed); throw error("Invalid manifest installed") }
        catch BrowserWebExtensionStore.StoreError.invalid { }
        catch let value as NSError where value.domain == WKWebExtension.errorDomain { }
        let linked = fixture.appendingPathComponent("linked")
        do { _ = try await store.prepare(linked); throw error("Linked resource installed") }
        catch BrowserWebExtensionStore.StoreError.unsafeFiles { }
        let oversize = fixture.appendingPathComponent("oversize.zip")
        do { _ = try BrowserWebExtensionStore.validate(oversize); throw error("Oversized ZIP installed") }
        catch BrowserWebExtensionStore.StoreError.tooLarge { }
        do { _ = try BrowserWebExtensionStore.validate(fixture.appendingPathComponent("many")); throw error("Directory entry limit ignored") }
        catch BrowserWebExtensionStore.StoreError.tooLarge { }
        for archive in ["mismatch.zip", "traversal.zip", "linked.zip"] {
            do { _ = try BrowserWebExtensionStore.validate(fixture.appendingPathComponent(archive)); throw error("Unsafe archive accepted: \(archive)") }
            catch BrowserWebExtensionStore.StoreError.unsafeFiles { }
        }
        print("Invalid manifests, directory entry limits, linked resources and ZIP expansion/path/header limits reject installation: passed")

        let browser = BrowserTab(initialFocus: .none)
        let second = BrowserTab(initialFocus: .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main-webextensions-test")
        window.contentView = browser.webView
        window.makeKeyAndOrderFront(nil)
        defer { browser.close(); second.close(); window.orderOut(nil); window.contentView = nil }
        try require(browser.webView.configuration.webExtensionController === browser.webExtensions.controller,
                    "BrowserTab does not use the production extension controller")
        try require(browser.webExtensions === second.webExtensions, "Local browser panes do not share extension runtime")
        let (entry, webExtension) = try await store.prepare(fixture.appendingPathComponent("extension"))
        try require(entry.permissions.contains("storage") && entry.websites.contains("http://127.0.0.1/*"), "Required permissions are missing from installation preview")
        let alert = BrowserWebExtensionManager.permissionAlert(name: entry.name, details: entry.permissions + entry.websites, installing: true)
        try require(alert.buttons.first?.title == String(localized: "Install") && alert.accessoryView is NSScrollView,
                    "Installation permission confirmation is not available")
        try require(!browser.webExtensions.controller.extensions.contains(webExtension), "Prepared extension ran before explicit installation")
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("extension"))
        try store.install(entry)
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        try await load(browser, base + "/page?enabled")
        try await injected(browser)
        let saved = try await browser.webView.evaluateJavaScript("document.body.dataset.extensionVisits") as? String
        try require(saved == "1", "Extension background messaging/storage did not run: \(saved ?? "nil")")
        try require(!FileManager.default.fileExists(atPath: store.resourceURL(for: entry).path + ".outside"), "Installer wrote beyond extension directory")
        print("Production BrowserTab content scripts, background messaging and storage.local: passed")

        try await load(second, base + "/page?second")
        try await injected(second)
        let visits = try await second.webView.evaluateJavaScript("document.body.dataset.extensionVisits") as? String
        try require(visits == "2", "Extension storage is not shared within the same browser data store")
        let context = browser.webExtensions.controller.extensionContexts.first!
        let tab = browser.webExtensions.tabs.first { $0.browser === browser }!
        try require(tab.webView(for: context) === browser.webView && tab.window(for: context) != nil, "Production tab/window adapter missing")
        try require(!tab.shouldGrantPermissionsOnUserGesture(for: context), "Extension silently grants website permissions on a gesture")
        try require(context.grantedPermissions.keys.contains(WKWebExtension.Permission(rawValue: "storage")), "Approved API permissions not applied")
        try require(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "http://127.0.0.1/*" }, "Approved site permissions not applied")
        let menu = NSMenu()
        browser.webExtensions.menu(for: browser, into: menu)
        let item = menu.items.first { $0.identifier?.rawValue == "zshell.browser.extensions" }
        try require(item?.submenu?.items.contains { $0.title == entry.name } == true, "Native extension action menu missing")
        guard let action = context.action(for: tab) else { throw error("Extension action missing") }
        try require(action.presentsPopup && context.optionsPageURL != nil, "Manifest popup/options not exposed")
        tab.performAction(context)
        try await until { action.popupPopover?.isShown == true }
        guard let popup = action.popupWebView else { throw error("Popup WebKit view missing") }
        try await until { !popup.isLoading && popup.url != nil }
        let popupResult = try await popup.evaluateJavaScript("document.querySelector('#popup').textContent") as? String
        try require(popupResult == "Extension popup", "Extension popup did not load")
        let localNetwork = try await network(popup, base + "/extension-network?local-background", background: true)
        try require(localNetwork == "served", "Local extension background fetch failed")
        try await optionalPermission(context, tab: tab, window: window, script: "return await browser.permissions.request({permissions:['cookies']});", allowing: false)
        try require(!context.hasPermission(.init(rawValue: "cookies")), "Rejected optional API permission was granted")
        try await optionalPermission(context, tab: tab, window: window, script: "return await browser.permissions.request({origins:['http://optional.invalid/*']});", allowing: false)
        try require(!context.hasAccess(to: URL(string: "http://optional.invalid/")!), "Rejected optional website permission was granted")
        try await optionalPermission(context, tab: tab, window: window, script: "return await browser.permissions.request({permissions:['cookies']});", allowing: true)
        try require(context.hasPermission(.init(rawValue: "cookies")), "Accepted optional API permission was not applied")
        try await optionalPermission(context, tab: tab, window: window, script: "return await browser.permissions.request({origins:['http://optional.invalid/*']});", allowing: true)
        try require(context.hasAccess(to: URL(string: "http://optional.invalid/")!), "Accepted optional website permission was not applied")
        action.closePopup()
        print("Native action menu, real WebKit popup and optional API/website permission Cancel/Allow: passed")

        let (dnrEntry, _) = try await store.prepare(fixture.appendingPathComponent("dnr"))
        try store.install(dnrEntry)
        try await until { browser.webExtensions.controller.extensionContexts.count == 2 }
        try require(try await network(browser.webView, base + "/dnr-allowed?enabled", background: false) == "served", "DNR blocked an unrelated request")
        try require(try await network(browser.webView, base + "/dnr-blocked?enabled", background: false) == "blocked", "DNR did not block the matching real request")
        try await store.remove(id: dnrEntry.id)
        try require(try await network(browser.webView, base + "/dnr-blocked?disabled", background: false) == "served", "Removing DNR extension left its rule active")
        print("Real DNR blocks matching HTTP request, allows unrelated request and unloads on remove: passed")

        let (activeEntry, _) = try await store.prepare(fixture.appendingPathComponent("active-tab"))
        try store.install(activeEntry)
        try await until { browser.webExtensions.controller.extensionContexts.count == 2 }
        let activeContext = browser.webExtensions.controller.extensionContexts.first { $0.uniqueIdentifier == activeEntry.id.uuidString.lowercased() }!
        let currentURL = browser.webView.url!
        try require(!activeContext.hasAccess(to: currentURL, in: tab), "activeTab granted website access before invoking the extension")
        tab.performAction(activeContext)
        try require(activeContext.hasAccess(to: currentURL, in: tab), "Explicit extension action did not grant activeTab")
        let secondTab = browser.webExtensions.tabs.first { $0.browser === second }!
        try require(!activeContext.hasAccess(to: second.webView.url!, in: secondTab), "activeTab leaked into another pane")
        try await value(in: browser.webView, script: "document.body.dataset.extensionAction", equals: "done")
        let extra = BrowserTab(initialFocus: .none)
        try require(browser.webExtensions.controller.extensionContexts.contains(context), "Opening another pane replaced an existing extension context")
        extra.close()
        try await store.remove(id: activeEntry.id)
        print("Explicit extension action grants activeTab only to its pane and executes the production scripting API: passed")

        let remoteID = UUID()
        let endpoint = try SSHEndpoint(host: "example.invalid")
        let remote = BrowserRemoteRouting(location: .ssh(endpoint: endpoint, remoteDirectory: "/tmp"), storageID: remoteID)
        let remoteBrowser = BrowserTab(initialFocus: .none, remoteRouting: remote, projectID: remoteID)
        defer { remoteBrowser.close() }
        try await until { remoteBrowser.webExtensions.controller.extensionContexts.count == 1 }
        try require(remoteBrowser.webExtensions !== browser.webExtensions, "Remote extension runtime shares local background state")
        try require(remoteBrowser.webExtensions.controller.configuration.defaultWebsiteDataStore?.identifier == remoteID,
                    "Remote background uses another project's cookie storage")
        try require(remote.loopbackRules != nil, "Remote extension loaded before loopback guards")
        let remoteRuntime = remoteBrowser.webExtensions
        let remoteController = remoteRuntime.controller
        let remoteContext = remoteController.extensionContexts.first!
        let remoteTab = remoteRuntime.tabs.first!
        guard let remoteAction = remoteContext.action(for: remoteTab), let remotePopup = remoteAction.popupWebView else { throw error("Remote popup missing") }
        try await until { !remotePopup.isLoading && remotePopup.url != nil }
        let remoteBackground = try await network(remotePopup, base + "/extension-network?remote-background", background: true)
        let remotePopupResult = try await network(remotePopup, base + "/extension-network?remote-popup", background: false)
        try require(remoteBackground == "blocked" && remotePopupResult == "blocked", "A remote extension accessed the Mac's loopback service")
        let types = WKWebExtensionController.allExtensionDataTypes
        let remoteRecords = await remoteController.dataRecords(ofTypes: types)
        try require(remoteRecords.contains { $0.uniqueIdentifier == entry.id.uuidString.lowercased() && $0.totalSizeInBytes > 0 }, "Remote extension storage fixture was not written")
        remoteAction.closePopup()
        remoteBrowser.close()
        let anotherID = UUID()
        let another = BrowserRemoteRouting(location: .ssh(endpoint: endpoint, remoteDirectory: "/tmp"), storageID: anotherID)
        let otherBrowser = BrowserTab(initialFocus: .none, remoteRouting: another, projectID: anotherID)
        defer { otherBrowser.close() }
        try require(otherBrowser.webExtensions !== remoteBrowser.webExtensions, "Two remote projects share extension runtime")
        print("Real remote background and popup requests fail closed; project WebKit data stores remain isolated: passed")

        let manager = BrowserWebExtensionManager.shared
        manager.showOptions(context, relativeTo: window, runtime: browser.webExtensions)
        guard let options = window.childWindows?.first(where: { $0.title == entry.name }) else { throw error("Extension options window missing") }
        guard let optionsView = options.contentView?.subviews.compactMap({ $0 as? WKWebView }).first else { throw error("Options WebKit view missing") }
        try await until { !optionsView.isLoading && optionsView.url != nil }
        try await value(in: optionsView, script: "document.querySelector('p').textContent", equals: "Extension options")
        try store.setEnabled(false, id: entry.id)
        try require(!options.isVisible && optionsView.superview == nil, "Disabling extension left its options window running")
        try require(browser.webExtensions.controller.extensionContexts.isEmpty, "Disabled extension still runs")
        try await load(browser, base + "/page?disabled")
        let disabled = try await browser.webView.evaluateJavaScript("document.body.dataset.extensionVisits") as? String
        try require(disabled == nil, "Disabled extension still injects new pages")
        try store.setEnabled(true, id: entry.id)
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        let resetContext = browser.webExtensions.controller.extensionContexts.first!
        try require(!resetContext.hasPermission(.init(rawValue: "cookies")) && !resetContext.hasAccess(to: URL(string: "http://optional.invalid/")!),
                    "Reloading an extension retained optional grants without a new request")
        try await load(browser, base + "/page?reenabled")
        try await injected(browser)
        try await store.remove(id: entry.id)
        let removedRecords = await remoteController.dataRecords(ofTypes: types)
        try require(!removedRecords.contains { $0.uniqueIdentifier == entry.id.uuidString.lowercased() && $0.totalSizeInBytes > 0 }, "Closed controller retained extension storage")
        let freshController = WKWebExtensionController(configuration: .init(identifier: remoteID))
        let freshRecords = await freshController.dataRecords(ofTypes: types)
        try require(!freshRecords.contains { $0.uniqueIdentifier == entry.id.uuidString.lowercased() && $0.totalSizeInBytes > 0 }, "Removing extension left closed project's persistent storage behind")
        try require(browser.webExtensions.controller.extensionContexts.isEmpty && !FileManager.default.fileExists(atPath: store.resourceURL(for: entry).path),
                    "Removing extension did not unload and remove copied resources")
        let (archive, _) = try await store.prepare(fixture.appendingPathComponent("extension.zip"))
        try store.install(archive)
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        try await load(browser, base + "/page?zip")
        try await injected(browser)
        try store.setEnabled(false, id: archive.id)
        print("Enable/disable/remove, directory independence and ZIP installation: passed")

        let pane = SettingsBrowserPane()
        pane.setCategory(.browser)
        _ = pane.view
        let buttons = descendants(pane.view).compactMap { $0 as? NSButton }
        try require(buttons.contains { $0.title == String(localized: "Manage Extensions") }, "Native Browser settings entry missing")
        manager.show(relativeTo: window)
        guard let managerWindow = window.childWindows?.first(where: { $0.title == String(localized: "Browser Extensions") }) else { throw error("Extension manager did not present") }
        try require(managerWindow.isVisible && descendants(managerWindow.contentView!).contains { ($0 as? NSButton)?.title == String(localized: "Install Extension…") }, "Extension manager's native controls missing")
        managerWindow.close()
        print("AppKit browser settings and extension manager presentation: passed")

        try store.setEnabled(true, id: archive.id)
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        let originalRuntime = browser.webExtensions
        let originalContext = originalRuntime.controller.extensionContexts.first!
        let oldTab = originalRuntime.tabs.first { $0.browser === browser }!
        oldTab.performAction(originalContext)
        try await until { originalContext.action(for: oldTab)?.popupPopover?.isShown == true }
        let closingPopup = originalContext.action(for: oldTab)?.popupPopover
        manager.showOptions(originalContext, relativeTo: window, runtime: originalRuntime)
        let closingOptions = window.childWindows?.first(where: { $0.title == archive.name })
        try require(closingOptions != nil, "Options window missing before last-pane close")
        browser.close()
        second.close()
        window.contentView = nil
        try require(originalRuntime.tabs.isEmpty && originalRuntime.controller.extensionContexts.isEmpty,
                    "Closing the last local pane kept extension contexts running")
        try await until { closingOptions?.isVisible == false && closingPopup?.isShown != true }
        try require(closingOptions?.isVisible == false && closingPopup?.isShown != true,
                    "Closing the last pane kept popup or options alive")
        let reopened = BrowserTab(initialFocus: .none)
        defer { reopened.close(); window.contentView = nil }
        window.contentView = reopened.webView
        try require(reopened.webExtensions !== originalRuntime, "Reopening reused a stopped runtime")
        try await until { reopened.webExtensions.controller.extensionContexts.count == 1 }
        try await load(reopened, base + "/page?reopened")
        try await injected(reopened)
        try store.setEnabled(false, id: archive.id)
        try require(reopened.webExtensions.controller.extensionContexts.isEmpty, "Disabling reopened runtime left extension loaded")
        print("Last-pane close unloads contexts/popup/options, reopen creates working runtime, disable still applies: passed")
    }

    @MainActor private static func verifyReviewBoundaries(_ base: String, fixture: URL, mode: String) async throws {
        let store = BrowserWebExtensionStore.shared
        if mode == "warning" {
            for language in AppLanguage.allCases where language != .system {
                AppLocalization.apply(language)
                let alert = BrowserWebExtensionManager.permissionAlert(name: "Active Tab Fixture", details: ["activeTab", "scripting"], installing: true)
                try require(alert.informativeText.contains("activeTab"), "Installation warning does not explain activeTab page access: \(language.rawValue)")
                if language == .english { try require(alert.informativeText.contains("current page when you invoke its action"), "English activeTab warning is unclear") }
            }
            print("Installation warning explains activeTab access on explicit action in all 17 languages: passed")
            return
        }
        let browser = BrowserTab(initialFocus: .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = .init("main-extension-review-test")
        window.contentView = browser.webView
        defer { browser.close(); window.contentView = nil; window.orderOut(nil) }
        let (entry, _) = try await store.prepare(fixture.appendingPathComponent("events"))
        try store.install(entry)
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        let context = browser.webExtensions.controller.extensionContexts.first!
        let tab = browser.webExtensions.tabs.first!
        guard let popup = context.action(for: tab)?.popupWebView else { throw error("Event reporter popup missing") }
        try await until { popup.url != nil && !popup.isLoading }
        _ = try await popup.callAsyncJavaScript("return await browser.runtime.sendMessage({eventReset:true});", arguments: [:], in: nil, contentWorld: .page)
        if mode == "events" {
            let opened = BrowserTab(initialFocus: .none)
            defer { opened.close() }
            let events = try await tabEvents(popup, expecting: 1)
            print("New-pane WebExtension tab events:", events)
            try require(events.count == 1 && events[0]["type"] as? String == "created", "New browser pane emits move/detach before creation: \(events)")
            AppSettings.shared.preserveTerminalSessions = false
            AppSettings.shared.restoreTerminalHistory = false
            let destination = TerminalManager()
            defer { destination.projects.forEach { $0.terminateAll() } }
            opened.transferHost(to: destination)
            let moved = try await tabEvents(popup, expecting: 3)
            try require(moved[0]["type"] as? String == "created" && moved.dropFirst().allSatisfy { ["detached", "attached", "moved"].contains($0["type"] as? String ?? "") },
                        "A known-window move did not follow creation: \(moved)")
            print("Known-window WebExtension tab events:", moved)
        } else {
            let (transient, _) = try await store.prepare(fixture.appendingPathComponent("transient"))
            let resource = store.resourceURL(for: transient)
            let unavailable = resource.deletingLastPathComponent().appendingPathComponent("unavailable")
            try FileManager.default.moveItem(at: resource, to: unavailable)
            try store.install(transient)
            try await until { store.error != nil }
            try require(browser.webExtensions.controller.extensionContexts.count == 1, "A failed extension removed the successful context")
            try FileManager.default.moveItem(at: unavailable, to: resource)
            browser.webExtensions.refresh()
            browser.webExtensions.refresh()
            try await until { browser.webExtensions.controller.extensionContexts.count == 2 }
            try require(browser.webExtensions.controller.extensionContexts.contains(context), "Retry replaced an already loaded context")
            let events = try await tabEvents(popup, expecting: 0)
            try require(events.isEmpty, "Retry re-emitted existing tab events: \(events)")
            try await load(browser, base + "/page?retry")
            try await injected(browser)
            try await store.remove(id: transient.id)
            print("Transient load recovers on refresh without replacing successful context or duplicating tab events: passed")
        }
        context.action(for: tab)?.closePopup()
        try await store.remove(id: entry.id)
    }

    @MainActor private static func tabEvents(_ popup: WKWebView, expecting count: Int) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let values = try await popup.callAsyncJavaScript("return await browser.runtime.sendMessage({eventList:true});", arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]] ?? []
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw error("WebExtension tab event callback timed out")
    }

    @MainActor private static func verifySSH(_ fixture: URL) async throws {
        let store = BrowserWebExtensionStore.shared
        let (entry, _) = try await store.prepare(fixture.appendingPathComponent("ssh-extension"))
        try store.install(entry)
        let projectID = UUID()
        let endpoint = try SSHEndpoint(host: "127.0.0.1", port: Int(CommandLine.arguments[4])!)
        let routing = BrowserRemoteRouting(location: .ssh(endpoint: endpoint, remoteDirectory: "/tmp"), storageID: projectID)
        let browser = BrowserTab(initialFocus: .none, remoteRouting: routing, projectID: projectID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = .init("main-extension-ssh-test")
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        window.orderFront(nil)
        defer { browser.close(); window.contentView = nil; window.close() }
        try await until { browser.webExtensions.controller.extensionContexts.count == 1 }
        let port = CommandLine.arguments[5]
        browser.navigate(to: "http://[::1]:\(port)/page?extension-ssh")
        do { try await until { browser.webView.url?.path == "/page" && !browser.navigationIsLoading } }
        catch { throw Self.error("SSH page failed: \(browser.errorMessage ?? "none"), \(routing.state), \(String(describing: browser.webView.url))") }
        try await result(in: browser.webView, script: "document.body.dataset.extensionRemote", server: "extension-remote", port: port)
        try await result(in: browser.webView, script: "document.body.dataset.extensionRemoteBackground", server: "extension-remote", port: port)
        try await until {
            browser.webView.url?.host == "ipv6-1.zshell-remote.localhost" && routing.localProxyPort != nil
        }
        let pageDeadline = Date().addingTimeInterval(10)
        var page: [String: Any] = [:]
        while Date() < pageDeadline {
            page = try await browser.webView.evaluateJavaScript("({script:window.fixtureScript,dynamic:window.fixtureDynamic,api:window.fixtureState?.api?.server,websocket:window.fixtureState?.websocket,pixel:document.querySelector('#pixel').naturalWidth>0})") as? [String: Any] ?? [:]
            if page["script"] as? String == "loaded", page["dynamic"] as? String == "loaded",
               page["api"] as? String == "secondary", page["websocket"] as? String == "hmr-echo", page["pixel"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try require(page["script"] as? String == "loaded" && page["dynamic"] as? String == "loaded"
                    && page["api"] as? String == "secondary" && page["websocket"] as? String == "hmr-echo" && page["pixel"] as? Bool == true,
                    "Existing remote page scripts/fetch/WebSocket/images failed with extension loaded: \(page)")
        let context = browser.webExtensions.controller.extensionContexts.first!
        let tab = browser.webExtensions.tabs.first!
        tab.performAction(context)
        guard let action = context.action(for: tab), let popup = action.popupWebView else { throw error("SSH popup missing") }
        try await until { action.popupPopover?.isShown == true && popup.url != nil && !popup.isLoading }
        let alias = "http://ipv6-1.zshell-remote.localhost:\(port)"
        for (value, background) in [(alias + "/api?extension-background", true), (alias + "/api?extension-popup", false),
                                    ("http://[::1]:\(port)/api?extension-popup-direct", false)] {
            let response = try await network(popup, value, background: background)
            try checkRemote(response, server: "extension-remote", port: port)
        }
        for value in ["http://127.0.0.1:\(port)/must-not-reach-local", "http://[::1]:\(port)/must-not-reach-direct"] {
            try require(try await network(popup, value, background: true) == "blocked", "Worker bypassed remote loopback protection")
        }
        action.closePopup()
        browser.close()
        try require(routing.localProxyPort == nil && browser.webExtensions.controller.extensionContexts.isEmpty,
                    "Closing SSH pane kept extension or forwarding running")
        try await store.remove(id: entry.id)
        print("Private real SSH: content script/background/popup reach remote target, direct worker loopback stays blocked, closing tears down forwarding: passed")
    }

    @MainActor private static func optionalPermission(_ context: WKWebExtensionContext, tab: BrowserWebExtensionTab, window: NSWindow, script: String, allowing: Bool) async throws {
        tab.performAction(context)
        guard let action = context.action(for: tab), let webView = action.popupWebView else { throw error("Optional permission popup missing") }
        try await until { action.popupPopover?.isShown == true && webView.url != nil && !webView.isLoading }
        var complete = false
        let request = Task { @MainActor in
            defer { complete = true }
            return try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
        try await until { window.attachedSheet != nil || complete }
        if complete { throw error("Optional permission did not show a sheet: \(String(describing: try await request.value)); host key=\(window.isKeyWindow)") }
        let title = allowing ? String(localized: "Allow") : String(localized: "Cancel")
        guard let sheet = window.attachedSheet, let button = descendants(sheet.contentView!).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == title }) else { throw error("Optional permission button missing: \(title)") }
        button.performClick(nil)
        let result = try await request.value
        try require(result as? Bool == allowing, "Optional permission result did not match selected response")
        try await until { window.attachedSheet == nil }
        action.closePopup()
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor private static func result(in webView: WKWebView, script: String, server: String, port: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String {
                try checkRemote(value, server: server, port: port)
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw error("SSH extension content script timed out: \(script)")
    }
    private static func checkRemote(_ value: String?, server: String, port: String) throws {
        guard let value, let data = value.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: String],
              response["server"] == server, response["host"] == "ipv6-1.zshell-remote.localhost:\(port)" else {
            throw error("Extension request missed SSH remote target: \(value ?? "nil")")
        }
    }

    @MainActor private static func load(_ browser: BrowserTab, _ value: String) async throws {
        browser.navigate(to: value)
        try await until { browser.webView.url?.absoluteString == value && !browser.webView.isLoading }
    }
    @MainActor private static func injected(_ browser: BrowserTab) async throws {
        let deadline = Date().addingTimeInterval(8)
        while (try? await browser.webView.evaluateJavaScript("document.body.dataset.extensionVisits !== undefined")) as? Bool != true {
            guard Date() < deadline else { throw error("Extension content script did not inject") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor private static func value(in webView: WKWebView, script: String, equals expected: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        while (try? await webView.evaluateJavaScript(script)) as? String != expected {
            guard Date() < deadline else { throw error("Extension result timed out: \(script)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor private static func network(_ webView: WKWebView, _ url: String, background: Bool) async throws -> String? {
        let script = background ? "return await browser.runtime.sendMessage({network:url});"
            : "try { return await (await fetch(url,{signal:AbortSignal.timeout(2000)})).text(); } catch { return 'blocked'; }"
        return try await webView.callAsyncJavaScript(script, arguments: ["url": url], in: nil, contentWorld: .page) as? String
    }
    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw error("Extension state timed out: \(BrowserWebExtensionStore.shared.error ?? "none")") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw error(message) } }
    private static func error(_ message: String) -> NSError { NSError(domain: "BrowserWebExtensionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
