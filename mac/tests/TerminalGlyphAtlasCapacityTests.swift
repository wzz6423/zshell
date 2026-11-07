import AppKit
import CoreText
import Metal
import QuartzCore

enum GlyphAtlasAllocationProbe {
    static var remainingSuccesses: Int?
}

private struct Grid {
    let keys: [[TerminalGlyphAtlas.Key]]

    func withSnapshot<T>(_ body: (ZshellSnapshot) -> T) -> T {
        let columns = keys[0].count
        var text: [UInt8] = []
        let cells = keys.flatMap { row in row.map { key -> ZshellCell in
            var cell = ZshellCell()
            cell.fg = 0xffffff
            switch key.content {
            case .scalar(let value): cell.ch = value
            case .cluster(let data):
                cell.ch = key.content.string!.unicodeScalars.first!.value
                cell.text_offset = UInt32(text.count)
                cell.text_len = UInt16(data.count)
                text.append(contentsOf: data)
            }
            if key.bold { cell.flags |= UInt16(ZSHELL_CELL_BOLD) }
            if key.italic { cell.flags |= UInt16(ZSHELL_CELL_ITALIC) }
            return cell
        }}
        return cells.withUnsafeBufferPointer { cells in
            text.withUnsafeBufferPointer { text in
                var snapshot = ZshellSnapshot()
                snapshot.columns = columns
                snapshot.rows = keys.count
                snapshot.cells = cells.baseAddress
                snapshot.text = text.baseAddress
                snapshot.text_len = text.count
                snapshot.cursor_line = -1
                snapshot.cursor_column = -1
                return body(snapshot)
            }
        }
    }
}

@MainActor
private final class GlyphFixture {
    let device = MTLCreateSystemDefaultDevice()!
    let renderer: TerminalMetalRenderer
    let metrics: AlacrittyMetrics
    let scale: CGFloat

    init(size: CGFloat = 13, scale: CGFloat = 2) {
        renderer = TerminalMetalRenderer(device: device)!
        metrics = Self.metrics(size: size)
        self.scale = scale
    }

    static func metrics(size: CGFloat) -> AlacrittyMetrics {
        AlacrittyMetrics(family: "Menlo", fallbackFamily: "", size: size, fontThicken: false,
                         fontThickenStrength: 0, lineHeight: 1)
    }

    func prepare(_ grid: Grid, dirtyRows: [Int]? = nil,
                 markedText: TerminalMarkedText? = nil) -> Bool {
        grid.withSnapshot { snapshot in
            renderer.testPrepare(snapshot: snapshot, markedText: markedText,
                                 metrics: metrics, scale: scale, dirtyRows: dirtyRows)
        }
    }

    func layer(size: CGSize) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        return layer
    }

    func render(_ grid: Grid, dirtyRows: [Int]? = nil,
                markedText: TerminalMarkedText? = nil,
                kittyPlacements: [AlacrittyKittyPlacement] = [],
                cursorColumn: Int? = nil) -> [UInt8] {
        let size = CGSize(width: CGFloat(grid.keys[0].count) * metrics.cellWidth + 8,
                          height: CGFloat(grid.keys.count) * metrics.cellHeight + 8)
        let layer = layer(size: size)
        let drawable = layer.nextDrawable()!
        let texture = drawable.texture
        let submitted = grid.withSnapshot { snapshot in
            var snapshot = snapshot
            snapshot.cursor_line = cursorColumn == nil ? -1 : 0
            snapshot.cursor_column = cursorColumn ?? -1
            snapshot.cursor_color = 0x00ff00
            return renderer.render(snapshot: snapshot, markedText: markedText,
                            kittyPlacements: kittyPlacements,
                            metrics: metrics, padding: CGPoint(x: 4, y: 4), scale: scale,
                            backgroundOpacity: 1, dirtyRows: dirtyRows, in: drawable,
                            viewportSize: size, waitUntilCompleted: true)
        }
        precondition(submitted)
        return Self.pixels(texture)
    }

    static func pixels(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }

    func wait(_ commands: MTLCommandBuffer) {
        commands.waitUntilCompleted()
        precondition(commands.status == .completed,
                     "Metal command failed: \(String(describing: commands.error))")
    }

    func statistics(_ label: String) {
        let atlas = renderer.testAtlas
        print("\(label): pages=\(atlas.pageCount), entries=\(atlas.testEntryCount), "
              + "generation=\(atlas.generation), resident_bytes=\(atlas.testTextureBytes), "
              + "page_budget=\(atlas.testMaximumPages), draws=\(renderer.testDrawCount)")
    }
}

@main
struct TerminalGlyphAtlasCapacityTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--benchmark") {
            preparationPerformance()
            return
        }
        lateGlyphsRebuildCleanRowsAndIME()
        visibleWorkingSetPagesAndShrinks()
        multiTextureDrawsKeepOrder()
        kittyGraphicsKeepTheirLayers()
        oldTexturesSurviveRebuildAndReset()
        allocationFailuresRecover()
        print("Glyph atlas capacity tests passed (CoreText, Metal, paging, caches, IME, reset, failures)")
    }

    private static func key(_ value: UInt32, bold: Bool = false,
                            italic: Bool = false) -> TerminalGlyphAtlas.Key {
        TerminalGlyphAtlas.Key(content: .scalar(value), bold: bold, italic: italic)
    }

    private static func cluster(_ value: String) -> TerminalGlyphAtlas.Key {
        TerminalGlyphAtlas.Key(content: .cluster(Data(value.utf8)), bold: false, italic: false)
    }

    private static func cjkGrid(styled: Bool = false) -> Grid {
        var rows: [[TerminalGlyphAtlas.Key]] = []
        for row in 0..<40 {
            let first = UInt32(0x4e00 + row * 40)
            rows.append((0..<40).map { column in
                key(first + UInt32(column), bold: styled && column % 3 == 0)
            })
        }
        return Grid(keys: rows)
    }

    @MainActor private static func fill(_ atlas: TerminalGlyphAtlas,
                                        start: UInt32 = 0x4e00) -> Int {
        var count = 0
        for value in start..<0xa000 where value != 0x7ec8 {
            _ = atlas.entry(for: key(value))
            count += 1
            if atlas.needsRebuild { return count }
        }
        preconditionFailure("CJK workload did not exhaust the cache budget")
    }

    @MainActor private static func lateGlyphsRebuildCleanRowsAndIME() {
        let fixture = GlyphFixture()
        let initial = Grid(keys: [
            [key(0x41), key(0x42), key(0x43), key(0x44)],
            [key(0x45), key(0x46), key(0x47), key(0x48)],
        ])
        _ = fixture.render(initial)
        let atlas = fixture.renderer.testAtlas
        let firstTexture = atlas.textures[0]
        let oldRow = fixture.renderer.testRowUVs(0)
        let generation = atlas.generation
        let count = fill(atlas)
        precondition(atlas.needsRebuild && atlas.pageCount == 2)
        let populatedGeneration = atlas.generation
        precondition(populatedGeneration == generation + 1, "Expected one lazy texture growth")
        let final = Grid(keys: [
            initial.keys[0], [key(0x7ec8, bold: true), cluster("👩🏽‍💻"), key(0x47), key(0x48)],
        ])
        let ime = TerminalMarkedText(text: "新🦊", line: 1, column: 0)
        let pixels = fixture.render(final, dirtyRows: [1], markedText: ime)
        precondition(atlas.generation == populatedGeneration + 1)
        precondition(atlas.pageCount == 1 && atlas.testMaximumPages == 2)
        precondition(atlas.testEntryCount == 10 && fixture.renderer.testGlyphCount == 10)
        precondition(atlas.textures[0] !== firstTexture)
        precondition(fixture.renderer.testRowUVs(0) != oldRow)
        precondition(fixture.renderer.testCachedGlyphsAreCurrent(final.keys), "Clean row kept stale UVs")
        precondition(atlas.testCachedEntry(cluster("👩🏽‍💻"))!.isColor)
        let fresh = GlyphFixture()
        precondition(pixels == fresh.render(final, markedText: ime), "Recovered frame differs from a fresh atlas")
        let steadyGeneration = atlas.generation
        for _ in 0..<8 {
            precondition(fixture.prepare(final, dirtyRows: [], markedText: ime))
            precondition(atlas.generation == steadyGeneration)
        }
        let secondCount = fill(atlas, start: 0x5500)
        precondition(fixture.prepare(final, dirtyRows: [], markedText: ime))
        precondition(atlas.generation == steadyGeneration + 1)
        precondition(atlas.pageCount == 1 && atlas.testEntryCount == 10)
        fixture.statistics("PASS late glyph / clean row / emoji / IME after \(count + secondCount) historical glyphs")
    }

    @MainActor private static func visibleWorkingSetPagesAndShrinks() {
        let fixture = GlyphFixture(size: 72)
        let large = cjkGrid(styled: true)
        precondition(fixture.prepare(large))
        let atlas = fixture.renderer.testAtlas
        precondition(atlas.pageCount > 4 && !atlas.needsRebuild)
        precondition(fixture.renderer.testGlyphCount == 1600)
        precondition(atlas.testEntryCount == 1600)
        precondition(fixture.renderer.testCachedGlyphsAreCurrent(large.keys))
        precondition(atlas.testMaximumPages == atlas.pageCount + 1)
        precondition(atlas.testTextureBytes == atlas.pageCount * 2048 * 2048 * 4)
        let generation = atlas.generation
        let pageCount = atlas.pageCount
        fixture.statistics("PASS large visible working set")
        for _ in 0..<8 {
            precondition(fixture.prepare(large, dirtyRows: []))
            precondition(atlas.generation == generation && atlas.pageCount == pageCount)
        }
        let small = Grid(keys: [[key(0x7ec8), cluster("🦊")]])
        precondition(fixture.prepare(small, dirtyRows: []))
        precondition(atlas.generation == generation + 1)
        precondition(atlas.pageCount == 1 && atlas.testMaximumPages == 2)
        precondition(atlas.testEntryCount == 2 && atlas.testTextureBytes == 16 * 1024 * 1024)
        for _ in 0..<8 { precondition(fixture.prepare(small, dirtyRows: [])) }
        precondition(atlas.generation == generation + 1)
        fixture.statistics("PASS small working set releases surplus pages without repeated rebuilds")
    }

    @MainActor private static func multiTextureDrawsKeepOrder() {
        let fixture = GlyphFixture(size: 72)
        let grid = cjkGrid()
        precondition(fixture.prepare(grid))
        precondition(fixture.renderer.testAtlas.pageCount > 7)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = fixture.device.makeTexture(descriptor: descriptor)!
        fixture.wait(fixture.renderer.testDrawPageSequence([4, 0, 4, 0], into: texture))
        let pixels = GlyphFixture.pixels(texture)
        let index = (24 * texture.width + 24) * 4
        precondition(Array(pixels[index..<index + 4]) == [26, 0, 0, 255],
                     "Cross-page grouping changed the final solid decoration")
        let pages = [4, 1, 7, 0, 5]
        let width = pages.count * 60
        let glyphDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: 64, mipmapped: false
        )
        glyphDescriptor.usage = [.shaderRead, .renderTarget]
        glyphDescriptor.storageMode = .shared
        let actualTexture = fixture.device.makeTexture(descriptor: glyphDescriptor)!
        let referenceTexture = fixture.device.makeTexture(descriptor: glyphDescriptor)!
        fixture.wait(fixture.renderer.testDrawGlyphPages(pages, into: actualTexture, reference: false))
        fixture.wait(fixture.renderer.testDrawGlyphPages(pages, into: referenceTexture, reference: true))
        let actual = GlyphFixture.pixels(actualTexture)
        precondition(actual == GlyphFixture.pixels(referenceTexture),
                     "Page groups or modulo texture slots sampled a different glyph")
        for (index, _) in pages.enumerated() {
            let inkPixels = (0..<64).reduce(0) { count, y in
                count + (index * 60..<(index + 1) * 60).filter { x in
                    actual[(y * width + x) * 4 + 3] > 0
                }.count
            }
            precondition(inkPixels > 50, "Glyph-only page test rendered no ink")
        }
        fixture.statistics("PASS glyph-only page 0/1/4/5/7 sampling and alternating draw order")
    }

    @MainActor private static func kittyGraphicsKeepTheirLayers() {
        func placement(_ color: [UInt8], id: UInt32, column: Int,
                       columns: Int, zIndex: Int) -> AlacrittyKittyPlacement {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<2 { for x in 0..<2 {
                for channel in 0..<4 {
                    bitmap.bitmapData![y * bitmap.bytesPerRow + x * 4 + channel] = color[channel]
                }
            }}
            var placement = ZshellKittyPlacement()
            placement.image_id = id
            placement.image_generation = 1
            placement.image_width = 2
            placement.image_height = 2
            placement.source_width = 2
            placement.source_height = 2
            placement.column = column
            placement.display_columns = UInt32(columns)
            placement.display_rows = 1
            placement.z_index = Int32(zIndex)
            return AlacrittyKittyPlacement(placement, png: bitmap.representation(using: .png, properties: [:])!)
        }
        let fixture = GlyphFixture()
        let grid = Grid(keys: [[key(0x41), key(0x42), key(0x43)]])
        let placements = [
            placement([0, 0, 255, 255], id: 1, column: 0, columns: 3, zIndex: -1),
            placement([255, 0, 0, 255], id: 2, column: 2, columns: 1, zIndex: 1),
        ]
        let pixels = fixture.render(grid, kittyPlacements: placements, cursorColumn: 1)
        let width = Int((fixture.metrics.cellWidth * 3 + 8) * fixture.scale)
        let expectedColors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        for (column, expected) in expectedColors.enumerated() {
            let x = Int((4 + CGFloat(column) * fixture.metrics.cellWidth + 0.5) * fixture.scale)
            let y = Int(5 * fixture.scale)
            let offset = (y * width + x) * 4
            precondition(Array(pixels[offset..<offset + 4]) == expected,
                         "Kitty layer column \(column): \(Array(pixels[offset..<offset + 4])) != \(expected)")
        }
        precondition(stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] == 255 && pixels[$0 + 1] == 255 && pixels[$0 + 2] == 255
        }, "Negative Kitty image hid the terminal glyph")
        print("PASS Kitty negative/positive layers keep glyph/cursor order with all shader textures bound")
    }

    @MainActor private static func preparationPerformance() {
        func measure(_ fixture: GlyphFixture, _ grid: Grid, dirtyRows: [Int],
                     iterations: Int, original: Bool) -> Double {
            grid.withSnapshot { snapshot in
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations {
                    if original {
                        fixture.renderer.testPrepareOriginalBuild(
                            snapshot: snapshot, metrics: fixture.metrics, dirtyRows: dirtyRows
                        )
                    } else {
                        precondition(fixture.renderer.testPrepare(
                            snapshot: snapshot, markedText: nil, metrics: fixture.metrics,
                            scale: fixture.scale, dirtyRows: dirtyRows
                        ))
                    }
                }
                return Double(DispatchTime.now().uptimeNanoseconds - start)
                    / Double(iterations) / 1000
            }
        }
        let largeFixture = GlyphFixture(size: 72)
        let large = cjkGrid()
        precondition(largeFixture.prepare(large))
        let singleFixture = GlyphFixture()
        let single = Grid(keys: (0..<80).map { row in (0..<120).map { column in
            key(UInt32(0x21 + (row + column) % 90))
        }})
        precondition(singleFixture.prepare(single))
        for (label, fixture, grid) in [("single-page 9600 cells", singleFixture, single),
                                        ("eight-page 1600 unique glyphs", largeFixture, large)] {
            for (damage, rows) in [("steady", []), ("one dirty row", [20])] {
                _ = measure(fixture, grid, dirtyRows: rows, iterations: 100, original: true)
                _ = measure(fixture, grid, dirtyRows: rows, iterations: 100, original: false)
                var baselines: [Double] = []
                var currents: [Double] = []
                for _ in 0..<7 {
                    baselines.append(measure(fixture, grid, dirtyRows: rows, iterations: 300, original: true))
                    currents.append(measure(fixture, grid, dirtyRows: rows, iterations: 300, original: false))
                }
                let baseline = baselines.sorted()[3]
                let current = currents.sorted()[3]
                print("PERF \(label), \(damage): original_build_us=\(baseline), "
                      + "capacity_prepare_us=\(current), added_us=\(current - baseline)")
            }
        }
        print("Preparation benchmark passed (-O; production build baseline with capacity bookkeeping bypassed)")
    }

    @MainActor private static func oldTexturesSurviveRebuildAndReset() {
        let fixture = GlyphFixture()
        let atlas = TerminalGlyphAtlas(device: fixture.device, metrics: fixture.metrics, scale: 2)!
        let entry = atlas.entry(for: cluster("👩🏽‍💻"))!
        let oldTexture = atlas.textures[entry.page]
        let expected = GlyphFixture.pixels(oldTexture)
        let event = fixture.device.makeSharedEvent()!
        let commands = fixture.renderer.testQueue.makeCommandBuffer()!
        precondition(commands.retainedReferences)
        let bytesPerRow = oldTexture.width * 4
        let readback = fixture.device.makeBuffer(length: expected.count, options: .storageModeShared)!
        commands.encodeWaitForEvent(event, value: 1)
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: oldTexture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: oldTexture.width, height: oldTexture.height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: expected.count)
        blit.endEncoding()
        commands.commit()
        precondition(atlas.beginRebuild())
        _ = atlas.entry(for: key(0x7ec8))
        atlas.finishRebuild(visibleGlyphArea: 1)
        precondition(atlas.textures[0] !== oldTexture)
        precondition(atlas.reset(metrics: GlyphFixture.metrics(size: 18), scale: 1))
        _ = atlas.entry(for: key(0x41))
        precondition(atlas.textures[0] !== oldTexture && atlas.pageCount == 1)
        let generation = atlas.generation
        precondition(atlas.reset(metrics: GlyphFixture.metrics(size: 18), scale: 1))
        precondition(atlas.generation == generation)
        event.signaledValue = 1
        fixture.wait(commands)
        let actual = Array(UnsafeBufferPointer(
            start: readback.contents().assumingMemoryBound(to: UInt8.self), count: expected.count
        ))
        precondition(actual == expected, "Rebuild/reset overwrote the delayed GPU texture")
        print("PASS delayed GPU read preserves old emoji texture through capacity/font/scale resets")
    }

    @MainActor private static func allocationFailuresRecover() {
        let fixture = GlyphFixture()
        let grid = Grid(keys: [[key(0x41), key(0x7ec8)]])
        precondition(fixture.prepare(grid))
        let atlas = fixture.renderer.testAtlas
        let generation = atlas.generation
        _ = fill(atlas)
        GlyphAtlasAllocationProbe.remainingSuccesses = 0
        precondition(!fixture.prepare(grid, dirtyRows: []), "Failed rebuild reported a complete frame")
        precondition(atlas.needsRebuild && atlas.generation == generation + 1)
        precondition(!atlas.reset(metrics: GlyphFixture.metrics(size: 18), scale: 1))
        GlyphAtlasAllocationProbe.remainingSuccesses = nil
        precondition(fixture.prepare(grid, dirtyRows: []))
        precondition(fixture.renderer.testCachedGlyphsAreCurrent(grid.keys))
        precondition(!atlas.needsRebuild)

        let largeFixture = GlyphFixture(size: 72)
        let large = cjkGrid()
        precondition(largeFixture.prepare(Grid(keys: [[key(0x41)]])))
        // Fail an additional page in a fresh visible-working-set rebuild.
        _ = fill(largeFixture.renderer.testAtlas)
        GlyphAtlasAllocationProbe.remainingSuccesses = 1
        precondition(!largeFixture.prepare(large))
        precondition(largeFixture.renderer.testAtlas.needsRebuild)
        GlyphAtlasAllocationProbe.remainingSuccesses = nil
        precondition(largeFixture.prepare(large, dirtyRows: []))
        precondition(largeFixture.renderer.testGlyphCount == 1600)
        precondition(largeFixture.renderer.testCachedGlyphsAreCurrent(large.keys))
        largeFixture.statistics("PASS allocation failure returns and retries a complete frame")
    }
}
