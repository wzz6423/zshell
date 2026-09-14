#!/usr/bin/env python3
"""Exercise click-position links with the real Ghostty engine in a hidden window."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

HARNESS = r'''
import AppKit
import GhosttyKit
@testable import GhosttyTerminal

enum Failure: Error { case check(String) }

@main struct Harness {
    @MainActor static func main() {
        do {
            try run()
        } catch {
            print("FAIL", error)
            exit(1)
        }
    }

    @MainActor static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("Sources/main.swift")
        try Data("fixture".utf8).write(to: file)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(configSource: .generated(
            "font-family = Menlo\nfont-size = 14\nwindow-padding-x = 0\n"
                + "window-padding-y = 0\nwindow-padding-balance = false\nshell-integration = none\n"
        ))
        let view = ProbeView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        // A hidden-window test must not change the user's system cursor.
        view.core.onMouseShapeChange = { _ in }
        view.delegate = view
        view.events = Session(currentDirectoryPath: directory.path)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.controller = nil
            window.contentView = nil
            window.close()
        }
        let longURL = "www.example.com/" + String(repeating: "segment/", count: 14) + "end"
        session.receive(
            "https://a.example\r\nhttps://b.example\r\nwww.example.com:8080/docs?q=x#h\r\n"
                + "前 😀 www.example.com/x\r\n./Sources/main.swift:42\r\n"
                + "\u{1b}]8;;https://osc.example/exact\u{1b}\\Click me\u{1b}]8;;\u{1b}\\\r\n"
                + "localhost:3000/health\r\nplain text\r\n" + longURL
        )
        let deadline = Date().addingTimeInterval(3)
        while session.readViewportText()?.contains("segment/end") != true && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let metrics = view.metrics else { throw Failure.check("missing grid metrics") }
        let width = CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor
        let height = CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor
        func event(_ row: Int, column: Int = 3, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(
                    x: (CGFloat(column) + 0.5) * width,
                    y: view.bounds.height - (CGFloat(row) + 0.5) * height
                ),
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        var checks = 0
        func check(_ name: String, _ event: NSEvent, _ expected: TerminalLinkTarget?) throws {
            let result = view.target(event)
            guard result == expected else {
                throw Failure.check("\(name): \(String(describing: result)) != \(String(describing: expected))")
            }
            checks += 1
            print("PASS", name)
        }
        view.mouseMoved(with: event(0, modifiers: []))
        try check("same position adds Command", event(0), .url(URL(string: "https://a.example")!))
        try check("first cell refresh", event(0, column: 0), .url(URL(string: "https://a.example")!))
        try check("new row without hover", event(1), .url(URL(string: "https://b.example")!))
        try check(
            "bare host port query and fragment", event(2),
            .url(URL(string: "https://www.example.com:8080/docs?q=x#h")!)
        )
        try check("Unicode prefix", event(3, column: 10), .url(URL(string: "https://www.example.com/x")!))
        try check("relative diagnostic file", event(4), .file(file.standardizedFileURL))
        try check("OSC8 target keeps destination", event(5), .url(URL(string: "https://osc.example/exact")!))
        try check("localhost retains port", event(6), .url(URL(string: "http://localhost:3000/health")!))
        try check("blank text drops old hover", event(7), nil)
        try check("soft wrapped bare URL", event(8), .url(URL(string: "https://" + longURL)!))
        try check("unmodified click is not a link action", event(0, modifiers: []), nil)
        _ = view.target(event(0))
        session.receive("\u{1b}[1;1Hhttps://c.example\u{1b}[K")
        let changedDeadline = Date().addingTimeInterval(3)
        while session.readViewportText()?.contains("https://c.example") != true && Date() < changedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check("changed output under stationary pointer", event(0), .url(URL(string: "https://c.example")!))
        session.receive("\u{1b}[?1003h\u{1b}[?1006h")
        let captureDeadline = Date().addingTimeInterval(3)
        while !view.isMouseCaptured && Date() < captureDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard view.isMouseCaptured else { throw Failure.check("mouse capture was not enabled") }
        try check(
            "mouse capture keeps host Command link action", event(2),
            .url(URL(string: "https://www.example.com:8080/docs?q=x#h")!)
        )
        session.receive("\u{1b}[?1003l\u{1b}[?1006l\u{1b}[2J\u{1b}[H👩🏽‍💻 e\u{301} https://example.com/\r\n")
        let unicodeDeadline = Date().addingTimeInterval(3)
        while session.readViewportText()?.contains("👩🏽‍💻") != true && Date() < unicodeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let unicodeEvent = event(0, column: 15)
        guard view.contextText(for: unicodeEvent) == "https://example.com/" else {
            throw Failure.check("emoji and combining prefix truncated the context token")
        }
        try check("emoji and combining prefix", unicodeEvent, .url(URL(string: "https://example.com/")!))

        let scrolledLink = "www.example.com/scrollback?row=7#anchor"
        session.receive("\u{1b}[2J\u{1b}[H" + (0..<50).map {
            ($0 == 7 ? scrolledLink : "scrollback row \($0)") + "\r\n"
        }.joined())
        let outputDeadline = Date().addingTimeInterval(3)
        while session.readViewportText()?.contains("scrollback row 49") != true && Date() < outputDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let bottomViewport = session.readViewportText(),
              bottomViewport.contains("scrollback row 49"), !bottomViewport.contains(scrolledLink)
        else { throw Failure.check("scrollback fixture has not reached the bottom") }
        guard view.scrollToRow(5) else { throw Failure.check("scrollToRow failed") }
        let scrollDeadline = Date().addingTimeInterval(3)
        while session.readViewportText()?.contains(scrolledLink) != true && Date() < scrollDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let row = session.readViewportText()?.components(separatedBy: "\n").firstIndex(of: scrolledLink), row > 0,
              let rawSurface = view.surface?.rawValue else { throw Failure.check("scrollback link is not visible") }
        let firstRow = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(metrics.columns), y: 0
            ),
            rectangle: false
        )
        var firstRowText = ghostty_text_s()
        guard ghostty_surface_read_text(rawSurface, firstRow, &firstRowText) else {
            throw Failure.check("cannot read the first scrollback row")
        }
        let firstRowOffset = firstRowText.offset_start
        ghostty_surface_free_text(rawSurface, &firstRowText)
        guard view.contextText(for: event(row)) == scrolledLink else {
            throw Failure.check("scrollback offset truncated the context token")
        }
        guard let word = view.surface?.quicklookWord(), word.offsetStart > firstRowOffset else {
            throw Failure.check("scrollback must exercise a later visible row")
        }
        try check("scrolled viewport resolves visible link", event(row), .url(URL(string: "https://" + scrolledLink)!))
        print("Ghostty context links: \(checks) assertions passed")
    }
}
'''


class GhosttyLinkPositionTests(unittest.TestCase):
    def test_current_click_and_link_text(self):
        session_source = (REPO / "mac/zshell/TerminalSession.swift").read_text()
        classifier = session_source[
            session_source.index("    func terminalLinkTarget(for value:"):
            session_source.index("    func terminalDidScroll(")
        ]
        view_source = (REPO / "mac/zshell/ZshellTerminalView.swift").read_text()
        link_target = view_source[
            view_source.index("    private func linkTarget(for event:"):
            view_source.index("    private func contextMenu(")
        ]
        with tempfile.TemporaryDirectory(prefix="zshell-ghostty-links-") as directory:
            package = Path(directory)
            sources = package / "Sources/Harness"
            sources.mkdir(parents=True)
            (sources / "Links.swift").write_text(
                "import AppKit\n@testable import GhosttyTerminal\n"
                "enum TerminalLinkTarget: Equatable { case file(URL), url(URL) }\n"
                "struct Session {\n"
                "    var foregroundDirectoryPath: String? = nil\n"
                "    let currentDirectoryPath: String\n"
                + classifier + "\n}\n"
                "@MainActor final class ProbeView: AppTerminalView, "
                "TerminalSurfaceHoverLinkDelegate, TerminalSurfaceGridResizeDelegate {\n"
                "    var hoveredLink: String?\n"
                "    var metrics: TerminalGridMetrics?\n"
                "    var events: Session?\n"
                "    func terminalDidUpdateHoverLink(_ url: String?) { hoveredLink = url }\n"
                "    func terminalDidResize(_ size: TerminalGridMetrics) { metrics = size }\n"
                "    func target(_ event: NSEvent) -> TerminalLinkTarget? { linkTarget(for: event) }\n"
                + link_target + "\n}\n"
            )
            (sources / "Harness.swift").write_text(HARNESS)
            ghostty_path = str(REPO / "mac/Vendor/libghostty-spm").replace("\\", "\\\\").replace('"', '\\"')
            (package / "Package.swift").write_text(
                "// swift-tools-version: 6.0\n"
                "import PackageDescription\n"
                'let package = Package(name: "GhosttyLinkRegression", '
                'platforms: [.macOS(.v14)], '
                f'dependencies: [.package(path: "{ghostty_path}")], '
                'targets: [.executableTarget(name: "Harness", dependencies: '
                '[.product(name: "GhosttyTerminal", package: "libghostty-spm")])], '
                'swiftLanguageModes: [.v5])\n'
            )
            result = subprocess.run(
                [
                    "swift", "run", "--package-path", str(package),
                    "--scratch-path", str(package / "build"), "Harness",
                    str(package / "fixture"),
                ],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                env={**os.environ, "TMPDIR": str(package)},
                timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("15 assertions passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
