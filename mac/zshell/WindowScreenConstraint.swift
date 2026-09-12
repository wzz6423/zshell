//
//  WindowScreenConstraint.swift
//  zshell
//

import AppKit

/// Keeps ordinary application windows reachable when the available screen
/// geometry changes. AppKit already owns the placement policy; this object only
/// asks it to reapply that policy after a system-driven screen update.
@MainActor
final class WindowScreenConstraint {
    static let shared = WindowScreenConstraint()

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleAllWindowsConstraint()
                }
            },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.scheduleConstraint(for: window)
                }
            },
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.scheduleConstraint(for: window)
                }
            },
        ]
    }

    func stop() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func scheduleAllWindowsConstraint() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.constrainWindowsToAvailableScreens()
            }
        }
    }

    private func scheduleConstraint(for window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.constrain(window, to: NSScreen.screens)
            }
        }
    }

    private func constrainWindowsToAvailableScreens() {
        let screens = NSScreen.screens
        for window in NSApp.windows {
            constrain(window, to: screens)
        }
    }

    private func constrain(_ window: NSWindow, to screens: [NSScreen]) {
        guard shouldConstrain(window),
              let screenIndex = WindowScreenGeometry.targetScreenIndex(
                for: window.frame,
                screenFrames: screens.map(\.frame)
              ) else {
            return
        }

        let constrainedFrame = window.constrainFrameRect(window.frame, to: screens[screenIndex])
        guard constrainedFrame != window.frame else { return }
        window.setFrame(constrainedFrame, display: true, animate: false)
    }

    private func shouldConstrain(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue,
              identifier == "settings" || identifier.hasPrefix("main") else {
            return false
        }
        return window.isVisible
            && !window.isMiniaturized
            && !window.styleMask.contains(.fullScreen)
    }
}

enum WindowScreenGeometry {
    static func targetScreenIndex(for windowFrame: CGRect, screenFrames: [CGRect]) -> Int? {
        screenFrames.indices.min { lhs, rhs in
            let lhsOverlap = overlapArea(windowFrame, screenFrames[lhs])
            let rhsOverlap = overlapArea(windowFrame, screenFrames[rhs])
            if lhsOverlap != rhsOverlap {
                return lhsOverlap > rhsOverlap
            }

            let lhsDistance = squaredDistance(windowFrame, screenFrames[lhs])
            let rhsDistance = squaredDistance(windowFrame, screenFrames[rhs])
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs < rhs
        }
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let horizontal = max(0, max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX))
        let vertical = max(0, max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY))
        return horizontal * horizontal + vertical * vertical
    }
}
