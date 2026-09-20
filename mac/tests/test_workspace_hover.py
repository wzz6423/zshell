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
# WorkspaceItemView and WorkspaceChromeButton compile unchanged in full;
# the fixture window supplies pointer/key state without moving the desktop mouse.
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

final class HoverWindow: NSWindow {
    var pointerLocation = NSPoint(x: -100, y: -100)
    var hasKeyStatus = true
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
    override var isKeyWindow: Bool { hasKeyStatus }
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
        func renderedColor(_ view: NSView, x: Int, y: Int) -> NSColor {
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
            return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }
        func hasTintedFillWithoutSolidBorder(_ view: NSView, fillX: Int, borderX: Int, y: Int) -> Bool {
            let fill = renderedColor(view, x: fillX, y: y)
            let border = renderedColor(view, x: borderX, y: y)
            return fill.alphaComponent > 0.99
                && (border.alphaComponent < 0.99
                    || border.redComponent >= fill.redComponent - 0.2
                    || border.greenComponent >= fill.greenComponent - 0.2)
        }
        let compactGroup = WorkspaceItemView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        compactGroup.appearance = NSAppearance(named: .aqua)
        compactGroup.apply(title: "Group", icon: nil, selected: false, group: true,
                           collapsed: true, grouped: true, marker: .defaultColor,
                           compactGroup: true, tabStrip: true)
        compactGroup.layoutSubtreeIfNeeded()
        check(compactGroup.preferredWidth == 17, "compact tab group is half its previous width")
        check(hasTintedFillWithoutSolidBorder(compactGroup, fillX: 17, borderX: 8, y: 17),
              "compact tab group keeps its fill without an idle marker-color border")

        let groupWindow = HoverWindow(contentRect: NSRect(x: 320, y: 240, width: 240, height: 80),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        groupWindow.isReleasedWhenClosed = false
        groupWindow.appearance = NSAppearance(named: .aqua)
        let groupRoot = FlippedView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        groupWindow.contentView = groupRoot
        let groupRow = WorkspaceItemView(frame: NSRect(x: 8, y: 8, width: 224, height: 28))
        groupRoot.addSubview(groupRow)
        groupRow.apply(title: "New Group", icon: nil, selected: false, group: true,
                       collapsed: false, marker: .defaultColor, sidebar: true,
                       fillsGroupRow: true)
        groupRow.layoutSubtreeIfNeeded()
        check(hasTintedFillWithoutSolidBorder(groupRow, fillX: 180, borderX: 0, y: 14),
              "sidebar group keeps its fill without an idle marker-color border")
        var groupSelections = 0
        var groupRenames = 0
        var committedGroupName: String?
        groupRow.onSelect = { groupSelections += 1 }
        groupRow.onRename = {
            groupRenames += 1
            groupRow.beginRename(value: "New Group") { committedGroupName = $0 }
        }
        func groupMouse(_ type: NSEvent.EventType, clickCount: Int) -> NSEvent {
            let location = groupRow.convert(NSPoint(x: 20, y: 14), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: groupWindow.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        groupRow.mouseDown(with: groupMouse(.leftMouseDown, clickCount: 1))
        groupRow.mouseUp(with: groupMouse(.leftMouseUp, clickCount: 1))
        groupRow.mouseDown(with: groupMouse(.leftMouseDown, clickCount: 2))
        groupRow.mouseUp(with: groupMouse(.leftMouseUp, clickCount: 2))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let renameField = groupRow.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        check(groupSelections == 0, "double-clicking a group does not collapse it")
        check(groupRenames == 1, "double-clicking a group starts rename")
        check(groupRow.isRenaming && !renameField.isHidden, "group rename shows its editable field")
        let fieldEditor = groupWindow.fieldEditor(false, for: renameField) as! NSTextView
        fieldEditor.selectedRange = NSRange(location: 0, length: 0)
        let candidateAnchor = fieldEditor.firstRect(
            forCharacterRange: fieldEditor.selectedRange,
            actualRange: nil
        )
        let titleScreenFrame = groupWindow.convertToScreen(groupRow.titleLabel.convert(groupRow.titleLabel.bounds, to: nil))
        check(titleScreenFrame.minX...titleScreenFrame.maxX ~= candidateAnchor.minX,
              "group rename anchors IME candidates to the visible title position")
        renameField.stringValue = "Renamed Group"
        _ = groupRow.control(renameField, textView: fieldEditor,
                             doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(committedGroupName == "Renamed Group", "group rename commits the edited name")

        groupSelections = 0
        groupRow.mouseDown(with: groupMouse(.leftMouseDown, clickCount: 1))
        groupRow.mouseUp(with: groupMouse(.leftMouseUp, clickCount: 1))
        check(groupSelections == 0, "group selection waits for the double-click interval")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: NSEvent.doubleClickInterval + 0.05))
        check(groupSelections == 1, "single-clicking a group still toggles it")
        groupWindow.close()

        for tabStrip in [true, false] {
            let window = HoverWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
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

            func trackingArea(_ view: NSView) -> NSTrackingArea {
                view.trackingAreas.first { ($0.owner as? NSView) === view }!
            }
            func trackingRect(_ view: NSView) -> NSRect {
                let area = trackingArea(view)
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
                window.pointerLocation = point
                for view in views {
                    let options = trackingArea(view).options
                    guard options.contains(.activeAlways)
                        || (options.contains(.activeInKeyWindow) && window.isKeyWindow) else { continue }
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
                renderedColor(view, x: x, y: y).alphaComponent
            }

            check(trackingRect(rows[0]) == rows[0].bounds, "row hover is bounded (tabStrip=\(tabStrip))")
            check(trackingRect(buttons[0]) == buttons[0].bounds, "close-button hover is bounded")
            let first = location(rows[0], x: 60, y: 17)
            check(!contains(rows[1], first), "neighbor row cannot enter hover")
            check(!contains(buttons[0], first), "tab body cannot hover its close button")
            move(first)
            check(alpha(rows[0]) > 0, "pointer over a tab paints hover")
            check(alpha(rows[1]) == 0, "non-hovered unselected tab has no background")
            window.hasKeyStatus = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            check(alpha(rows[0]) == 0, "window deactivation clears a stale row hover")
            window.pointerLocation = location(rows[1], x: 60, y: 17)
            window.hasKeyStatus = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            check(alpha(rows[0]) == 0, "window activation does not restore the old row hover")
            check(alpha(rows[1]) > 0, "window activation restores hover only under the current pointer")
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

            let outside = root.convert(NSPoint(x: 50, y: 150), to: nil)
            move(location(buttons[0], x: 12, y: 12))
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) > 0, "tracking refresh preserves hover under a stationary pointer")
            let originalFrame = rows[0].frame
            rows[0].setFrameOrigin(NSPoint(x: 40, y: 0))
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) == 0, "moving a tab away clears close hover without an exit event")
            rows[0].frame = originalFrame
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) > 0, "moving the close button under a stationary pointer restores hover")
            clip.scroll(to: NSPoint(x: 50, y: 0))
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) == 0, "scrolling the close button away clears hover without an exit event")
            clip.scroll(to: .zero)
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) > 0, "scrolling the close button back under the pointer restores hover")
            clip.setFrameSize(NSSize(width: 174, height: 34))
            buttons[0].updateTrackingAreas()
            check(alpha(buttons[0], x: 3, y: 12) == 0, "a clipped part of the close button cannot retain hover")
            clip.setFrameSize(NSSize(width: 600, height: 34))
            buttons[0].updateTrackingAreas()
            move(outside)

            move(location(buttons[0], x: 12, y: 12))
            buttons[0].isHidden = true
            window.pointerLocation = outside
            buttons[0].isHidden = false
            check(alpha(buttons[0], x: 3, y: 12) == 0, "showing a close button again does not restore stale hover")
            move(outside)
            move(location(buttons[0], x: 12, y: 12))
            rows[0].isHidden = true
            window.pointerLocation = outside
            rows[0].isHidden = false
            check(alpha(buttons[0], x: 3, y: 12) == 0, "showing a tab again does not restore its close button's stale hover")
            move(outside)
            move(location(buttons[0], x: 12, y: 12))
            rows[0].isHidden = true
            rows[0].isHidden = false
            check(alpha(buttons[0], x: 3, y: 12) > 0, "showing a tab under a stationary pointer restores real close hover")
            rows[0].removeFromSuperview()
            window.pointerLocation = outside
            document.addSubview(rows[0])
            check(alpha(buttons[0], x: 3, y: 12) == 0, "reattaching a tab does not restore its close button's stale hover")
            move(outside)

            move(location(buttons[0], x: 12, y: 12))
            window.hasKeyStatus = false
            move(outside)
            check(alpha(buttons[0], x: 3, y: 12) == 0, "leaving the close button after window deactivation clears hover")
            window.hasKeyStatus = true
            move(outside)
            check(alpha(rows[2]) > 0, "hover lifecycle changes preserve the selected tab background")

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
