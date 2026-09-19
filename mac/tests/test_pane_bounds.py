"""Exercise production pane chrome beside a native content surface at narrow widths.

Run: python3 mac/tests/test_pane_bounds.py [--source-ref <git-ref>]
The offscreen fixture never sends input to the user's desktop.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "mac/zshell/PaneLayoutView.swift"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref", help="Run the same regression against an earlier revision")
args = parser.parse_args()


def read_source(path):
    return (subprocess.check_output(["git", "show", f"{args.source_ref}:{path}"], cwd=ROOT, text=True)
            if args.source_ref else (ROOT / path).read_text())


source = read_source(SOURCE)
terminal_source = read_source("mac/zshell/TerminalHostView.swift")
queue_source = read_source("mac/zshell/PromptQueueBarView.swift")


def section(start, end):
    return source[source.index(start):source.index(end)]


pane_view = section("private struct PaneView:", "/// Compact chrome for a pane")
content_start = pane_view.index("    @ViewBuilder\n    private var content:")
content_end = pane_view.index("    @ViewBuilder\n    private var dropHighlight:")
pane_view = (pane_view[:content_start]
             + "    private var content: some View { SurfaceFixture(id: pane.id) }\n\n"
             + pane_view[content_end:])
header = section("private struct PaneHeaderView:", "/// Mounts a session's find bar")
reporter = section("private struct PaneFramePreferenceKey:", "private extension NSView")
terminal_container = terminal_source[terminal_source.index("private final class TerminalContainerView:"):]
queue_metrics = queue_source[queue_source.index("    private enum Metrics {"):queue_source.index("    private var queue:")]
queue_build = queue_source[queue_source.index("    private func buildView() {"):queue_source.index("    // MARK: - State")]

fixture = r'''
enum FixtureState { static var showsQueue = false }
final class ThemeChanges: ObservableObject {}
enum Theme {
    static let changes = ThemeChanges()
    static let background = NSColor.white
    static let accent = NSColor.blue
}
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    let isTerminalBackgroundBlurActive = false
}
final class TerminalManager {}
final class PaneTab: ObservableObject {
    @Published var focusedPaneID = UUID()
}
final class TerminalSession: ObservableObject {
    let title = "wzz@MacBook-Pro:~/a-very-long-project-path"
    let agentRollup: ZshellAgentRollup? = nil
}
final class FileTab: ObservableObject {
    let name = "long-file-name.swift"
    let path = "/fixture/long-file-name.swift"
    let isDirty = true
}
final class BrowserTab: ObservableObject {
    let title = "Fixture browser"
    let urlString = "about:blank"
}
struct DiffTab {
    let title = "Fixture diff"
    let path = "/fixture/file.swift"
}
enum PaneContent {
    case session(TerminalSession), file(FileTab), browser(BrowserTab), diff(DiffTab)
}
struct Pane: Identifiable {
    let id = UUID()
    let content: PaneContent
}
enum PaneDropEdge { case left, right, top, bottom }
struct ZshellAgentRollup {}
struct AgentStatusBadgeRepresentable: View {
    let rollup: ZshellAgentRollup
    var body: some View { Color.blue.frame(width: 14, height: 14) }
}
struct BrowserFaviconView: View {
    let browser: BrowserTab
    let size: CGFloat
    var body: some View { Color.blue.frame(width: size, height: size) }
}
struct MaterialFileIconView: View {
    let path: String
    let size: CGFloat
    var opacity: Double = 1
    var body: some View { Color.blue.frame(width: size, height: size) }
}
struct PaneFocusRing: View {
    let isFocused: Bool
    var body: some View { Rectangle().stroke(Color.blue) }
}
enum TooltipEdge { case below }
enum TooltipAlignment { case trailing }
extension View {
    func tooltip(_ text: LocalizedStringKey, edge: TooltipEdge, alignment: TooltipAlignment) -> some View { self }
}
protocol TerminalBackendSurface: NSView { func setSurfaceVisible(_ visible: Bool) }
enum OverlayScrollbarView { static let stripWidth: CGFloat = 10 }
final class SurfaceView: NSView, TerminalBackendSurface {
    let id: UUID
    override var isFlipped: Bool { true }
    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.red.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSurfaceVisible(_ visible: Bool) {}
}
final class PromptQueueFixture: NSView, NSTextFieldDelegate {
    __QUEUE_METRICS__
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    private lazy var listHeightConstraint = listScroll.heightAnchor.constraint(equalToConstant: 0)
    private let inputField = NSTextField(string: "")
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let inputRow = NSStackView(views: [])
    private let contentStack = NSStackView()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        buildView()
        isHidden = !FixtureState.showsQueue
        heightConstraint.constant = FixtureState.showsQueue ? Metrics.padding * 2 + Metrics.inputRowHeight : 0
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func addToQueue() {}
    @objc private func closeClicked() {}
    __QUEUE_BUILD__
}
struct SurfaceFixture: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.focusOnAppear = false
        container.mount(SurfaceView(id: id), scrollbar: NSView(), queueBar: PromptQueueFixture())
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
func descendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
}
struct LayoutFixture: View {
    let panes: [Pane]
    let width: CGFloat
    let height: CGFloat
    let tab = PaneTab()
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                PaneView(manager: TerminalManager(), tab: tab, pane: pane,
                         showSplitChrome: true, allowsMove: true, isMoveSource: false,
                         dropEdge: nil, onMove: { _ in }, onMoveEnded: {}, onSplit: { _ in },
                         onNewBrowserTab: { _ in }, onNewBrowserPane: { _ in },
                         onNewFileTab: { _ in }, onNewFilePane: { _ in })
                    .frame(width: width, height: height)
                    .offset(x: CGFloat(index) * (width + 10), y: 0)
            }
        }
        .frame(width: CGFloat(panes.count) * (width + 10), height: height, alignment: .topLeading)
    }
}
@main
struct PaneBoundsRegression {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        for (width, height, showsQueue): (CGFloat, CGFloat, Bool) in [
            (360, 240, false), (160, 240, false), (80, 240, false), (32, 240, false),
            (360, 90, true), (160, 90, true), (80, 90, true), (32, 90, true),
        ] {
            FixtureState.showsQueue = showsQueue
            let panes = (0..<4).map { _ in Pane(content: .session(TerminalSession())) }
            let hosting = NSHostingView(rootView: LayoutFixture(panes: panes, width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 360),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 360))
            window.contentView = root
            hosting.frame = NSRect(x: 80, y: 40, width: CGFloat(panes.count) * (width + 10), height: height)
            root.addSubview(hosting)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
            hosting.layoutSubtreeIfNeeded()
            let surfaces = descendants(hosting).compactMap { $0 as? SurfaceView }
            check(surfaces.count == panes.count, "all panes mount at width \(width), queue open=\(showsQueue)")
            for (index, pane) in panes.enumerated() {
                guard let surface = surfaces.first(where: { $0.id == pane.id }) else { continue }
                let frame = surface.convert(surface.bounds, to: hosting)
                let expectedMinX = CGFloat(index) * (width + 10)
                check(frame.minX >= expectedMinX - 0.5 && frame.maxX <= expectedMinX + width + 0.5,
                      "pane \(index) stays in allocated width \(width): x=\(frame.minX), width=\(frame.width)")
                check(frame.minY >= -0.5 && frame.maxY <= height + 0.5,
                      "pane \(index) stays in allocated height \(height)")
                let bar = surface.superview!.subviews.compactMap { $0 as? PromptQueueFixture }.first!
                let barFrame = bar.convert(bar.bounds, to: hosting)
                check(barFrame.minX >= expectedMinX - 0.5 && barFrame.maxX <= expectedMinX + width + 0.5,
                      "queue bar stays inside pane \(index)")
                check(bar.layer?.masksToBounds == true, "narrow queue content remains clipped inside its bar")
                if width == 360 {
                    let stack = bar.subviews.compactMap { $0 as? NSStackView }.first!
                    check(abs(stack.frame.maxX - (bar.bounds.width - 10)) < 0.5,
                          "queue controls fill the available width when it fits")
                }
            }
            if width == 360 {
                // Reuse the same live surfaces while width changes, as it does
                // on every divider-drag update; static initial layout is not enough.
                for resizedWidth: CGFloat in [240, 160, 80, 32, 80, 160, 360] {
                    hosting.rootView = LayoutFixture(panes: panes, width: resizedWidth, height: height)
                    hosting.setFrameSize(NSSize(width: CGFloat(panes.count) * (resizedWidth + 10), height: height))
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
                    hosting.layoutSubtreeIfNeeded()
                    let resized = descendants(hosting).compactMap { $0 as? SurfaceView }
                    check(Set(resized.map(ObjectIdentifier.init)) == Set(surfaces.map(ObjectIdentifier.init)),
                          "resizing to \(resizedWidth) preserves live terminal surfaces")
                    for (index, pane) in panes.enumerated() {
                        guard let surface = resized.first(where: { $0.id == pane.id }) else { continue }
                        let frame = surface.convert(surface.bounds, to: hosting)
                        let expectedMinX = CGFloat(index) * (resizedWidth + 10)
                        check(frame.minX >= expectedMinX - 0.5 && frame.maxX <= expectedMinX + resizedWidth + 0.5,
                              "resize to \(resizedWidth) keeps pane \(index) aligned with its allocated edges")
                    }
                }
            }
            window.close()
        }
        print("Pane bounds regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
fixture = fixture.replace("__QUEUE_METRICS__", queue_metrics).replace("__QUEUE_BUILD__", queue_build)

with tempfile.TemporaryDirectory(prefix="zshell-pane-bounds-tests-") as directory:
    helper = Path(directory) / "PaneBoundsRegression.swift"
    helper.write_text("import AppKit\nimport SwiftUI\n" + fixture + pane_view + header + reporter + terminal_container)
    executable = Path(directory) / "pane-bounds-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
