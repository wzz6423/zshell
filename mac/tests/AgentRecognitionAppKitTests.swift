import AppKit
import Darwin
import Foundation
@testable import zshell

@MainActor
private final class RecognitionTestApplication: NSApplication {
    var host: NSWindow?
    override var keyWindow: NSWindow? { host }
    override var mainWindow: NSWindow? { host }
}

@MainActor
private final class RecognitionTestHost: NSWindow {
    override var isVisible: Bool { true }
}

@main
@MainActor
struct AgentRecognitionAppKitTests {
    static var checks = 0
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("Agent recognition AppKit failed after \(checks): \(error)\n", stderr); exit(1) }
    }

    static func pump(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func run() throws {
        let app = RecognitionTestApplication.shared as! RecognitionTestApplication
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let host = RecognitionTestHost(contentRect: NSRect(x: -100000, y: -100000, width: 1100, height: 800),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.identifier = .init("main-agent-recognition-probe")
        QuickTerminalOffscreen.prepare(host)
        app.host = host
        let controller = AgentRecognitionRulesController.shared
        let rules = AgentRecognitionRulesStore.shared
        defer {
            controller.close()
            app.host = nil
            host.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: label, code: 1) }
            checks += 1
            print("PASS AppKit: \(label)")
        }
        func wait(_ label: String, _ condition: () -> Bool) throws {
            let until = Date().addingTimeInterval(5)
            while !condition(), Date() < until { pump(0.02) }
            try check(condition(), label)
        }
        func button(_ title: String, in window: NSWindow) throws -> NSButton {
            guard let content = window.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw NSError(domain: "missing button \(title)", code: 1)
            }
            return button
        }
        func table(_ window: NSWindow) throws -> NSTableView {
            guard let content = window.contentView,
                  let table = descendants(content).compactMap({ $0 as? NSTableView }).first else {
                throw NSError(domain: "missing rules table", code: 1)
            }
            return table
        }
        func editor(_ window: NSWindow) throws -> (NSWindow, NSTextView) {
            try wait("agent editor sheet opens") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let text = descendants(content).compactMap({ $0 as? NSTextView }).first else {
                throw NSError(domain: "missing TOML editor", code: 1)
            }
            return (sheet, text)
        }
        func save(_ values: [AgentRecognitionManifest]) throws {
            var complete = false
            var error: String?
            rules.save(values) { error = $0; complete = true }
            try wait("fixture rules save finishes") { complete }
            try check(error == nil, "fixture rules save succeeds")
        }
        func checkLayout(_ window: NSWindow, label: String) throws {
            guard let content = window.contentView else { throw NSError(domain: "no content", code: 1) }
            content.layoutSubtreeIfNeeded()
            pump(0.02)
            let bounds = content.bounds.insetBy(dx: -1, dy: -1)
            let buttons = descendants(content).compactMap { $0 as? NSButton }
            for button in buttons where !button.isHidden && button.enclosingScrollView == nil {
                let frame = button.convert(button.bounds, to: content)
                try check(bounds.contains(frame) && frame.width + 1 >= button.intrinsicContentSize.width,
                          "\(label) button \(button.title) fits")
            }
        }
        try save([])
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            pump(0.05)
            controller.show()
            guard let panel = controller.window else { throw NSError(domain: "manager did not open", code: 1) }
            for width in [480.0, 680, 900] {
                panel.setContentSize(NSSize(width: width, height: 570))
                try checkLayout(panel, label: "\(language.rawValue) \(Int(width))")
                let rulesTable = try table(panel)
                try check(rulesTable.numberOfRows == 9, "\(language.rawValue) built-in table is available")
            }
            panel.setFrame(NSRect(origin: QuickTerminalOffscreen.origin, size: panel.minSize), display: false)
            try checkLayout(panel, label: "\(language.rawValue) minimum")
            let pane = SettingsAutomationPane()
            pane.setCategory(.automation)
            let view = pane.view
            host.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 480, height: 700)
            view.layoutSubtreeIfNeeded()
            let switches = descendants(view).compactMap { $0 as? NSSwitch }.filter {
                $0.accessibilityLabel() == String(localized: "Use custom recognition rules")
                    || $0.accessibilityLabel() == String(localized: "Infer agent state from the screen")
            }
            try check(switches.count == 2, "\(language.rawValue) independent settings switches exist")
            for control in switches {
                guard let row = control.superview?.superview else { throw NSError(domain: "missing settings row", code: 1) }
                let frame = control.convert(control.bounds, to: row)
                try check(row.bounds.insetBy(dx: -1, dy: -1).contains(frame) && frame.width > 0,
                          "\(language.rawValue) narrow settings switch fits")
            }
            host.contentView = nil
            controller.close()
        }
        AppLocalization.apply(.english)
        pump(0.05)
        controller.show()
        guard let panel = controller.window else { throw NSError(domain: "manager missing", code: 1) }
        panel.setContentSize(NSSize(width: 680, height: 570))
        let list = try table(panel)
        let scrollingEntries = (0..<60).map {
            AgentRecognitionManifest(id: "scroll-agent-\($0)", name: "Tool \($0)", executables: [], rules: [])
        }
        try save(scrollingEntries)
        pump(0.1)
        list.layoutSubtreeIfNeeded()
        let firstVisible = list.rows(in: list.visibleRect)
        let firstRows = (firstVisible.location..<(firstVisible.location + firstVisible.length)).compactMap {
            list.view(atColumn: 0, row: $0, makeIfNecessary: true)
        }
        let firstIDs = Set(firstRows.map(ObjectIdentifier.init))
        list.scrollRowToVisible(list.numberOfRows - 1)
        pump(0.05)
        list.layoutSubtreeIfNeeded()
        list.scrollRowToVisible(0)
        pump(0.05)
        list.layoutSubtreeIfNeeded()
        let visible = list.rows(in: list.visibleRect)
        let reloadedRows = (visible.location..<(visible.location + visible.length)).compactMap {
            list.view(atColumn: 0, row: $0, makeIfNecessary: true)
        }
        try check(reloadedRows.contains { firstIDs.contains(ObjectIdentifier($0)) }, "table reuses AppKit row views while scrolling")
        try save([])
        pump(0.05)
        try button(String(localized: "Add Agent…"), in: panel).performClick(nil)
        let (sheet, text) = try editor(panel)
        let draft = text.string + "# unsaved draft survives language changes\n"
        text.string = draft
        text.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        AppLocalization.apply(.simplifiedChinese)
        pump(0.05)
        try check(controller.window === panel && panel.attachedSheet === sheet && text.string == draft,
                  "language change preserves the manager, editor sheet, and unsaved TOML")
        try check(sheet.title == String(localized: "Edit Agent Rules")
                  && panel.title == String(localized: "Agent Recognition Rules"), "open windows update their language in place")
        try check(text.selectedRange().location == (draft as NSString).length, "language change preserves editor selection")
        AppLocalization.apply(.english)
        pump(0.05)
        text.string = "[[agents]]\nid = 42"
        let saveButton = try button(String(localized: "Save"), in: sheet)
        let cancelButton = try button(String(localized: "Cancel"), in: sheet)
        NSApp.sendAction(saveButton.action!, to: saveButton.target, from: saveButton)
        try check(!saveButton.isEnabled && !cancelButton.isEnabled, "saving disables duplicate save and cancellation")
        AppLocalization.apply(.german)
        NotificationCenter.default.post(name: AppLocalization.didChange, object: nil)
        try check(controller.window === panel && panel.attachedSheet === sheet && !saveButton.isEnabled,
                  "language change preserves a pending save and its sheet")
        cancelButton.performClick(nil)
        try check(panel.attachedSheet === sheet, "cancel cannot close a pending save")
        try wait("invalid editor recovers for retry") { saveButton.isEnabled }
        try check(rules.manifests.isEmpty && panel.attachedSheet === sheet, "invalid editor keeps current rules and its sheet")
        AppLocalization.apply(.english)
        pump(0.05)
        let frog = AgentRecognitionManifest(id: "frog", name: "Untranslated Tool", executables: ["frog-cli"], rules: [])
        text.string = AgentRecognitionManifest.serialize([frog]) + String(repeating: "# long editor row\n", count: 400)
        sheet.contentView?.layoutSubtreeIfNeeded()
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
        try check(text.isVerticallyResizable && text.enclosingScrollView!.contentView.bounds.minY > 0,
                  "long TOML editor scrolls to its final line")
        NSApp.sendAction(saveButton.action!, to: saveButton.target, from: saveButton)
        AppLocalization.apply(.japanese)
        NotificationCenter.default.post(name: AppLocalization.didChange, object: nil)
        try check(controller.window === panel && panel.attachedSheet === sheet, "successful save stays attached during language change")
        try wait("retry saves custom agent and closes sheet") { panel.attachedSheet == nil && rules.manifests == [frog] }
        AppLocalization.apply(.english)
        pump(0.05)
        try wait("manager updates the added row") { list.numberOfRows == 10 }
        let customRow = list.numberOfRows - 1
        list.selectRowIndexes(IndexSet(integer: customRow), byExtendingSelection: false)
        try button(String(localized: "Edit…"), in: panel).performClick(nil)
        let (editSheet, editText) = try editor(panel)
        var changed = frog
        changed.name = "Updated raw tool name"
        editText.string = AgentRecognitionManifest.serialize([changed])
        try button(String(localized: "Save"), in: editSheet).performClick(nil)
        try wait("edit applies raw tool name") { panel.attachedSheet == nil && rules.manifests == [changed] }
        list.selectRowIndexes(IndexSet(integer: customRow), byExtendingSelection: false)
        try button(String(localized: "Delete"), in: panel).performClick(nil)
        try wait("delete removes only the custom agent") { rules.manifests.isEmpty && list.numberOfRows == 9 }
        var override = AgentRecognitionManifest.editableDefault(.claude)
        override.screenEnabled = false
        try save([override])
        pump(0.05)
        list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let restore = try button(String(localized: "Restore Default"), in: panel)
        try check(restore.isEnabled, "built-in overrides expose Restore Default")
        restore.performClick(nil)
        try wait("restore removes the built-in override") { rules.manifests.isEmpty }
        try button(String(localized: "Add Agent…"), in: panel).performClick(nil)
        let (cancelSheet, _) = try editor(panel)
        try button(String(localized: "Cancel"), in: cancelSheet).performClick(nil)
        try wait("editor cancel closes without saving") { panel.attachedSheet == nil }
        try check(rules.manifests.isEmpty, "cancel leaves rules unchanged")
        try check(QuickTerminalOffscreen.isSafe(), "AppKit checks never take focus or present on a display")
        print("\(checks) AppKit agent recognition production checks passed")
    }
}
