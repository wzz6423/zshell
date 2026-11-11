"""Exercise production glyph paging, row caches and real Metal texture reads."""

from pathlib import Path
import platform
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ALACRITTY = ROOT / "mac/zshell/Alacritty"

ATLAS_PROBES = r'''
extension TerminalGlyphAtlas {
    var testEntryCount: Int { entries.count + glyphEntries.count }
    var testMaximumPages: Int { maximumPages }
    var testTextureBytes: Int { pages.reduce(0) { $0 + $1.texture.width * $1.texture.height * 4 } }
    func testCachedEntry(_ key: Key) -> Entry? { entries[key] }
}
'''

RENDERER_PROBES = r'''
extension TerminalMetalRenderer {
    var testAtlas: TerminalGlyphAtlas { atlas! }
    var testQueue: MTLCommandQueue { queue }
    var testGlyphCount: Int { instances.filter { $0.kind == 1 || $0.kind == 2 }.count }
    var testDrawCount: Int {
        atlas!.pageCount <= Self.texturesPerDraw ? 1 : instanceRanges().count
    }

    private func testUploadInstanceBuffer(to commands: MTLCommandBuffer) -> MTLBuffer {
        return uploadInstances()!
    }

    func testPrepare(
        snapshot: ZshellSnapshot, markedText: TerminalMarkedText?,
        metrics: AlacrittyMetrics, scale: CGFloat, dirtyRows: [Int]?
    ) -> Bool {
        prepare(snapshot: snapshot, markedText: markedText, metrics: metrics,
                padding: CGPoint(x: 4, y: 4), scale: scale, backgroundOpacity: 1,
                dirtyRows: dirtyRows, viewportSize: CGSize(width: 512, height: 512))
    }

    func testRowUVs(_ row: Int) -> [SIMD2<Float>] {
        rowInstances[row].instances.filter { $0.kind == 1 || $0.kind == 2 }.map(\.uvOrigin)
    }

    func testGlyphIsColor(row: Int, column: Int) -> Bool {
        rowInstances[row].instances.filter { $0.kind == 1 || $0.kind == 2 }[column].kind == 2
    }

    // Reference the pre-shaping renderer's per-cell CTLine atlas path. Keep
    // the same Metal pipeline so comparison measures glyph choice/placement.
    func testRenderPerCell(snapshot: ZshellSnapshot, metrics: AlacrittyMetrics, scale: CGFloat,
                           in drawable: CAMetalDrawable, viewportSize: CGSize) {
        let original = instances
        defer { instances = original }
        let legacyAtlas = TerminalGlyphAtlas(device: device, metrics: metrics, scale: scale)!
        instances = []
        for row in 0..<snapshot.rows {
            for column in 0..<snapshot.columns {
                let cell = snapshot.cells![row * snapshot.columns + column]
                let content: TerminalGlyphAtlas.Content = cell.text_len > 0
                    ? .cluster(Data(bytes: snapshot.text!.advanced(by: Int(cell.text_offset)), count: Int(cell.text_len)))
                    : .scalar(cell.ch)
                let key = TerminalGlyphAtlas.Key(content: content,
                    bold: cell.flags & UInt16(ZSHELL_CELL_BOLD) != 0,
                    italic: cell.flags & UInt16(ZSHELL_CELL_ITALIC) != 0)
                guard let entry = legacyAtlas.entry(for: key) else { continue }
                instances.append(Instance(
                    origin: SIMD2(4 + Float(column) * Float(metrics.cellWidth)
                                  + Float(metrics.glyphOffset(columns: 1)) + entry.bearing.x,
                                  4 + Float(row) * Float(metrics.cellHeight) + Float(metrics.baseline)
                                  - entry.bearing.y - entry.size.y),
                    size: entry.size, color: Self.color(cell.fg), uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize, kind: entry.isColor ? 2 : 1, atlasPage: UInt32(entry.page)
                ))
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let background = Self.color(snapshot.background)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        let buffer = testUploadInstanceBuffer(to: commands)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        drawInstances(atlas: legacyAtlas, with: encoder)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        precondition(commands.status == .completed)
    }

    func testPrepareOriginalBuild(snapshot: ZshellSnapshot, metrics: AlacrittyMetrics,
                                  dirtyRows: [Int]?) {
        build(snapshot: snapshot, markedText: nil, metrics: metrics,
              padding: CGPoint(x: 4, y: 4), atlas: atlas!, backgroundOpacity: 1,
              dirtyRows: dirtyRows, viewportSize: CGSize(width: 512, height: 512))
    }

    func testCachedGlyphsAreCurrent(_ keys: [[TerminalGlyphAtlas.Key]]) -> Bool {
        keys.enumerated().allSatisfy { row, keys in
            let glyphs = rowInstances[row].instances.filter { $0.kind == 1 || $0.kind == 2 }
            return glyphs.count == keys.count && glyphs.allSatisfy { instance in
                guard let entry = atlas!.testEntries.first(where: {
                    let origin = $0.uvOrigin
                    let end = origin + $0.uvSize
                    let epsilon: Float = 0.000001
                    return instance.atlasPage == UInt32($0.page)
                        && instance.uvOrigin.x >= origin.x - epsilon && instance.uvOrigin.y >= origin.y - epsilon
                        && instance.uvOrigin.x + instance.uvSize.x <= end.x + epsilon
                        && instance.uvOrigin.y + instance.uvSize.y <= end.y + epsilon
                }) else { return false }
                return instance.atlasPage == UInt32(entry.page)
                    && instance.uvOrigin.y == entry.uvOrigin.y && instance.uvSize.y == entry.uvSize.y
            }
        }
    }

    func testDrawPageSequence(_ pages: [Int], into texture: MTLTexture) -> MTLCommandBuffer {
        // Reuse real glyph UVs but overlap the quads to make reordered draws
        // observable. Solid decorations between groups must remain in order.
        let original = instances
        defer { instances = original }
        instances = []
        for page in pages {
            var glyph = original.first { $0.kind == 1 && $0.atlasPage == UInt32(page) }!
            glyph.origin = SIMD2(4, 4)
            glyph.size = SIMD2(48, 48)
            glyph.color = page % 2 == 0 ? SIMD4(1, 0, 0, 1) : SIMD4(0, 1, 0, 1)
            instances.append(glyph)
            instances.append(Instance(origin: SIMD2(4, 4), size: SIMD2(48, 48),
                                      color: SIMD4(0, 0, Float(page + 1) / 10, 1),
                                      uvOrigin: .zero, uvSize: .zero, kind: 0))
        }
        let batches = instanceRanges()
        precondition(batches.flatMap { Array($0.range) } == Array(instances.indices))
        precondition(batches.count == pages.count)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        let buffer = testUploadInstanceBuffer(to: commands)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(64, 64)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        drawInstances(atlas: atlas!, with: encoder)
        encoder.endEncoding()
        commands.commit()
        return commands
    }

    func testDrawGlyphPages(_ pages: [Int], into texture: MTLTexture,
                           reference: Bool) -> MTLCommandBuffer {
        let original = instances
        defer { instances = original }
        instances = pages.enumerated().map { index, page in
            var glyph = original.first { $0.kind == 1 && $0.atlasPage == UInt32(page) }!
            glyph.origin = SIMD2(Float(index * 60 + 4), 4)
            glyph.size = SIMD2(48, 48)
            glyph.color = SIMD4(1, 1, 1, 1)
            return glyph
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        let buffer = testUploadInstanceBuffer(to: commands)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        if reference {
            // Sample each known page on its own. Binding that same texture to
            // every slot makes the reference independent of group/modulo logic.
            for (index, page) in pages.enumerated() {
                for slot in 0..<Self.texturesPerDraw {
                    encoder.setFragmentTexture(atlas!.textures[page], index: slot)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: 1, baseInstance: index)
            }
        } else {
            drawInstances(atlas: atlas!, with: encoder)
        }
        encoder.endEncoding()
        commands.commit()
        return commands
    }
}
'''


with tempfile.TemporaryDirectory(prefix="zshell-glyph-atlas-") as directory:
    temporary = Path(directory)
    atlas = temporary / "TerminalGlyphAtlas.swift"
    source = (ALACRITTY / atlas.name).read_text()
    marker = "    private static func makeTexture(device: MTLDevice, dimension: Int) -> MTLTexture? {\n"
    if source.count(marker) != 1:
        raise AssertionError("expected one production atlas texture allocator")
    source = source.replace(marker, marker + """
        if let remaining = GlyphAtlasAllocationProbe.remainingSuccesses {
            guard remaining > 0 else { return nil }
            GlyphAtlasAllocationProbe.remainingSuccesses = remaining - 1
        }
""")
    atlas.write_text(source + ATLAS_PROBES + """
extension TerminalGlyphAtlas {
    var testEntries: [Entry] { Array(entries.values) + Array(glyphEntries.values) }
}
""")

    renderer = temporary / "TerminalMetalRenderer.swift"
    renderer_source = (ALACRITTY / renderer.name).read_text()
    pool = ALACRITTY / "TerminalInstanceBufferPool.swift"
    uses_pool = "TerminalInstanceBufferPool" in renderer_source
    if uses_pool and not pool.is_file():
        raise AssertionError("the renderer's instance pool source is missing")
    probes = RENDERER_PROBES
    if uses_pool:
        probes = probes.replace("        return uploadInstances()!", """
        let lease = uploadInstances(waitUntilAvailable: false, onAvailable: nil)!
        lease.releaseWhenCompleted(by: commands)
        return lease.buffer
""")
    renderer.write_text(renderer_source + probes)

    # Keep production metrics, font cascade and color contrast. The fixture
    # never selects cells and never reads or writes a user's configuration.
    source = (ALACRITTY / "AlacrittyRenderer.swift").read_text()
    metrics = source[:source.index("/// Draws one snapshot of the grid with CoreText.")]
    colors = source[source.index("    // MARK: - Colors"):]
    selection_start = colors.index("    static func selectionColors()")
    selection_end = colors.index("    private static func contrastedColor", selection_start)
    colors = colors[:selection_start] + """
    static func selectionColors() -> (foreground: UInt32, background: UInt32) {
        preconditionFailure("Selected cells are outside this glyph fixture")
    }

""" + colors[selection_end:]
    models = temporary / "RendererModels.swift"
    models.write_text(metrics.replace("import GhosttyTheme\n", "")
                      + "struct AlacrittyRenderer {\n" + colors)

    source = (ROOT / "mac/zshell/TerminalFont.swift").read_text()
    start = source.index("    /// The terminal font for the current settings")
    end = source.index("    /// Resolves a family name", start)
    font = temporary / "TerminalFont.swift"
    font.write_text(source[:start] + source[end:])

    binary = temporary / "glyph-atlas-tests"
    benchmark = "--benchmark" in sys.argv
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-strict-concurrency=complete",
        "-warnings-as-errors", "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "modules"),
        "-import-objc-header", str(ROOT / "mac/Vendor/alacritty-bridge/include/zshell_alacritty.h"),
        *([str(pool)] if uses_pool else []),
        str(atlas), str(ALACRITTY / "AlacrittyKittyGraphics.swift"),
        str(ALACRITTY / "TerminalTextShaper.swift"),
        str(ROOT / "mac/zshell/TerminalFontFeatures.swift"),
        str(ROOT / "mac/zshell/TerminalContrast.swift"),
        str(font), str(models), str(renderer),
        str(ROOT / "mac/tests/TerminalGlyphAtlasCapacityTests.swift"),
        *(["-O"] if benchmark else []),
        "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), *(["--benchmark"] if benchmark else [])],
                   cwd=ROOT, check=True, timeout=60)
