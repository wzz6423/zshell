import AppKit
import Darwin
import ImageIO
@testable import zshell

@MainActor private final class ClipboardTestWindow: NSWindow {
    var key = true
    override var isKeyWindow: Bool { key }
}

@MainActor private func pumpClipboard(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

@MainActor private func waitClipboard(_ label: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if condition() { return }
        pumpClipboard(0.02)
    }
    throw NSError(domain: "LocalClipboardSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
}

@main struct LocalClipboardImageSurfaceTests {
    @MainActor static func main() {
        do {
            if CommandLine.arguments.dropFirst().first == "--capture-bracketed" {
                try captureBracketedPaste()
            } else { try run() }
        }
        catch { fputs("Local clipboard surface failed: \(error)\n", stderr); exit(1) }
    }

    private static func captureBracketedPaste() throws {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw PTYMuxWire.errnoError("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw PTYMuxWire.errnoError("tcsetattr") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        try PTYMuxWire.writeAll(Data("\u{1b}[?2004hBRACKET_READY\r\n".utf8), to: STDOUT_FILENO)
        var received = Data()
        let end = Data("\u{1b}[201~".utf8)
        while received.count < 16_384 {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw PTYMuxWire.errnoError("read") }
            received.append(byte)
            if received.suffix(end.count) == end { break }
        }
        try received.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        try PTYMuxWire.writeAll(Data("\u{1b}[?2004lBRACKET_DONE\r\n".utf8), to: STDOUT_FILENO)
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let root = FileManager.default.homeDirectoryForCurrentUser
        let temporary = FileManager.default.temporaryDirectory
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        let session = TerminalSession(initialDirectory: root.path, commandArguments: ["/bin/sh", "-i"])
        let surface = session.surface
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 480)
        let window = ClipboardTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        surface.setSurfaceVisible(true)
        window.makeFirstResponder(surface)
        let pasteboard = NSPasteboard(name: .init("zshell-local-clipboard-\(UUID().uuidString)"))
        var stored: [URL] = []
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw NSError(domain: "LocalClipboardSurface", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
            print("PASS \(backend) clipboard: \(label)")
        }
        func text() -> String { surface.readVisibleText(maxLines: 256, maxColumns: 2000) ?? "" }
        func batches() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("zshell-clipboard-") })
        }
        func path(from quoted: String) throws -> URL {
            let output = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' " + quoted], timeout: 2, outputLimit: 16_384)
            try check(output.terminationStatus == 0 && !output.output.wasTruncated, "clipboard path is valid shell quoting")
            return URL(fileURLWithPath: output.output.stdout)
        }
        func checkImage(_ url: URL, expectedPNG: Data? = nil) throws {
            stored.append(url)
            let bytes = try Data(contentsOf: url)
            try check(url.path.hasPrefix(temporary.path) && url.pathExtension == "png", "pasted path names a local temporary PNG")
            try check(bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "pasted file uses PNG encoding")
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)
            try check(source != nil && CGImageSourceCreateImageAtIndex(source!, 0, nil) != nil, "saved PNG actually decodes")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let parentAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
                && (parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "native paste creates owner-only file and directory")
            if let expectedPNG { try check(bytes == expectedPNG, "native PNG paste preserves original bytes") }
        }
        defer {
            session.terminate()
            pumpClipboard(0.3)
            window.contentView = nil
            for url in stored { LocalClipboardImageStore.discard(url) }
            pasteboard.releaseGlobally()
        }
        try waitClipboard("local terminal did not launch") { session.shellPid != nil }
        session.sendCommand("printf 'CLIPBOARD_READY\\n'\r")
        try waitClipboard("local terminal did not respond") { text().split(separator: "\n").contains { $0.hasPrefix("CLIPBOARD_READY") } }
        try check(surface.hasEffectiveTerminalFocus, "local fixture has effective terminal focus")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 150, count: 48)
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        let beforeOrdinary = try batches()
        pasteboard.setString("ordinary text", forType: .string)
        try check(!session.terminalHandleUserPaste(pasteboard, paste: { _ in preconditionFailure("ordinary text intercepted") }),
            "ordinary text retains existing backend paste behavior")
        let original = root.appendingPathComponent("existing file ' screenshot.png")
        try png.write(to: original)
        pasteboard.clearContents()
        pasteboard.writeObjects([original as NSURL])
        try check(!session.terminalHandleUserPaste(pasteboard, paste: { _ in preconditionFailure("file URL intercepted") }),
            "local file URLs retain existing backend paste behavior")
        try check(try batches() == beforeOrdinary, "ordinary paste does not create image files")

        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        var converted: String?
        try check(session.terminalHandleUserPaste(pasteboard, paste: { converted = $0 }), "pure TIFF clipboard is captured by the local session")
        try waitClipboard("TIFF clipboard callback did not complete") { converted != nil }
        try checkImage(path(from: converted!))

        // Both real backend selectors read the native clipboard. Preserve its
        // data and avoid restoring over a copy made by the user during the probe.
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        var ownedPasteboardChangeCount = general.changeCount
        defer {
            if general.changeCount == ownedPasteboardChangeCount {
                general.clearContents()
                general.writeObjects(saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, bytes) in values { item.setData(bytes, forType: type) }
                    return item
                })
            }
        }
        for (kind, bytes, label) in [(NSPasteboard.PasteboardType.png, png, "PNG"), (.tiff, tiff, "TIFF")] {
            general.clearContents()
            general.setData(bytes, forType: kind)
            ownedPasteboardChangeCount = general.changeCount
            let marker = "NATIVE_" + label + "_PATH="
            let received = root.appendingPathComponent(marker)
            session.sendCommand("printf '%s' > " + TerminalSession.shellQuote(received.path) + " ")
            try check(surface.tryToPerform(#selector(NSText.paste(_:)), with: nil), "backend accepts the native \(label) paste action")
            try waitClipboard("native image path did not reach the prompt") {
                let visible = text().replacingOccurrences(of: "\n", with: "")
                guard let start = visible.range(of: marker) else { return false }
                return visible[start.upperBound...].contains(".png'")
            }
            session.sendEnter()
            try waitClipboard("native image path was not passed to the shell") {
                guard let value = try? String(contentsOf: received, encoding: .utf8) else { return false }
                return value.hasPrefix("/") && value.hasSuffix(".png")
            }
            let url = URL(fileURLWithPath: try String(contentsOf: received, encoding: .utf8))
            try checkImage(url, expectedPNG: label == "PNG" ? png : nil)
        }

        let bracketCapture = root.appendingPathComponent("bracketed-input")
        let bracketed = TerminalSession(initialDirectory: root.path,
            commandArguments: [CommandLine.arguments[0], "--capture-bracketed", bracketCapture.path],
            allowsPersistence: false)
        let bracketSurface = bracketed.surface
        bracketSurface.frame = surface.frame
        window.contentView = bracketSurface
        bracketSurface.setSurfaceVisible(true)
        window.makeFirstResponder(bracketSurface)
        defer { bracketed.terminate() }
        try waitClipboard("raw PTY fixture did not enable bracketed paste") {
            (bracketSurface.readVisibleText(maxLines: 64, maxColumns: 1000) ?? "").contains("BRACKET_READY")
        }
        general.clearContents()
        general.setData(png, forType: .png)
        ownedPasteboardChangeCount = general.changeCount
        try check(bracketSurface.tryToPerform(#selector(NSText.paste(_:)), with: nil), "raw PTY accepts the native image paste action")
        try waitClipboard("raw PTY did not receive the complete bracketed image paste") {
            FileManager.default.fileExists(atPath: bracketCapture.path)
        }
        let rawPaste = try String(contentsOf: bracketCapture, encoding: .utf8)
        let prefix = "\u{1b}[200~", suffix = "\u{1b}[201~"
        try check(rawPaste.hasPrefix(prefix) && rawPaste.hasSuffix(suffix), "native image path retains bracketed-paste framing for agents")
        try checkImage(path(from: String(rawPaste.dropFirst(prefix.count).dropLast(suffix.count))), expectedPNG: png)
        bracketed.terminate()
        window.contentView = surface
        surface.setSurfaceVisible(true)
        window.makeFirstResponder(surface)

        let field = NSTextField(frame: .init(x: 0, y: 0, width: 100, height: 20))
        surface.addSubview(field)
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        var stalePane = false
        let beforeFocus = try batches()
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in stalePane = true }), "image starts before a pane focus change")
        window.makeFirstResponder(field)
        window.makeFirstResponder(surface)
        var currentPane: String?
        try check(session.terminalHandleUserPaste(pasteboard, paste: { currentPane = $0 }), "a new image paste can start after focus returns")
        try waitClipboard("new paste was lost to an old cancelled task") { currentPane != nil }
        pumpClipboard(0.3)
        try check(!stalePane, "a pane that loses and regains focus never receives its stale paste")
        let currentPaneURL = try path(from: currentPane!)
        try checkImage(currentPaneURL)
        LocalClipboardImageStore.discard(currentPaneURL)
        try waitClipboard("cancelled pane paste left a private batch") { (try? batches()) == beforeFocus }

        var staleWindow = false
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in staleWindow = true }), "image starts before window loses key status")
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        var currentWindow: String?
        try check(session.terminalHandleUserPaste(pasteboard, paste: { currentWindow = $0 }), "a fresh paste starts after the window returns")
        try waitClipboard("new window paste did not complete") { currentWindow != nil }
        pumpClipboard(0.3)
        try check(!staleWindow, "window focus loss cancels stale image paste even if focus returns")
        let currentWindowURL = try path(from: currentWindow!)
        try checkImage(currentWindowURL)
        LocalClipboardImageStore.discard(currentWindowURL)
        try waitClipboard("cancelled window paste left a private batch") { (try? batches()) == beforeFocus }

        var staleHidden = false
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in staleHidden = true }), "image starts before parking the surface")
        surface.setSurfaceVisible(false)
        surface.setSurfaceVisible(true)
        window.makeFirstResponder(surface)
        var currentVisible: String?
        try check(session.terminalHandleUserPaste(pasteboard, paste: { currentVisible = $0 }), "a fresh paste starts after the surface is remounted")
        try waitClipboard("remounted surface paste did not complete") { currentVisible != nil }
        pumpClipboard(0.3)
        try check(!staleHidden, "a parked surface never receives its stale paste")
        let currentVisibleURL = try path(from: currentVisible!)
        try checkImage(currentVisibleURL)
        LocalClipboardImageStore.discard(currentVisibleURL)
        try waitClipboard("cancelled hidden paste left a private batch") { (try? batches()) == beforeFocus }

        var afterClose = false
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in afterClose = true }), "image starts before terminal close")
        session.terminate()
        try waitClipboard("terminal did not finish closing") { session.hasExited }
        pumpClipboard(0.3)
        try check(!afterClose, "terminal close cancels clipboard paste")
        try waitClipboard("closed terminal paste left a private batch") { (try? batches()) == beforeFocus }
        print("Local clipboard \(backend): \(checks) checks passed")
    }
}
