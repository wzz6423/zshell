import AppKit
import Foundation
#if ZSHELL_BUILT_APP
import STTextView
@testable import zshell
#endif

private final class SearchPanelFixtureWindow: NSWindow {
    // AppKit's click handling needs a key-window context, without activating a window.
    override var isKeyWindow: Bool { true }
}

@main
@MainActor
struct FileContentSearchPanelTests {
    static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let mode = CommandLine.arguments[1]
        let root = CommandLine.arguments[2]
        let model = FileContentSearchModel()
        model.sync(root: root)
        model.query = CommandLine.arguments[3]
        if mode == "remount" { try search(model) }

        var opened: [FileContentSearchModel.Match] = []
        let panel = FileContentSearchPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        panel.configure(model: model, fontScale: 1) { match in
            opened.append(match)
        }
        let window = SearchPanelFixtureWindow(contentRect: QuickTerminalOffscreen.frame(panel.frame),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = panel
        defer { window.contentView = nil; window.close() }
        guard let table = descendants(panel).compactMap({ $0 as? NSScrollView }).first?.documentView as? NSTableView else {
            throw failure("The production search panel has no result table")
        }
        if mode != "remount" { try search(model) }
        var result = snapshot(model, panel: panel, table: table)

        if mode == "refresh" {
            model.query = CommandLine.arguments[4]
            try search(model)
            result["replacement"] = snapshot(model, panel: panel, table: table)
            model.query = "no-such-search-panel-match"
            try search(model)
            result["empty"] = snapshot(model, panel: panel, table: table)
            model.query = CommandLine.arguments[3]
            try search(model)
            model.sync(root: (root as NSString).appendingPathComponent("empty"))
            try flushPanelUpdates()
            result["rerooted"] = snapshot(model, panel: panel, table: table)
        } else if mode == "actions" || mode == "editor" {
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            result["selectionOnlyOpenCount"] = opened.count
            pressReturn(table, window: window)
            result["returnOpenCount"] = opened.count
            table.deselectAll(nil)
            pressReturn(table, window: window)
            result["unselectedReturnOpenCount"] = opened.count
            if table.numberOfRows > 0 {
                click(row: 0, in: table, window: window)
            }
            result["clickedRow"] = table.selectedRow
            result["opened"] = opened.map(matchJSON)
            #if ZSHELL_BUILT_APP
            if mode == "editor" {
                var editors: [[String: Any]] = []
                for match in opened { editors.append(try openEditor(match, root: root)) }
                result["editors"] = editors
            }
            #endif
        }
        result["offscreenSafe"] = QuickTerminalOffscreen.isSafe()
        result["windowVisible"] = window.isVisible
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    private static func search(_ model: FileContentSearchModel) throws {
        model.run()
        try wait("grep did not complete") { !model.isRunning }
        try flushPanelUpdates()
    }

    private static func flushPanelUpdates() throws {
        // The observer enqueues its read during willSet, before the new value lands.
        var complete = false
        DispatchQueue.main.async { complete = true }
        try wait("panel update did not complete") { complete }
    }

    private static func wait(_ message: String, until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !complete() {
            guard Date() < deadline else { throw failure(message) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func snapshot(
        _ model: FileContentSearchModel, panel: FileContentSearchPanel, table: NSTableView
    ) -> [String: Any] {
        panel.layoutSubtreeIfNeeded()
        let cells = (0..<table.numberOfRows).map { row -> [String] in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return [] }
            return descendants(cell).compactMap { $0 as? NSTextField }.map(\.stringValue)
        }
        return [
            "failed": model.failureMessage != nil,
            "matches": model.matches.map(matchJSON),
            "rows": table.numberOfRows,
            "cells": cells,
        ]
    }

    private static func matchJSON(_ match: FileContentSearchModel.Match) -> [String: Any] {
        ["path": match.path, "line": match.line, "content": match.content]
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func pressReturn(_ table: NSTableView, window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        table.keyDown(with: event)
    }

    private static func click(row: Int, in table: NSTableView, window: NSWindow) {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
        }
        // NSTableView tracks until mouse-up; enqueue only in this test process.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        table.mouseDown(with: event(.leftMouseDown))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FileContentSearchPanelTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if ZSHELL_BUILT_APP
    private static func openEditor(_ match: FileContentSearchModel.Match, root: String) throws -> [String: Any] {
        let path = (root as NSString).appendingPathComponent(match.path)
        var location: Int?
        var resolved = false
        Task {
            location = await FileContentSearchModel.lineStartLocation(line: match.line, filePath: path)
            resolved = true
        }
        try wait("The selected line did not resolve") { resolved }
        let file = FileTab(path: path)
        if let location { file.revealSelection(at: location) }
        try wait("The selected file did not load") { file.reloadRevision > 0 }
        let viewer = FileViewerContainerView(file: file)
        viewer.update(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                      palette: .theme(dark: true), wrapLines: false, isFocused: false,
                      showsSource: true, onFocused: {}, onSplit: { _ in })
        let window = NSWindow(contentRect: QuickTerminalOffscreen.frame(NSRect(x: 0, y: 0, width: 700, height: 500)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer
        defer { window.contentView = nil; window.close() }
        viewer.layoutSubtreeIfNeeded()
        let editor = (file.editorView as? NSScrollView)?.documentView as? STTextView
        return [
            "path": file.path, "line": match.line,
            "location": location as Any? ?? NSNull(),
            "selection": editor?.textSelection.location as Any? ?? NSNull(),
            "selectionLength": editor?.textSelection.length as Any? ?? NSNull(),
            "hasEditor": editor != nil, "text": file.text, "windowVisible": window.isVisible,
        ]
    }
    #endif
}
