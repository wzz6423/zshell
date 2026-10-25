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
        let deadline = Date().addingTimeInterval(20)
        while !complete && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { fputs("\(failure)\n", stderr); exit(1) }
        guard complete else { fputs("Browser navigation test timed out.\n", stderr); exit(1) }
        print("Browser first automated navigation with srcdoc: passed")
    }

    @MainActor private static func verify() async throws {
        let browser = BrowserTab(initialFocus: .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = browser.webView
        defer { window.contentView = nil; browser.webView.stopLoading() }
        browser.automationNavigate("navigate", url: URL(string: CommandLine.arguments[1])!)
        let deadline = Date().addingTimeInterval(10)
        while browser.webView.isLoading || browser.webView.url == nil {
            guard Date() < deadline else { throw failure("Initial navigation did not finish.") }
            try await Task.sleep(for: .milliseconds(20))
        }
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

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BrowserAutomationNavigationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
