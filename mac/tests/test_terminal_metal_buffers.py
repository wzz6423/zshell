"""Compile the production renderer and pause real Metal reads between frames."""

from pathlib import Path
import platform
import subprocess
import tempfile

from swift_test_source import extract_enum


ROOT = Path(__file__).resolve().parents[2]
ALACRITTY = ROOT / "mac/zshell/Alacritty"

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
}
""")

    # Keep production metrics and color resolution; theme selection is outside
    # this fixture, which only uses unselected cells and solid cursor instances.
    source = (ALACRITTY / "AlacrittyRenderer.swift").read_text()
    metrics = source[:source.index("/// Draws one snapshot of the grid with CoreText.")]
    colors = source[source.index("    // MARK: - Colors"):]
    selection_start = colors.index("    static func selectionColors()")
    selection_end = colors.index("    private static func contrastedColor", selection_start)
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
        str(ROOT / "mac/tests/TerminalMetalBufferTests.swift"),
        "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=45)
