import AppKit
import IOSurface
import Metal
@testable import GhosttyTerminal
@testable import zshell

@MainActor
private final class PreeditApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
}

@main
@MainActor
struct TerminalPreeditSurfaceTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        setbuf(stdout, nil)
        let app = PreeditApplication.shared as! PreeditApplication
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let backend = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let samples: [(name: String, text: String, color: Bool)] = [
            ("emoji", "😀", true), ("plain", "e", false), ("NFD", "e\u{301}", false),
            ("ZWJ", "👩‍💻", true), ("skin tone", "👩🏽‍💻", true), ("VS16", "✈️", true),
            ("VS15", "⌚︎", false), ("flag", "🇨🇳", true), ("CJK", "中文", false),
            ("leading combining", "\u{301}a", false), ("mixed", "中😀e\u{301}", true),
        ]
        var controlGeneration = 0
        func control(edge: Bool) throws {
            controlGeneration += 1
            try JSONSerialization.data(withJSONObject: ["samples": samples.map(\.text), "edge": edge,
                                                        "generation": controlGeneration])
                .write(to: directory.appendingPathComponent("control.json"), options: .atomic)
        }
        try control(edge: false)
        let settings = AppSettings.shared
        settings.fontFamily = "Menlo"
        settings.fontFallbackFamily = "PingFang SC"
        settings.fontSize = 13
        settings.fontThicken = false
        settings.cursorBlinking = false
        settings.terminalLineHeight = 1
        settings.terminalCellWidth = 1
        settings.terminalTextHints = false
        TerminalFont.registerBundledFonts()
        let fixture = CommandLine.arguments[2]
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = TerminalLaunch(
            program: "/usr/bin/python3", arguments: [fixture, directory.path],
            commandLine: "/usr/bin/python3 \(quoted(fixture)) \(quoted(directory.path))",
            interactiveShell: nil, workingDirectory: directory.path,
            environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"]
        )
        let view: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 760)
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        window.orderFront(nil)
        func pump(_ seconds: TimeInterval = 0.03) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
        defer {
            view.sendText("\u{4}")
            pump(0.1)
            view.setSurfaceVisible(false)
            view.detach()
            window.contentView = nil
            window.close()
        }
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "\(backend): \(message)", code: 1) }
            checks += 1
        }
        func geometry() -> [String: Int]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("size.json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        }
        func settled() -> Bool {
            guard let size = geometry(), let generation = size["generation"],
                  let snapshot = view.readVisibleSnapshot() else { return false }
            return snapshot.columns == size["columns"] && snapshot.rows.count == size["rows"]
                && snapshot.rows.contains { $0.text.contains("PREEDIT_READY_\(generation)") }
        }
        func wait(_ label: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { pump() }
            if !condition() {
                print("WAIT \(label): \(String(describing: geometry()))")
                print("VIEW \(String(describing: view.readVisibleText(maxLines: 30, maxColumns: 100)))")
            }
            try check(condition(), label)
        }
        try wait("real PTY and surface ready", settled)
        guard let client = view as? any NSTextInputClient,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "missing input client or Metal device", code: 1)
        }
        func pixels(row: Int) throws -> [UInt8] {
            if let ghostty = view as? ZshellTerminalView {
                for _ in 0..<2 { ghostty.core.surface?.draw(); pump() }
            } else { view.applyAppearance(); pump(0.06) }
            guard let surface = view.layer?.contents as? IOSurface, let snapshot = view.readVisibleSnapshot() else {
                throw NSError(domain: "missing presented IOSurface", code: 1)
            }
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            let scale = CGFloat(height) / view.bounds.height
            let first = Int(((snapshot.origin.y + CGFloat(row) * snapshot.cellSize.height) * scale).rounded())
            let last = Int(((snapshot.origin.y + CGFloat(row + 1) * snapshot.cellSize.height) * scale).rounded())
            let count = last - first, rowBytes = width * 4
            try check(first >= 0 && count > 0 && last <= height, "readback row fits the drawable")
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .renderTarget]
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
                  let buffer = device.makeBuffer(length: rowBytes * count, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
                throw NSError(domain: "Metal row readback setup failed", code: 1)
            }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: first, z: 0),
                sourceSize: MTLSize(width: width, height: count, depth: 1), to: buffer,
                destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * count)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            try check(commands.status == .completed, "Metal presents the requested row")
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self),
                                            count: rowBytes * count))
        }
        func colored(_ pixels: [UInt8]) -> Int {
            stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, i in
                let channels = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
                return count + (channels.max()! - channels.min()! > 30 ? 1 : 0)
            }
        }
        func difference(_ first: [UInt8], _ second: [UInt8]) throws -> Int {
            try check(first.count == second.count, "pixel bands have identical geometry")
            return stride(from: 0, to: first.count, by: 4).reduce(0) { count, i in
                let delta = (0..<3).map { abs(Int(first[i + $0]) - Int(second[i + $0])) }.max()!
                return count + (delta > 12 ? 1 : 0)
            }
        }
        func marked(_ text: String) throws {
            let range = NSRange(location: text.utf16.count, length: 0)
            client.setMarkedText(NSAttributedString(string: text), selectedRange: range,
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            try check(client.hasMarkedText(), "marked state is active")
            try check(client.markedRange() == NSRange(location: 0, length: text.utf16.count),
                      "UTF-16 marked range retains the source")
            if backend == "ghostty" {
                try check(client.selectedRange() == range, "UTF-16 selected range retains the source")
                var actual = NSRange(location: NSNotFound, length: 0)
                let substring = client.attributedSubstring(forProposedRange: client.markedRange(), actualRange: &actual)
                try check(substring?.string.utf16.elementsEqual(text.utf16) == true && actual == client.markedRange(),
                          "attributed substring retains NFD, selectors and joiners verbatim")
            }
            let rect = client.firstRect(forCharacterRange: range, actualRange: nil)
            let local = view.convert(window.convertFromScreen(rect), from: nil)
            let snapshot = view.readVisibleSnapshot()!
            let column = CGFloat(geometry()!["cursorColumn"]!) + (backend == "ghostty" ? 0.5 : 0)
            try check(local.width.isFinite && local.height.isFinite && local.width >= 0 && local.height > 0
                      && abs(local.minX - (snapshot.origin.x + column * snapshot.cellSize.width)) < 1,
                      "IME anchor stays on the logical cursor after font and width changes")
        }
        for size in [13.0, 18.0, 32.0] {
            for multiplier in [1.0, 0.75, 1.25, 2.0] {
                client.unmarkText()
                let previousGeneration = geometry()!["generation"]!
                settings.fontSize = size
                settings.terminalCellWidth = multiplier
                view.applyAppearance()
                try control(edge: false)
                try wait("font and column width settle on the real PTY") {
                    settled() && geometry()!["generation"]! > previousGeneration && geometry()!["cursorColumn"] == 2
                }
                let row = geometry()!["preeditRow"]!
                let empty = try pixels(row: row)
                var plain: [UInt8] = []
                for (index, sample) in samples.enumerated() {
                    let normal = try pixels(row: index)
                    try marked(sample.text)
                    let composition = try pixels(row: row)
                    try check(try difference(composition, empty) > 10, "\(sample.name) produces real pixels")
                    if sample.color {
                        try check(colored(composition) > 10, "\(sample.name) uses the color atlas")
                        // Ghostty mode 2027 makes PTY clusters a direct rendering
                        // reference. Alacritty's PTY parser can split a ZWJ sequence.
                        if backend == "ghostty" || sample.name == "emoji" {
                            try check(colored(normal) > 10 && colored(composition) >= colored(normal) / 2,
                                      "\(sample.name) retains the regular glyph's color atlas")
                        }
                    }
                    if sample.name == "plain" { plain = composition }
                    if sample.name == "NFD" {
                        try check(try difference(composition, plain) > 10, "NFD combining accent is visible")
                    }
                    if sample.name == "VS15" {
                        try check(colored(composition) <= colored(normal) + 5, "VS15 keeps text presentation")
                    }
                    client.unmarkText()
                    try check(!client.hasMarkedText() && client.markedRange().location == NSNotFound,
                              "unmark clears the input state")
                    try check(try difference(pixels(row: row), empty) == 0, "unmark removes every preedit pixel")
                }
                if backend == "ghostty" {
                    let oldGeneration = geometry()!["generation"]!
                    try control(edge: true)
                    try wait("cursor moves to the last column") { settled() && geometry()!["generation"]! > oldGeneration }
                    let edgeEmpty = try pixels(row: row)
                    for text in ["e\u{301}👩🏽‍💻", String(repeating: "中😀e\u{301}", count: 100) + "👩🏽‍💻"] {
                        try marked(text)
                        try check(colored(pixels(row: row)) > 10, "right-edge composition retains a whole color cluster")
                        client.unmarkText()
                        try check(try difference(pixels(row: row), edgeEmpty) == 0, "right-edge unmark restores the row")
                    }
                }
                try check((try Data(contentsOf: directory.appendingPathComponent("received.bin"))).isEmpty,
                          "PTY receives no uncommitted composition bytes")
                print("PASS \(backend): \(Int(size))pt \(Int(multiplier * 100))% Unicode pixels and unmark")
            }
        }
        let committed = "PREEDIT_COMMITTED_😀e\u{301}"
        try marked(committed)
        app.inputEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)
        client.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        app.inputEvent = nil
        try wait("committed text arrives in the PTY exactly once") {
            (try? Data(contentsOf: directory.appendingPathComponent("received.bin"))) == Data(committed.utf8)
        }
        try check(!client.hasMarkedText(), "commit clears the marked state")
        try check(QuickTerminalOffscreen.isSafe(), "tests preserve desktop windows and focus")
        print("Preedit \(backend): \(checks) assertions passed")
    }
}
