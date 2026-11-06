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
        wait("点击行内评论未打开原生讨论") { app.windows.contains { $0.title == String(localized: "Pull Request Review") && $0.isVisible } }
        let discussionWindow = app.windows.first { $0.title == String(localized: "Pull Request Review") && $0.isVisible }!
        let discussionViews = descendants(discussionWindow.contentView!)
        let replyButton = discussionViews.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Reply") }!
        let replyEditor = discussionViews.compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        wait("讨论未加载或权限缺失") {
            discussionViews.compactMap { $0 as? NSTextView }.contains { $0.string.contains("当前行的意见") }
                && discussionViews.compactMap { $0 as? NSButton }.contains { $0.title == String(localized: "Resolve Discussion") && $0.isEnabled }
        }
        precondition(ReviewOpenFixture.opened == nil, "查看讨论不得自动跳转GitHub或提交")
        precondition(!replyButton.isEnabled, "空回复不得提交")
        replyEditor.string = "Unsent reply <script>quoted()</script>"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        wait("非空回复未启用") { replyButton.isEnabled }
        replyButton.performClick(nil)
        wait("权限错误未展示") {
            discussionViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == ProjectPullRequestReviewActionError.forbidden.message }
        }
        precondition(replyEditor.string.contains("Unsent reply"), "提交失败必须保留回复草稿")
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            wait("语言切换未刷新评审错误或回复按钮") {
                discussionViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == ProjectPullRequestReviewActionError.forbidden.message }
                    && replyButton.title == String(localized: "Reply")
            }
            precondition(replyEditor.string.contains("Unsent reply"), "语言切换必须保留回复草稿")
        }
        AppLocalization.apply(.english)
        wait("恢复英文后评审控件未刷新") {
            discussionViews.compactMap { $0 as? NSButton }.contains { $0.title == String(localized: "Open on GitHub") }
                && replyButton.title == String(localized: "Reply")
        }
        replyEditor.string = ""
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        let openButton = discussionViews.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Open on GitHub") }!
        openButton.performClick(nil)
        wait("讨论外链未打开对应GitHub讨论") { ReviewOpenFixture.opened?.fragment == "discussion_right" }
        precondition(ReviewOpenFixture.opened?.host == "github.com", "评论链接必须由原PR身份核验")
        discussionWindow.close()
        diff.showPullRequestReview()
        wait("评审提交窗口未显示") { discussionWindow.isVisible }
        let decision = discussionViews.compactMap { $0 as? NSPopUpButton }.first!
        wait("评审权限未加载") { decision.isEnabled }
        precondition(decision.indexOfSelectedItem == 0 && decision.numberOfItems == 3,
                     "评审必须默认Comment，提供Approve和Request Changes")
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSHELL_PR_REVIEW_FIXTURES"]!)
        let actionDelay = fixtures.appendingPathComponent("action-thread-delay")
        let actionStarted = fixtures.appendingPathComponent("action-thread-started")
        try! Data().write(to: actionDelay)
        diff.showPullRequestReview(threadID: "right")
        wait("延迟讨论查询未开始") { FileManager.default.fileExists(atPath: actionStarted.path) }
        diff.showPullRequestReview()
        precondition(!discussionViews.compactMap { $0 as? NSTextView }.contains { $0.string.contains("当前行的意见") },
                     "切换评审目标必须立即清除旧讨论")
        wait("切换后评审权限未加载") { decision.isEnabled }
        pump(0.6)
        precondition(discussionViews.compactMap { $0 as? NSTextView }.contains {
            $0.string == String(localized: "Submit your review of this pull request. The review is attached to the displayed commit.")
        }, "旧讨论的异步响应不得覆盖新的评审目标")
        try! FileManager.default.removeItem(at: actionDelay)
        try! FileManager.default.removeItem(at: actionStarted)
        discussionWindow.close()

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

        let peerDiff = DiffTab(repoRoot: CommandLine.arguments[5], path: "Review.swift", staged: false, untracked: false, origPath: nil)
        let peerView = DiffViewerNSView(diff: peerDiff)
        let peerWindow = NSWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 820, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        peerWindow.isReleasedWhenClosed = false
        peerWindow.contentView = peerView
        peerView.setSelected(true)
        peerWindow.orderFront(nil)
        defer {
            peerDiff.pullRequest.detach()
            peerWindow.orderOut(nil)
            peerWindow.contentView = nil
            peerWindow.close()
        }
        wait("第二个worktree未完成PR状态加载") { !peerDiff.isLoading && peerDiff.canShowPullRequestComments }
        peerDiff.showPullRequestComments()
        wait("第二个worktree未显示PR评论") { if case .ready = peerDiff.pullRequestReviewState { return peerDiff.pullRequestWeb.isReady }; return false }
        peerDiff.showPullRequestReview(threadID: "right")
        let peerPanel = app.windows.first { $0 !== discussionWindow && $0.title == String(localized: "Pull Request Review") && $0.isVisible }!
        let peerViews = descendants(peerPanel.contentView!)
        let peerEditor = peerViews.compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        let peerReply = peerViews.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Reply") }!
        wait("第二个worktree未加载讨论权限") {
            peerViews.compactMap { $0 as? NSButton }.contains { $0.title == String(localized: "Resolve Discussion") && $0.isEnabled }
        }
        peerEditor.string = "Peer draft survives another worktree's write"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: peerEditor)
        wait("第二个worktree草稿未启用回复") { peerReply.isEnabled }

        try! Data().write(to: fixtures.appendingPathComponent("mutation-success"))
        try! Data().write(to: fixtures.appendingPathComponent("review-delay"))
        func mutations() -> [String] {
            ((try? String(contentsOf: fixtures.appendingPathComponent("mutations"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func renderedDiscussion(_ value: String, in views: [NSView]) -> Bool {
            views.compactMap { $0 as? NSTextView }.contains { !$0.isEditable && $0.string.contains(value) }
        }
        diff.showPullRequestReview(threadID: "right")
        let resolution = discussionViews.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Resolve Discussion") }!
        wait("回复成功流程未加载权限") { resolution.isEnabled }
        let successBody = "Successful reply 你好 <script>literal()</script>"
        replyEditor.string = successBody
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        wait("成功回复未启用提交") { replyButton.isEnabled }
        replyButton.performClick(nil)
        wait("成功回复未返回") { mutations() == ["reply"] && replyEditor.string.isEmpty }
        wait("成功回复后未开始延迟diff刷新") { if case .loading = diff.pullRequestReviewState { return true }; return false }
        pump(0.25)
        precondition(!replyButton.isEnabled && !resolution.isEnabled, "diff刷新完成前不得再次写入")
        wait("成功回复后diff未恢复") { if case .ready = diff.pullRequestReviewState { return true }; return false }
        wait("成功回复后讨论或解决按钮未恢复") { renderedDiscussion(successBody, in: discussionViews) && resolution.isEnabled }
        precondition(replyEditor.string.isEmpty, "成功回复必须清空草稿")
        replyEditor.string = "Second successful reply"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        wait("成功回复后不能再次回复") { replyButton.isEnabled }
        replyButton.performClick(nil)
        wait("第二次回复未返回") { mutations() == ["reply", "reply"] && replyEditor.string.isEmpty }
        wait("第二次回复后操作未恢复") { resolution.isEnabled && renderedDiscussion("Second successful reply", in: discussionViews) }
        wait("同PR另worktree仍显示旧评论") {
            if case .failed(.changed) = peerDiff.pullRequestReviewState { return true }
            if case .ready(let peerFile) = peerDiff.pullRequestReviewState {
                return peerFile.threads.flatMap(\.comments.nodes).contains { $0.body == "Second successful reply" }
            }
            return false
        }
        if case .ready = peerDiff.pullRequestReviewState {
            wait("同PR另worktree讨论窗口未刷新") { renderedDiscussion("Second successful reply", in: peerViews) && peerReply.isEnabled }
        } else { precondition(!peerReply.isEnabled, "失效的另worktree讨论不得继续写入") }
        precondition(peerEditor.string == "Peer draft survives another worktree's write", "跨worktree刷新必须保留未发送草稿")
        peerEditor.string = ""
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: peerEditor)
        peerPanel.close()
        print("成功回复与跨worktree同步通过")

        resolution.performClick(nil)
        wait("解决讨论后按钮未恢复为重新打开") {
            resolution.title == String(localized: "Reopen Discussion") && resolution.isEnabled
                && renderedDiscussion(String(localized: "Resolved"), in: discussionViews)
        }
        resolution.performClick(nil)
        wait("重新打开讨论后按钮未恢复") {
            resolution.title == String(localized: "Resolve Discussion") && resolution.isEnabled
                && renderedDiscussion(String(localized: "Unresolved"), in: discussionViews)
        }
        precondition(mutations() == ["reply", "reply", "resolveReviewThread", "unresolveReviewThread"],
                     "解决与重开必须各提交一次")
        print("成功解决／重开讨论通过")

        for (index, event) in ["COMMENT", "APPROVE", "REQUEST_CHANGES"].enumerated() {
            discussionWindow.close()
            diff.showPullRequestReview()
            wait("成功评审未加载权限") { discussionWindow.isVisible && decision.isEnabled }
            decision.selectItem(at: index)
            decision.sendAction(decision.action, to: decision.target)
            replyEditor.string = index == 1 ? "" : "Successful \(event) review"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
            wait("评审选项未启用提交：\(event)") { replyButton.isEnabled }
            replyButton.performClick(nil)
            wait("成功评审未关闭窗口：\(event)") { !discussionWindow.isVisible && mutations().last == event }
            precondition(replyEditor.string.isEmpty, "成功评审必须清空草稿")
            wait("成功评审后diff未恢复") { if case .ready = diff.pullRequestReviewState { return true }; return false }
        }
        print("Comment／Approve／Request Changes成功关窗通过")

        diff.showPullRequestReview(threadID: "right")
        wait("切回本地diff前讨论未加载") { resolution.isEnabled }
        diff.hidePullRequestComments()
        wait("讨论窗口打开时未返回本地diff") { !diff.showsPullRequestComments && ordinary.superview != nil && review.superview == nil }
        let hiddenStart = mutations().count
        for index in 1...2 {
            replyEditor.string = "Reply from local diff \(index)"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
            wait("本地diff中的讨论不能回复") { replyButton.isEnabled }
            replyButton.performClick(nil)
            wait("本地diff中的成功回复未清空草稿") { mutations().count == hiddenStart + index && replyEditor.string.isEmpty }
            wait("本地diff中的回复后操作未恢复") {
                resolution.isEnabled && renderedDiscussion("Reply from local diff \(index)", in: discussionViews)
            }
            precondition(!diff.showsPullRequestComments && ordinary.superview != nil && review.superview == nil,
                         "讨论成功回复不得将本地diff切回PR评论")
        }
        print("切回本地diff后连续回复与视图保留通过")
        diff.showPullRequestComments()
        wait("生命周期测试后评论未恢复") { if case .ready = diff.pullRequestReviewState { return review.superview != nil }; return false }

        peerDiff.showPullRequestReview(threadID: "right")
        wait("释放源标签测试前peer讨论未加载") {
            peerViews.compactMap { $0 as? NSButton }.contains { $0.title == String(localized: "Resolve Discussion") && $0.isEnabled }
        }
        peerEditor.string = "Peer draft survives closing the source tab"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: peerEditor)
        wait("释放源标签测试前peer回复未启用") { peerReply.isEnabled }
        let delayedMutation = fixtures.appendingPathComponent("mutation-response-delay")
        let acceptedMutation = fixtures.appendingPathComponent("mutation-accepted")
        try! Data().write(to: delayedMutation)
        let closingBody = "Reply accepted after the source tab closes"
        weak var releasedDiff: DiffTab?
        weak var releasedPanel: NSWindow?
        autoreleasepool {
            var source: DiffTab? = DiffTab(repoRoot: root, path: "Review.swift", staged: false, untracked: false, origPath: nil)
            releasedDiff = source
            source!.pullRequest.sync(directory: root, force: true)
            wait("待关闭源标签未加载PR身份") { source!.canShowPullRequestComments }
            source!.showPullRequestComments()
            wait("待关闭源标签未加载评论") { if case .ready = source!.pullRequestReviewState { return true }; return false }
            source!.showPullRequestReview(threadID: "right")
            do {
                let panel = app.windows.first {
                    $0 !== discussionWindow && $0 !== peerPanel && $0.title == String(localized: "Pull Request Review") && $0.isVisible
                }!
                releasedPanel = panel
                let views = descendants(panel.contentView!)
                let editor = views.compactMap { $0 as? NSTextView }.first { $0.isEditable }!
                let submit = views.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Reply") }!
                wait("待关闭源讨论未加载权限") {
                    views.compactMap { $0 as? NSButton }.contains { $0.title == String(localized: "Resolve Discussion") && $0.isEnabled }
                }
                editor.string = closingBody
                NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
                wait("待关闭源回复未启用") { submit.isEnabled }
                submit.performClick(nil)
                wait("待关闭源写入未被fixture接受") { FileManager.default.fileExists(atPath: acceptedMutation.path) }
                panel.close()
            }
            source!.pullRequest.detach()
            source = nil
        }
        wait("提交期间源标签未释放") { releasedDiff == nil }
        pump(0.8)
        wait("源标签释放后peer未收到成功刷新") {
            if case .ready(let peerFile) = peerDiff.pullRequestReviewState {
                return peerFile.threads.flatMap(\.comments.nodes).contains { $0.body == closingBody }
                    && renderedDiscussion(closingBody, in: peerViews) && peerReply.isEnabled
            }
            return false
        }
        precondition(peerEditor.string == "Peer draft survives closing the source tab", "源标签关闭后的刷新必须保留peer草稿")
        precondition(releasedPanel?.isVisible != true, "已关闭的源讨论不得重新弹出")
        try! FileManager.default.removeItem(at: delayedMutation)
        try! FileManager.default.removeItem(at: acceptedMutation)
        peerEditor.string = ""
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: peerEditor)
        peerPanel.close()
        print("接受写入后释放源标签仍同步peer通过")

        diff.showPullRequestReview(threadID: "right")
        wait("head变化检查前讨论未加载") { resolution.isEnabled }
        try! CommandLine.arguments[4].write(to: fixtures.appendingPathComponent("changed-head"), atomically: true, encoding: .utf8)
        diff.showPullRequestComments(force: true)
        wait("head变化后diff未加载新版本") {
            if case .ready(let changedFile) = diff.pullRequestReviewState { return changedFile.headOID != file.headOID }
            return false
        }
        replyEditor.string = "Stale revision must not submit"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        precondition(!replyButton.isEnabled && !resolution.isEnabled, "head变化后旧讨论必须禁写")
        let countBeforeStale = mutations().count
        replyButton.performClick(nil)
        pump(0.1)
        precondition(mutations().count == countBeforeStale, "旧head不得发mutation")
        replyEditor.string = ""
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        try! FileManager.default.removeItem(at: fixtures.appendingPathComponent("changed-head"))
        diff.showPullRequestComments(force: true)
        wait("恢复head后diff未完成") { if case .ready(let restored) = diff.pullRequestReviewState { return restored.headOID == file.headOID }; return false }
        discussionWindow.close()
        diff.showPullRequestReview(threadID: "right")
        wait("分支变化检查前讨论未加载") { resolution.isEnabled }
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
        replyEditor.string = "Stale branch must not submit"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: replyEditor)
        precondition(!replyButton.isEnabled && !resolution.isEnabled, "分支变化后旧讨论必须禁写")
        replyButton.performClick(nil)
        pump(0.1)
        precondition(mutations().count == countBeforeStale, "旧分支不得发mutation")
        replyEditor.string = ""
        discussionWindow.close()
        diff.setEditing(false)
        print("真实AppKit/WebKit PR评论：懒加载、左右对应行、分页、纯文本、原生讨论回复与失败草稿、评审选择、链接、窄布局、刷新、双视图编辑滚动保留及分支切换失效通过")
    }
}
