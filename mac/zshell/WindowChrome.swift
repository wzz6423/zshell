//
//  WindowChrome.swift
//  zshell
//

import AppKit
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let showsFrostedBackground: Bool
    private let onAttach: (NSWindow) -> Void

    init(
        showsFrostedBackground: Bool = false,
        onAttach: @escaping (NSWindow) -> Void = { _ in }
    ) {
        self.showsFrostedBackground = showsFrostedBackground
        self.onAttach = onAttach
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttach: onAttach)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(window)
                context.coordinator.setFrostedBackground(showsFrostedBackground, in: view)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            context.coordinator.attach(window)
            context.coordinator.setFrostedBackground(showsFrostedBackground, in: view)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var frostedBackground: NSVisualEffectView?
        private let onAttach: (NSWindow) -> Void

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            frostedBackground?.removeFromSuperview()
            frostedBackground = nil
            self.window = window
            onAttach(window)
            // WindowDragArea still limits pointer-driven moves to empty header
            // surfaces; AppKit needs the window itself movable to offer system
            // display destinations such as Sidecar.
            window.isMovable = true
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        func setFrostedBackground(_ visible: Bool, in hostView: NSView) {
            guard visible else {
                frostedBackground?.removeFromSuperview()
                frostedBackground = nil
                return
            }
            guard frostedBackground?.superview !== hostView else { return }
            frostedBackground?.removeFromSuperview()

            let background = NSVisualEffectView(frame: hostView.bounds)
            background.material = .underWindowBackground
            background.blendingMode = .behindWindow
            background.state = .followsWindowActiveState
            // SwiftUI sizes this background's host. Keeping the effect inside
            // it avoids covering the root's rendering or constraining its layout.
            background.autoresizingMask = [.width, .height]
            hostView.addSubview(background, positioned: .below, relativeTo: nil)
            frostedBackground = background
        }

        private func reposition() {
            guard let window else { return }
            window.isMovable = true
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            frostedBackground?.removeFromSuperview()
        }
    }
}

/// A deliberate window-moving surface. Interactive header controls are kept
/// outside this view so their own drag gestures receive the full mouse stream.
///
/// Double-clicking runs the standard title-bar action (zoom / minimize per
/// System Settings) — behavior our non-movable, hidden title bar would
/// otherwise lose. The tap is simultaneous with the drag: a stationary
/// double-click never registers a move, so the two don't conflict.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                NSApp.keyWindow?.performTitlebarDoubleClickAction()
            })
            .allowsWindowActivationEvents()
    }
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }
}
