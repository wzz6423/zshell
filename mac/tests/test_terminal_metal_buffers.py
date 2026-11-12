"""Compile the production renderer and pause real Metal reads between frames."""

from pathlib import Path
import platform
import re
import subprocess
import tempfile

from swift_test_source import extract_enum


ROOT = Path(__file__).resolve().parents[2]
ALACRITTY = ROOT / "mac/zshell/Alacritty"


def check_cursor_blink_timer():
    """A blink must schedule a frame without forcing every row to rebuild."""
    view = (ALACRITTY / "AlacrittyTerminalView.swift").read_text()
    start = view.index("    private func updateCursorTimer()")
    timer = view[start:view.index("    private func resetCursorBlink()", start)]
    if re.search(r"scheduleRender\s*\(\s*force:\s*true", timer, re.S):
        raise SystemExit("updateCursorTimer still schedules a full redraw")
    if "cursorBlinkNeedsFrame = true" not in timer or "scheduleRender" not in timer:
        raise SystemExit("updateCursorTimer no longer schedules a cursor-only frame")
    render_start = view.index("        var damage = ZshellDamage()")
    decision = view[render_start:view.index("        let consumesUnconditionalRedraw", render_start)]
    for snippet in (
        "terminalFrameRowDecision(",
        "cursorBlinkNeedsFrame",
        "guard decision.presents",
        "decision.dirtyRows",
    ):
        if snippet not in decision:
            raise SystemExit(f"renderFrame lost the cursor-only row decision: {snippet}")
    print("PASS: updateCursorTimer schedules a cursor-only frame")


check_cursor_blink_timer()

with tempfile.TemporaryDirectory(prefix="zshell-metal-buffers-") as directory:
    temporary = Path(directory)
    renderer = temporary / "TerminalMetalRenderer.swift"
    renderer.write_text((ALACRITTY / renderer.name).read_text() + """
extension TerminalMetalRenderer {
    func testUploadOrigins(
        _ origins: [Float],
        onAvailable: (@Sendable () -> Void)? = nil
    ) -> TerminalInstanceBufferPool.Lease? {
        instances = origins.map {
            Instance(origin: SIMD2($0, 0), size: SIMD2(1, 1), color: SIMD4(repeating: 1),
                     uvOrigin: .zero, uvSize: .zero, kind: 0)
        }
        return uploadInstances(waitUntilAvailable: false, onAvailable: onAvailable)
    }

    var testQueue: MTLCommandQueue { queue }
    var testInstanceStride: Int { MemoryLayout<Instance>.stride }

    func testPreparedColors(
        snapshot: ZshellSnapshot,
        metrics: AlacrittyMetrics,
        dirtyRows: [Int]?
    ) -> (glyphs: Int, colors: [SIMD4<Float>]) {
        precondition(prepare(
            snapshot: snapshot, markedText: nil, metrics: metrics,
            padding: .zero, scale: 1, paddingColor: .extend,
            dirtyRows: dirtyRows, viewportSize: CGSize(width: 64, height: 64)
        ))
        return (instances.filter { $0.kind == 1 }.count, instances.map(\\.color))
    }

    func testFrameColors(
        snapshot: ZshellSnapshot,
        metrics: AlacrittyMetrics,
        dirtyRows: [Int]?
    ) -> (glyphs: [SIMD4<Float>], solids: [SIMD4<Float>]) {
        precondition(prepare(
            snapshot: snapshot, markedText: nil, metrics: metrics,
            padding: .zero, scale: 1, paddingColor: .extend,
            dirtyRows: dirtyRows, viewportSize: CGSize(width: 64, height: 64)
        ), "prepare failed")
        return (
            instances.filter { $0.kind == 1 }.map { $0.color },
            instances.filter { $0.kind == 0 }.map { $0.color }
        )
    }
}

func cursorBlinkPreservesCachedRows() {
    func rgba(_ packed: UInt32) -> SIMD4<Float> {
        SIMD4(
            Float((packed >> 16) & 0xff) / 255,
            Float((packed >> 8) & 0xff) / 255,
            Float(packed & 0xff) / 255,
            1
        )
    }

    let cursorOnly = terminalFrameRowDecision(
        needsUnconditionalRedraw: false,
        damageKind: ZSHELL_DAMAGE_NONE,
        partialRows: nil,
        presentWithoutDamage: true
    )
    precondition(cursorOnly.presents && cursorOnly.dirtyRows == .some([Int]()),
                 "cursor-only frame must present with no dirty rows")
    let forced = terminalFrameRowDecision(
        needsUnconditionalRedraw: true,
        damageKind: ZSHELL_DAMAGE_NONE,
        partialRows: nil,
        presentWithoutDamage: true
    )
    precondition(forced.presents && forced.dirtyRows == nil,
                 "an unconditional redraw must rebuild the grid")
    let partial = terminalFrameRowDecision(
        needsUnconditionalRedraw: false,
        damageKind: ZSHELL_DAMAGE_PARTIAL,
        partialRows: [3, 4],
        presentWithoutDamage: true
    )
    precondition(partial.presents && partial.dirtyRows == .some([3, 4]),
                 "emulator damage must win over a cursor blink")
    let full = terminalFrameRowDecision(
        needsUnconditionalRedraw: false,
        damageKind: ZSHELL_DAMAGE_FULL,
        partialRows: [0],
        presentWithoutDamage: true
    )
    precondition(full.presents && full.dirtyRows == nil,
                 "full damage must win over a cursor blink")
    let idle = terminalFrameRowDecision(
        needsUnconditionalRedraw: false,
        damageKind: ZSHELL_DAMAGE_NONE,
        partialRows: nil,
        presentWithoutDamage: false
    )
    precondition(!idle.presents, "a frame with no host or emulator damage must be skipped")

    let device = MTLCreateSystemDefaultDevice()!
    let renderer = TerminalMetalRenderer(device: device)!
    renderer.setMinimumContrast(1)
    let metrics = AlacrittyMetrics(
        family: "", fallbackFamily: "", size: 13, fontThicken: false,
        fontThickenStrength: 0, lineHeight: 1, cellWidth: 8
    )
    let oldTop = rgba(0x112233)
    let oldBottom = rgba(0x445566)
    let newTop = rgba(0xaabbcc)
    let newBottom = rgba(0xddeeff)
    let cursor = rgba(0x00ff00)
    var cells = [ZshellCell(), ZshellCell()]
    cells[0].ch = UInt32(UInt8(ascii: "M"))
    cells[1].ch = UInt32(UInt8(ascii: "M"))
    cells[0].fg = 0x112233
    cells[1].fg = 0x445566
    cells[0].bg = 0x010101
    cells[1].bg = 0x010101
    var snapshot = ZshellSnapshot()
    snapshot.columns = 1
    snapshot.rows = 2
    snapshot.background = 0x010101
    snapshot.cursor_shape = 0
    snapshot.cursor_color = 0x00ff00
    snapshot.cursor_line = -1
    snapshot.cursor_column = -1
    cells.withUnsafeMutableBufferPointer { buffer in
        snapshot.cells = buffer.baseAddress.map { UnsafePointer($0) }
        let cached = renderer.testFrameColors(
            snapshot: snapshot, metrics: metrics, dirtyRows: nil
        )
        precondition(cached.glyphs.count >= 2, "warmup frame produced no glyph rows")
        precondition(cached.glyphs.contains(oldTop) && cached.glyphs.contains(oldBottom),
                     "warmup glyphs were not the cached row colors: \\(cached.glyphs)")
        precondition(!cached.solids.contains(cursor), "warmup frame drew a cursor")

        snapshot.cursor_line = 0
        snapshot.cursor_column = 0
        let reused = renderer.testFrameColors(
            snapshot: snapshot, metrics: metrics, dirtyRows: cursorOnly.dirtyRows
        )
        precondition(reused.glyphs == cached.glyphs,
                     "cursor-only frame rebuilt cached glyph rows: \\(cached.glyphs) -> \\(reused.glyphs)")
        precondition(reused.solids.contains(cursor),
                     "cursor-only frame did not append the cursor")

        buffer[0].fg = 0xaabbcc
        buffer[1].fg = 0xddeeff
        snapshot.cursor_line = -1
        snapshot.cursor_column = -1
        let rebuilt = renderer.testFrameColors(
            snapshot: snapshot, metrics: metrics, dirtyRows: forced.dirtyRows
        )
        precondition(rebuilt.glyphs.contains(newTop) && rebuilt.glyphs.contains(newBottom),
                     "forced frame kept stale glyph rows: \\(rebuilt.glyphs)")
        precondition(!rebuilt.glyphs.contains(oldTop) && !rebuilt.glyphs.contains(oldBottom),
                     "forced frame did not rebuild every cached glyph row")
    }
    print("PASS: cursor blink reuses cached glyph rows and a forced frame rebuilds them")
}
""")

    # Keep production metrics and color resolution; theme selection is outside
    # this fixture, which only uses unselected cells and solid cursor instances.
    source = (ALACRITTY / "AlacrittyRenderer.swift").read_text()
    metrics = source[:source.index("/// Draws one snapshot of the grid with CoreText.")]
    colors = source[source.index("    // MARK: - Colors"):]
    selection_start = colors.index("    static func selectionColors()")
    selection_end = colors.index("    final class ContrastCache", selection_start)
    colors = (colors[:selection_start] + """
    static func selectionColors() -> (foreground: UInt32, background: UInt32) {
        preconditionFailure("Selection colors are outside this buffer fixture")
    }

""" + colors[selection_end:])
    models = temporary / "RendererModels.swift"
    settings = (ROOT / "mac/zshell/AppSettings.swift").read_text()
    models.write_text(metrics.replace("import GhosttyTheme\n", "")
                      + extract_enum(settings, "TerminalPaddingColor")
                      + "struct AlacrittyRenderer {\n" + colors)

    font_source = (ROOT / "mac/zshell/TerminalFont.swift").read_text()
    font_start = font_source.index("    /// The terminal font for the current settings")
    font_end = font_source.index("    /// Resolves a family name", font_start)
    font = temporary / "TerminalFont.swift"
    font.write_text(font_source[:font_start] + font_source[font_end:])

    harness = (ROOT / "mac/tests/TerminalMetalBufferTests.swift").read_text()
    marker = '        print("Metal buffer ownership tests passed (real GPU, upload/render/growth/reuse/lifecycle)")'
    if marker not in harness:
        raise SystemExit("metal buffer test entry point moved")
    tests = temporary / "TerminalMetalBufferTests.swift"
    tests.write_text(harness.replace(
        marker, "        cursorBlinkPreservesCachedRows()\n" + marker, 1
    ))

    binary = temporary / "metal-buffer-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-strict-concurrency=complete",
        "-warnings-as-errors", "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "modules"),
        "-import-objc-header", str(ROOT / "mac/Vendor/alacritty-bridge/include/zshell_alacritty.h"),
        str(ALACRITTY / "TerminalInstanceBufferPool.swift"),
        str(ALACRITTY / "TerminalGlyphAtlas.swift"),
        str(ALACRITTY / "TerminalTextShaper.swift"),
        str(ROOT / "mac/zshell/TerminalFontFeatures.swift"),
        str(ALACRITTY / "AlacrittyKittyGraphics.swift"),
        str(ROOT / "mac/zshell/TerminalContrast.swift"),
        str(font), str(models), str(renderer),
        str(tests),
        "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=45)
