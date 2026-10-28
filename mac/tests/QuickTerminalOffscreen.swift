import AppKit
import ObjectiveC.runtime

/// Keep integration-test panels, popovers and click-catching backdrops outside
/// every display. The process must never become active or take keyboard focus.
@MainActor
enum QuickTerminalOffscreen {
    static let origin = NSPoint(x: -100_000, y: -100_000)

    static func frame(_ requested: NSRect) -> NSRect { NSRect(origin: origin, size: requested.size) }

    static func prepare(_ window: NSWindow) {
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        if window.frame.origin != origin { window.setFrame(frame(window.frame), display: false) }
    }

    static func install() {
        for (original, replacement) in [
            ("constrainFrameRect:toScreen:", "quickTest_constrainFrameRect:toScreen:"),
            ("setFrame:display:", "quickTest_setFrame:display:"),
            ("setFrameOrigin:", "quickTest_setFrameOrigin:"),
            ("orderFront:", "quickTest_orderFront:"),
            ("orderFrontRegardless", "quickTest_orderFrontRegardless"),
            ("orderWindow:relativeTo:", "quickTest_orderWindow:relativeTo:"),
            ("makeKeyWindow", "quickTest_makeKeyWindow"),
            ("makeMainWindow", "quickTest_makeMainWindow"),
            ("makeKeyAndOrderFront:", "quickTest_makeKeyAndOrderFront:"),
        ] {
            guard let first = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(original)),
                  let second = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(replacement)) else {
                preconditionFailure("Missing window method \(original)")
            }
            method_exchangeImplementations(first, second)
        }
    }

    static func isSafe() -> Bool {
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(display.uint32Value)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let intersectsDisplay = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
        }.contains { record in
            guard let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return true }
            return frame.width > 0 && frame.height > 0 && displays.contains { $0.intersects(frame) }
        }
        return !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()
            && !intersectsDisplay && NSApp.windows.filter(\.isVisible).allSatisfy { window in
                window.ignoresMouseEvents && !window.isKeyWindow && !window.isMainWindow
                    && NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }
            }
    }
}

extension NSWindow {
    @objc(quickTest_constrainFrameRect:toScreen:) fileprivate func quickTest_constrainFrameRect(_ requested: NSRect, to screen: NSScreen?) -> NSRect {
        // AppKit 在窗口显示时还会约束坐标，单独拦截 setFrame 无法保证离屏。
        QuickTerminalOffscreen.frame(requested)
    }

    @objc(quickTest_setFrame:display:) fileprivate func quickTest_setFrame(_ requested: NSRect, display: Bool) {
        ignoresMouseEvents = true
        quickTest_setFrame(QuickTerminalOffscreen.frame(requested), display: display)
    }

    @objc(quickTest_setFrameOrigin:) fileprivate func quickTest_setFrameOrigin(_ requested: NSPoint) {
        ignoresMouseEvents = true
        quickTest_setFrameOrigin(QuickTerminalOffscreen.origin)
    }

    @objc(quickTest_orderFront:) fileprivate func quickTest_orderFront(_ sender: Any?) {
        QuickTerminalOffscreen.prepare(self)
        quickTest_orderFront(sender)
    }

    @objc(quickTest_orderFrontRegardless) fileprivate func quickTest_orderFrontRegardless() {
        QuickTerminalOffscreen.prepare(self)
        quickTest_orderFrontRegardless()
    }

    @objc(quickTest_orderWindow:relativeTo:) fileprivate func quickTest_orderWindow(_ place: NSWindow.OrderingMode, relativeTo: Int) {
        QuickTerminalOffscreen.prepare(self)
        quickTest_orderWindow(place, relativeTo: relativeTo)
    }

    @objc(quickTest_makeKeyWindow) fileprivate func quickTest_makeKeyWindow() {}
    @objc(quickTest_makeMainWindow) fileprivate func quickTest_makeMainWindow() {}

    @objc(quickTest_makeKeyAndOrderFront:) fileprivate func quickTest_makeKeyAndOrderFront(_ sender: Any?) {
        QuickTerminalOffscreen.prepare(self)
        orderFront(sender)
    }
}

@MainActor
final class QuickTerminalFocusFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // 可见验收也只需要焦点转移，不应把辅助小窗口移回用户屏幕。
        frameRect
    }
}
