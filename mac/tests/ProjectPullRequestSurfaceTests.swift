import AppKit
import ObjectiveC.runtime
import SwiftUI
@testable import zshell

@MainActor private enum OpenFixture {
    static var url: URL?
    static func exchange() {
        let original = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("openURL:"))!
        let replacement = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("prFixture_openURL:"))!
        method_exchangeImplementations(original, replacement)
    }
}

extension NSWorkspace {
    @objc(prFixture_openURL:) func prFixture_open(_ url: URL) -> Bool {
        MainActor.assumeIsolated { OpenFixture.url = url }
        return true
    }
}

@main @MainActor
struct ProjectPullRequestSurfaceTests {
    static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    static func wait(_ message: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { pump(0.02) }
        precondition(condition(), message)
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppSettings.shared.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.resumeAgentConversations = false
        OpenFixture.exchange()
        defer { OpenFixture.exchange() }

        let manager = TerminalManager()
        guard let project = manager.selectedProject, let session = project.selectedSession else {
            fatalError("missing project or terminal surface")
        }
        precondition(CommandLine.arguments[1] == "ghostty"
            ? session.surface is ZshellTerminalView : session.surface is AlacrittyTerminalView,
            "the requested terminal backend was not created")
        let checkoutPath = CommandLine.arguments[2]
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = root
        // The bar sits in a SwiftUI stack exactly as it does in the Git panel.
        let panel = NSHostingView(rootView: VStack(spacing: 0) {
            GitPullRequestBar(directory: checkoutPath, fontScale: 1).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.frame(width: 240, height: 400))
        panel.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        session.surface.frame = NSRect(x: 240, y: 0, width: 400, height: 400)
        root.addSubview(panel)
        root.addSubview(session.surface)
        session.surface.setSurfaceVisible(true)
        root.layoutSubtreeIfNeeded()
        var probes: [TerminalSession] = []
        defer {
            probes.forEach { $0.surface.setSurfaceVisible(false) }
            session.surface.setSurfaceVisible(false)
            manager.windowClosed()
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
            _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
        }

        func bar() -> GitPullRequestBarView? {
            descendants(panel).compactMap { $0 as? GitPullRequestBarView }.first
        }
        let environment = ProcessInfo.processInfo.environment
        let proxyLog = URL(fileURLWithPath: environment["ZSHELL_PR_PROXY_FILE"]!)
        func proxiesSeenByGH() -> [String] {
            ((try? String(contentsOf: proxyLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        // Proxy off (the default): the PR lookup and a new terminal's Git see nothing.
        precondition(!AppSettings.shared.gitProxyEnabled && AppSettings.shared.gitProxyAddress == GitProxy.defaultAddress,
                     "Git proxy must default to off with the default address prefilled")
        wait("first PR was not displayed") { bar()?.button.title.contains("#1") == true }
        precondition(proxiesSeenByGH().allSatisfy { $0 == "none" }, "PR lookup used a proxy while it was off")
        func terminalGitProxy(_ name: String) -> String {
            let output = URL(fileURLWithPath: environment["ZSHELL_PR_TERMINAL_DIRECTORY"]!).appendingPathComponent(name)
            let script = "printf '%s' \"$(git config --get http.proxy)\" > '\(output.path).tmp' && mv '\(output.path).tmp' '\(output.path)'"
            guard let probe = project.newSession(directory: checkoutPath, commandArguments: ["/bin/sh", "-c", script]) else {
                fatalError("could not open a terminal probe")
            }
            probes.append(probe)
            probe.surface.frame = session.surface.frame
            root.addSubview(probe.surface)
            probe.surface.setSurfaceVisible(true)
            wait("terminal \(name) did not run Git") { FileManager.default.fileExists(atPath: output.path) }
            return try! String(contentsOf: output, encoding: .utf8)
        }
        precondition(terminalGitProxy("off").isEmpty, "terminal Git saw a proxy while it was off")

        guard let item = bar() else { fatalError("Git panel PR bar missing") }
        root.layoutSubtreeIfNeeded()
        precondition(item.frame.height > 0 && item.bounds.contains(item.button.frame), "PR button exceeds the Git panel bar")
        precondition(item.button.isEnabled, "PR button is disabled")
        let buttonPoint = NSPoint(x: item.button.frame.midX, y: item.button.frame.midY)
        precondition(item.hitTest(item.convert(buttonPoint, to: item.superview)) === item.button, "PR button is not hit-testable")
        if let path = environment["ZSHELL_PR_TEST_SCREENSHOT"],
           let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: image)
            try! image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        item.button.performClick(nil)
        wait("PR click did not open the expected URL") { OpenFixture.url?.absoluteString == "https://github.com/example/base/pull/1" }

        // Proxy on: both the lookup and Git in a newly opened terminal use it.
        AppSettings.shared.gitProxyEnabled = true
        OpenFixture.url = nil
        let checkout = Process()
        checkout.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        checkout.currentDirectoryURL = URL(fileURLWithPath: checkoutPath)
        checkout.arguments = ["checkout", "-qb", "feature/other"]
        try! checkout.run()
        checkout.waitUntilExit()
        precondition(checkout.terminationStatus == 0, "fixture checkout failed")
        item.button.performClick(nil)
        pump(0.3)
        precondition(OpenFixture.url == nil, "old PR opened after branch switch")
        wait("new branch PR was not displayed") { bar()?.button.title.contains("#2") == true }
        precondition(proxiesSeenByGH().last == GitProxy.defaultAddress, "PR lookup ignored the Git proxy")
        bar()?.button.performClick(nil)
        wait("new branch PR click did not open expected URL") { OpenFixture.url?.absoluteString == "https://github.com/example/base/pull/2" }
        precondition(terminalGitProxy("on") == GitProxy.defaultAddress, "terminal Git did not use the Git proxy")

        let refreshTitle = String(localized: "Refresh Pull Request Status")
        guard let refresh = item.menu?.items.first(where: { $0.title == refreshTitle }), refresh.isEnabled,
              item.button.menu === item.menu else { fatalError("refresh menu item missing") }
        let queryFile = URL(fileURLWithPath: environment["ZSHELL_PR_COUNT_FILE"]!)
        let previousCount = (try? Data(contentsOf: queryFile).count) ?? 0
        _ = refresh.target?.perform(refresh.action)
        wait("refresh did not issue another query") { ((try? Data(contentsOf: queryFile).count) ?? 0) > previousCount }

        AppSettings.shared.gitProxyEnabled = false
        precondition(terminalGitProxy("off-again").isEmpty, "terminal Git kept the proxy after it was turned off")
        let detached = GitPullRequestBarView()
        detached.update(directory: nil, fontScale: 1)
        pump(0.1)
        precondition(detached.intrinsicContentSize.height == 0 && detached.isHidden, "a folder without a PR context must take no space")
        print("Git panel PR \(CommandLine.arguments[1]): real terminal, window, branch switch, click, refresh and Git proxy passed")
    }
}
