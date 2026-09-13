//
//  MiddleClickCatcher.swift
//  zshell
//

import AppKit
import SwiftUI

/// Invisible overlay that handles middle clicks while passing primary-button
/// events through to the SwiftUI controls underneath.
struct MiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.onMiddleClick = action
        return view
    }

    func updateNSView(_ view: MiddleClickNSView, context: Context) {
        view.onMiddleClick = action
    }
}

final class MiddleClickNSView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim only the middle button's down event. Every other event —
        // left clicks in particular — must fall through to the SwiftUI
        // controls underneath, or gestures like double-click-to-rename
        // sitting on those controls would stop firing.
        guard let event = NSApp.currentEvent, event.type == .otherMouseDown else { return nil }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onMiddleClick?()
    }
}
