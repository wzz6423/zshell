import AppKit
import Darwin
import IOSurface
import Metal
@testable import zshell

@MainActor private final class ContrastTestApplication: NSApplication {
    var inputEvent: NSEvent?
    override var currentEvent: NSEvent? { inputEvent ?? super.currentEvent }
}

@MainActor private final class ContrastTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private struct ContrastPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func crop(_ rect: CGRect, bounds: CGRect) -> [UInt8] {
        let scaleX = CGFloat(width) / bounds.width
        let scaleY = CGFloat(height) / bounds.height
        let left = max(0, Int((rect.minX * scaleX).rounded(.down)))
        let right = min(width, Int((rect.maxX * scaleX).rounded(.up)))
        let top = max(0, Int((rect.minY * scaleY).rounded(.down)))
        let bottom = min(height, Int((rect.maxY * scaleY).rounded(.up)))
        guard right > left, bottom > top else { return [] }
        return (top..<bottom).flatMap { y in
            Array(bytes[((y * width + left) * 4)..<((y * width + right) * 4)])
        }
    }
}

@main struct TerminalMinimumContrastSurfaceTests {
    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        MainActor.assumeIsolated {
            do { try run() }
            catch { fputs("FAIL minimum contrast: \(error)\n", stderr); exit(1) }
        }
    }

    @MainActor private static func pump(_ duration: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw NSError(domain: "TerminalMinimumContrast", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        print("PASS: \(label)")
    }

    @MainActor private static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            pump(0.02)
        }
        throw NSError(domain: "TerminalMinimumContrast", code: 2, userInfo: [NSLocalizedDescriptionKey: label])
    }

    @MainActor private static func pixels(_ surface: any TerminalBackendSurface) throws -> ContrastPixels {
        func layerSurface(_ layer: CALayer?) -> IOSurface? {
            guard let layer else { return nil }
            if let surface = layer.presentation()?.contents as? IOSurface { return surface }
            if let surface = layer.contents as? IOSurface { return surface }
            return layer.sublayers?.compactMap { layerSurface($0) }.max { $0.width < $1.width }
        }
        let mirrorSurface = Mirror(reflecting: surface).children.first { $0.label == "lastPresentedSurface" }?.value as? IOSurface
        guard let frame = mirrorSurface ?? layerSurface(surface.layer), frame.width > 0, frame.height > 0 else {
            throw NSError(domain: "TerminalMinimumContrast", code: 3, userInfo: [NSLocalizedDescriptionKey: "native IOSurface unavailable"])
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = device.makeTexture(descriptor: descriptor, iosurface: frame, plane: 0),
              let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: frame.width * frame.height * 4, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            throw NSError(domain: "TerminalMinimumContrast", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "native IOSurface Metal readback unavailable"])
        }
        let stride = frame.width * 4
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                  sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                  destinationBytesPerImage: stride * frame.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw NSError(domain: "TerminalMinimumContrast", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Metal readback failed"])
        }
        let base = buffer.contents().assumingMemoryBound(to: UInt8.self)
        let bytes = (0..<frame.height).flatMap { y in
            Array(UnsafeBufferPointer(start: base.advanced(by: y * stride), count: frame.width * 4))
        }
        return ContrastPixels(width: frame.width, height: frame.height, bytes: bytes)
    }

    @MainActor private static func region(_ frame: ContrastPixels, surface: any TerminalBackendSurface,
                                          grid: TerminalViewportSnapshot, row: Int, columns: Range<Int>) -> [UInt8] {
        // A balanced half-point origin can overlap the next row after rounding.
        frame.crop(grid.rect(row: row, columns: columns).insetBy(dx: 1, dy: 1), bounds: surface.bounds)
    }

    private static func brightest(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count - 3, by: 4).map { index in
            Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
        }.max() ?? -1
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = ContrastTestApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let backend = CommandLine.arguments[1]
        let settings = AppSettings.shared
        try check(settings.terminalMinimumContrast == 3, "new and existing configs start at compatible 3:1")
        settings.theme = .dark
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.preserveTerminalSessions = true
        settings.restoreTerminalHistory = false
        settings.copyOnSelect = false
        settings.cursorShape = .block
        settings.cursorBlinking = false
        settings.fontFamily = "Menlo"
        settings.fontSize = 18
        settings.terminalStartupProgram = "/usr/bin/python3"
        settings.terminalStartupArguments = TerminalSession.shellQuote(CommandLine.arguments[2])
        settings.terminalMinimumContrast = 1
        TerminalFont.registerBundledFonts()
        defer { shutdownPTYs() }
        try colorResolution()

        let manager = TerminalManager()
        let project = manager.projects[0]
        project.splitRight()
        let sessions = project.sessions
        try check(sessions.count == 2, "\(backend) independent panes exist")
        let windows = sessions.enumerated().map { index, session in
            let frame = NSRect(x: CGFloat(index * 40), y: CGFloat(index * 40), width: 800, height: 600)
            let window = ContrastTestWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.surface
            session.surface.frame = NSRect(origin: .zero, size: frame.size)
            window.makeFirstResponder(session.surface)
            session.surface.setSurfaceVisible(true)
            window.orderFront(nil)
            return window
        }
        defer {
            for session in sessions { session.sendCommand("\u{4}"); session.terminate() }
            pump()
            windows.forEach { $0.contentView = nil; $0.close() }
            manager.close(project)
        }
        do {
            try wait("both native PTYs are ready") {
                sessions.allSatisfy { ($0.surface.readVisibleText(maxLines: 30, maxColumns: 100) ?? "").contains("CONTRAST_READY") && $0.shellPid != nil }
            }
        } catch {
            for session in sessions {
                print("PTY diagnostic: pid=\(String(describing: session.shellPid)), exited=\(session.hasExited), text=\(session.surface.readVisibleText(maxLines: 30, maxColumns: 100) ?? "<unavailable>")")
                if let result = try? PTYMuxCommandLine.exchange(method: "get", params: [
                    "id": .string(session.id.uuidString), "tailBytes": .number(1024)
                ]).result?.objectValue, let encoded = result["tailBase64"]?.stringValue,
                   let data = Data(base64Encoded: encoded) {
                    print("PTY tail: \(String(decoding: data, as: UTF8.self))")
                }
            }
            throw error
        }
        let pids = sessions.map { $0.shellPid! }
        sessions.forEach { $0.sendCommand("r") }
        try wait("fixtures repaint after initial PTY resize") {
            sessions.allSatisfy { $0.surface.readVisibleSnapshot()?.rows[0].text.contains("MMMMMM") == true }
        }
        pump()
        var frames: [[Double: ContrastPixels]] = Array(repeating: [:], count: sessions.count)
        let initialGrids = sessions.map { $0.surface.readVisibleSnapshot()! }
        for ratio in [1.0, 3, 7, 21, 1] {
            settings.terminalMinimumContrast = ratio
            pump()
            for (index, session) in sessions.enumerated() {
                let grid = session.surface.readVisibleSnapshot()!
                try check(grid.columns == initialGrids[index].columns && grid.cellSize == initialGrids[index].cellSize,
                          "\(backend) \(ratio):1 keeps pane \(index) geometry")
                frames[index][ratio] = try pixels(session.surface)
            }
        }
        for (index, session) in sessions.enumerated() {
            let grid = initialGrids[index]
            func row(_ ratio: Double, _ row: Int, columns: Range<Int> = 0..<6) -> [UInt8] {
                region(frames[index][ratio]!, surface: session.surface, grid: grid, row: row, columns: columns)
            }
            try check(brightest(row(1, 0)) == 72, "\(backend) 1:1 renders original 24/24/24 true color")
            try check(brightest(row(3, 0)) > brightest(row(1, 0)) + 120, "\(backend) low contrast brightens in pane \(index)")
            try check(row(1, 1) == row(3, 1) && brightest(row(7, 1)) > brightest(row(3, 1)) + 100,
                      "\(backend) mid contrast preserves 3:1 and improves at 7:1")
            try check(row(1, 2) == row(21, 2), "\(backend) high contrast keeps original ANSI color")
            for flaggedRow in [3, 4, 5, 7] {
                try check(brightest(row(7, flaggedRow)) > brightest(row(1, flaggedRow)) + 100,
                          "\(backend) inverse/bold/dim/Unicode row \(flaggedRow) uses resolved background")
            }
            try check(row(1, 6) == row(21, 6), "\(backend) invisible text remains invisible")
            try check(row(1, 8, columns: 0..<4) == row(21, 8, columns: 0..<4), "\(backend) emoji pixels preserve intrinsic colors")
            let image1 = row(1, 9, columns: 0..<8) + row(1, 10, columns: 0..<8)
            let image21 = row(21, 9, columns: 0..<8) + row(21, 10, columns: 0..<8)
            try check(image1 == image21 && image1.contains(26), "\(backend) Kitty image pixels retain their low-contrast color")
            for paletteRow in [15, 16] {
                try check(brightest(row(3, paletteRow)) > brightest(row(1, paletteRow)) + 200,
                          "\(backend) 16/256-color ANSI row \(paletteRow) improves contrast")
            }
            try check(row(1, 14, columns: 2..<3) == row(3, 14, columns: 2..<3),
                      "\(backend) disabling ANSI adjustment keeps the existing cursor color")
            if backend == "alacritty" {
                try check(row(1, 14, columns: 2..<3) == row(21, 14, columns: 2..<3),
                          "Alacritty keeps its native independent block cursor color")
            } else {
                try check(brightest(row(7, 14, columns: 2..<3)) >= brightest(row(3, 14, columns: 2..<3)),
                          "Ghostty keeps its native readable block cursor policy")
            }
        }
        try check(sessions.map { $0.shellPid! } == pids && pids.allSatisfy { kill($0, 0) == 0 },
                  "\(backend) contrast hot updates keep both original PTYs alive")

        var profile = TerminalProfile(name: "Contrast profile")
        profile.host = "contrast-manual-profile.invalid"
        profile.appearance.fontSize = 20
        profile.appearance.themeDark = "Dracula"
        settings.terminalProfiles = [profile]
        sessions[0].selectTerminalProfile(.profile(profile.id))
        pump()
        sessions[0].sendCommand("r")
        pump()
        let profileGrid = sessions[0].surface.readVisibleSnapshot()!
        let profileOriginal = try pixels(sessions[0].surface)
        settings.terminalMinimumContrast = 7
        pump()
        let profileAdjusted = try pixels(sessions[0].surface)
        try check(brightest(region(profileAdjusted, surface: sessions[0].surface, grid: profileGrid, row: 0, columns: 0..<6))
                  > brightest(region(profileOriginal, surface: sessions[0].surface, grid: profileGrid, row: 0, columns: 0..<6)) + 200,
                  "\(backend) profile appearance uses the global contrast setting")
        try selection(sessions[0].surface)
        try transparent(sessions[1].surface)
        try quickTerminal(settings: settings, backend: backend)
        try configuration(settings: settings, session: sessions[1])
        try switchedBackend(settings: settings, manager: manager, backend: backend)
        try check(sessions.map { $0.shellPid! } == pids && pids.allSatisfy { kill($0, 0) == 0 },
                  "\(backend) reload/reset/backend switch preserve existing PTYs")
        print("Native minimum contrast passed: \(backend), 1/3/7/21, ANSI flags, Unicode, emoji, Kitty, profile, selection, cursor, transparency, Quick Terminal")
    }

    @MainActor private static func shutdownPTYs() {
        if let entries = try? PTYMuxCommandLine.exchange(method: "list").result?.arrayValue {
            for entry in entries {
                if let id = entry.objectValue?["id"]?.stringValue {
                    _ = try? PTYMuxCommandLine.exchange(method: "terminate", params: ["id": .string(id)])
                }
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? PTYMuxCommandLine.exchange(method: "shutdown", timeout: 0.2)) != nil { return }
            pump(0.05)
        }
    }

    @MainActor private static func configuration(settings: AppSettings, session: TerminalSession) throws {
        let surface = session.surface
        let grid = surface.readVisibleSnapshot()!
        func brightness() throws -> Int {
            brightest(region(try pixels(surface), surface: surface, grid: grid, row: 0, columns: 0..<6))
        }
        let exported = settings.serializedConfig()
        var imported = TOML.parseStrictly(text: exported).values
        imported["terminal.minimum-contrast"] = .number(1)
        settings.applyImported(imported)
        pump()
        let original = try brightness()
        try check(original == 72, "import turns off ANSI adjustment on the existing surface")
        var restored = TOML.parseStrictly(text: exported).values
        restored["terminal.minimum-contrast"] = .number(7)
        try SettingsConfigFile.write(settings.serializedConfig().replacingOccurrences(
            of: "terminal.minimum-contrast = 1", with: "terminal.minimum-contrast = 7"), at: AppSettings.configURL)
        try wait("live config reload reaches production settings") { settings.terminalMinimumContrast == 7 }
        pump()
        let reloaded = try brightness()
        try check(reloaded > original + 200, "external reload adjusts native pixels in place")

        settings.resetToDefaults()
        try check(settings.terminalMinimumContrast == 3, "reset restores compatible minimum contrast")
        // Keep the fixture palette/font fixed while verifying reset's contrast effect.
        restored["terminal.minimum-contrast"] = .number(settings.terminalMinimumContrast)
        settings.applyImported(restored)
        pump()
        session.sendCommand("r")
        pump()
        let resetGrid = surface.readVisibleSnapshot()!
        let resetPixels = try pixels(surface)
        try check(brightest(region(resetPixels, surface: surface, grid: resetGrid, row: 0, columns: 0..<6)) > original + 200,
                  "reset 3:1 keeps original process and readable pixels")
    }

    @MainActor private static func switchedBackend(settings: AppSettings, manager: TerminalManager, backend: String) throws {
        settings.terminalBackend = backend == "ghostty" ? .alacritty : .libghostty
        settings.terminalMinimumContrast = 1
        let project = manager.newProject()
        let session = project.sessions[0]
        let surface = session.surface
        let window = ContrastTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        window.orderFront(nil)
        defer {
            session.sendCommand("\u{4}")
            session.terminate()
            window.contentView = nil
            window.close()
            manager.close(project)
        }
        try wait("switched backend starts the production ANSI fixture") {
            surface.readVisibleText(maxLines: 30, maxColumns: 100)?.contains("CONTRAST_READY") == true
        }
        pump()
        session.sendCommand("r")
        pump()
        let pid = session.shellPid
        let grid = surface.readVisibleSnapshot()!
        let original = try pixels(surface)
        settings.terminalMinimumContrast = 7
        pump()
        let adjusted = try pixels(surface)
        try check(session.backend == settings.terminalBackend &&
                  brightest(region(adjusted, surface: surface, grid: grid, row: 0, columns: 0..<6))
                  > brightest(region(original, surface: surface, grid: grid, row: 0, columns: 0..<6)) + 200,
                  "Settings backend switch gives the new terminal live contrast")
        try check(session.shellPid == pid, "switched backend hot update keeps its native PTY")
    }

    @MainActor private static func colorResolution() throws {
        let cache = AlacrittyRenderer.ContrastCache()
        var cell = ZshellCell()
        cell.fg = 0x181818
        cell.bg = 0
        for ratio in [1.0, 3, 7, 21] {
            cache.setMinimumRatio(ratio)
            try check(cache.foreground(of: cell, default: 0x777777) == (ratio == 1 ? 0x181818 : 0xffffff),
                      "production color cache \(ratio):1 uses cell background")
            cell.flags = UInt16(ZSHELL_CELL_BOLD)
            try check(cache.foreground(of: cell, default: 0) == (ratio == 1 ? 0x181818 : 0xffffff), "bold uses the same contrast policy")
            cell.flags = UInt16(ZSHELL_CELL_INVERSE)
            cell.fg = 0
            cell.bg = 0x181818
            try check(cache.foreground(of: cell, default: 0xffffff) == (ratio == 1 ? 0x181818 : 0xffffff), "inverse colors resolve before contrast")
            cell.fg = 0x181818
            cell.bg = 0
            cell.flags = 0
        }
        cache.setMinimumRatio(1)
        cell.flags = UInt16(ZSHELL_CELL_DIM)
        try check(cache.foreground(of: cell, default: 0) == 0x101010, "disabled contrast preserves SGR dim colors")
        cell.flags = UInt16(ZSHELL_CELL_SELECTED)
        let selected = cache.foreground(of: cell, default: 0)
        cache.setMinimumRatio(3)
        try check(cache.foreground(of: cell, default: 0) == selected, "selection retains its existing minimum readability when ANSI adjustment is disabled")
        cell.flags = 0
        cell.fg = 0x777777
        cell.bg = 0x777777
        cache.setMinimumRatio(21)
        try check([UInt32(0), 0xffffff].contains(cache.foreground(of: cell, default: 0)), "unattainable ratio keeps the existing best-readable fallback")
    }

    @MainActor private static func selection(_ surface: any TerminalBackendSurface) throws {
        let grid = surface.readVisibleSnapshot()!
        func event(_ type: NSEvent.EventType, column: CGFloat) -> NSEvent {
            let point = NSPoint(x: grid.origin.x + column * grid.cellSize.width,
                                y: surface.bounds.maxY - grid.origin.y - grid.cellSize.height * 0.5)
            return NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: surface.window!.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let app = NSApp as! ContrastTestApplication
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let pointer = event(type, column: type == .leftMouseDown ? 0.1 : 5.9)
            app.inputEvent = pointer
            switch type {
            case .leftMouseDown: surface.mouseDown(with: pointer)
            case .leftMouseDragged: surface.mouseDragged(with: pointer)
            default: surface.mouseUp(with: pointer)
            }
            app.inputEvent = nil
        }
        try check(surface.hasSelection, "native pointer drag creates an actual selection")
        AppSettings.shared.terminalMinimumContrast = 1
        pump()
        let first = try pixels(surface)
        AppSettings.shared.terminalMinimumContrast = 3
        pump()
        let second = try pixels(surface)
        try check(region(first, surface: surface, grid: grid, row: 0, columns: 0..<6)
                  == region(second, surface: surface, grid: grid, row: 0, columns: 0..<6), "native selection stays readable with ANSI adjustment off")
    }

    @MainActor private static func transparent(_ surface: any TerminalBackendSurface) throws {
        surface.setBackgroundOpacity(0.5)
        AppSettings.shared.terminalMinimumContrast = 1
        pump()
        let grid = surface.readVisibleSnapshot()!
        let first = try pixels(surface)
        AppSettings.shared.terminalMinimumContrast = 7
        pump()
        let second = try pixels(surface)
        try check(brightest(region(second, surface: surface, grid: grid, row: 0, columns: 0..<6))
                  > brightest(region(first, surface: surface, grid: grid, row: 0, columns: 0..<6)) + 200,
                  "transparent terminal adjusts against resolved cell background")
    }

    @MainActor private static func quickTerminal(settings: AppSettings, backend: String) throws {
        settings.terminalMinimumContrast = 1
        settings.quickTerminalMode = .fresh
        settings.quickTerminalOpacity = 0.5
        let overlay = GlobalTerminalOverlay.shared
        overlay.start()
        defer { overlay.stop() }
        overlay.toggle()
        try wait("Quick Terminal fixture ready") {
            overlay.allSessions.first?.surface.readVisibleText(maxLines: 30, maxColumns: 100)?.contains("CONTRAST_READY") == true
        }
        let session = overlay.allSessions[0]
        let pid = session.shellPid
        pump()
        let grid = session.surface.readVisibleSnapshot()!
        let original = try pixels(session.surface)
        settings.terminalMinimumContrast = 7
        pump()
        let adjusted = try pixels(session.surface)
        try check(brightest(region(adjusted, surface: session.surface, grid: grid, row: 0, columns: 0..<6))
                  > brightest(region(original, surface: session.surface, grid: grid, row: 0, columns: 0..<6)) + 200,
                  "\(backend) already-open Quick Terminal changes contrast")
        try check(session.shellPid == pid && session.surface.readVisibleSnapshot()?.columns == grid.columns,
                  "\(backend) Quick Terminal keeps its process and grid")

        overlay.stop()
        settings.quickTerminalMode = .reuse
        settings.terminalMinimumContrast = 1
        overlay.start()
        pump()
        overlay.toggle()
        do {
            try wait("reusable Quick Terminal fixture ready") {
                guard let first = overlay.allSessions.first else { return false }
                first.sendCommand("r")
                return first.surface.readVisibleText(maxLines: 30, maxColumns: 100)?.contains("CONTRAST_READY") == true
            }
        } catch {
            print("QUICK diagnostic: \(overlay.allSessions.count) sessions, mode=\(settings.quickTerminalMode)")
            for item in overlay.allSessions {
                print("QUICK pane: \(item.surface.bounds), pid=\(String(describing: item.shellPid)), exited=\(item.hasExited), text=\(item.surface.readVisibleText(maxLines: 30, maxColumns: 100) ?? "<unavailable>")")
            }
            throw error
        }
        let reusable = overlay.allSessions[0]
        let reusablePID = reusable.shellPid
        pump()
        reusable.surface.setSurfaceVisible(true)
        reusable.sendCommand("r")
        pump()
        let reusableGrid = reusable.surface.readVisibleSnapshot()!
        let parkedOriginal = try pixels(reusable.surface)
        overlay.toggle()
        settings.terminalMinimumContrast = 7
        pump()
        overlay.toggle()
        pump()
        // Offscreen windows cannot resolve a display-centered area on reopening.
        // Restore the same panel geometry without changing the production surface.
        if let panel = reusable.surface.window {
            panel.setContentSize(NSSize(width: 1310, height: 790))
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        reusable.surface.setSurfaceVisible(true)
        reusable.sendCommand("r")
        pump()
        var resumed: ContrastPixels?
        try wait("reopened Quick Terminal has a settled native frame") {
            reusable.surface.setSurfaceVisible(true)
            reusable.surface.window?.contentView?.layoutSubtreeIfNeeded()
            resumed = try? pixels(reusable.surface)
            return resumed != nil
        }
        try check(overlay.allSessions.first?.id == reusable.id && reusable.shellPid == reusablePID,
                  "\(backend) dismissed reusable Quick Terminal keeps its PTY")
        try check(brightest(region(resumed!, surface: reusable.surface, grid: reusableGrid, row: 0, columns: 0..<6))
                  > brightest(region(parkedOriginal, surface: reusable.surface, grid: reusableGrid, row: 0, columns: 0..<6)) + 200,
                  "\(backend) hidden Quick Terminal receives contrast before reopening")
    }
}
