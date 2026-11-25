import AppKit
import Foundation
@testable import zshell

private enum SSHConfigPickerFailure: Error { case failed(String) }

@main
@MainActor
struct SSHConfigHostPickerTests {
    private static var checks = 0
    private static var visible: Bool { CommandLine.arguments.contains("--visible") }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if !visible { QuickTerminalOffscreen.install() }
        AppSettings.shared.language = .english
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.restoreTerminalHistory = false
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.resumeAgentConversations = false
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ssh = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let config = ssh.appendingPathComponent("config")
        try Data("Host alpha beta gamma\n    HostName 127.0.0.1\n".utf8).write(to: config)
        let source = SSHConfigHosts(configurationURL: config, sshDirectory: ssh)
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        owner.isReleasedWhenClosed = false
        owner.orderFront(nil)
        let picker = SSHConfigHostPickerController(source: { source })
        var choices: [String?] = []
        picker.present(on: owner, selecting: "beta") { choices.append($0) }
        let (panel, search, table, choose) = try controls(owner)
        try wait("config hosts finish loading") { table.numberOfRows == 3 }
        try check(table.selectedRow == 1 && choose.isEnabled, "current alias selects the matching native row")
        try check(panel.sheetParent === owner, "picker belongs to its caller's sheet")
        search.stringValue = "GAM"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(table.numberOfRows == 1 && choose.isEnabled, "case-insensitive search filters Host aliases")
        try check(label(at: 0, table: table) == "gamma", "search keeps the original alias")
        try click(choose)
        pump(0.1)
        try check(choices.count == 1 && choices[0] == "gamma", "Choose returns only the alias once")
        try check(owner.attachedSheet == nil, "Choose ends the sheet")

        picker.present(on: owner, selecting: "") { choices.append($0) }
        let (_, cancelSearch, cancelTable, cancelChoose) = try controls(owner)
        try wait("reopened config hosts finish loading") { cancelTable.numberOfRows == 3 }
        cancelSearch.stringValue = "missing"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cancelSearch))
        try check(cancelTable.numberOfRows == 0 && !cancelChoose.isEnabled, "empty search disables selection")
        try check(
            picker.control(cancelSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))),
            "Escape is handled by the picker")
        pump(0.1)
        try check(choices.count == 2 && choices[1] == nil && owner.attachedSheet == nil, "Cancel returns no alias once")

        picker.present(on: owner, selecting: "alpha") { choices.append($0) }
        let (_, keyboardSearch, keyboardTable, _) = try controls(owner)
        try wait("keyboard picker finishes loading") { keyboardTable.numberOfRows == 3 }
        _ = picker.control(keyboardSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        try check(keyboardTable.selectedRow == 1, "Down selects the next config host")
        _ = picker.control(keyboardSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        try check(keyboardTable.selectedRow == 0, "Up selects the previous config host")
        _ = picker.control(keyboardSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.1)
        try check(choices.count == 3 && choices[2] == "alpha", "Return chooses the selected alias")

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let delayed = SSHConfigHostPickerController(source: {
            started.signal()
            _ = release.wait(timeout: .now() + 3)
            defer { completed.signal() }
            return source
        })
        var cancelled = 0
        delayed.present(on: owner, selecting: "") { _ in cancelled += 1 }
        let (_, _, delayedTable, delayedChoose) = try controls(owner)
        try check(started.wait(timeout: .now() + 1) == .success, "background reader starts outside the main actor")
        delayed.close()
        release.signal()
        try check(completed.wait(timeout: .now() + 1) == .success, "cancelled background source returns")
        pump(0.2)
        try check(
            cancelled == 1 && delayedTable.numberOfRows == 0 && !delayedChoose.isEnabled,
            "late results cannot update a closed picker or call completion twice")

        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        var oldOwnerCalls = 0
        var newOwnerCalls = 0
        picker.present(on: owner, selecting: "") { _ in oldOwnerCalls += 1 }
        pump(0.1)
        picker.present(on: other, selecting: "") { _ in newOwnerCalls += 1 }
        let (newPanel, _, newTable, _) = try controls(other)
        try wait("second owner config hosts finish loading") { newTable.numberOfRows == 3 }
        try check(
            oldOwnerCalls == 1 && newPanel.sheetParent === other && owner.attachedSheet == nil,
            "reopening under another owner cancels the original sheet")
        picker.close()
        pump(0.1)
        try check(newOwnerCalls == 1, "new owner's Cancel completes once")

        let closedOwner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        closedOwner.isReleasedWhenClosed = false
        closedOwner.orderFront(nil)
        let ownerStarted = DispatchSemaphore(value: 0)
        let ownerRelease = DispatchSemaphore(value: 0)
        let ownerCompleted = DispatchSemaphore(value: 0)
        let ownerPicker = SSHConfigHostPickerController(source: {
            ownerStarted.signal()
            _ = ownerRelease.wait(timeout: .now() + 3)
            defer { ownerCompleted.signal() }
            return source
        })
        var closedOwnerCalls = 0
        ownerPicker.present(on: closedOwner, selecting: "") { host in
            precondition(host == nil)
            closedOwnerCalls += 1
        }
        let (_, _, ownerTable, ownerChoose) = try controls(closedOwner)
        try check(ownerStarted.wait(timeout: .now() + 1) == .success, "owner-close reader starts")
        closedOwner.close()
        ownerRelease.signal()
        try check(ownerCompleted.wait(timeout: .now() + 1) == .success, "owner-close reader finishes")
        pump(0.2)
        try check(
            closedOwnerCalls == 1 && closedOwner.attachedSheet == nil && ownerTable.numberOfRows == 0 && !ownerChoose.isEnabled,
            "closing the owner cancels its sheet and suppresses late candidates")

        let errorPicker = SSHConfigHostPickerController(source: { throw SSHEndpoint.ValidationError.invalidConfiguration })
        errorPicker.present(on: owner, selecting: "") { _ in }
        let (errorPanel, _, _, errorChoose) = try controls(owner)
        try wait("invalid configuration reports a native error") {
            descendants(errorPanel.contentView!).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == SSHEndpoint.ValidationError.invalidConfiguration.errorDescription
            }
        }
        try check(!errorChoose.isEnabled, "invalid override cannot choose a personal fallback host")
        errorPicker.close()

        try formIntegration(root: root)
        owner.close()
        other.close()
        pump(0.1)
        if !visible { try check(QuickTerminalOffscreen.isSafe(), "native fixtures never activate or intersect a display") }
        print("SSH config picker: \(checks) passed, 0 failed")
    }

    private static func formIntegration(root: URL) throws {
        let manager = TerminalManager()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        host.identifier = NSUserInterfaceItemIdentifier("main-ssh-config-fixture")
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        manager.attach(to: host)
        let controller = SSHProjectController.shared
        controller.present(for: manager)
        guard let form = host.childWindows?.first, let content = form.contentView else {
            throw SSHConfigPickerFailure.failed("SSH project dialog is missing")
        }
        defer {
            form.close()
            manager.windowClosed()
            host.close()
        }
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        guard let new = buttons.first(where: { $0.title == "New" }) else {
            throw SSHConfigPickerFailure.failed("New SSH project button missing")
        }
        try click(new)
        guard let grid = descendants(content).first(where: { $0 is NSGridView }) as? NSGridView,
            let hostRow = grid.cell(atColumnIndex: 1, rowIndex: 1).contentView,
            let field = descendants(hostRow).compactMap({ $0 as? NSTextField }).first,
            let user = grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as? NSTextField,
            let port = grid.cell(atColumnIndex: 1, rowIndex: 3).contentView as? NSTextField,
            let directory = grid.cell(atColumnIndex: 1, rowIndex: 4).contentView as? NSTextField,
            let authentication = grid.cell(atColumnIndex: 1, rowIndex: 5).contentView as? NSPopUpButton,
            let trigger = descendants(hostRow).compactMap({ $0 as? NSButton }).first,
            let save = buttons.first(where: { $0.title == "Save" })
        else { throw SSHConfigPickerFailure.failed("SSH project form fields missing") }
        field.stringValue = "original"
        user.stringValue = "explicit-user"
        port.stringValue = "2200"
        directory.stringValue = "~/keep directory"
        authentication.selectItem(at: 2)
        guard let keyRow = grid.cell(atColumnIndex: 1, rowIndex: 7).contentView,
            let key = descendants(keyRow).compactMap({ $0 as? NSTextField }).first
        else { throw SSHConfigPickerFailure.failed("private key path field missing") }
        key.stringValue = "~/.ssh/fixture-key"
        let before = SSHProjectStore.shared.entries.count
        if visible {
            NSApp.activate(ignoringOtherApps: true)
            form.makeKeyAndOrderFront(nil)
            pump(0.2)
            try capture(form, root: root, name: "ssh-form")
        }
        try click(trigger)
        let (panel, _, table, choose) = try controls(form)
        try wait("form picker reads the environment override") { table.numberOfRows == 2 }
        try check(label(at: 0, table: table) == "form-host", "form uses the explicit SSH config source")
        if visible {
            panel.makeKeyAndOrderFront(nil)
            pump(0.2)
            try capture(panel, root: root, name: "ssh-config-picker")
        }
        panel.cancelOperation(nil)
        pump(0.1)
        try check(
            field.stringValue == "original" && SSHProjectStore.shared.entries.count == before,
            "cancel keeps the typed host and leaves saved projects unchanged")
        try click(trigger)
        let (_, _, reopened, _) = try controls(form)
        try wait("form picker reopens") { reopened.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click(choose)
        pump(0.1)
        try check(field.stringValue == "form-host", "picker replaces only the host field")
        if visible { try capture(form, root: root, name: "ssh-chosen-host") }
        try check(
            user.stringValue == "explicit-user" && port.stringValue == "2200"
                && directory.stringValue == "~/keep directory" && authentication.indexOfSelectedItem == 2
                && key.stringValue == "~/.ssh/fixture-key", "selection preserves explicit user, port, directory and authentication")
        try check(SSHProjectStore.shared.entries.count == before, "choosing an alias does not save or connect")
        try click(save)
        guard let saved = SSHProjectStore.shared.entries.last else { throw SSHConfigPickerFailure.failed("Save did not create an entry") }
        try check(
            SSHProjectStore.shared.entries.count == before + 1 && saved.host == "form-host"
                && saved.user == "explicit-user" && saved.port == 2200 && saved.directory == "~/keep directory"
                && saved.authentication == .privateKeyPath("~/.ssh/fixture-key"), "Save keeps the existing SSH project form semantics")
        let stored = try JSONDecoder().decode([SSHProjectEntry].self, from: Data(contentsOf: SSHProjectStore.fileURL))
        try check(stored.last == saved, "saved alias and explicit overrides round-trip through the existing store")
        let endpoint = try SSHEndpoint(host: saved.host, user: saved.user, port: saved.port)
        let arguments = try endpoint.terminalArguments(
            remoteDirectory: saved.directory, authentication: saved.authentication,
            identityFile: "~/.ssh/fixture-key")
        try check(
            arguments.first == "-F" && arguments.contains("explicit-user@form-host") && arguments.contains("2200")
                && arguments.contains("~/.ssh/fixture-key"),
            "existing connection arguments retain alias, config override and authentication")
        SSHProjectStore.shared.remove(saved)
    }

    private static func capture(_ window: NSWindow, root: URL, name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let url = root.appendingPathComponent(name + ".png")
        process.arguments = ["-x", "-l" + String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "visible fixture screenshot is captured")
    }

    private static func controls(_ owner: NSWindow) throws -> (NSWindow, NSSearchField, NSTableView, NSButton) {
        guard let panel = owner.attachedSheet, let content = panel.contentView,
            let search = descendants(content).first(where: { $0.accessibilityIdentifier() == "ssh-config-host-search" }) as? NSSearchField,
            let table = descendants(content).first(where: { $0.accessibilityIdentifier() == "ssh-config-host-list" }) as? NSTableView,
            let choose = descendants(content).first(where: { $0.accessibilityIdentifier() == "ssh-config-host-choose" }) as? NSButton
        else { throw SSHConfigPickerFailure.failed("picker controls missing") }
        return (panel, search, table, choose)
    }

    private static func label(at row: Int, table: NSTableView) -> String? {
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func click(_ button: NSButton) throws {
        guard let action = button.action, NSApp.sendAction(action, to: button.target, from: button) else {
            throw SSHConfigPickerFailure.failed("button action was not dispatched")
        }
    }
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw SSHConfigPickerFailure.failed(message) }
        checks += 1
    }
    private static func wait(_ message: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { pump(0.01) }
        try check(condition(), message)
    }
    private static func pump(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
}
