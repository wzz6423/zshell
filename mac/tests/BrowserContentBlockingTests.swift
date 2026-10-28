import AppKit
import WebKit
@testable import zshell

@main
struct BrowserContentBlockingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var complete = false
        var failure: Error?
        Task { @MainActor in
            do { try await verify() } catch { failure = error }
            complete = true
        }
        let deadline = Date().addingTimeInterval(180)
        while !complete && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { fputs("\(failure)\n", stderr); exit(1) }
        guard complete else { fputs("Content blocking tests timed out.\n", stderr); exit(1) }
    }

    @MainActor private static func verify() async throws {
        let base = CommandLine.arguments[1]
        let settings = AppSettings.shared
        let mode = CommandLine.arguments.dropFirst(2).first ?? "verify"
        if mode == "persistence" {
            try require(!settings.browserContentBlocking && settings.browserFilterLists == base + "/filters.txt?version=2", "Settings did not persist across processes")
            print("Settings restart persistence: passed")
            return
        }
        settings.browserContentBlocking = true
        settings.browserFilterLists = base + "/filters.txt"
        let blocker = BrowserContentBlocker.shared
        try await until { if case .active = blocker.status { return true }; return false }
        try require(!blocker.ruleLists.isEmpty, "Native compiled rules missing")

        let browser = BrowserTab(initialFocus: .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = browser.webView
        defer { browser.close(); window.contentView = nil }
        try await load(browser, base + "/page?case=enabled")
        let on = try await values(browser)
        try require(on["blocked.png"] == false && on["allowed.png"] == true && on["normal.png"] == true, "Network blocking/@@ exception failed: \(on)")
        try require(on["scoped.png"] == true && on["negative.png"] == true && on["mixed.png"] == true, "Excluded scope widened a filter: \(on)")
        try await requireStyle(browser, ".hidden-ad", "none")
        try await requireStyle(browser, ".except-ad", "block")
        try await requireStyle(browser, ".scoped-ad", "block")
        try await requireStyle(browser, ".negative-ad", "block")
        print("Real WebKit network block, @@, domain exclusions and cosmetic #@#: passed")

        let localhost = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        try await load(browser, localhost + "/page?case=scoped")
        let scoped = try await values(browser)
        try require(scoped["scoped.png"] == false && scoped["negative.png"] == false, "Positive/negative domain scope failed: \(scoped)")
        try await requireStyle(browser, ".scoped-ad", "none")
        try await requireStyle(browser, ".negative-ad", "none")
        print("Real WebKit positive and negative top-domain scopes: passed")

        let sidebar = SettingsSidebarViewController()
        _ = sidebar.view
        let categoryButtons = descendants(sidebar.view).compactMap { $0 as? NSButton }
        try require(categoryButtons.contains { $0.accessibilityLabel() == SettingsCategory.browser.title || $0.title == SettingsCategory.browser.title }, "Browser settings sidebar entry missing")
        let pane = SettingsBrowserPane()
        pane.setCategory(.browser)
        _ = pane.view
        pane.syncFromSettings()
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.contentViewController = pane
        settingsWindow.setContentSize(NSSize(width: 480, height: 460))
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        try require(pane.view.bounds.width == 480, "Browser settings minimum detail width changed")
        let scrolls = descendants(pane.view).compactMap { $0 as? NSScrollView }
        try require(!scrolls.isEmpty && scrolls.allSatisfy { $0.frame.width <= 480 }, "Browser controls overflow minimum detail width")
        print("Native sidebar entry and 480pt detail width layout: passed")
        let switches = descendants(pane.view).compactMap { $0 as? NSSwitch }
        guard let enabled = switches.first(where: { $0.accessibilityLabel() == String(localized: "Block ads and trackers") }) else { throw error("Native switch missing") }
        enabled.state = .off
        _ = enabled.sendAction(enabled.action, to: enabled.target)
        try await until { blocker.status == .disabled }
        try await load(browser, base + "/page?case=disabled")
        let off = try await values(browser)
        try require(off["blocked.png"] == true && off["allowed.png"] == true, "Native switch did not remove active rules")
        try await requireStyle(browser, ".hidden-ad", "block")
        enabled.state = .on
        _ = enabled.sendAction(enabled.action, to: enabled.target)
        try await until { if case .active = blocker.status { return true }; return false }
        try await load(browser, base + "/page?case=reenabled")
        try require(try await values(browser)["blocked.png"] == false, "Re-enabling did not restore blocking")
        print("Native AppKit switch changes existing WKWebView rules live: passed")

        guard let editor = descendants(pane.view).compactMap({ $0 as? NSTextView }).first,
              let apply = descendants(pane.view).compactMap({ $0 as? NSButton }).first(where: { $0.title == String(localized: "Apply Lists") }) else { throw error("Native list editor missing") }
        editor.string = base + "/filters.txt?version=2"
        pane.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        apply.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        try await until { settings.browserFilterLists == base + "/filters.txt?version=2" && blocker.status != .updating }
        try await until { if case .active = blocker.status { return true }; return false }
        try await load(browser, base + "/page?case=updated")
        let updated = try await values(browser)
        try require(updated["blocked.png"] == true && updated["normal.png"] == false, "Native list replacement did not update rules: \(updated)")
        print("Native AppKit custom list editor replaces active rules: passed")

        settings.browserFilterLists = base + "/slow.txt"
        try await Task.sleep(for: .milliseconds(100))
        settings.browserFilterLists = base + "/filters.txt?version=2"
        let closed = BrowserTab(initialFocus: .none)
        closed.close()
        try await until { if case .active = blocker.status { return true }; return false }
        try await Task.sleep(for: .milliseconds(700))
        try require(closed.isClosed, "Closed browser was revived")
        try await load(browser, base + "/page?case=stale")
        try require(try await values(browser)["normal.png"] == false, "Stale download overwrote current selection")
        print("Stale downloads and closed-browser lifecycle guards: passed")

        settings.browserFilterLists = base + "/missing.txt"
        try await Task.sleep(for: .milliseconds(100))
        try await until { if case .failed = blocker.status { return true }; return false }
        try require(blocker.ruleLists.isEmpty, "Failed replacement retained an unrelated list")
        settings.browserFilterLists = base + "/oversize.txt"
        try await Task.sleep(for: .milliseconds(100))
        try await until { if case .failed = blocker.status { return true }; return false }
        try require(blocker.ruleLists.isEmpty, "Oversize list was accepted")
        print("HTTP failure and oversized list rejection report real failure: passed")

        settings.browserFilterLists = base + "/filters.txt?version=2"
        try await Task.sleep(for: .milliseconds(100))
        try await until { if case .active = blocker.status { return true }; return false }
        _ = try await URLSession.shared.data(from: URL(string: base + "/fail-updates")!)
        blocker.refresh()
        try await until { if case .active(_, _, true) = blocker.status { return true }; return false }
        try require(!blocker.ruleLists.isEmpty, "Last known list was lost after refresh failure")
        print("Failed refresh uses cached rules and displays degraded status: passed")

        try await chunkedRules(base: base)
        if CommandLine.arguments.count > 3 {
            let texts = try CommandLine.arguments.suffix(2).map { try String(contentsOfFile: $0, encoding: .utf8) }
            let result = try BrowserContentRules.convert(texts)
            for (index, json) in result.lists.enumerated() {
                _ = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "zshell-test-full-\(index)", encodedContentRuleList: json)
                try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "zshell-test-full-\(index)")
            }
            print("Current full EasyList/EasyPrivacy: \(result.converted) converted, \(result.skipped) skipped, \(result.lists.count) native lists compiled")
        }
        settings.browserContentBlocking = false
        settings.browserFilterLists = base + "/filters.txt?version=2"
        try require(settings.serializedConfig().contains("browser.content-blocking = false"), "Toggle was not serialized")
        print("Content blocking fixture: passed")
    }

    @MainActor private static func chunkedRules(base: String) async throws {
        let result = try BrowserContentRules.convert(["/blocked.png$image\n/normal.png$image\n@@/blocked.png$image\n##.hidden-ad", "127.0.0.1#@#.hidden-ad"], rulesPerList: 2)
        let browser = BrowserTab(initialFocus: .none)
        defer { browser.close() }
        let controller = browser.webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        for (index, json) in result.lists.enumerated() {
            guard let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "zshell-test-chunk-\(index)", encodedContentRuleList: json) else { throw error("Native compile returned no rule list") }
            controller.add(rule)
        }
        try await load(browser, base + "/page?case=chunks")
        let values = try await values(browser)
        try require(values["blocked.png"] == true && values["normal.png"] == false, "Exception missing from a split native list")
        try await requireStyle(browser, ".hidden-ad", "block")
        for index in result.lists.indices { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "zshell-test-chunk-\(index)") }
        print("Cross-source cosmetic exceptions and split native network exceptions: passed")
    }

    @MainActor private static func load(_ browser: BrowserTab, _ url: String) async throws {
        browser.navigate(to: url)
        try await until { browser.webView.url?.absoluteString == url && !browser.webView.isLoading }
        let deadline = Date().addingTimeInterval(5)
        while (try? await browser.webView.evaluateJavaScript("window.fixtureDone === true")) as? Bool != true {
            guard Date() < deadline else { throw error("Page resources did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func values(_ browser: BrowserTab) async throws -> [String: Bool] {
        try await browser.webView.evaluateJavaScript("window.fixtureResults") as? [String: Bool] ?? [:]
    }

    @MainActor private static func requireStyle(_ browser: BrowserTab, _ selector: String, _ value: String) async throws {
        let actual = try await browser.webView.evaluateJavaScript("getComputedStyle(document.querySelector('\(selector)')).display") as? String
        try require(actual == value, "Cosmetic \(selector): expected \(value), got \(actual ?? "nil")")
    }

    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !predicate() {
            guard Date() < deadline else { throw error("Timed out waiting for state: \(BrowserContentBlocker.shared.status), error: \(BrowserContentBlocker.shared.lastError ?? "none")") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw error(message) } }
    private static func error(_ message: String) -> NSError { NSError(domain: "BrowserContentBlockingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
