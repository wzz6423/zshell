import AppKit
import Foundation
import WebKit
@testable import zshell

@main
struct BrowserRemoteRoutingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var complete = false
        var failure: Error?
        Task { @MainActor in
            do { try await verify() } catch { failure = error }
            complete = true
        }
        let deadline = Date().addingTimeInterval(110)
        while !complete && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        if let failure { fputs("Remote browser test failed: \(failure)\n", stderr); exit(1) }
        guard complete else { fputs("Remote browser test timed out.\n", stderr); exit(1) }
    }

    @MainActor private static func verify() async throws {
        let arguments = CommandLine.arguments
        let backend = arguments[1]
        let sshPort = Int(arguments[2])!
        let primaryPort = Int(arguments[3])!
        let secondaryPort = Int(arguments[4])!
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        let manager = TerminalManager()
        defer { manager.projects.forEach { $0.terminateAll() } }
        let localProject = manager.projects[0]
        let endpoint = try SSHEndpoint(host: "127.0.0.1", port: sshPort)
        manager.newSSHProject(endpoint: endpoint, remoteDirectory: nil)
        guard let project = manager.projects.first(where: { $0.isRemote }),
              let caller = project.sessions.first else { throw failure("SSH project or terminal missing") }

        let response = await request("browser.open", caller: caller.id, params: [
            "url": .string("http://localhost:\(primaryPort)/redirect?start=1#before"),
            "tab": .bool(true), "focus": .bool(false),
        ])
        guard response.ok, let id = response.result?.objectValue?["browser_id"]?.stringValue,
              let browser = project.tabs.flatMap(\.browsers).first(where: { $0.id.uuidString == id }),
              let routing = browser.remoteRouting else { throw failure("Automation did not create a project-bound remote browser: \(String(describing: response.error))") }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.webView
        defer { window.contentView = nil; window.close() }
        try await waitForPage(browser, expectedPath: "/page/next")
        let deadline = Date().addingTimeInterval(10)
        var values: [String: Any] = [:]
        repeat {
            values = try await browser.webView.evaluateJavaScript("({state:window.fixtureState,script:window.fixtureScript,dynamic:window.fixtureDynamic,pixel:document.querySelector('#pixel').complete && document.querySelector('#pixel').naturalWidth > 0,frame:!!document.querySelector('#child').contentWindow})") as? [String: Any] ?? [:]
            if let state = values["state"] as? [String: Any],
               state["websocket"] as? String == "hmr-echo", state["api"] != nil,
               values["script"] as? String == "loaded", values["dynamic"] as? String == "loaded",
               values["pixel"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        guard let state = values["state"] as? [String: Any],
              state["path"] as? String == "/page/next",
              state["query"] as? String == "?from=redirect&encoded=%2F",
              state["hash"] as? String == "#fragment",
              state["websocket"] as? String == "hmr-echo",
              let api = state["api"] as? [String: Any], api["server"] as? String == "primary",
              values["script"] as? String == "loaded", values["dynamic"] as? String == "loaded",
              values["pixel"] as? Bool == true, values["frame"] as? Bool == true else {
            throw failure("Redirect, resources, fetch or WebSocket did not load: \(values)")
        }
        guard browser.webView.url?.port == secondaryPort, routing.localProxyPort != nil,
              browser.urlString == "http://localhost:\(secondaryPort)/page/next?from=redirect&encoded=%2F#fragment",
              browser.snapshotURL == browser.urlString else {
            throw failure("The browser lost the original remote URL or did not establish SSH forwarding")
        }
        let faviconDeadline = Date().addingTimeInterval(10)
        while browser.favicon == nil, Date() < faviconDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard browser.favicon != nil else { throw failure("The redirected remote favicon did not load") }
        let waited = await request("browser.wait", caller: caller.id, params: ["browser_id": .string(id), "timeout_ms": .number(10_000)])
        guard waited.ok else { throw failure("Automation wait failed: \(String(describing: waited.error))") }
        _ = try await browser.webView.evaluateJavaScript("document.cookie='remote_scope=only; path=/'; localStorage.setItem('remote_scope','only'); true")

        let second = project.newBrowserTab(initialURL: "http://localhost:\(secondaryPort)/page/second", initialFocus: .none, focus: false)
        try await waitForPage(second, expectedPath: "/page/second")
        guard second.remoteRouting === routing,
              try await second.webView.evaluateJavaScript("document.cookie.includes('remote_scope=only')") as? Bool == true else {
            throw failure("Browsers in one remote project did not share their routing and site data")
        }
        let local = localProject.newBrowserTab(initialURL: "http://localhost:\(secondaryPort)/page/local", initialFocus: .none, focus: false)
        try await waitForPage(local, expectedPath: "/page/local")
        guard local.remoteRouting == nil,
              try await local.webView.evaluateJavaScript("document.cookie.includes('remote_scope=only')") as? Bool == false else {
            throw failure("Local and remote browser data stores were not isolated")
        }
        manager.newSSHProject(endpoint: endpoint, remoteDirectory: nil)
        guard let otherProject = manager.projects.first(where: { $0.isRemote && $0 !== project }) else {
            throw failure("Second remote project missing")
        }
        let other = otherProject.newBrowserTab(initialURL: "http://localhost:\(secondaryPort)/page/other", initialFocus: .none, focus: false)
        try await waitForPage(other, expectedPath: "/page/other")
        guard other.remoteRouting !== routing,
              try await other.webView.evaluateJavaScript("document.cookie.includes('remote_scope=only')") as? Bool == false else {
            throw failure("Separate remote projects shared site data")
        }

        guard let secondTab = project.tabs.first(where: { $0.browsers.contains { $0 === second } }),
              manager.moveTab(id: secondTab.id, from: project.id, to: otherProject.id, in: ObjectIdentifier(manager)).failure == nil else {
            throw failure("Moving the remote browser tab failed")
        }
        try await waitForPage(second, expectedPath: "/page/second")
        guard second.remoteRouting === other.remoteRouting,
              try await second.webView.evaluateJavaScript("document.cookie.includes('remote_scope=only')") as? Bool == false else {
            throw failure("Moved remote browser kept the source project's routing or site data")
        }

        other.remoteRouting!.setAvailable(false, projectID: otherProject.id)
        other.navigate(to: "data:text/html,<title>public</title><p>public</p>")
        let publicDeadline = Date().addingTimeInterval(5)
        while other.webView.url?.scheme != "data" || other.webView.isLoading, Date() < publicDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        guard other.webView.url?.scheme == "data", other.errorMessage == nil, !other.isPreparingNavigation,
              other.remoteRouting?.localProxyPort == nil else {
            throw failure("A public page waited for or failed on remote forwarding")
        }

        let oldPort = routing.localProxyPort!
        routing.setAvailable(false, projectID: project.id)
        _ = try? await browser.webView.evaluateJavaScript("(()=>{fetch('http://localhost:\(primaryPort)/blocked-fetch-\(backend)').catch(()=>{});new WebSocket('ws://localhost:\(primaryPort)/socket?blocked=\(backend)');return true})()")
        try await Task.sleep(for: .milliseconds(500))
        browser.navigate(to: "http://localhost:\(primaryPort)/must-not-reach-local-\(backend)")
        try await Task.sleep(for: .milliseconds(500))
        guard routing.localProxyPort == nil, browser.errorMessage != nil else {
            throw failure("Disconnected remote browser did not fail closed")
        }
        routing.setAvailable(true, projectID: project.id)
        let reconnectDeadline = Date().addingTimeInterval(5)
        while browser.errorMessage != nil, Date() < reconnectDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try await waitForPage(browser, expectedPath: "/must-not-reach-local-\(backend)")
        guard routing.localProxyPort != nil else { throw failure("Remote browser did not reconnect") }
        second.close()
        browser.close()
        try await Task.sleep(for: .milliseconds(300))
        guard routing.localProxyPort == nil else { throw failure("Closing the last remote browser did not release forwarding") }
        print("PASS \(backend): SSH project/browser automation, redirect, original URL, HTTP resources, fetch, WebSocket, project isolation and reconnect (old proxy \(oldPort))")
    }

    @MainActor private static func waitForPage(_ browser: BrowserTab, expectedPath: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let message = browser.errorMessage { throw failure("Navigation failed: \(message)") }
            if !browser.navigationIsLoading, browser.webView.url?.path == expectedPath,
               (try? await browser.webView.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw failure("Timed out loading \(expectedPath), current URL \(String(describing: browser.webView.url))")
    }

    @MainActor private static func request(_ method: String, caller: UUID, params: [String: ZshellJSONValue]) async -> ZshellAutomationResponse {
        await ZshellAutomationRouter.route(
            ZshellAutomationRequest(version: 1, id: UUID().uuidString, method: method,
                                    token: "fixture-only", terminalID: caller.uuidString, params: params),
            callerTerminalID: caller
        )
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BrowserRemoteRoutingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
