import AppKit
import ObjectiveC.runtime
import WebKit
import PierreDiffsSwift
@testable import zshell

@MainActor private enum ReviewOpenFixture {
    static var opened: URL?
    static func exchange() {
        let original = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("openURL:"))!
        let replacement = class_getInstanceMethod(NSWorkspace.self, NSSelectorFromString("reviewFixture_openURL:"))!
        method_exchangeImplementations(original, replacement)
    }
}

extension NSWorkspace {
    @objc(reviewFixture_openURL:) func reviewFixture_open(_ url: URL) -> Bool {
        MainActor.assumeIsolated { ReviewOpenFixture.opened = url }
        return true
    }
}

@main @MainActor
struct ProjectPullRequestReviewSurfaceTests {
    static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    static func wait(_ message: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { pump(0.02) }
        precondition(condition(), message)
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var finished = false
        var result: Any?
        var failure: Error?
        // 离屏 WebKit 节流动画帧；同步入口推进真实 CodeView，不改变生产调度。
        webView.evaluateJavaScript("window.__INSTANCE?.render(true);" + script) { value, error in
            result = value
            failure = error
            finished = true
        }
        wait("WebKit脚本未完成") { finished }
        precondition(failure == nil, "WebKit脚本错误：\(String(describing: failure))")
        return result
    }

    static let annotationsScript = """
        (() => {
          const roots = [document, ...Array.from(document.querySelectorAll('diffs-container')).map(node => node.shadowRoot).filter(Boolean)];
          return roots.flatMap(root => Array.from(root.querySelectorAll('.pierre-annotation')).map(node => {
            const slot = node.closest('[slot]')?.getAttribute('slot');
            const target = slot && root.querySelector(`slot[name="${slot}"]`);
            return { id:node.dataset.annotationId, body:node.querySelector('.pierre-annotation-body').textContent,
                     readOnly:!node.querySelector('button'), role:node.getAttribute('role'),
                     line:target?.closest('[data-line]')?.getAttribute('data-line'),
                     slot:slot || '', html:node.querySelector('.pierre-annotation-body').innerHTML };
          }));
        })()
        """

    static func annotations(_ webView: WKWebView) -> [[String: Any]] {
        evaluate(webView, annotationsScript) as? [[String: Any]] ?? []
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppSettings.shared.fontSize = 12
        let root = CommandLine.arguments[1]
        let diff = DiffTab(repoRoot: root, path: "Review.swift", staged: false, untracked: false, origPath: nil)
        let window = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 820, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DiffViewerNSView(diff: diff)
        window.contentView = view
        view.setSelected(true)
        window.orderFront(nil)
        ReviewOpenFixture.exchange()
        defer {
            ReviewOpenFixture.exchange()
            diff.pullRequest.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        wait("普通diff未完成加载") { !diff.isLoading && diff.webHostView != nil && diff.web.isReady }
        guard let ordinary = diff.webHostView,
              let ordinaryWeb = descendants(ordinary).compactMap({ $0 as? WKWebView }).first else { fatalError("普通diff缺少WKWebView") }
        wait("PR入口未出现") { diff.canShowPullRequestComments }
        let log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_QUERY_LOG"]!)
        func queries() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        precondition(!queries().contains { $0.contains("reviewThreads") }, "点击之前不得加载评论")
        let initialNewContents = diff.web.newContent
        diff.setDiffStyle(.split)
        diff.setEditing(true)
        wait("普通diff编辑器未创建") {
            (evaluate(ordinaryWeb, "document.querySelector('diffs-container')?.shadowRoot?.querySelectorAll('[contenteditable=true]').length || 0") as? Int ?? 0) > 0
        }
        _ = evaluate(ordinaryWeb, "window.reviewPreserved = 'ordinary'; document.getElementById('diff-container').scrollTop = 45")
        pump(0.15)
        let scrollBefore = evaluate(ordinaryWeb, "document.getElementById('diff-container').scrollTop") as? Double ?? 0
        guard let comments = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == String(localized: "PR Comments") }) else {
            fatalError("PR Comments控件未出现")
        }
        comments.performClick(nil)
        wait("PR评论未显示") { if case .ready = diff.pullRequestReviewState { return diff.pullRequestWeb.isReady }; return false }
        guard let review = diff.pullRequestWebHostView,
              let reviewWeb = descendants(review).compactMap({ $0 as? WKWebView }).first,
              case .ready(let file) = diff.pullRequestReviewState else { fatalError("评论视图缺少WKWebView或数据") }
        wait("行内评论未渲染") { annotations(reviewWeb).count == 3 }
        precondition(file.headOID == CommandLine.arguments[2] && file.mergeBaseOID == CommandLine.arguments[3],
                     "评论必须读取精确PR版本")
        precondition(file.newContents != initialNewContents && diff.web.newContent == initialNewContents,
                     "PR版本与普通未提交diff必须各自保留")
        let shown = annotations(reviewWeb)
        precondition(Set(shown.compactMap { $0["id"] as? String }) == ["left", "right", "reply"], "分页回复或左右评论缺失")
        precondition(shown.allSatisfy { $0["readOnly"] as? Bool == true && $0["role"] as? String == "link" }, "PR评论不得显示编辑删除控件")
        precondition(evaluate(reviewWeb, "window.reviewInjected === true") as? Bool == false, "评论HTML不得执行")
        precondition(shown.contains { ($0["html"] as? String)?.contains("&lt;script&gt;") == true }, "评论必须按纯文本显示")
        precondition((evaluate(reviewWeb, "document.querySelector('diffs-container')?.shadowRoot?.querySelectorAll('[contenteditable=true]').length || 0") as? Int ?? 0) == 0,
                     "普通diff启用编辑后，PR评论仍须只读")
        let left = shown.first { $0["id"] as? String == "left" }!, right = shown.first { $0["id"] as? String == "right" }!
        precondition((left["slot"] as? String)?.contains("deletions-10") == true
            && (right["slot"] as? String)?.contains("additions-30") == true, "评论slot必须对应LEFT旧10行和RIGHT新30行")
        _ = evaluate(reviewWeb, "Array.from(document.querySelectorAll('diffs-container')).flatMap(node => Array.from(node.querySelectorAll('[data-annotation-id]'))).find(node => node.dataset.annotationId === 'right')?.click()")
        wait("点击行内评论未打开对应GitHub讨论") { ReviewOpenFixture.opened?.fragment == "discussion_right" }
        precondition(ReviewOpenFixture.opened?.host == "github.com", "评论链接必须由原PR身份核验")

        let statusDelay = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_FIXTURES"]!)
            .appendingPathComponent("status-delay")
        try! Data().write(to: statusDelay)
        diff.pullRequest.refresh()
        wait("PR后台刷新未进入加载状态") { if case .loading = diff.pullRequest.state { return true }; return false }
        pump(0.05)
        precondition(diff.currentPullRequestIdentity == file.identity && diff.pullRequestReviewState == .ready(file),
                     "同一分支的PR后台刷新不得使已显示评论失效")
        wait("PR后台刷新未完成") { if case .pullRequest = diff.pullRequest.state { return true }; return false }
        try! FileManager.default.removeItem(at: statusDelay)
        precondition(review.superview != nil && diff.pullRequestReviewState == .ready(file),
                     "后台刷新完成必须保留评论文档")

        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.apply(language)
            pump(0.1)
            let back = String(localized: "Back to Changes")
            wait("语言切换未刷新PR控件") {
                descendants(view).compactMap { $0 as? NSButton }.contains { $0.toolTip == back }
            }
            let segments = descendants(view).compactMap { $0 as? NSSegmentedControl }
            precondition(segments.contains { $0.label(forSegment: 0) == String(localized: "Review")
                && $0.label(forSegment: 1) == String(localized: "Edit") }, "语言切换未刷新Diff模式")
            precondition(segments.contains { $0.label(forSegment: 0) == String(localized: "Unified")
                && $0.label(forSegment: 1) == String(localized: "Split") }, "语言切换未刷新Diff布局")
            wait("语言切换未刷新评论状态") { diff.pullRequestWeb.annotations == file.annotations }
            precondition(diff.pullRequestWebHostView === review && diff.webHostView === ordinary,
                         "语言切换不得重建评论或本地diff文档")
        }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: name)
            pump(0.1)
            wait("外观切换未刷新评论") { diff.pullRequestWeb.usesDarkAppearance == (name == .darkAqua) }
            precondition(diff.pullRequestWebHostView === review && annotations(reviewWeb).count == 3,
                         "外观切换不得丢失评论文档")
        }

        let screenshotPath = ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_SCREENSHOT"]
        if let screenshotPath {
            var snapshot: NSImage?
            var finished = false
            reviewWeb.takeSnapshot(with: nil) { image, _ in snapshot = image; finished = true }
            wait("WebKit截图未完成") { finished }
            if let data = snapshot?.tiffRepresentation, let image = NSBitmapImageRep(data: data) {
                try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: screenshotPath))
            }
        }
        view.frame.size.width = 320
        view.layoutSubtreeIfNeeded()
        pump(0.1)
        for control in descendants(view).compactMap({ $0 as? NSControl }) where !control.isHidden && !control.isHiddenOrHasHiddenAncestor {
            if control is NSButton || control is NSSegmentedControl {
                let frame = control.convert(control.bounds, to: view)
                precondition(frame.minX >= -1 && frame.maxX <= view.bounds.width + 1, "窄屏控件超出diff范围：\(frame)")
            }
        }
        diff.hidePullRequestComments()
        wait("返回普通diff后未恢复同一视图") { ordinary.superview != nil && review.superview == nil }
        precondition(diff.webHostView === ordinary && evaluate(ordinaryWeb, "window.reviewPreserved") as? String == "ordinary",
                     "返回普通diff必须复用同一WebKit文档")
        let scrollAfter = evaluate(ordinaryWeb, "document.getElementById('diff-container').scrollTop") as? Double ?? 0
        precondition(abs(scrollAfter - scrollBefore) <= 1, "返回普通diff必须保持滚动位置")
        precondition((evaluate(ordinaryWeb, "document.querySelector('diffs-container')?.shadowRoot?.querySelectorAll('[contenteditable=true]').length || 0") as? Int ?? 0) > 0,
                     "返回普通diff必须保留编辑器")
        diff.showPullRequestComments()
        wait("重新打开评论未复用已加载视图") { review.superview != nil && diff.pullRequestWeb.isReady }
        precondition(diff.pullRequestWebHostView === review, "评论视图必须长期保留")
        let previousQueryCount = queries().filter { $0.contains("reviewThreads") }.count
        diff.showPullRequestComments(force: true)
        wait("刷新未重新查询") { queries().filter { $0.contains("reviewThreads") }.count > previousQueryCount }
        wait("刷新后评论未显示") { if case .ready = diff.pullRequestReviewState { return annotations(reviewWeb).count == 3 }; return false }
        let checkout = Process()
        checkout.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        checkout.currentDirectoryURL = URL(fileURLWithPath: root)
        checkout.arguments = ["checkout", "-qb", "feature/other"]
        try! checkout.run()
        checkout.waitUntilExit()
        precondition(checkout.terminationStatus == 0)
        diff.pullRequest.sync(directory: root, force: true)
        wait("分支切换仍显示旧评论") { if case .failed(.changed) = diff.pullRequestReviewState { return review.superview == nil }; return false }
        ReviewOpenFixture.opened = nil
        diff.pullRequestWeb.onAnnotationClick?("right")
        pump(0.1)
        precondition(ReviewOpenFixture.opened == nil, "分支切换后不得打开旧讨论")
        diff.setEditing(false)
        print("真实AppKit/WebKit PR评论：懒加载、左右对应行、分页、纯文本只读、链接、窄布局、刷新、双视图编辑滚动保留及分支切换失效通过")
    }
}
