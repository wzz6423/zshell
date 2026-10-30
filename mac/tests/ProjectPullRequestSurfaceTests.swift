import AppKit
import ObjectiveC.runtime
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
        project.customName = "PR fixture"
        project.customDirectory = CommandLine.arguments[2]
        let sidebar = ProjectSidebarNSView(manager: manager, tabDrag: TabSplitDragCoordinator(), bottomBarHeight: 40)
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = root
        sidebar.frame = NSRect(x: 0, y: 0, width: 180, height: 400)
        session.surface.frame = NSRect(x: 180, y: 0, width: 460, height: 400)
        root.addSubview(sidebar)
        root.addSubview(session.surface)
        session.surface.setSurfaceVisible(true)
        sidebar.refresh()
        root.layoutSubtreeIfNeeded()
        defer {
            sidebar.detach()
            session.surface.setSurfaceVisible(false)
            manager.windowClosed()
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
            _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
        }

        func row() -> WorkspaceItemView? {
            descendants(sidebar).compactMap { $0 as? WorkspaceItemView }.first { $0.titleLabel.stringValue == "PR fixture" }
        }
        wait("first PR was not displayed") { row()?.pullRequestButton.title.contains("#1") == true }
        guard let item = row() else { fatalError("project row missing") }
        root.layoutSubtreeIfNeeded()
        precondition(item.bounds.contains(item.pullRequestButton.frame), "PR button exceeds the project row")
        precondition(item.pullRequestButton.isEnabled, "PR button is disabled")
        let buttonPoint = NSPoint(x: item.frame.minX + item.pullRequestButton.frame.midX,
                                  y: item.frame.minY + item.pullRequestButton.frame.midY)
        precondition(item.hitTest(buttonPoint) === item.pullRequestButton, "PR button is not hit-testable")
        if let path = ProcessInfo.processInfo.environment["ZSHELL_PR_TEST_SCREENSHOT"],
           let image = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
            sidebar.cacheDisplay(in: sidebar.bounds, to: image)
            try! image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        item.pullRequestButton.performClick(nil)
        wait("PR click did not open the expected URL") { OpenFixture.url?.absoluteString == "https://github.com/example/base/pull/1" }

        OpenFixture.url = nil
        let checkout = Process()
        checkout.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        checkout.currentDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[2])
        checkout.arguments = ["checkout", "-qb", "feature/other"]
        try! checkout.run()
        checkout.waitUntilExit()
        precondition(checkout.terminationStatus == 0, "fixture checkout failed")
        item.pullRequestButton.performClick(nil)
        pump(0.3)
        precondition(OpenFixture.url == nil, "old PR opened after branch switch")
        wait("new branch PR was not displayed") { row()?.pullRequestButton.title.contains("#2") == true }
        row()?.pullRequestButton.performClick(nil)
        wait("new branch PR click did not open expected URL") { OpenFixture.url?.absoluteString == "https://github.com/example/base/pull/2" }

        let menu = item.menuItems?() ?? []
        let refreshTitle = String(localized: "Refresh Pull Request Status")
        let refresh = menu.compactMap { entry -> (() -> Void)? in
            if case .action(let title, let enabled, let handler) = entry, title == refreshTitle, enabled { return handler }
            return nil
        }.first
        guard let refresh else { fatalError("refresh menu item missing") }
        let queryFile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSHELL_PR_COUNT_FILE"]!)
        let previousCount = (try? Data(contentsOf: queryFile).count) ?? 0
        refresh()
        wait("refresh did not issue another query") { ((try? Data(contentsOf: queryFile).count) ?? 0) > previousCount }
        print("Project PR sidebar \(CommandLine.arguments[1]): real terminal, window, branch switch and click passed")
    }
}
