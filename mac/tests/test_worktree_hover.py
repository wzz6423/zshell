"""Render real Git worktree rows while scrolling beneath a stationary pointer.

Run: python3 mac/tests/test_worktree_hover.py [--source-ref <git-ref>]
The offscreen AppKit fixture never sends desktop input.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = "mac/zshell/AppKitWorktreeSectionView.swift"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
args = parser.parse_args()
source = (subprocess.check_output(["git", "show", f"{args.source_ref}:{SOURCE}"],
                                 cwd=ROOT, text=True)
          if args.source_ref else (ROOT / SOURCE).read_text())

# Compile the complete production section, rows, table, and layout metrics.
# Only app settings and repository data unrelated to pointer handling are stubbed.
fixture = r'''
enum Theme { static let accent = NSColor.systemBlue }
struct AppSettings {
    static let sidebarFontSizeRange = 9.0...20.0
    static let defaultSidebarFontSize = 11.0
    static let interfaceScaleRange = 0.8...1.5
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
final class HoverWindow: NSWindow {
    var pointerLocation = NSPoint(x: -100, y: -100)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}

@main
struct WorktreeHoverRegression {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func alpha(_ view: NSView, selection: Bool = false) -> CGFloat {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(view.bounds)
            if selection { (view as! NSTableRowView).drawSelection(in: view.bounds) }
            else { view.draw(view.bounds) }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: Int(view.bounds.width) - 28,
                                  y: Int(view.bounds.height) / 2)!.alphaComponent
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = HoverWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let section = GitWorktreeSectionNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            window.contentView = section
            let worktrees = (0..<12).map {
                GitStatusModel.Worktree(path: "/fixture/worktree-\($0)", headOID: "abc",
                    branch: "feature/\($0)", isBare: false, isCurrent: $0 == 0)
            }
            section.apply(worktrees: worktrees, isCollapsed: false, fontScale: 1,
                openWorktree: { _ in }, createWorktree: {}, removeWorktree: { _ in },
                deleteBranch: { _ in }, toggleCollapsed: {})
            section.layoutSubtreeIfNeeded()
            let scroll = section.subviews.compactMap { $0 as? NSScrollView }.first!
            let table = scroll.documentView as! NSTableView
            table.layoutSubtreeIfNeeded()
            func row(_ index: Int) -> GitWorktreeRowButton {
                let button = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! GitWorktreeRowButton
                button.layoutSubtreeIfNeeded()
                return button
            }
            let first = row(0)
            let point = first.convert(NSPoint(x: 80, y: first.bounds.midY), to: nil)
            window.pointerLocation = point
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            first.mouseEntered(with: enter)
            check(alpha(first) > 0, "pointer over worktree paints hover (\(appearance))")
            check(table.selectedRow == -1, "hover does not select a worktree")

            // AppKit rebuilds tracking areas as clipping changes without always
            // delivering the previous region's mouseExited event.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rowHeight * 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            first.updateTrackingAreas()
            let next = row(2)
            next.updateTrackingAreas()
            check(alpha(first) == 0, "scrolling a row away clears its hover without an exit event")
            check(alpha(next) > 0, "only the row scrolled under the pointer gains hover")
            check(table.selectedRow == -1, "scrolling retains the unselected table state")

            window.pointerLocation = NSPoint(x: -100, y: -100)
            next.updateTrackingAreas()
            check(alpha(next) == 0, "leaving the viewport clears a refreshed row hover")
            next.mouseEntered(with: enter)
            next.apply(worktree: worktrees[8], metrics: GitWorktreeSectionMetrics(fontScale: 1),
                       open: {}, remove: {}, deleteBranch: { _ in })
            next.updateTrackingAreas()
            check(alpha(next) == 0, "reconfiguring a row cannot retain a previous worktree hover")

            window.pointerLocation = next.convert(NSPoint(x: 80, y: next.bounds.midY), to: nil)
            next.mouseEntered(with: enter)
            check(alpha(next) > 0, "row hover can be restored after scrolling")
            next.removeFromSuperview()
            check(alpha(next) == 0, "detaching a recycled row clears hover")

            let selected = GitWorktreeTableRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
            selected.isSelected = true
            check(alpha(selected, selection: true) > 0,
                  "actual table selection keeps its independent background")
            window.close()
        }
        print("Worktree hover regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="zshell-worktree-hover-") as directory:
    helper = Path(directory) / "WorktreeHoverRegression.swift"
    helper.write_text(source
                      + (ROOT / "mac/zshell/RowButtonTableView.swift").read_text()
                      + (ROOT / "mac/zshell/SidebarLayoutMetrics.swift").read_text()
                      + fixture)
    executable = Path(directory) / "worktree-hover-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
