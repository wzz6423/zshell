"""Exercise native tab hit testing beside a real SwiftUI hosting view.

Run: python3 mac/tests/test_tab_strip_scrolling.py [--source-ref <git-ref>]
The offscreen fixture never sends input to the user's desktop.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "mac/zshell/AppKitSessionTabsView.swift"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref", help="Run the same regression against an earlier revision")
args = parser.parse_args()
source = (subprocess.check_output(["git", "show", f"{args.source_ref}:{SOURCE}"], cwd=ROOT, text=True)
          if args.source_ref else (ROOT / SOURCE).read_text())


def section(start, end):
    return source[source.index(start):source.index(end)]


native_scroll_views = section("private final class SessionStripScrollView:",
                              "private final class HeaderDropTargetView:")
overlay_lifecycle = section("    private func installWindowOverlay()", "    override func viewWillMove(")
wheel_hit_test = section("    private func handlesScrollWheel(", "    override func updateTrackingAreas()")
scroll_configuration = section("        scrollView.drawsBackground =", "        scrollView.contentView.postsBoundsChangedNotifications")
tab_wheel_handler = section("    override func scrollWheel(with event: NSEvent) {\n        isPointerInsideStrip",
                            "    private func installScrollWheelMonitor()")
scroller_update = section("    private func updateOverlayScroller()", "    private func documentPoint(")

fixture = r'''
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class WindowDragFixture: NSView {
    weak var dragWindow: NSWindow?
}

private final class MainHeaderNSView: NSView {
    let manager: Int
    let tabDrag: Int
    let presentsWindowOverlay: Bool
    let windowDrag = WindowDragFixture()
    weak var overlayHeader: MainHeaderNSView?
    var overlayObservers: [NSObjectProtocol] = []
    let scrollView = SessionStripScrollView()
    let document = SessionStripDocumentView()
    let overlayScroller = SessionStripOverlayScroller()
    let firstRow = FlippedView()
    let secondRow = FlippedView()
    let closeButton = NSButton()
    var isPointerInsideStrip = false
    override var isFlipped: Bool { true }

    init(manager: Int = 0, tabDrag: Int = 0, presentsWindowOverlay: Bool = true) {
        self.manager = manager
        self.tabDrag = tabDrag
        self.presentsWindowOverlay = presentsWindowOverlay
        super.init(frame: .zero)
        __SCROLL_CONFIGURATION__
        scrollView.documentView = document
        document.scrollView = scrollView
        addSubview(scrollView)
        addSubview(overlayScroller)
        document.addSubview(firstRow)
        document.addSubview(secondRow)
        firstRow.addSubview(closeButton)
        overlayScroller.onScroll = { [weak self] position in
            guard let self else { return }
            let maximum = self.document.bounds.width - self.scrollView.contentSize.width
            self.scrollView.contentView.scroll(to: NSPoint(x: maximum * position, y: 0))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        document.frame = NSRect(x: 0, y: 0, width: 1200, height: 34)
        overlayScroller.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 10)
        firstRow.frame = NSRect(x: 0, y: 0, width: 200, height: 34)
        secondRow.frame = NSRect(x: 200, y: 0, width: 200, height: 34)
        closeButton.frame = NSRect(x: 170, y: 5, width: 24, height: 24)
        showScroller(true)
    }

    func showScroller(_ visible: Bool) {
        overlayScroller.update(position: scrollView.contentView.bounds.minX / 740,
                               viewportWidth: bounds.width, contentWidth: 1200, visible: visible)
    }

    func attach() { installWindowOverlay() }
    func sync() { syncWindowOverlay() }
    func detach() { removeWindowOverlay() }
    func handles(_ event: NSEvent) -> Bool { handlesScrollWheel(event) }

    // Compile the production attachment, cleanup and wheel-routing methods.
    __OVERLAY_LIFECYCLE__
    __WHEEL_HIT_TEST__
    __TAB_WHEEL_HANDLER__
    __SCROLLER_UPDATE__
}

@main
struct TabStripRegression {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        for titled in [false, true] {
            let style: NSWindow.StyleMask = titled ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                  styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            let hostingView = NSHostingView(rootView: Color.clear)
            window.contentView = hostingView
            let host = FlippedView(frame: NSRect(x: 100, y: 0, width: 460, height: 34))
            hostingView.addSubview(host)
            let placeholder = MainHeaderNSView()
            placeholder.frame = host.bounds
            host.addSubview(placeholder)
            placeholder.attach()
            let header = placeholder.overlayHeader!
            header.layoutSubtreeIfNeeded()
            let root = window.contentView!.superview!

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                header.convert(NSPoint(x: x, y: y), to: nil)
            }
            func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
                root.hitTest(point(x, y))
            }
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point(x, y), modifierFlags: [],
                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func wheel(_ x: Int32, _ y: Int32, units: CGScrollEventUnit = .pixel) {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                 wheel1: y, wheel2: x, wheel3: 0)!
                let location = mouse(.mouseMoved, 100, 17)
                if placeholder.handles(location) {
                    placeholder.scrollWheel(with: NSEvent(cgEvent: cg)!)
                } else if header.handles(location) {
                    header.scrollWheel(with: NSEvent(cgEvent: cg)!)
                }
            }
            func paintedThumbPixels() -> Int {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 460, pixelsHigh: 10,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0)!
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.clear(header.overlayScroller.bounds)
                header.overlayScroller.draw(header.overlayScroller.bounds)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                return (0..<10).reduce(0) { total, y in
                    total + (0..<460).filter { bitmap.colorAt(x: $0, y: y)!.alphaComponent > 0 }.count
                }
            }

            check(header.superview === root, "header is outside NSHostingView (titled=\(titled))")
            check(header.visibleRect == header.bounds, "hover tracking is limited to the header bounds")
            check(hit(100, 32) === header.overlayScroller, "painted scrollbar receives clicks")
            check(hit(100, 29) === header.overlayScroller, "thin scrollbar has a larger hit area")
            check(hit(100, 17) === header.firstRow, "tab body remains clickable")
            check(hit(180, 17) === header.closeButton, "close button remains clickable")
            check(header.handles(mouse(.mouseMoved, 100, 17)), "visible header owns wheel input")
            check(!placeholder.handles(mouse(.mouseMoved, 100, 17)), "covered header cannot consume wheel input")
            check(!header.handles(mouse(.mouseMoved, 100, 80)), "terminal area is not intercepted")

            wheel(-100, 0)
            check(header.scrollView.contentView.bounds.minX == 100, "horizontal pixel wheel moves right")
            wheel(60, 0)
            check(header.scrollView.contentView.bounds.minX == 40, "horizontal pixel wheel moves left")
            wheel(0, -2, units: .line)
            check(header.scrollView.contentView.bounds.minX > 40, "vertical mouse wheel maps to horizontal")
            wheel(-5000, 0)
            check(header.scrollView.contentView.bounds.minX == 740, "scroll clamps at the right edge")
            wheel(5000, 0)
            check(header.scrollView.contentView.bounds.minX == 0, "scroll clamps at the left edge")

            let dragTarget = hit(70, 32)
            dragTarget?.mouseDown(with: mouse(.leftMouseDown, 70, 32))
            dragTarget?.mouseDragged(with: mouse(.leftMouseDragged, 260, 32))
            dragTarget?.mouseUp(with: mouse(.leftMouseUp, 260, 32))
            check(header.scrollView.contentView.bounds.minX > 400, "thumb drag moves the visible document")
            let offset = header.scrollView.contentView.bounds.minX
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            check(header.scrollView.contentView.bounds.minX == offset, "layout preserves manual scrolling")

            header.scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
            check(hit(100, 17) === header.secondRow, "hit testing follows the scrolled document")
            header.showScroller(false)
            check(hit(100, 32) === header.overlayScroller,
                  "scrollbar can be grabbed before hover callbacks arrive")
            check(paintedThumbPixels() == 0, "idle scrollbar stays visually hidden")
            let coldTarget = hit(100, 32)
            coldTarget?.mouseDown(with: mouse(.leftMouseDown, 100, 32))
            coldTarget?.mouseDragged(with: mouse(.leftMouseDragged, 200, 32))
            check(header.scrollView.contentView.bounds.minX > 200,
                  "drag works without a preceding hover event")
            check(paintedThumbPixels() > 0, "dragging reveals the thumb")
            coldTarget?.mouseUp(with: mouse(.leftMouseUp, 200, 32))
            wheel(0, 0)
            check(paintedThumbPixels() > 0, "zero-delta wheel phase still reveals the scrollbar")
            header.showScroller(true)
            header.overlayScroller.update(position: 0, viewportWidth: 1200, contentWidth: 1200, visible: true)
            check(header.overlayScroller.isHidden, "no overflow means no scrollbar")

            host.setFrameOrigin(NSPoint(x: 140, y: 130))
            placeholder.sync()
            check(header.frame == host.convert(host.bounds, to: root), "header follows host geometry")
            placeholder.detach()
            check(header.superview == nil && placeholder.overlayHeader == nil, "detaching removes the overlay")
            window.close()
        }
        print("Tab strip regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
fixture = fixture.replace("__OVERLAY_LIFECYCLE__", overlay_lifecycle).replace("__WHEEL_HIT_TEST__", wheel_hit_test)
fixture = fixture.replace("__SCROLL_CONFIGURATION__", scroll_configuration)
fixture = fixture.replace("__TAB_WHEEL_HANDLER__", tab_wheel_handler).replace("__SCROLLER_UPDATE__", scroller_update)

with tempfile.TemporaryDirectory(prefix="zshell-tab-scroll-tests-") as directory:
    helper = Path(directory) / "TabStripRegression.swift"
    helper.write_text("import AppKit\nimport SwiftUI\n" + native_scroll_views + fixture)
    executable = Path(directory) / "tab-strip-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
