"""Exercise Git worktree header sizing and the always-visible native file filter.

Run: python3 mac/tests/test_git_panel_controls.py [--source-ref <git-ref>]
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
args = parser.parse_args()


def read_source(path, optional=False):
    if args.source_ref:
        run = subprocess.run(["git", "show", f"{args.source_ref}:{path}"], cwd=ROOT,
                             capture_output=True, text=True)
        if optional and run.returncode:
            return ""
        run.check_returncode()
        return run.stdout
    file = ROOT / path
    return file.read_text() if file.exists() else ""


section = read_source("mac/zshell/AppKitWorktreeSectionView.swift")
panel = read_source("mac/zshell/RightSidebarView.swift")
field = read_source("mac/zshell/AppKitGitFilterView.swift", optional=True)
filter_bar = panel[panel.index("    // MARK: Filter"):panel.index("    // MARK: Change list")]
state = "\n".join(re.findall(r"^    @State private var (?:filterText|showFilter) = .*", panel, re.M))
header = panel[panel.index("    private var header: some View {", panel.index("private struct GitPanel")):
               panel.index("    /// Remote repositories cannot switch branches", panel.index("private struct GitPanel"))]
fixture = r'''
enum Theme { static let accent = NSColor.systemBlue }
struct AppSettings {
    static let sidebarFontSizeRange = 9.0...24.0
    static let defaultSidebarFontSize = 14.0
    static let interfaceScaleRange = 0.9...1.5
}
struct GitStatusModel {
    struct Worktree: Equatable {
        let path: String
        let headOID: String?
        let branch: String?
        let isBare: Bool
        let isCurrent: Bool
    }
}
struct FilterFixture: View {
    FILTER_STATE
    let sidebarFontScale: CGFloat
    var body: some View { filterBar }
    FILTER_BAR
}
@main struct GitPanelControlsRegression {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(name)") }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        for scale in [0.9, 1.0, 1.5, 2.0, 24.0 / 14.0 * 1.5] {
            for width in [162.0, 180, 240, 500] {
                let view = GitWorktreeSectionNSView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
                for count in [2, 8, 12, 128] {
                    let trees = (0..<count).map {
                        GitStatusModel.Worktree(path: "/fixture/\($0)", headOID: nil,
                            branch: "feature/\($0)", isBare: false, isCurrent: $0 == 0)
                    }
                    view.apply(worktrees: trees, isCollapsed: false, fontScale: scale,
                        openWorktree: { _ in }, createWorktree: {}, removeWorktree: { _ in },
                        deleteBranch: { _ in }, toggleCollapsed: {})
                    view.layoutSubtreeIfNeeded()
                    let label = view.subviews.compactMap { $0 as? NSTextField }.first!
                    let add = view.subviews.compactMap { $0 as? NSButton }.first { $0.title.isEmpty }!
                    let labelSize = label.cell!.cellSize
                    check(label.frame.width >= ceil(labelSize.width),
                          "entire count \(count) fits at scale \(scale), width \(width)")
                    check(label.frame.height >= ceil(labelSize.height), "count has enough line height")
                    check(view.bounds.contains(label.frame), "count stays inside the sidebar")
                    check(!label.frame.intersects(add.frame), "count and create button do not overlap")
                }
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: FilterFixture(sidebarFontScale: scale))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            let fields = descendants(host).compactMap { $0 as? NSSearchField }
            check(fields.count == 1 && !fields[0].isHiddenOrHasHiddenAncestor,
                  "file filter is visible on initial presentation at scale \(scale)")
            if let search = fields.first {
                check(search.sendsSearchStringImmediately, "filter updates on each edit")
                check(search.placeholderString == String(localized: "Filter changed files"),
                      "filter keeps its existing localized placeholder")
                check(search.frame.width > 0 && search.frame.height > 0, "native field has usable bounds")
            }
            window.close()
        }
        FIELD_BINDING_CHECK
        print("Git panel control regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
binding_check = r'''
        var query = ""
        let binding = Binding<String>(get: { query }, set: { query = $0 })
        let representable = GitChangedFilesSearchField(text: binding, fontScale: 1)
        let coordinator = representable.makeCoordinator()
        let native = NSSearchField()
        native.stringValue = "README"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: native))
        check(query == "README", "editing the native field updates the Git filter binding")
        native.stringValue = ""
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: native))
        check(query.isEmpty, "clearing the native field restores the complete file list")
'''
fixture = fixture.replace("FILTER_STATE", state).replace("FILTER_BAR", filter_bar)
fixture = fixture.replace("FIELD_BINDING_CHECK", binding_check if field else "")
with tempfile.TemporaryDirectory(prefix="zshell-git-panel-controls-") as directory:
    helper = Path(directory) / "ControlsRegression.swift"
    helper.write_text(section + field
                      + (ROOT / "mac/zshell/RowButtonTableView.swift").read_text()
                      + (ROOT / "mac/zshell/SidebarLayoutMetrics.swift").read_text()
                      + (ROOT / "mac/zshell/SidebarTypography.swift").read_text()
                      + fixture)
    executable = Path(directory) / "git-panel-controls-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
if "Filter Changed Files" in header or "showFilter" in panel:
    raise SystemExit("The Git panel must not retain the obsolete filter-toggle control or visibility state")
