//
//  AppWindowPresentation.swift
//  zshell
//

import AppKit

/// Keeps ordinary AppKit windows attached to the Zshell window that opened
/// them. A missing host is treated as "do not present" rather than falling
/// back to the pointer screen or activating another application.
@MainActor
enum AppWindowPresentation {
    enum Placement {
        case centered
        case topCentered(CGFloat)
    }

    static func hostWindow(relativeTo preferred: NSWindow? = nil) -> NSWindow? {
        for candidate in [preferred, NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let host = applicationWindow(owning: candidate) {
                return host
            }
        }
        return nil
    }

    static func attach(
        _ child: NSWindow,
        to host: NSWindow,
        placement: Placement
    ) {
        if child.parent !== host {
            child.parent?.removeChildWindow(child)
            host.addChildWindow(child, ordered: .above)
        }

        child.level = .normal
        if let panel = child as? NSPanel {
            panel.isFloatingPanel = false
        }
        var behavior = child.collectionBehavior
        behavior.remove(.canJoinAllSpaces)
        behavior.remove(.canJoinAllApplications)
        behavior.remove(.fullScreenAuxiliary)
        behavior.remove(.moveToActiveSpace)
        child.collectionBehavior = behavior
        position(child, relativeTo: host, placement: placement)
    }

    static func hideChild(_ child: NSWindow) {
        child.parent?.removeChildWindow(child)
        child.orderOut(nil)
    }

    /// A singleton sheet can outlive the window that first presented it. End
    /// that relationship before attaching it to the newly focused Zshell
    /// window, otherwise AppKit keeps the sheet logically owned by the old
    /// window even when it is ordered to the front.
    static func presentSheet(_ sheet: NSWindow, on host: NSWindow) {
        guard sheet !== host else {
            sheet.makeKeyAndOrderFront(nil)
            return
        }

        if let parent = sheet.sheetParent, parent !== host {
            parent.endSheet(sheet)
            DispatchQueue.main.async { [weak sheet, weak host] in
                guard let sheet, let host,
                      sheet.sheetParent == nil,
                      host.isVisible,
                      !host.isMiniaturized else { return }
                host.beginSheet(sheet)
            }
        } else if sheet.sheetParent == nil {
            host.beginSheet(sheet)
        } else {
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    static func position(
        _ child: NSWindow,
        relativeTo host: NSWindow,
        placement: Placement
    ) {
        let size = child.frame.size
        let hostFrame = host.frame
        let desiredY: CGFloat
        switch placement {
        case .centered:
            desiredY = hostFrame.midY - size.height / 2
        case .topCentered(let offset):
            desiredY = hostFrame.maxY - offset - size.height
        }
        let origin = NSPoint(
            x: clampedOrigin(
                desired: hostFrame.midX - size.width / 2,
                minimum: hostFrame.minX + 16,
                maximum: hostFrame.maxX - size.width - 16
            ),
            y: clampedOrigin(
                desired: desiredY,
                minimum: hostFrame.minY + 16,
                maximum: hostFrame.maxY - size.height - 16
            )
        )
        child.setFrameOrigin(origin)
    }

    private static func clampedOrigin(
        desired: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard minimum <= maximum else { return desired }
        return min(max(desired, minimum), maximum)
    }

    private static func applicationWindow(owning window: NSWindow) -> NSWindow? {
        var current: NSWindow? = window
        var visited = Set<ObjectIdentifier>()
        while let candidate = current,
              visited.insert(ObjectIdentifier(candidate)).inserted {
            if isApplicationWindow(candidate),
               candidate.isVisible,
               !candidate.isMiniaturized {
                return candidate
            }
            current = candidate.sheetParent ?? candidate.parent
        }
        return nil
    }

    private static func isApplicationWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier == "settings" || identifier.hasPrefix("main")
    }
}
