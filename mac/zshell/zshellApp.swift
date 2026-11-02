//
//  zshellApp.swift
//  zshell
//

import AppKit
import SwiftUI

@MainActor
enum zshellApp {
    nonisolated static func main() {
        MainActor.assumeIsolated { run() }
    }

    private static func run() {
        let application = NSApplication.shared
        let delegate = ZshellApplicationDelegate()
        application.delegate = delegate
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
        AppSettings.shared.reconcileAIEnabled()
        Self.migrateDefaultWindowFrame()
        Self.migrateDefaultWindowFrameToScreenshotSize()
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func migrateDefaultWindowFrame() {
        let defaults = UserDefaults.standard
        let migrationKey = "zshell.default-window-size-migrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSWindow Frame main") {
            guard let savedFrame = defaults.string(forKey: key) else { continue }
            var components = savedFrame.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard components.count >= 4,
                  let x = Double(components[0]),
                  let width = Double(components[2]),
                  let height = Double(components[3]),
                  width == 900,
                  height == 600
            else { continue }

            components[0] = String(Int((x - 90).rounded()))
            components[2] = "1080"
            defaults.set(components.joined(separator: " "), forKey: key)
        }

        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateDefaultWindowFrameToScreenshotSize() {
        let defaults = UserDefaults.standard
        let migrationKey = "zshell.default-window-size-1260x706-migrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSWindow Frame main") {
            guard let savedFrame = defaults.string(forKey: key) else { continue }
            var components = savedFrame.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard components.count >= 4,
                  let x = Double(components[0]),
                  let y = Double(components[1]),
                  let width = Double(components[2]),
                  let height = Double(components[3]),
                  width == 1080,
                  height == 600
            else { continue }

            components[0] = String(Int((x - 90).rounded()))
            components[1] = String(Int((y - 53).rounded()))
            components[2] = "1260"
            components[3] = "706"
            defaults.set(components.joined(separator: " "), forKey: key)
        }

        defaults.set(true, forKey: migrationKey)
    }

}

@MainActor
final class ZshellWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let manager = TerminalManager()
    var onClose: (() -> Void)?
    private var localizationObservation: NSObjectProtocol?

    init(number: Int) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 706),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-\(number)")
        window.title = "zshell"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        let content = NSHostingView(rootView: ContentView(manager: manager)
            .environment(\.locale, AppLocalization.current.locale))
        window.contentView = content
        window.setContentSize(NSSize(width: 1260, height: 706))
        let frameName = "main-AppWindow-\(number)"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        // 内容桥保留原视图；窗口与菜单生命周期不再进入 SwiftUI AppGraph。
        manager.attach(to: window)
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        localizationObservation = NotificationCenter.default.addObserver(
            forName: AppLocalization.didChange, object: nil, queue: .main
        ) { [weak content, weak manager] _ in
            MainActor.assumeIsolated {
                guard let content, let manager else { return }
                content.rootView = ContentView(manager: manager)
                    .environment(\.locale, AppLocalization.current.locale)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        if let localizationObservation { NotificationCenter.default.removeObserver(localizationObservation) }
        localizationObservation = nil
        manager.windowClosed()
        if let window {
            window.saveFrame(usingName: window.frameAutosaveName)
            NSApp.removeWindowsItem(window)
            window.contentView = nil
        }
        onClose?()
    }
}
