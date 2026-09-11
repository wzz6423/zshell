//
//  PinContextMenuMonitor.swift
//  zshell
//

import AppKit
import SwiftUI

enum AppKitContextMenuItem {
    case action(title: String, enabled: Bool = true, handler: () -> Void)
    /// A nested menu (e.g. "Move Tab to Project"); its items resolve lazily
    /// through the same handler registry as top-level actions.
    case submenu(title: String, enabled: Bool = true, items: [AppKitContextMenuItem])
    case separator
}

/// Presents an AppKit-owned context menu over an existing SwiftUI surface.
/// The view itself ignores hit testing; a window-local monitor preserves the
/// underlying row or tab's normal click and drag behavior.
struct AppKitContextMenuMonitor: NSViewRepresentable {
    let items: [AppKitContextMenuItem]

    func makeNSView(context: Context) -> AppKitContextMenuMonitorView {
        AppKitContextMenuMonitorView()
    }

    func updateNSView(_ nsView: AppKitContextMenuMonitorView, context: Context) {
        nsView.items = items
    }

    static func dismantleNSView(
        _ nsView: AppKitContextMenuMonitorView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
final class AppKitContextMenuMonitorView: NSView {
    var items: [AppKitContextMenuItem] = []
    private var eventMonitor: Any?
    private var activeHandlers: [Int: () -> Void] = [:]
    private var nextHandlerTag = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            let input = AppKitContextMenuEvent(event)
            let output: AppKitContextMenuEvent = MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let event = input.value,
                      event.window === window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
                else { return input }

                self.activeHandlers = [:]
                self.nextHandlerTag = 0
                let menu = self.makeMenu(items: self.items)
                _ = menu.popUp(positioning: nil, at: self.convert(event.locationInWindow, from: nil), in: self)
                self.activeHandlers = [:]
                return AppKitContextMenuEvent(nil)
            }
            return output.value
        }
    }

    private func makeMenu(items: [AppKitContextMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let enabled, let handler):
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(performMenuAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = nextHandlerTag
                nextHandlerTag += 1
                menuItem.isEnabled = enabled
                activeHandlers[menuItem.tag] = handler
                menu.addItem(menuItem)
            case .submenu(let title, let enabled, let subItems):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = enabled
                menuItem.submenu = makeMenu(items: subItems)
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        activeHandlers[sender.tag]?()
    }

    func detach() {
        activeHandlers = [:]
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

private struct AppKitContextMenuEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}
