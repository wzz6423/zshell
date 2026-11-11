import AppKit
import WebKit
import PierreDiffsSwift
@testable import zshell

@main @MainActor
struct DiffWrapSurfaceTests {
    static func pump(_ duration: TimeInterval = 0.02) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func wait(_ message: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { pump() }
        precondition(condition(), message)
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func evaluate(_ web: WKWebView, _ script: String) -> Any? {
        var finished = false
        var result: Any?
        var failure: Error?
        // Offscreen WebKit throttles animation frames; flush the real virtualizer.
        web.evaluateJavaScript("window.__INSTANCE?.render(true);" + script) { value, error in
            result = value
            failure = error
            finished = true
        }
        wait("WebKit script did not finish") { finished }
        precondition(failure == nil, "WebKit script failed: \(String(describing: failure))")
        return result
    }

    static func webView(in view: NSView?) -> WKWebView {
        guard let view, let web = descendants(view).compactMap({ $0 as? WKWebView }).first else {
            fatalError("Diff host has no WebView")
        }
        return web
    }

    static func wrapButton(in view: NSView) -> NSButton {
        guard let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: {
            $0.accessibilityLabel() == String(localized: "Wrap lines to diff width")
        }) else { fatalError("Native diff toolbar has no wrapping button") }
        precondition(button.image != nil, "Diff wrap button has no visible symbol")
        precondition(!button.isHiddenOrHasHiddenAncestor && !button.visibleRect.isEmpty,
            "Diff wrap button is not visible in the pane")
        return button
    }

    static func wrapping(_ web: WKWebView, _ wraps: Bool) -> Bool {
        let modes = evaluate(web, "Array.from(document.querySelectorAll('diffs-container')).flatMap(node => Array.from(node.shadowRoot?.querySelectorAll('[data-overflow]') || [])).map(node => node.dataset.overflow)") as? [String] ?? []
        return !modes.isEmpty && modes.allSatisfy { $0 == (wraps ? "wrap" : "scroll") }
    }

    static func lineGeometry(_ web: WKWebView) -> [String: Double] {
        evaluate(web, """
            (() => {
              const line = Array.from(document.querySelectorAll('diffs-container')).flatMap(node =>
                Array.from(node.shadowRoot?.querySelectorAll('[data-line]') || [])).find(node => node.textContent.includes('long_token_'));
              if (!line) return {};
              return {height:line.getBoundingClientRect().height, width:line.clientWidth, scrollWidth:line.scrollWidth};
            })()
            """) as? [String: Double] ?? [:]
    }

    static func mount(_ diff: DiffTab, width: CGFloat = 640) -> (NSWindow, DiffViewerNSView) {
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: width, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DiffViewerNSView(diff: diff)
        window.contentView = view
        view.setSelected(true)
        window.orderFront(nil)
        wait("Diff did not load") { !diff.isLoading && diff.web.isReady && diff.webHostView != nil }
        return (window, view)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let settings = AppSettings.shared
        settings.diffWrapLines = false
        settings.fontSize = 12
        let root = CommandLine.arguments[1]
        let ordinary = DiffTab(repoRoot: root, path: "Review.swift", staged: false, untracked: false, origPath: nil)
        let (window, view) = mount(ordinary)
        let web = webView(in: ordinary.webHostView)
        ordinary.setEditing(false)
        ordinary.setDiffStyle(.unified)
        var windows = [window]
        var tabs = [ordinary]
        defer {
            tabs.forEach { $0.pullRequest.detach() }
            windows.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() }
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        wait("Default diff did not use horizontal scrolling") { wrapping(web, false) }
        let scrolling = lineGeometry(web)
        precondition(scrolling["height"] != nil, "Long line fixture did not render")
        let snapshot = ordinary.reviewSnapshot
        if let snapshot { DiffReviewStore.shared.setReviewed(true, for: snapshot) }
        let host = ordinary.webHostView
        let button = wrapButton(in: view)
        button.performClick(nil)
        wait("Toolbar did not wrap long lines") { settings.diffWrapLines && wrapping(web, true) }
        let wrapped = lineGeometry(web)
        precondition((wrapped["height"] ?? 0) > (scrolling["height"] ?? 0) * 2, "Long Unicode/tab line did not visually wrap")
        precondition((wrapped["scrollWidth"] ?? 0) <= (wrapped["width"] ?? 0) + 1, "Wrapped line still overflows horizontally")
        precondition(button.state == .on && ordinary.webHostView === host, "Wrap toggle recreated the host or lost its state")
        precondition(ordinary.reviewSnapshot == snapshot && snapshot.map(DiffReviewStore.shared.isReviewed) == true,
            "A display option invalidated exact-change review status")
        wait("Toolbar did not persist its setting") { TOML.parse(at: AppSettings.configURL)?["editor.diff-wrap-lines"]?.bool == true }

        let history = DiffTab(repoRoot: root, path: "Review.swift", staged: false, untracked: false,
            origPath: "Before.swift", commitHash: CommandLine.arguments[2])
        let (historyWindow, historyView) = mount(history)
        windows.append(historyWindow)
        tabs.append(history)
        let historyWeb = webView(in: history.webHostView)
        wait("New historical diff ignored the global setting") { wrapping(historyWeb, true) }
        precondition(!history.isEditable, "Historical diff became editable")

        let editorPane = SettingsEditorPane()
        editorPane.setCategory(.editor)
        let settingsWindow = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 500, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentViewController = editorPane
        settingsWindow.orderFront(nil)
        windows.append(settingsWindow)
        pump(0.1)
        let settingsSwitch = descendants(editorPane.view).compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == String(localized: "Wrap lines to diff width")
        }!
        wait("Editor settings did not synchronize with the toolbar") { settingsSwitch.state == .on }
        settingsSwitch.performClick(nil)
        wait("Editor settings did not update both open diffs") { !settings.diffWrapLines && wrapping(web, false) && wrapping(historyWeb, false) }
        ordinary.setDiffStyle(.split)
        button.performClick(nil)
        wait("Split diff did not wrap") { wrapping(web, true) }
        precondition((lineGeometry(web)["height"] ?? 0) > (wrapped["height"] ?? 0), "Split-column width did not affect wrapping")

        ordinary.setEditing(true)
        wait("Diff editor did not attach") { evaluate(web, "window.__INSTANCE?.getEditor('Review.swift') != null") as? Bool == true }
        let initial = ordinary.web.newContent
        _ = evaluate(web, """
            window.wrapEditor = window.__INSTANCE.getEditor('Review.swift');
            window.wrapEditor.applyEdits([{range:{start:{line:0,character:0},end:{line:0,character:0}},newText:'// Unsaved wrapping draft\\n'}]);
            window.wrapEditor.setSelections([{start:{line:0,character:3},end:{line:0,character:9}}]);
            window.wrapSelection = JSON.stringify(window.wrapEditor.getState().selections);
            document.getElementById('diff-container').scrollTop = 55;
            """)
        wait("Editor did not publish unsaved content") { ordinary.isDirty && ordinary.unsavedText?.hasPrefix("// Unsaved wrapping draft") == true }
        let draft = ordinary.unsavedText
        let scroll = evaluate(web, "document.getElementById('diff-container').scrollTop") as? Double ?? 0
        settings.diffWrapLines = false
        wait("Editable diff did not switch to scrolling") { wrapping(web, false) }
        settings.diffWrapLines = true
        wait("Editable diff did not switch back to wrapping") { wrapping(web, true) }
        precondition(evaluate(web, "window.__INSTANCE.getEditor('Review.swift') === window.wrapEditor && JSON.stringify(window.wrapEditor.getState().selections) === window.wrapSelection && window.wrapEditor.canUndo") as? Bool == true,
            "Wrapping lost editor identity, selection, or undo history")
        precondition(ordinary.isDirty && ordinary.unsavedText == draft && ordinary.web.newContent == initial,
            "Wrapping replaced or saved the edit draft")
        precondition(abs((evaluate(web, "document.getElementById('diff-container').scrollTop") as? Double ?? 0) - scroll) < 2,
            "Wrapping moved an unaffected scroll anchor")

        for backend in TerminalBackend.allCases {
            settings.terminalBackend = backend
            settings.diffWrapLines = false
            wait("Diff rendering depended on a terminal backend") { wrapping(web, false) && wrapping(historyWeb, false) }
            settings.diffWrapLines = true
            wait("Diff wrapping did not apply with \(backend.rawValue)") { wrapping(web, true) && wrapping(historyWeb, true) }
        }

        wait("PR comments entry did not appear") { ordinary.canShowPullRequestComments }
        ordinary.showPullRequestComments()
        wait("PR comments diff did not load") { if case .ready = ordinary.pullRequestReviewState { return ordinary.pullRequestWeb.isReady }; return false }
        let commentsWeb = webView(in: ordinary.pullRequestWebHostView)
        wait("PR comments ignored wrapping") { wrapping(commentsWeb, true) }
        let commentsHost = ordinary.pullRequestWebHostView
        let reviewState = ordinary.pullRequestReviewState
        precondition(evaluate(commentsWeb, "window.__INSTANCE?.getEditor('Review.swift') == null") as? Bool == true,
            "PR comments became editable")
        wrapButton(in: view).performClick(nil)
        wait("PR toolbar did not synchronize all renderers") { wrapping(web, false) && wrapping(commentsWeb, false) && wrapping(historyWeb, false) }
        precondition(ordinary.pullRequestWebHostView === commentsHost && ordinary.pullRequestReviewState == reviewState
            && ordinary.unsavedText == draft, "PR wrapping replaced review data, host, or local draft")
        for width in [180.0, 240, 320] {
            window.setContentSize(NSSize(width: width, height: 560))
            for _ in 0..<3 { view.layoutSubtreeIfNeeded(); pump() }
            precondition(!wrapButton(in: view).isHiddenOrHasHiddenAncestor, "Narrow PR toolbar lost its wrap button")
            let visible = descendants(view).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            precondition(visible.allSatisfy { view.convert($0.bounds, from: $0).maxX <= width + 1 }, "PR toolbar escaped its pane")
        }
        ordinary.hidePullRequestComments()
        ordinary.setEditing(false)
        wait("Read-only diff did not show the final draft") { ordinary.web.newContent == draft }

        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let localizedPane = SettingsEditorPane()
            localizedPane.setCategory(.editor)
            settingsWindow.contentViewController = localizedPane
            for _ in 0..<3 { localizedPane.view.layoutSubtreeIfNeeded(); pump() }
            let icon = descendants(localizedPane.view).compactMap { $0 as? SettingsIconView }.first!
            precondition(icon.frame.size == NSSize(width: 32, height: 32), "Diff setting icon is not square")
            precondition(descendants(icon).compactMap { $0 as? NSImageView }.contains { $0.image != nil },
                "Diff setting icon has no visible symbol")
            let search = SettingsSearchIndex.results(for: "editor.diff-wrap-lines")
            precondition(search.count == 1 && search.first?.title == String(localized: "Wrap lines to diff width"),
                "Diff setting did not appear in localized search")
            for width in [180.0, 240, 320, 480, 820, 240, 820] {
                ordinary.setEditing(true)
                window.setContentSize(NSSize(width: width, height: 560))
                for _ in 0..<3 { view.layoutSubtreeIfNeeded(); pump() }
                let visible = descendants(view).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
                let frames = visible.map { view.convert($0.bounds, from: $0) }
                precondition(frames.allSatisfy { $0.minX >= -1 && $0.maxX <= width + 1 },
                    "Toolbar escaped pane bounds: \(language.rawValue) \(width) \(frames)")
                for index in frames.indices {
                    for other in frames.indices where index < other {
                        precondition(!frames[index].intersects(frames[other]), "Toolbar controls overlap: \(language.rawValue) \(width)")
                    }
                }
                let localizedButton = wrapButton(in: view)
                precondition(!localizedButton.isHiddenOrHasHiddenAncestor && localizedButton.frame.size == NSSize(width: 24, height: 24),
                    "Wrap entry was hidden or lost its square frame")
                let options = descendants(view).compactMap { $0 as? NSButton }.first {
                    $0.accessibilityLabel() == String(localized: "Diff Options")
                }!
                if width == 180 {
                    precondition(!options.isHiddenOrHasHiddenAncestor, "Narrow pane has no native overflow menu")
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.tag = 7
                    options.superview!.superview!.perform(NSSelectorFromString("optionSelected:"), with: item)
                    precondition(ordinary.diffStyle == .split, "Overflow menu failed to apply split layout")
                }
            }
        }
        ordinary.setEditing(false)
        AppLocalization.apply(.english)
        if let directory = ProcessInfo.processInfo.environment["ZSHELL_DIFF_WRAP_GUI_DIRECTORY"] {
            let pane = SettingsEditorPane()
            pane.setCategory(.editor)
            settingsWindow.contentViewController = pane
            window.setContentSize(NSSize(width: 640, height: 560))
            historyWindow.setContentSize(NSSize(width: 640, height: 560))
            window.setFrameOrigin(NSPoint(x: 90, y: 170))
            historyWindow.setFrameOrigin(NSPoint(x: 750, y: 170))
            settingsWindow.setFrameOrigin(NSPoint(x: 90, y: 20))
            settings.diffWrapLines = true
            window.title = "Diff Wrapping"
            historyWindow.title = "Historical Diff Wrapping"
            settingsWindow.title = "Editor Settings"
            let ready = URL(fileURLWithPath: directory).appendingPathComponent("ready")
            try! String(ProcessInfo.processInfo.processIdentifier).write(to: ready, atomically: true, encoding: .utf8)
            while !FileManager.default.fileExists(atPath: URL(fileURLWithPath: directory).appendingPathComponent("done").path) { pump(0.1) }
        }
        withExtendedLifetime(historyView) {}
        print("Native diff wrapping: toolbar/settings synchronization, Unicode/tab line geometry, unified/split/edit/history/PR, draft/selection/undo/review preservation, config persistence, and 17-language narrow layout passed")
    }
}
