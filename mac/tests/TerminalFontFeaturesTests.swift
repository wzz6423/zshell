import AppKit
import Combine
import CoreText
import Metal
import QuartzCore
import IOSurface
import GhosttyTerminal
import GhosttyKit
@testable import zshell

@MainActor private final class FontProbeWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor private func pump(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    print("PASS: \(label)")
}

private func mirrored<T>(_ value: Any, _ name: String, as type: T.Type = T.self) -> T? {
    for child in Mirror(reflecting: value).children where child.label == name { return child.value as? T }
    if let parent = Mirror(reflecting: value).superclassMirror {
        for child in parent.children where child.label == name { return child.value as? T }
    }
    return nil
}

private struct Grid {
    var cells: [ZshellCell]
    var text: [UInt8]
    let columns: Int
    let rows: Int

    init(_ strings: [String]) {
        var contents: [[ZshellCell]] = []
        var backing: [UInt8] = []
        for string in strings {
            var row: [ZshellCell] = []
            for character in string {
                var cell = ZshellCell()
                let scalars = Array(character.unicodeScalars)
                cell.ch = scalars[0].value
                cell.fg = 0xffffff
                cell.bg = 0x080a0c
                if scalars.count > 1 {
                    cell.text_offset = UInt32(backing.count)
                    cell.text_len = UInt16(String(character).utf8.count)
                    backing += String(character).utf8
                }
                let wide = scalars[0].value >= 0x2e80 && scalars[0].value != 0xe0a0
                if wide { cell.flags |= UInt16(ZSHELL_CELL_WIDE) }
                row.append(cell)
                if wide {
                    var spacer = ZshellCell()
                    spacer.ch = 32
                    spacer.fg = cell.fg
                    spacer.bg = cell.bg
                    spacer.flags = UInt16(ZSHELL_CELL_WIDE_SPACER)
                    row.append(spacer)
                }
            }
            contents.append(row)
        }
        let columnCount = contents.map(\.count).max()!
        columns = columnCount
        rows = strings.count
        let blank: ZshellCell = { var c = ZshellCell(); c.ch = 32; c.fg = 0xffffff; c.bg = 0x080a0c; return c }()
        cells = contents.flatMap { $0 + Array(repeating: blank, count: columnCount - $0.count) }
        text = backing
    }

    func snapshot<T>(cursor: Int = -1, _ body: (ZshellSnapshot) -> T) -> T {
        cells.withUnsafeBufferPointer { cells in
            text.withUnsafeBufferPointer { text in
                var snapshot = ZshellSnapshot()
                snapshot.columns = columns
                snapshot.rows = rows
                snapshot.background = 0x080a0c
                snapshot.cells = cells.baseAddress
                snapshot.text = text.baseAddress
                snapshot.text_len = text.count
                snapshot.cursor_line = cursor >= 0 ? 0 : -1
                snapshot.cursor_column = cursor
                snapshot.cursor_shape = 0
                snapshot.cursor_color = 0x55cc99
                return body(snapshot)
            }
        }
    }
}

@MainActor private func metrics(_ features: String = "", ligatures: Bool = true, size: CGFloat = 13) -> AlacrittyMetrics {
    AlacrittyMetrics(family: "", fallbackFamily: "", size: size, fontThicken: false, fontThickenStrength: 255,
                     lineHeight: 1, fontFeatures: TerminalFontFeatures(features, ligatures: ligatures))
}

@MainActor private func metal(_ grid: Grid, metrics: AlacrittyMetrics, renderer: TerminalMetalRenderer,
                              cursor: Int = -1, dirtyRows: [Int]? = nil, markedText: TerminalMarkedText? = nil) -> [UInt8] {
    let size = CGSize(width: CGFloat(grid.columns) * metrics.cellWidth + 20,
                      height: CGFloat(grid.rows) * metrics.cellHeight + 16)
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()!
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.drawableSize = CGSize(width: size.width * 2, height: size.height * 2)
    let drawable = layer.nextDrawable()!
    let texture = drawable.texture
    grid.snapshot(cursor: cursor) { snapshot in
        check(renderer.render(snapshot: snapshot, markedText: markedText, kittyPlacements: [], metrics: metrics,
                              padding: CGPoint(x: 10, y: 8), scale: 2, backgroundOpacity: 1, dirtyRows: dirtyRows,
                              in: drawable, viewportSize: size, waitUntilCompleted: true), "Metal frame submitted")
    }
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                     from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return pixels
}

@MainActor private func shapingAndMetal() {
    let device = MTLCreateSystemDefaultDevice()!
    let renderer = TerminalMetalRenderer(device: device)!
    let grid = Grid(["-> != === => 0", "e\u{301} e\u{20d7} 中文 😀 \u{e0a0}"])
    let first = metal(grid, metrics: metrics(), renderer: renderer)
    let shaper: TerminalTextShaper = mirrored(renderer, "textShaper")!
    let count: Int = mirrored(shaper, "shapedRunCount")!
    let noLigatures = metal(grid, metrics: metrics(ligatures: false), renderer: renderer)
    check(first != noLigatures, "Alacritty real raster changes when ligatures are disabled")
    let alt = metal(grid, metrics: metrics("zero=1"), renderer: renderer)
    check(first != alt, "Alacritty zero feature changes real raster")
    let initialMetrics = metrics()
    let restored = metal(grid, metrics: initialMetrics, renderer: renderer)
    check(restored == first, "font feature reset restores exact raster")
    let pixelWidth = Int((CGFloat(grid.columns) * initialMetrics.cellWidth + 20) * 2)
    func changedColumns(_ a: [UInt8], _ b: [UInt8]) -> Set<Int> {
        Set(zip(a, b).enumerated().compactMap { index, pair in
            guard pair.0 != pair.1 else { return nil }
            let x = index / 4 % pixelWidth
            // Edge cell backgrounds intentionally extend into terminal padding.
            return max(0, Int(floor((CGFloat(x) / 2 - 10) / initialMetrics.cellWidth)))
        })
    }
    let stableCount: Int = mirrored(shaper, "shapedRunCount")!
    var selected = grid
    selected.cells[0].flags |= UInt16(ZSHELL_CELL_SELECTED)
    let selection = metal(selected, metrics: initialMetrics, renderer: renderer)
    check(selection != first, "selection paints a ligature fragment")
    check(changedColumns(selection, first) == [0], "selection changes only its original VT column")
    check(mirrored(shaper, "shapedRunCount", as: Int.self) == stableCount, "selection reuses shaped rows")
    let block = metal(selected, metrics: initialMetrics, renderer: renderer, cursor: 1)
    check(block != selection, "block cursor inverts its ligature fragment")
    check(changedColumns(block, selection) == [1], "block cursor changes only its original VT column")
    check(mirrored(shaper, "shapedRunCount", as: Int.self) == stableCount, "cursor reuses shaped rows")
    let stable = metal(grid, metrics: initialMetrics, renderer: renderer, dirtyRows: [])
    check(mirrored(shaper, "shapedRunCount", as: Int.self) == stableCount, "clean rows skip shaping")
    _ = metal(grid, metrics: initialMetrics, renderer: renderer)
    var changed = grid
    changed.cells[grid.columns].ch = 65
    let partial = metal(changed, metrics: initialMetrics, renderer: renderer, dirtyRows: [1])
    let fresh = metal(changed, metrics: initialMetrics, renderer: TerminalMetalRenderer(device: device)!)
    check(partial == fresh, "dirty row update equals a fresh render")
    let atlas: TerminalGlyphAtlas = mirrored(renderer, "atlas")!
    check(atlas.beginRebuild(), "atlas rebuild allocates")
    let rebuilt = metal(changed, metrics: initialMetrics, renderer: renderer)
    atlas.finishRebuild(visibleGlyphArea: 1)
    check(rebuilt == fresh, "atlas rebuild preserves glyph coverage")
    let beforeIME: Int = mirrored(shaper, "shapedRunCount")!
    let ime = metal(changed, metrics: initialMetrics, renderer: renderer, dirtyRows: [],
                    markedText: TerminalMarkedText(text: "中文😀", line: 0, column: 0))
    check(ime != rebuilt && mirrored(shaper, "shapedRunCount", as: Int.self) == beforeIME, "IME overlay preserves shaping cache")
    let wide = Grid(["e\u{20d7}中😀->X"])
    let wideShaper = TerminalTextShaper()
    let m = metrics()
    wideShaper.reset(metrics: m, rowCount: 1)
    wide.snapshot { snapshot in
        let glyphs = wideShaper.glyphs(row: 0, snapshot: snapshot, metrics: m)
        check(glyphs.contains { $0.columns == 1..<3 }, "CJK stays two columns")
        check(glyphs.contains { $0.columns == 3..<5 }, "emoji stays two columns")
        check(glyphs.filter { $0.columns == 0..<1 }.count >= 1, "combining marks share their base cell")
        check(glyphs.contains { $0.columns == 5..<7 }, "ligature after Unicode uses correct columns")
    }
    for flags in [UInt16(ZSHELL_CELL_BOLD), UInt16(ZSHELL_CELL_ITALIC), UInt16(ZSHELL_CELL_BOLD | ZSHELL_CELL_ITALIC)] {
        var styled = Grid(["->!="])
        for i in styled.cells.indices { styled.cells[i].flags |= flags }
        let a = metal(styled, metrics: m, renderer: TerminalMetalRenderer(device: device)!)
        let b = metal(styled, metrics: metrics(ligatures: false), renderer: TerminalMetalRenderer(device: device)!)
        check(a != b, "styled font ligatures respond to toggle \(flags)")
    }
    for size in [CGFloat(8), 13, 24, 32] {
        let sized = metrics(size: size)
        _ = metal(grid, metrics: sized, renderer: renderer)
        let alignment = TerminalTextShaper()
        let spaced = Grid(["A -> X"])
        alignment.reset(metrics: sized, rowCount: 1)
        spaced.snapshot { snapshot in
            let glyphs = alignment.glyphs(row: 0, snapshot: snapshot, metrics: sized)
            let first = glyphs.first { $0.columns == 0..<1 }!
            let last = glyphs.first { $0.columns == 5..<6 }!
            check(abs(last.position.x - first.position.x - 5 * sized.cellWidth) < 0.001,
                  "font size \(size) keeps glyphs on the VT grid")
            check(glyphs.contains { $0.columns == 2..<4 },
                  "font size \(size) retains ligature cell coverage")
        }
    }
    for ligatures in [true, false] {
        let shaped = TerminalTextShaper()
        let arabic = Grid(["لا"])
        let arabicMetrics = metrics(ligatures: ligatures)
        shaped.reset(metrics: arabicMetrics, rowCount: 1)
        arabic.snapshot { snapshot in
            let glyphs = shaped.glyphs(row: 0, snapshot: snapshot, metrics: arabicMetrics)
            check(glyphs.count == 1 && glyphs[0].columns == 0..<2,
                  "required Arabic lam-alef joining survives ligature toggle \(ligatures)")
        }
    }
    print("SHAPE: initial runs=\(count) beforeIME=\(beforeIME) stable raster bytes=\(stable.count)")
}

@main struct TerminalFontFeaturesTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        check(AppSettings.configURL.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              "settings use the temporary home")
        TerminalFont.registerBundledFonts()
        let settings = AppSettings.shared
        settings.resetToDefaults()
        check(settings.fontLigatures && settings.fontFeatures.isEmpty && settings.isAtDefaults, "feature defaults/reset")
        check(TerminalFontFeatures.parse("-calt, ss01 zero=1 +liga cv01=2")?.count == 5, "feature grammar")
        check(TerminalFontFeatures.parse("liga,-liga,liga=2") == [.init(tag: "liga", value: 2)], "later duplicate wins")
        for bad in ["abc", "abcde", "zero=-1", "liga=", "=1", "-liga=1", "liga=4294967296", "liga\nfont-size=99", String(repeating: "x", count: 4097)] {
            check(TerminalFontFeatures.parse(bad) == nil, "invalid feature value rejected: \(bad.prefix(22))")
        }
        settings.applyImported(["terminal.font-features": .string("-calt, ss01"), "terminal.font-ligatures": .bool(false)])
        check(settings.fontFeatures == "-calt, ss01" && !settings.fontLigatures, "config reload applies feature values")
        settings.applyImported(["terminal.font-features": .string("bad")])
        check(settings.fontFeatures.isEmpty && settings.fontLigatures, "invalid config uses safe feature defaults")
        settings.fontLigatures = false
        settings.fontFeatures = "ss01, zero=1"
        check(settings.serializedConfig().contains("terminal.font-ligatures = false") && settings.serializedConfig().contains("terminal.font-features = \"ss01, zero=1\""), "feature persistence serialization")
        check(!settings.isAtDefaults, "default detection includes features")
        settings.fontLigatures = true
        settings.fontFeatures = ""
        let language = settings.language
        let panes = AppLanguage.allCases.filter { $0 != .system }.map { choice -> SettingsAppearancePane in
            settings.language = choice
            let pane = SettingsAppearancePane()
            let window = FontProbeWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            window.contentView?.layoutSubtreeIfNeeded()
            let field: NSTextField = mirrored(pane, "featuresField")!
            let toggle: NSSwitch = mirrored(pane, "ligaturesSwitch")!
            var ancestor = field.superview
            while ancestor != nil && !(ancestor is SettingsRow) { ancestor = ancestor?.superview }
            let row = ancestor as! SettingsRow
            let description: NSTextField = mirrored(row, "descriptionLabel")!
            let validDescription = description.stringValue
            check(field.bounds.width == 200 && !field.hasAmbiguousLayout && !toggle.hasAmbiguousLayout, "\(choice.rawValue) native feature control layout")
            check(pane.revealSearchResult(String(localized: "OpenType features"), in: String(localized: "Font")), "\(choice.rawValue) feature search reveals row")
            if choice == .arabic {
                let paragraph = NSMutableParagraphStyle()
                paragraph.baseWritingDirection = .rightToLeft
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: validDescription,
                    attributes: [.font: description.font!, .paragraphStyle: paragraph]
                ))
                let tag = (validDescription as NSString).range(of: "-calt")
                var positions: [Int: CGFloat] = [:]
                for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                    let count = CTRunGetGlyphCount(run)
                    var indices = [CFIndex](repeating: 0, count: count)
                    var points = [CGPoint](repeating: .zero, count: count)
                    CTRunGetStringIndices(run, CFRange(), &indices)
                    CTRunGetPositions(run, CFRange(), &points)
                    for (index, point) in zip(indices, points) { positions[index] = point.x }
                }
                let example = (tag.location..<NSMaxRange(tag)).map { positions[$0]! }
                check(zip(example, example.dropFirst()).allSatisfy { $0 < $1 },
                      "Arabic explanation displays the minus before its feature tag")
            }
            field.stringValue = "ss01, zero=1"
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            check(settings.fontFeatures == "ss01, zero=1", "\(choice.rawValue) native feature field writes settings")
            field.stringValue = "bad"
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            check(settings.fontFeatures == "ss01, zero=1", "\(choice.rawValue) invalid input retains previous settings")
            check(window.makeFirstResponder(field), "\(choice.rawValue) native feature editor takes focus")
            let editor = field.currentEditor() as! NSTextView
            editor.string = "bad"
            editor.didChangeText()
            check(field.stringValue == "bad" && description.stringValue != validDescription,
                  "\(choice.rawValue) invalid editing shows validation feedback")
            check(window.makeFirstResponder(nil), "\(choice.rawValue) native feature editor leaves focus")
            check(field.stringValue == settings.fontFeatures && description.stringValue == validDescription,
                  "\(choice.rawValue) native blur restores persisted features and description")
            toggle.state = .off
            toggle.sendAction(toggle.action, to: toggle.target)
            check(!settings.fontLigatures, "\(choice.rawValue) native ligature switch writes settings")
            settings.resetFont()
            pane.syncFromSettings()
            check(field.stringValue.isEmpty && toggle.state == .on, "\(choice.rawValue) native controls follow reset")
            window.contentViewController = nil
            window.close()
            return pane
        }
        check(panes.count == 17, "all native control localizations exercised")
        settings.language = language
        if backend == "alacritty" { shapingAndMetal() }
        let script = root.appendingPathComponent("terminal.py")
        try """
        import os
        os.write(1, '\\033[2J\\033[H-> != === => 0\\r\\n\\033[1m-> !=\\033[0m \\033[3m-> !=\\033[0m \\033[1;3m-> !=\\033[0m\\r\\né e⃗ 中文 😀 \\ue0a0\\r\\n\\033[?25l'.encode())
        while True:
            data = os.read(0, 1024)
            if not data: break
        """.write(to: script, atomically: true, encoding: .utf8)
        let launch = TerminalLaunch(program: "/usr/bin/python3", arguments: [script.path], commandLine: "/usr/bin/python3 '" + script.path + "'", interactiveShell: nil,
                                    workingDirectory: root.path, environment: ["TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"])
        let view: any TerminalBackendSurface = backend == "ghostty"
            ? ZshellTerminalView(launch: launch) : AlacrittyTerminalView(launch: launch)
        let window = FontProbeWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        defer {
            view.setSurfaceVisible(false)
            view.detach()
            window.contentView = nil
            window.close()
        }
        pump(1.5)
        func visible() -> String { view.readVisibleText(maxLines: 100, maxColumns: 1000) ?? "" }
        check(visible().contains("-> != === => 0") && visible().contains("中文"), "\(backend) real PTY Unicode text")
        let text = visible()
        func pixels() -> [UInt8]? {
            pump(0.15)
            func surface(in layer: CALayer) -> IOSurface? {
                if let content = layer.contents, CFGetTypeID(content as CFTypeRef) == IOSurfaceGetTypeID() {
                    return (content as! IOSurface)
                }
                for child in layer.sublayers ?? [] { if let result = surface(in: child) { return result } }
                return nil
            }
            let frame: IOSurface?
            if let alacritty = view as? AlacrittyTerminalView { frame = mirrored(alacritty, "lastPresentedSurface", as: IOSurface.self) }
            else { frame = view.layer.flatMap(surface) }
            guard let frame else { return nil }
            let width = IOSurfaceGetWidth(frame)
            let height = IOSurfaceGetHeight(frame)
            let device = MTLCreateSystemDefaultDevice()!
            // Metal converts the drawable's tiled/compressed IOSurface storage
            // to linear BGRA; reading its raw base address does not.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: frame, plane: 0) else { return nil }
            let rowBytes = width * 4
            let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
            let commands = device.makeCommandQueue()!.makeCommandBuffer()!
            let blit = commands.makeBlitCommandEncoder()!
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0,
                destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            check(commands.status == .completed, "\(backend) IOSurface GPU readback completed")
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
        }
        guard let initialPixels = pixels() else { preconditionFailure("Missing terminal raster") }
        print("SURFACE: \(backend) bitmapBytes=\(initialPixels.count)")
        for (features, ligatures) in [("", false), ("zero=1, ss01", true), ("-calt", true), ("", true)] {
            settings.fontFeatures = features
            settings.fontLigatures = ligatures
            view.applyAppearance()
            pump(0.5)
            check(visible() == text, "\(backend) live feature change keeps original text and columns")
            guard let current = pixels() else { preconditionFailure("Missing updated terminal raster") }
            if features.isEmpty && ligatures {
                check(current == initialPixels, "\(backend) live reset restores exact raster")
            } else {
                check(current != initialPixels, "\(backend) live feature changes IOSurface raster")
            }
        }
        view.setSurfaceVisible(false)
        pump(0.2)
        view.setSurfaceVisible(true)
        pump(0.4)
        check(visible() == text, "\(backend) park/unpark retains PTY text")
        view.beginFind("===")
        pump(0.3)
        view.endFind()
        check(visible() == text, "\(backend) search leaves shaped text intact")
        print("Font feature production probes passed for \(backend)")
        if CommandLine.arguments.contains("--hold") {
            settings.language = .english
            settings.fontSize = 20
            view.applyAppearance()
            let appearance = Publishers.CombineLatest3(
                settings.$fontFeatures.removeDuplicates(), settings.$fontLigatures.removeDuplicates(),
                settings.$fontSize.removeDuplicates()
            )
                .receive(on: DispatchQueue.main)
                .sink { _ in view.applyAppearance() }
            let pane = SettingsAppearancePane()
            pane.setCategory(.appearance)
            let preferences = NSWindow(
                contentRect: CGRect(x: 700, y: 150, width: 660, height: 600),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            preferences.isReleasedWhenClosed = false
            preferences.title = "Font feature settings"
            preferences.contentViewController = pane
            NSApplication.shared.setActivationPolicy(.regular)
            window.title = "Font features: \(backend)"
            window.setContentSize(NSSize(width: 620, height: 220))
            window.setFrameOrigin(NSPoint(x: 40, y: 400))
            window.orderFront(nil)
            preferences.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            pump(0.2)
            check(pane.revealSearchResult(String(localized: "OpenType features"), in: String(localized: "Font")),
                  "visible settings reveal font feature controls")
            print("HOLD: close Font feature settings to finish \(backend) GUI acceptance")
            while preferences.isVisible { pump(0.1) }
            appearance.cancel()
            preferences.contentViewController = nil
            preferences.close()
        }
    }
}
