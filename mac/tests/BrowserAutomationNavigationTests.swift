import AppKit
import WebKit
@testable import zshell

@main
struct BrowserAutomationNavigationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var complete = false
        var failure: Error?
        Task { @MainActor in
            do { try await verify() } catch { failure = error }
            complete = true
        }
        let deadline = Date().addingTimeInterval(65)
        while !complete && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        if let failure { fputs("\(failure)\n", stderr); exit(1) }
        guard complete else { fputs("Browser navigation test timed out.\n", stderr); exit(1) }
        print("WebKit: unmounted viewport pixels/focus, srcdoc, Cookie/localStorage restore, CSP-safe page eval/Promise/errors/timeout cleanup, project/window scope passed")
    }

    @MainActor private static func verify() async throws {
        let browser = BrowserTab(initialFocus: .none)
        defer { browser.webView.stopLoading() }
        browser.automationNavigate("navigate", url: URL(string: CommandLine.arguments[1])!)
        try await loaded(browser)
        guard !browser.automation.navigationWasRejected else {
            throw failure("A safe srcdoc child frame incorrectly blocked the first automated navigation.")
        }
        let snapshot = try await browser.automation.perform(
            "snapshot", in: browser.webView,
            params: ["max_elements": .number(20), "max_text": .number(1_000)],
            timeoutMS: 3_000, scopeIsValid: { true }
        )
        guard snapshot.objectValue?["text"]?.stringValue?.contains("Parent document") == true,
              snapshot.objectValue?["text"]?.stringValue?.contains("Child document") == false else {
            throw failure("The main-frame snapshot did not preserve its document boundary.")
        }
        guard browser.webView.superview == nil, browser.webView.bounds.size == .zero else {
            throw failure("The screenshot fixture was already mounted or sized.")
        }
        let keyWindow = NSApp.keyWindow
        let mainWindow = NSApp.mainWindow
        let screenshot = try await browser.automation.screenshot(in: browser.webView, width: 800, timeoutMS: 5_000, scopeIsValid: { true })
        guard let encoded = screenshot.objectValue?["data_base64"]?.stringValue,
              let png = Data(base64Encoded: encoded), let bitmap = NSBitmapImageRep(data: png),
              bitmap.pixelsWide > 100, bitmap.pixelsHigh > 100 else {
            throw failure("The unmounted browser did not produce a PNG viewport.")
        }
        func color(_ x: Double, _ y: Double, _ red: Double, _ green: Double, _ blue: Double) -> Bool {
            guard let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x), y: Int(Double(bitmap.pixelsHigh) * y)) else { return false }
            return abs(color.redComponent * 255 - red) < 12 && abs(color.greenComponent * 255 - green) < 12 && abs(color.blueComponent * 255 - blue) < 12
        }
        guard color(0.1, 0.2, 220, 40, 60), color(0.5, 0.5, 20, 170, 90), color(0.9, 0.9, 22, 50, 79) else {
            if CommandLine.arguments.count > 2 { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("unmounted-viewport.png")) }
            throw failure("The hidden viewport contains blank or incorrect pixels instead of fixture color blocks.")
        }
        guard NSApp.keyWindow === keyWindow, NSApp.mainWindow === mainWindow,
              browser.webView.superview == nil, browser.webView.bounds.size == .zero,
              !NSApp.windows.contains(where: { $0.isVisible }) else {
            throw failure("Screenshot staging changed focus, showed a window, or did not restore the unmounted view.")
        }
        if CommandLine.arguments.count > 2 { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("unmounted-viewport.png")) }
        try await verifyEvaluation(browser, snapshot: snapshot)
        try await verifyDisabledControls(browser)
        try await verifyStrictCSP()
        try await verifyStorage(browser)
        try await verifyRouterScope()
        _ = try await browser.automation.perform(
            "click", in: browser.webView, params: ["selector": .string("#blocked-frame")],
            timeoutMS: 3_000, scopeIsValid: { true }
        )
        let blockedDeadline = Date().addingTimeInterval(3)
        while !browser.automation.navigationWasRejected && Date() < blockedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard browser.automation.navigationWasRejected, browser.webView.url?.scheme == "http" else {
            throw failure("An external protocol in a child frame was not rejected.")
        }
    }

    @MainActor private static func loaded(_ browser: BrowserTab) async throws {
        let deadline = Date().addingTimeInterval(10)
        while browser.webView.isLoading || browser.webView.url == nil {
            guard Date() < deadline else { throw failure("Initial navigation did not finish.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func evaluate(_ source: String, _ browser: BrowserTab, timeout: Int = 3_000) async throws -> ZshellJSONValue {
        try await browser.automation.evaluate(source, in: browser.webView, timeoutMS: timeout, scopeIsValid: { true })
    }

    @MainActor private static func verifyEvaluation(_ browser: BrowserTab, snapshot: ZshellJSONValue) async throws {
        let result = try await evaluate("({token: window.fixturePageToken, title: document.title, values: [true, 4, null]})", browser)
        guard result.objectValue?["value"]?.objectValue?["token"]?.stringValue == "page-context" else {
            throw failure("Eval did not run in the real page context.")
        }
        let promise = try await evaluate("Promise.resolve({answer: 42})", browser)
        guard promise.objectValue?["value"]?.objectValue?["answer"]?.intValue == 42 else { throw failure("Eval did not await the returned Promise.") }
        let scalar = try await evaluate("6 * 7", browser)
        let empty = try await evaluate("undefined", browser)
        guard scalar.objectValue?["value"]?.intValue == 42, empty.objectValue?["value"] == .null else { throw failure("Invalid scalar/undefined JSON result.") }
        for (source, expected) in [
            ("throw new Error('fixture failure')", "javascript_error"),
            ("Promise.reject(new Error('fixture rejection'))", "javascript_error"),
            ("1n", "invalid_javascript_result"), ("NaN", "invalid_javascript_result"),
            ("(()=>{const x={};x.self=x;return x})()", "invalid_javascript_result"),
            ("'x'.repeat(262145)", "response_too_large"),
            ("Array(10001)", "response_too_large"),
            (String(repeating: "x", count: 65_537), "invalid_params"),
            ("new Promise(()=>{})", "browser_timeout"),
        ] {
            do { _ = try await evaluate(source, browser, timeout: 150); throw failure("Invalid eval unexpectedly succeeded.") }
            catch let error as BrowserAutomationError { guard error.code == expected else { throw failure("Unexpected eval error code: \(error.code)") } }
        }
        let recovered = try await evaluate("Promise.resolve(42)", browser)
        guard recovered.objectValue?["value"]?.intValue == 42 else { throw failure("Browser did not recover after async evaluation timeout.") }
        let statements = try await evaluate("var fixtureDeclared = (window.fixtureExecutions = (window.fixtureExecutions || 0) + 1, 5); fixtureDeclared + 2", browser)
        let declarations = try await evaluate("({declared: fixtureDeclared, count: fixtureExecutions})", browser)
        guard statements.objectValue?["value"]?.intValue == 7,
              declarations.objectValue?["value"]?.objectValue?["declared"]?.intValue == 5,
              declarations.objectValue?["value"]?.objectValue?["count"]?.intValue == 1 else {
            throw failure("Multi-statement completion/global declaration semantics changed or executed twice.")
        }
        let completion = try await evaluate("try { Promise.resolve(7) } finally { window.fixtureExecutions++ }", browser)
        guard completion.objectValue?["value"]?.intValue == 7 else { throw failure("Multi-statement Promise completion changed.") }
        if let ref = snapshot.objectValue?["elements"]?.arrayValue?.first?.objectValue?["ref"]?.stringValue {
            do {
                _ = try await browser.automation.perform("click", in: browser.webView, params: ["ref": .string(ref)], timeoutMS: 1_000, scopeIsValid: { true })
                throw failure("Eval did not invalidate an old DOM reference.")
            } catch let error as BrowserAutomationError { guard error.code == "stale_element_reference" else { throw error } }
        }
        do {
            _ = try await browser.automation.evaluate("window.scopeLeak=true", in: browser.webView, timeoutMS: 1_000, scopeIsValid: { false })
            throw failure("Eval ignored an invalid project/window scope.")
        } catch let error as BrowserAutomationError { guard error.code == "browser_scope_changed" else { throw error } }
        let untouched = try await evaluate("typeof window.scopeLeak", browser)
        guard untouched.objectValue?["value"]?.stringValue == "undefined" else { throw failure("Out-of-scope script reached the page.") }
    }

    @MainActor private static func verifyDisabledControls(_ browser: BrowserTab) async throws {
        _ = try await browser.webView.evaluateJavaScript("""
        (() => {
          const fixture = document.createElement('div');
          fixture.id = 'fixture-disabled-controls';
          fixture.innerHTML = '<fieldset disabled><legend><input id="fixture-legend" value="before"></legend><input id="fixture-fieldset" value="before"></fieldset><select id="fixture-select"><option value="first" selected>First</option><optgroup disabled><option value="group">Group</option><option value="duplicate">Disabled duplicate</option></optgroup><option value="duplicate">Enabled duplicate</option><option disabled value="own">Disabled</option></select>';
          document.body.append(fixture);
        })()
        """)
        defer { browser.webView.evaluateJavaScript("document.getElementById('fixture-disabled-controls').remove()") { _, _ in } }
        let snapshot = try await browser.automation.perform("snapshot", in: browser.webView,
            params: ["max_elements": .number(100), "max_text": .number(1_000)],
            timeoutMS: 1_000, scopeIsValid: { true })
        let controls = snapshot.objectValue?["elements"]?.arrayValue ?? []
        func disabled(_ id: String) -> Bool? {
            controls.first { $0.objectValue?["id"]?.stringValue == id }?.objectValue?["disabled"]?.boolValue
        }
        guard disabled("fixture-fieldset") == true, disabled("fixture-legend") == false else {
            throw failure("Snapshot lost disabled fieldset inheritance or its first legend exception.")
        }
        for (selector, value, code) in [("#fixture-fieldset", "after", "element_disabled"),
                                         ("#fixture-select", "group", "invalid_value"),
                                         ("#fixture-select", "own", "invalid_value")] {
            do {
                _ = try await browser.automation.perform("fill", in: browser.webView,
                    params: ["selector": .string(selector), "value": .string(value)],
                    timeoutMS: 1_000, scopeIsValid: { true })
                throw failure("Fill changed a disabled control or option.")
            } catch let error as BrowserAutomationError { guard error.code == code else { throw error } }
        }
        let retained = try await browser.webView.evaluateJavaScript("document.getElementById('fixture-select').value === 'first' && document.getElementById('fixture-fieldset').value === 'before'") as? Bool
        guard retained == true else { throw failure("Rejected fill changed a previous control value.") }
        _ = try await browser.automation.perform("fill", in: browser.webView,
            params: ["selector": .string("#fixture-legend"), "value": .string("after")],
            timeoutMS: 1_000, scopeIsValid: { true })
        let legend = try await browser.webView.evaluateJavaScript("document.getElementById('fixture-legend').value") as? String
        guard legend == "after" else { throw failure("Fill rejected the enabled first legend control.") }
        _ = try await browser.automation.perform("fill", in: browser.webView,
            params: ["selector": .string("#fixture-select"), "value": .string("duplicate")],
            timeoutMS: 1_000, scopeIsValid: { true })
        let duplicate = try await browser.webView.evaluateJavaScript("document.getElementById('fixture-select').selectedIndex") as? Int
        guard duplicate == 3 else { throw failure("A duplicate value selected the earlier disabled option.") }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('#fixture-select optgroup').disabled = false")
        let filled = try await browser.automation.perform("fill", in: browser.webView,
            params: ["selector": .string("#fixture-select"), "value": .string("group")],
            timeoutMS: 1_000, scopeIsValid: { true })
        let selected = try await browser.webView.evaluateJavaScript("document.getElementById('fixture-select').value") as? String
        guard filled.objectValue?["filled"]?.boolValue == true, selected == "group" else {
            throw failure("Fill rejected the option after its optgroup was enabled.")
        }
    }

    @MainActor private static func verifyStrictCSP() async throws {
        let browser = BrowserTab(initialFocus: .none)
        defer { browser.webView.stopLoading() }
        browser.automationNavigate("navigate", url: URL(string: CommandLine.arguments[1])!.appendingPathComponent("csp"))
        try await loaded(browser)
        _ = try await browser.webView.evaluateJavaScript("window.value='page-value'; window.source='page-source'; window.deadline='page-deadline'; window.maximum='page-maximum'; window.slot='page-slot'; window.fixtureExecutions=0")
        let globals = try await evaluate("/* leading */ ({token:fixturePageToken, receiver:this===window, args:typeof arguments, value, source, deadline, maximum, slot}); // trailing", browser)
        let object = globals.objectValue?["value"]?.objectValue
        guard object?["token"]?.stringValue == "page-context", object?["receiver"]?.boolValue == true,
              object?["args"]?.stringValue == "undefined", object?["value"]?.stringValue == "page-value",
              object?["source"]?.stringValue == "page-source", object?["deadline"]?.stringValue == "page-deadline",
              object?["maximum"]?.stringValue == "page-maximum", object?["slot"]?.stringValue == "page-slot" else {
            throw failure("Strict-CSP expression evaluation lost or shadowed global Script bindings.")
        }
        let scalar = try await evaluate("6 * 7; /* trailing */", browser)
        let promise = try await evaluate("Promise.resolve({answer:42})", browser)
        let once = try await evaluate("(++window.fixtureExecutions, fixtureExecutions)", browser)
        let iife = try await evaluate("(() => { window.fixtureExecutions++; const value='IIFE'; return Promise.resolve({value,count:fixtureExecutions}); })()", browser)
        guard scalar.objectValue?["value"]?.intValue == 42,
              promise.objectValue?["value"]?.objectValue?["answer"]?.intValue == 42,
              once.objectValue?["value"]?.intValue == 1,
              iife.objectValue?["value"]?.objectValue?["count"]?.intValue == 2 else {
            throw failure("Strict-CSP scalar/Promise/IIFE results failed or side effects executed twice.")
        }
        for source in ["Promise.reject(new Error('CSP rejection'))", "(() => { throw new Error('CSP exception'); })()"] {
            do { _ = try await evaluate(source, browser); throw failure("Strict-CSP rejected/thrown script unexpectedly succeeded.") }
            catch let error as BrowserAutomationError {
                guard error.code == "javascript_error", error.message.contains("CSP ") else { throw error }
            }
        }
        do {
            _ = try await evaluate("window.fixtureExecutions++; fixtureExecutions", browser)
            throw failure("Strict CSP unexpectedly allowed multi-statement string evaluation.")
        } catch let error as BrowserAutomationError {
            guard error.code == "javascript_error", error.message.contains("IIFE") else { throw error }
        }
        for source in ["window.fixtureExecutions++; (]", "window.fixtureExecutions++, new.target"] {
            do { _ = try await evaluate(source, browser); throw failure("A syntax-invalid script unexpectedly executed.") }
            catch let error as BrowserAutomationError { guard error.code == "javascript_error" else { throw error } }
        }
        let unchanged = try await evaluate("fixtureExecutions", browser)
        guard unchanged.objectValue?["value"]?.intValue == 2 else { throw failure("CSP or syntax rejection executed a script prefix.") }
        for source in [
            "new Promise(()=>{})",
            "(() => { const end=Date.now()+350; while(Date.now()<end){}; return ++window.fixtureExecutions; })()",
        ] {
            do { _ = try await evaluate(source, browser, timeout: 100); throw failure("Slow strict-CSP script did not time out.") }
            catch let error as BrowserAutomationError { guard error.code == "browser_timeout" else { throw error } }
            try await Task.sleep(for: .milliseconds(400))
            let recovered = try await evaluate("({answer:42,slots:Object.keys(globalThis).filter(key=>key.startsWith('__zshellEvaluation_')).length})", browser)
            guard recovered.objectValue?["value"]?.objectValue?["answer"]?.intValue == 42,
                  recovered.objectValue?["value"]?.objectValue?["slots"]?.intValue == 0 else {
                throw failure("A timed-out evaluation leaked its slot or prevented the next evaluation.")
            }
        }
        do {
            _ = try await browser.webView.evaluateJavaScript("(0,eval)('1')")
            throw failure("Automation weakened the fixture's CSP.")
        } catch let error as NSError {
            guard error.domain == WKError.errorDomain else { throw error }
        }
    }

    @MainActor private static func verifyStorage(_ browser: BrowserTab) async throws {
        let saved = try await browser.automation.saveState(in: browser.webView, format: .storageState, timeoutMS: 3_000, scopeIsValid: { true })
        guard let encoded = saved.objectValue?["data_base64"]?.stringValue, let data = Data(base64Encoded: encoded),
              let url = browser.webView.url else { throw failure("Missing exported storage state.") }
        let decoded = try BrowserStorageState.decode(data, format: .storageState, for: url)
        guard decoded.localStorage?["fixture-login"] == "fixture-only",
              let cookie = decoded.cookies.first(where: { $0.name == "fixture_http" }),
              cookie.isHTTPOnly, !cookie.isSecure, cookie.sameSitePolicy?.rawValue.lowercased() == "strict",
              let expiration = cookie.expiresDate, expiration.timeIntervalSinceNow > 3_500,
              decoded.cookies.contains(where: { $0.name == "fixture_session" && $0.expiresDate == nil }) else {
            throw failure("Real Set-Cookie attributes or localStorage were not exported correctly.")
        }
        let store = browser.webView.configuration.websiteDataStore.httpCookieStore
        for cookie in decoded.cookies {
            await withCheckedContinuation { continuation in store.delete(cookie) { continuation.resume() } }
        }
        _ = try await evaluate("localStorage.clear()", browser)
        let cleared = try await evaluate("({storage: localStorage.length, cookie: document.cookie})", browser)
        guard cleared.objectValue?["value"]?.objectValue?["storage"]?.intValue == 0,
              cleared.objectValue?["value"]?.objectValue?["cookie"]?.stringValue == "" else { throw failure("Fixture state was not cleared before restore.") }
        _ = try await browser.automation.loadState(data, in: browser.webView, format: .storageState, timeoutMS: 3_000, scopeIsValid: { true })
        let restored = try await evaluate("(async()=>({login:localStorage.getItem('fixture-login'), visible:document.cookie.includes('fixture_session='), hidden:!document.cookie.includes('fixture_http='), server:await (await fetch('/cookie-check')).json()}))()", browser)
        let values = restored.objectValue?["value"]?.objectValue
        guard values?["login"]?.stringValue == "fixture-only", values?["visible"]?.boolValue == true,
              values?["hidden"]?.boolValue == true, values?["server"]?.objectValue?["httpOnly"]?.boolValue == true,
              values?["server"]?.objectValue?["session"]?.boolValue == true else {
            throw failure("Restored cookies/localStorage did not reach document and HTTP request boundaries.")
        }
        let again = try await browser.automation.saveState(in: browser.webView, format: .storageState, timeoutMS: 3_000, scopeIsValid: { true })
        let restoredData = Data(base64Encoded: again.objectValue!["data_base64"]!.stringValue!)!
        let restoredCookie = try BrowserStorageState.decode(restoredData, format: .storageState, for: url).cookies.first { $0.name == "fixture_http" }
        guard restoredCookie?.isHTTPOnly == true, restoredCookie?.sameSitePolicy?.rawValue.lowercased() == "strict",
              restoredCookie?.expiresDate == expiration else { throw failure("WebKit did not preserve restored HttpOnly/SameSite/expiry attributes.") }
        let netscape = try browserStateData(again, format: .cookies, url: url)
        _ = try await browser.automation.loadState(netscape, in: browser.webView, format: .cookies, timeoutMS: 3_000, scopeIsValid: { true })
        let cookieCheck = try await evaluate("fetch('/cookie-check').then(r=>r.json())", browser)
        guard cookieCheck.objectValue?["value"]?.objectValue?["httpOnly"]?.boolValue == true else { throw failure("Netscape restore lost HttpOnly cookies.") }
        var malicious = try JSONDecoder().decode(ZshellJSONValue.self, from: data).objectValue!
        malicious["origins"] = .array([.object(["origin": .string("https://other.test"), "localStorage": .array([])])])
        do {
            _ = try await browser.automation.loadState(JSONEncoder().encode(ZshellJSONValue.object(malicious)), in: browser.webView, format: .storageState, timeoutMS: 1_000, scopeIsValid: { true })
            throw failure("A foreign storage origin was accepted.")
        } catch let error as BrowserAutomationError { guard error.code == "invalid_storage_state" else { throw error } }
        let retained = try await evaluate("localStorage.getItem('fixture-login')", browser)
        guard retained.objectValue?["value"]?.stringValue == "fixture-only" else { throw failure("Rejected storage import changed existing localStorage.") }
    }

    private static func browserStateData(_ saved: ZshellJSONValue, format: BrowserStorageState.Format, url: URL) throws -> Data {
        let original = Data(base64Encoded: saved.objectValue!["data_base64"]!.stringValue!)!
        return try BrowserStorageState.decode(original, format: .storageState, for: url).encoded(format: format, for: url)
    }

    @MainActor private static func verifyRouterScope() async throws {
        AppSettings.shared.preserveTerminalSessions = false
        guard !AppSettings.shared.aiEnabled else { throw failure("The fixture must disable AI integrations in its isolated config.") }
        AppSettings.shared.terminalBackend = .alacritty
        let first = TerminalManager()
        let second = TerminalManager()
        defer { for manager in [first, second] { manager.projects.forEach { $0.terminateAll() } } }
        guard let project = first.projects.first, let callerID = project.sessions.first?.id,
              let outside = second.projects.first else { throw failure("Could not create scoped browser fixtures.") }
        let allowed = project.newBrowserTab(initialFocus: .none, focus: false)
        let foreignProject = first.newProject().newBrowserTab(initialFocus: .none, focus: false)
        let foreignWindow = outside.newBrowserTab(initialFocus: .none, focus: false)
        first.selectedProjectID = project.id
        let selectedTab = project.selectedTabID
        let focusedPane = project.selectedTab?.focusedPaneID
        func request(_ method: String, _ browser: BrowserTab, extra: [String: ZshellJSONValue] = [:]) async -> ZshellAutomationResponse {
            let params = extra.merging(["browser_id": .string(browser.id.uuidString)]) { _, target in target }
            return await ZshellAutomationRouter.route(ZshellAutomationRequest(version: 1, id: UUID().uuidString, method: method,
                token: "fixture-only", terminalID: callerID.uuidString, params: params), callerTerminalID: callerID)
        }
        for foreign in [foreignProject, foreignWindow] {
            for method in ["browser.get", "browser.eval", "browser.screenshot", "browser.state.save", "browser.state.load"] {
                let response = await request(method, foreign, extra: ["script": .string("window.scopeLeak=true")])
                guard !response.ok, response.error?.code == "browser_not_found" else { throw failure("Browser router accepted a cross-project/window target.") }
            }
        }
        allowed.automationNavigate("navigate", url: URL(string: CommandLine.arguments[1])!)
        try await loaded(allowed)
        let response = await request("browser.screenshot", allowed, extra: ["width": .number(320)])
        guard response.ok, first.selectedProjectID == project.id, project.selectedTabID == selectedTab,
              project.selectedTab?.focusedPaneID == focusedPane, allowed.webView.superview == nil else {
            throw failure("A scoped background screenshot failed or changed the invoking pane's selection.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BrowserAutomationNavigationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
