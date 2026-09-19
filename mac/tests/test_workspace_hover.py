"""Check the real workspace controls' hover regions and background painting.

Run: python3 mac/tests/test_workspace_hover.py [--source-ref <git-ref>]
The offscreen fixture resolves tracking regions without sending desktop input.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "mac/zshell/WorkspaceChromeViews.swift"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
args = parser.parse_args()
source = (subprocess.check_output(["git", "show", f"{args.source_ref}:{SOURCE}"], cwd=ROOT, text=True)
          if args.source_ref else (ROOT / SOURCE).read_text())

# Only dependencies unrelated to hover/layout/painting are stubbed. Both
# WorkspaceItemView and WorkspaceChromeButton compile unchanged in full.
fixture = r'''
enum Theme { static let accent = NSColor.systemBlue }
struct AppCommand { var title = "Command" }
struct Shortcut { var displayString = "" }
struct AppSettings {
    static let shared = AppSettings()
    func commandShortcut(for command: AppCommand) -> Shortcut { Shortcut() }
}
struct ProjectTabMarkerColor {
    static let defaultColor = ProjectTabMarkerColor()
    var nsColor: NSColor { .systemBlue }
    var displayValue: String { "Blue" }
}
struct ZshellAgentRollup { var phase = 0; var count = 0 }
final class AgentStatusBadgeView: NSView {
    func apply(phase: Int, count: Int) {}
}
enum AppKitContextMenuItem {}
final class AppKitContextMenuMonitorView: NSView {
    func popUp(items: [AppKitContextMenuItem], at: NSPoint, in: NSView) {}
}
extension NSWindow { func performTitlebarDoubleClickAction() {} }

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@main
struct HoverRegression {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        for tabStrip in [true, false] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            root.clipsToBounds = true
            window.contentView = root
            let clip = NSClipView(frame: NSRect(x: 90, y: 20, width: 600, height: 34))
            clip.clipsToBounds = true
            let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
            clip.documentView = document
            root.addSubview(clip)
            let rows = (0..<3).map { index -> WorkspaceItemView in
                let row = WorkspaceItemView(frame: NSRect(x: CGFloat(index) * 200, y: 0, width: 197, height: 34))
                document.addSubview(row)
                row.apply(title: "Session", icon: nil, selected: index == 2,
                          sidebar: !tabStrip, tabStrip: tabStrip, action: {})
                row.layoutSubtreeIfNeeded()
                return row
            }
            let buttons = rows.map { $0.subviews.compactMap { $0 as? WorkspaceChromeButton }.first! }
            let views: [NSView] = rows + buttons
            views.forEach { $0.updateTrackingAreas() }

            func trackingRect(_ view: NSView) -> NSRect {
                let area = view.trackingAreas.first { ($0.owner as? NSView) === view }!
                return area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
            }
            func contains(_ view: NSView, _ location: NSPoint) -> Bool {
                !view.isHiddenOrHasHiddenAncestor && trackingRect(view).contains(view.convert(location, from: nil))
            }
            func location(_ view: NSView, x: CGFloat, y: CGFloat) -> NSPoint {
                view.convert(NSPoint(x: x, y: y), to: nil)
            }
            var entered = Set<ObjectIdentifier>()
            func move(_ point: NSPoint) {
                for view in views {
                    let id = ObjectIdentifier(view)
                    let inside = contains(view, point)
                    if inside != entered.contains(id) {
                        let type: NSEvent.EventType = inside ? .mouseEntered : .mouseExited
                        let event = NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, trackingNumber: 0, userData: nil)!
                        if inside { entered.insert(id); view.mouseEntered(with: event) }
                        else { entered.remove(id); view.mouseExited(with: event) }
                    }
                }
            }
            func alpha(_ view: NSView, x: Int = 10, y: Int = 17) -> CGFloat {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                    pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.clear(view.bounds)
                view.draw(view.bounds)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                return bitmap.colorAt(x: x, y: y)!.alphaComponent
            }

            check(trackingRect(rows[0]) == rows[0].bounds, "row hover is bounded (tabStrip=\(tabStrip))")
            check(trackingRect(buttons[0]) == buttons[0].bounds, "close-button hover is bounded")
            let first = location(rows[0], x: 60, y: 17)
            check(!contains(rows[1], first), "neighbor row cannot enter hover")
            check(!contains(buttons[0], first), "tab body cannot hover its close button")
            move(first)
            check(alpha(rows[0]) > 0, "pointer over a tab paints hover")
            check(alpha(rows[1]) == 0, "non-hovered unselected tab has no background")
            check(alpha(buttons[0], x: 3, y: 12) == 0, "non-hovered close button has no background")
            move(location(buttons[0], x: 12, y: 12))
            check(alpha(buttons[0], x: 3, y: 12) > 0, "close button paints its own hover")
            move(location(rows[1], x: 60, y: 17))
            check(alpha(rows[0]) == 0, "leaving a tab clears its hover background")
            check(alpha(buttons[0], x: 3, y: 12) == 0, "leaving a close button clears its hover")
            move(root.convert(NSPoint(x: 50, y: 150), to: nil))
            check(alpha(rows[1]) == 0, "leaving the strip clears hover")
            check(alpha(rows[2]) > 0, "selected tab retains its background without hover")
            if tabStrip {
                check(alpha(rows[2], y: 3) == 0, "selected tab keeps the compact vertical inset")
            }
            clip.scroll(to: NSPoint(x: 50, y: 0))
            views.forEach { $0.updateTrackingAreas() }
            check(!contains(rows[0], location(rows[0], x: 10, y: 17)), "clipped tab portion cannot hover")
            check(contains(rows[0], location(rows[0], x: 100, y: 17)), "visible tab portion can hover after scrolling")
            window.close()
        }
        print("Workspace hover regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="zshell-hover-tests-") as directory:
    helper = Path(directory) / "HoverRegression.swift"
    helper.write_text(source + fixture)
    executable = Path(directory) / "hover-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
