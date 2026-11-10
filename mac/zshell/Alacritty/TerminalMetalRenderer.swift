//
//  TerminalMetalRenderer.swift
//  zshell
//

import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

/// IME preedit captured separately from the snapshot cursor, which may be
/// hidden or restyled before the frame is submitted.
struct TerminalMarkedText {
    let text: String
    let line: Int
    let column: Int
}

/// GPU renderer for a terminal grid.
///
/// One instanced draw call normally covers a frame: every cell background, glyph,
/// underline, strikethrough and the cursor becomes a quad in a single buffer.
/// Quad corners are generated in the vertex shader from `vertex_id`, so there
/// is no geometry to upload — only the per-instance array.
///
/// Glyphs are still rasterized by CoreText (see `TerminalGlyphAtlas`); Metal
/// only composites them. That keeps font matching and fallback identical to
/// Zshell's editor and to the Ghostty backend, which is the whole reason the
/// text stack stays on the platform side.
final class TerminalMetalRenderer {
    /// Mirrors `Instance` in the shader below. Field order and padding must
    /// stay in step with it.
    private struct Instance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        /// 0 solid, 1 foreground-tinted glyph, 2 intrinsic-color glyph,
        /// 3 Kitty graphics texture.
        var kind: UInt32
        var atlasPage: UInt32 = 0
    }

    private struct RowInstances {
        var instances: [Instance]
        var backgroundCount: Int
    }

    private struct VisibleGlyph: Hashable {
        let page: UInt32
        let uvOrigin: SIMD2<Float>
    }

    private static let texturesPerDraw = 4

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let instanceBuffers: TerminalInstanceBufferPool
    private var atlas: TerminalGlyphAtlas?
    private var kittyTextures: [AlacrittyKittyImageKey: MTLTexture] = [:]

    private var instances: [Instance] = []

    /// Draw instances per grid row, kept between frames.
    ///
    /// Building a row means an atlas lookup, a colour unpack and a flag test
    /// per cell — the bulk of a frame's CPU cost. Almost every change touches
    /// one row (a prompt redraw, a cursor blink), so rows the emulator did not
    /// damage are reused verbatim and only the dirty ones are rebuilt.
    private var rowInstances: [RowInstances] = []
    /// Rebuilt rows are only valid for the geometry they were built at.
    private var cachedColumns = 0
    private var cachedRows = 0
    private var cachedPaddingColor: TerminalPaddingColor = .extend

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        textureLoader = MTKTextureLoader(device: device)
        instanceBuffers = TerminalInstanceBufferPool(device: device)

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "zshell_terminal_vertex"),
              let fragmentFunction = library.makeFunction(name: "zshell_terminal_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Glyph coverage arrives as alpha, so quads blend rather than replace.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        // Glyphs remain fully opaque over a potentially translucent terminal
        // background, so their alpha must replace rather than inherit the
        // background alpha in the retained IOSurface.
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }
        self.pipeline = pipeline

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.sampler = sampler
    }

    // MARK: - Frame

    @discardableResult
    func render(
        snapshot: ZshellSnapshot,
        markedText: TerminalMarkedText?,
        kittyPlacements: [AlacrittyKittyPlacement],
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        scale: CGFloat,
        backgroundOpacity: CGFloat,
        paddingColor: TerminalPaddingColor = .extend,
        dirtyRows: [Int]?,
        in drawable: CAMetalDrawable,
        viewportSize: CGSize,
        onPresented: (@Sendable () -> Void)? = nil,
        onBufferAvailable: (@Sendable () -> Void)? = nil,
        waitUntilCompleted: Bool = false
    ) -> Bool {
        guard prepare(
            snapshot: snapshot, markedText: markedText,
            metrics: metrics, padding: padding,
            scale: scale,
            paddingColor: paddingColor,
            dirtyRows: dirtyRows,
            viewportSize: viewportSize
        ), let atlas else { return false }

        let instanceLease: TerminalInstanceBufferPool.Lease?
        if instances.isEmpty {
            instanceLease = nil
        } else {
            guard let lease = uploadInstances(
                waitUntilAvailable: waitUntilCompleted,
                onAvailable: onBufferAvailable
            ) else { return false }
            instanceLease = lease
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let background = Self.color(snapshot.background)
        let alpha = Double(backgroundOpacity)
        // Core Animation composites this transparent drawable as premultiplied alpha.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x) * alpha,
            green: Double(background.y) * alpha,
            blue: Double(background.z) * alpha,
            alpha: alpha
        )

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return false }

        drawKittyGraphics(
            kittyPlacements.filter { $0.zIndex < 0 },
            metrics: metrics,
            padding: padding,
            viewportSize: viewportSize,
            with: encoder
        )
        if let buffer = instanceLease?.buffer {
            var viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            drawInstances(atlas: atlas, with: encoder)
        }
        drawKittyGraphics(
            kittyPlacements.filter { $0.zIndex >= 0 },
            metrics: metrics,
            padding: padding,
            viewportSize: viewportSize,
            with: encoder
        )
        let activeImageKeys = Set(kittyPlacements.map(\.imageKey))
        kittyTextures = kittyTextures.filter { activeImageKeys.contains($0.key) }

        encoder.endEncoding()
        if let onPresented {
            drawable.addPresentedHandler { _ in onPresented() }
        }
        commands.present(drawable)
        instanceLease?.releaseWhenCompleted(by: commands)
        commands.commit()
        if waitUntilCompleted {
            commands.waitUntilCompleted()
            return commands.status != .error
        }
        return true
    }

    private func prepare(
        snapshot: ZshellSnapshot,
        markedText: TerminalMarkedText?,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        scale: CGFloat,
        paddingColor: TerminalPaddingColor,
        dirtyRows: [Int]?,
        viewportSize: CGSize
    ) -> Bool {
        if atlas == nil {
            atlas = TerminalGlyphAtlas(device: device, metrics: metrics, scale: scale)
        }
        guard let atlas else { return false }
        let generationBeforeReset = atlas.generation
        guard atlas.reset(metrics: metrics, scale: scale) else { return false }
        let resetAtlas = atlas.generation != generationBeforeReset

        let generationBeforeBuild = atlas.generation
        build(
            snapshot: snapshot, markedText: markedText,
            metrics: metrics, padding: padding, atlas: atlas,
            paddingColor: paddingColor,
            dirtyRows: resetAtlas ? nil : dirtyRows,
            viewportSize: viewportSize
        )
        if atlas.generation != generationBeforeBuild {
            // Growth changes UVs, including those in retained clean rows.
            // It happens at most once, from the initial page to the final size.
            build(
                snapshot: snapshot, markedText: markedText,
                metrics: metrics, padding: padding, atlas: atlas,
                paddingColor: paddingColor,
                dirtyRows: nil, viewportSize: viewportSize
            )
        }

        let visibleArea = atlas.pageCount > 2 ? visibleGlyphArea() : 0
        if atlas.needsRebuild || atlas.shouldCompact(visibleGlyphArea: visibleArea) {
            // Repack the complete visible grid and IME, not just dirty rows.
            // Unlike history caching, this pass may add the pages the frame
            // actually needs. Fresh textures leave in-flight frames untouched.
            guard atlas.beginRebuild() else { return false }
            build(
                snapshot: snapshot, markedText: markedText,
                metrics: metrics, padding: padding, atlas: atlas,
                paddingColor: paddingColor,
                dirtyRows: nil, viewportSize: viewportSize
            )
            atlas.finishRebuild(visibleGlyphArea: visibleGlyphArea())
        }
        return !atlas.needsRebuild
    }

    private func visibleGlyphArea() -> Float {
        var visible: Set<VisibleGlyph> = []
        var area: Float = 0
        // Include retained clean rows and transient preedit, deduplicating
        // glyphs whose rasterized bitmap is shared by many cells.
        for instance in instances where instance.kind == 1 || instance.kind == 2 {
            if visible.insert(VisibleGlyph(
                page: instance.atlasPage, uvOrigin: instance.uvOrigin
            )).inserted {
                area += instance.uvSize.x * instance.uvSize.y
            }
        }
        return area
    }

    /// Consecutive ranges keep backgrounds, overlapping glyphs, decorations
    /// and the cursor in their original order when a grid needs >4 pages.
    private func instanceRanges() -> [(range: Range<Int>, firstPage: Int)] {
        guard !instances.isEmpty else { return [] }
        var ranges: [(range: Range<Int>, firstPage: Int)] = []
        var start = 0
        var firstPage = 0
        for (index, instance) in instances.enumerated()
            where instance.kind == 1 || instance.kind == 2
        {
            let group = Int(instance.atlasPage) / Self.texturesPerDraw * Self.texturesPerDraw
            if group != firstPage {
                if index > start { ranges.append((start..<index, firstPage)) }
                start = index
                firstPage = group
            }
        }
        ranges.append((start..<instances.count, firstPage))
        return ranges
    }

    private func drawInstances(atlas: TerminalGlyphAtlas, with encoder: MTLRenderCommandEncoder) {
        let textures = atlas.textures
        let batches = textures.count <= Self.texturesPerDraw
            ? [(range: 0..<instances.count, firstPage: 0)] : instanceRanges()
        for batch in batches {
            // Populate every shader binding, including unused slots. Solid
            // instances can start a batch before its first glyph arrives.
            for slot in 0..<Self.texturesPerDraw {
                let page = batch.firstPage + slot
                encoder.setFragmentTexture(textures[page < textures.count ? page : 0], index: slot)
            }
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6,
                instanceCount: batch.range.count, baseInstance: batch.range.lowerBound
            )
        }
    }

    private func drawKittyGraphics(
        _ placements: [AlacrittyKittyPlacement],
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        viewportSize: CGSize,
        with encoder: MTLRenderCommandEncoder
    ) {
        guard !placements.isEmpty else { return }
        var viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(
            &viewport,
            length: MemoryLayout<SIMD2<Float>>.stride,
            index: 1
        )
        encoder.setFragmentSamplerState(sampler, index: 0)

        for placement in placements {
            guard placement.imageWidth > 0,
                  placement.imageHeight > 0,
                  placement.sourceWidth > 0,
                  placement.sourceHeight > 0,
                  placement.displayColumns > 0,
                  placement.displayRows > 0,
                  let texture = kittyTexture(for: placement)
            else { continue }

            let destinationWidth = Float(placement.displayColumns) * Float(metrics.cellWidth)
            let destinationHeight = Float(placement.displayRows) * Float(metrics.cellHeight)
            var instance = Instance(
                origin: SIMD2(
                    Float(padding.x)
                        + Float(placement.column) * Float(metrics.cellWidth)
                        + Float(placement.xOffset),
                    Float(padding.y)
                        + Float(placement.viewportRow) * Float(metrics.cellHeight)
                        + Float(placement.yOffset)
                ),
                size: SIMD2(destinationWidth, destinationHeight),
                color: SIMD4(repeating: 1),
                uvOrigin: SIMD2(
                    Float(placement.sourceX) / Float(placement.imageWidth),
                    Float(placement.sourceY) / Float(placement.imageHeight)
                ),
                uvSize: SIMD2(
                    Float(placement.sourceWidth) / Float(placement.imageWidth),
                    Float(placement.sourceHeight) / Float(placement.imageHeight)
                ),
                kind: 3
            )
            encoder.setVertexBytes(
                &instance,
                length: MemoryLayout<Instance>.stride,
                index: 0
            )
            for slot in 0..<Self.texturesPerDraw {
                encoder.setFragmentTexture(texture, index: slot)
            }
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: 1
            )
        }
    }

    private func kittyTexture(for placement: AlacrittyKittyPlacement) -> MTLTexture? {
        if let texture = kittyTextures[placement.imageKey] {
            return texture
        }
        guard let texture = try? textureLoader.newTexture(
            data: placement.png,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false,
            ]
        ) else {
            return nil
        }
        kittyTextures[placement.imageKey] = texture
        return texture
    }

    private func uploadInstances(
        waitUntilAvailable: Bool,
        onAvailable: (@Sendable () -> Void)?
    ) -> TerminalInstanceBufferPool.Lease? {
        let length = MemoryLayout<Instance>.stride * instances.count
        guard let lease = instanceBuffers.acquire(
            length: length,
            waitUntilAvailable: waitUntilAvailable,
            onAvailable: onAvailable
        ) else { return nil }
        instances.withUnsafeBytes { raw in
            lease.buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: length)
        }
        return lease
    }

    // MARK: - Instance building

    private func build(
        snapshot: ZshellSnapshot,
        markedText: TerminalMarkedText?,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        atlas: TerminalGlyphAtlas,
        paddingColor: TerminalPaddingColor,
        dirtyRows: [Int]?,
        viewportSize: CGSize
    ) {
        instances.removeAll(keepingCapacity: true)
        guard let cells = snapshot.cells else { return }

        let columns = snapshot.columns
        let rows = snapshot.rows

        // A geometry change invalidates every cached row: positions are baked
        // into the instances. Rebuild every row even if the emulator only
        // reported partial damage for this frame.
        let geometryChanged = cachedColumns != columns || cachedRows != rows
        let paddingColorChanged = cachedPaddingColor != paddingColor
        cachedPaddingColor = paddingColor
        if geometryChanged {
            rowInstances = Array(
                repeating: RowInstances(instances: [], backgroundCount: 0),
                count: rows
            )
            cachedColumns = columns
            cachedRows = rows
        }

        // nil means rebuild everything — a full-damage frame, or a host-side
        // change the emulator never saw. An empty array preserves all retained
        // rows while transient preedit instances are appended below.
        let rowsToBuild: [Int]
        if geometryChanged || paddingColorChanged {
            rowsToBuild = Array(0..<rows)
        } else if let dirtyRows {
            rowsToBuild = dirtyRows.filter { $0 >= 0 && $0 < rows }
        } else {
            rowsToBuild = Array(0..<rows)
        }
        for row in rowsToBuild {
            rowInstances[row] = buildRow(
                row: row, cells: cells, columns: columns,
                snapshot: snapshot, metrics: metrics, padding: padding,
                atlas: atlas,
                paddingColor: paddingColor,
                viewportSize: viewportSize
            )
        }

        instances.reserveCapacity(
            rowInstances.reduce(0) { $0 + $1.instances.count } + 1
        )
        for row in rowInstances {
            instances.append(contentsOf: row.instances)
        }
        appendCursor(
            snapshot: snapshot,
            metrics: metrics,
            padding: padding,
            blockInsertionIndex: blockCursorInsertionIndex(snapshot: snapshot)
        )
        appendMarkedText(
            markedText,
            snapshot: snapshot,
            metrics: metrics,
            padding: padding,
            atlas: atlas
        )
    }

    /// Preedit changes without emulator damage, so it deliberately sits outside
    /// the retained row cache and is appended from the current frame's state.
    private func appendMarkedText(
        _ markedText: TerminalMarkedText?,
        snapshot: ZshellSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        atlas: TerminalGlyphAtlas
    ) {
        guard let markedText,
              let cells = snapshot.cells,
              markedText.line >= 0,
              markedText.column >= 0,
              markedText.line < snapshot.rows,
              markedText.column < snapshot.columns
        else { return }

        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let anchorCell = cells[markedText.line * snapshot.columns + markedText.column]
        let color = Self.color(
            AlacrittyRenderer.foreground(of: anchorCell, default: snapshot.background)
        )
        let top = Float(padding.y) + Float(markedText.line) * cellHeight
        let baseline = top + Float(metrics.baseline)
        var column = Float(markedText.column)

        for character in markedText.text {
            guard column < Float(snapshot.columns) else { break }
            let left = Float(padding.x) + column * cellWidth
            var advance: Float = 1
            let key = TerminalGlyphAtlas.Key(
                content: .cluster(Data(String(character).utf8)),
                bold: false,
                italic: false
            )
            if let entry = atlas.entry(for: key) {
                if entry.size.x > cellWidth * 1.5 { advance = 2 }
                instances.append(Instance(
                    origin: SIMD2(
                        left + entry.bearing.x,
                        baseline - entry.bearing.y - entry.size.y
                    ),
                    size: entry.size,
                    color: color,
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    kind: entry.isColor ? 2 : 1,
                    atlasPage: UInt32(entry.page)
                ))
            }
            instances.append(Instance(
                origin: SIMD2(left, baseline + cellHeight * 0.12),
                size: SIMD2(advance * cellWidth, 1),
                color: color,
                uvOrigin: .zero,
                uvSize: .zero,
                kind: 0
            ))
            column += advance
        }
    }

    private func buildRow(
        row: Int,
        cells: UnsafePointer<ZshellCell>,
        columns: Int,
        snapshot: ZshellSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        atlas: TerminalGlyphAtlas,
        paddingColor: TerminalPaddingColor,
        viewportSize: CGSize
    ) -> RowInstances {
        var instances: [Instance] = []
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let originX = Float(padding.x)
        let originY = Float(padding.y)
        let defaultBackground = snapshot.background

        let top = originY + Float(row) * cellHeight
        let extendsSides = paddingColor != .background
        let extendsVertically = paddingColor == .always
            || (paddingColor == .extend && (row == 0 || row + 1 == snapshot.rows)
                && !Self.rowNeverExtendsBackground(
                row, cells: cells, columns: columns, background: defaultBackground
            ))
        var column = 0

        // Backgrounds first, coalescing equal-coloured runs into one quad.
        while column < columns {
            let cell = cells[row * columns + column]
            let background = AlacrittyRenderer.background(of: cell, default: defaultBackground)
            let drawsBackground = Self.drawsBackground(cell, resolved: background, default: defaultBackground)
            var span = 1
            while column + span < columns {
                let next = cells[row * columns + column + span]
                guard AlacrittyRenderer.background(of: next, default: defaultBackground)
                    == background,
                      Self.drawsBackground(next, resolved: background, default: defaultBackground)
                    == drawsBackground else { break }
                span += 1
            }
            if drawsBackground {
                let reachesLeftEdge = extendsSides && column == 0
                let reachesRightEdge = extendsSides && column + span == columns
                let reachesTopEdge = extendsVertically && row == 0
                let reachesBottomEdge = extendsVertically && row + 1 == snapshot.rows
                let left = reachesLeftEdge
                    ? 0 : originX + Float(column) * cellWidth
                let right = reachesRightEdge
                    ? Float(viewportSize.width)
                    : originX + Float(column + span) * cellWidth
                let runTop = reachesTopEdge ? 0 : top
                let bottom = reachesBottomEdge
                    ? Float(viewportSize.height) : top + cellHeight
                instances.append(Instance(
                    origin: SIMD2(left, runTop),
                    size: SIMD2(max(right - left, 0), max(bottom - runTop, 0)),
                    // Ghostty keeps explicit, selected and inverse backgrounds
                    // opaque; only untouched cells expose the translucent clear.
                    color: Self.color(background),
                    uvOrigin: .zero,
                    uvSize: .zero,
                    kind: 0
                ))
            }
            column += span
        }
        let backgroundCount = instances.count

        for column in 0..<columns {
            let cell = cells[row * columns + column]
            guard cell.flags & UInt16(ZSHELL_CELL_HIDDEN) == 0,
                  cell.flags & UInt16(ZSHELL_CELL_WIDE_SPACER) == 0
            else { continue }

            var foreground = AlacrittyRenderer.foreground(of: cell, default: defaultBackground)
            let isCursorCell = snapshot.cursor_line == row
                && snapshot.cursor_column == column
                && snapshot.cursor_shape == 0
            if isCursorCell {
                foreground = AlacrittyRenderer.background(of: cell, default: defaultBackground)
            }
            let color = Self.color(foreground)
            let left = originX + Float(column) * cellWidth

            if cell.ch != 0,
               cell.text_len > 0 || cell.ch != UInt32(UInt8(ascii: " ")) {
                let content: TerminalGlyphAtlas.Content
                let offset = Int(cell.text_offset)
                let length = Int(cell.text_len)
                if length > 0,
                   let text = snapshot.text,
                   offset >= 0,
                   offset + length <= snapshot.text_len {
                    content = .cluster(Data(bytes: text.advanced(by: offset), count: length))
                } else {
                    content = .scalar(cell.ch)
                }
                let key = TerminalGlyphAtlas.Key(
                    content: content,
                    bold: cell.flags & UInt16(ZSHELL_CELL_BOLD) != 0,
                    italic: cell.flags & UInt16(ZSHELL_CELL_ITALIC) != 0
                )
                if let entry = atlas.entry(for: key) {
                    // The atlas stores bearings relative to the text
                    // origin; y grows downward here, so the ascent above
                    // the baseline becomes a negative offset.
                    let baseline = top + Float(metrics.baseline)
                    instances.append(Instance(
                        origin: SIMD2(
                            left + entry.bearing.x,
                            baseline - entry.bearing.y - entry.size.y
                        ),
                        size: entry.size,
                        color: color,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        kind: entry.isColor ? 2 : 1,
                        atlasPage: UInt32(entry.page)
                    ))
                }
            }

            if cell.flags & UInt16(ZSHELL_CELL_UNDERLINE) != 0 {
                instances.append(Instance(
                    origin: SIMD2(left, top + Float(metrics.baseline) + cellHeight * 0.12),
                    size: SIMD2(cellWidth, 1),
                    color: color,
                    uvOrigin: .zero, uvSize: .zero, kind: 0
                ))
            }
            if cell.flags & UInt16(ZSHELL_CELL_STRIKEOUT) != 0 {
                instances.append(Instance(
                    origin: SIMD2(left, top + Float(metrics.baseline) - cellHeight * 0.22),
                    size: SIMD2(cellWidth, 1),
                    color: color,
                    uvOrigin: .zero, uvSize: .zero, kind: 0
                ))
            }
        }

        return RowInstances(
            instances: instances,
            backgroundCount: backgroundCount
        )
    }

    private static func drawsBackground(_ cell: ZshellCell, resolved: UInt32, default background: UInt32) -> Bool {
        cell.flags & UInt16(ZSHELL_CELL_EXPLICIT_BACKGROUND | ZSHELL_CELL_INVERSE | ZSHELL_CELL_SELECTED) != 0
            || resolved != background
    }

    /// Mirrors Ghostty's row.zig: inspect the terminal's original background,
    /// before selection or inverse video changes the displayed edge color.
    private static func rowNeverExtendsBackground(
        _ row: Int, cells: UnsafePointer<ZshellCell>, columns: Int, background: UInt32
    ) -> Bool {
        for column in 0..<columns {
            let cell = cells[row * columns + column]
            if cell.flags & UInt16(ZSHELL_CELL_SEMANTIC_PROMPT) != 0 || cell.bg == background {
                return true
            }
            switch cell.ch {
            case 0xE0B0...0xE0C8, 0xE0CA, 0xE0CC...0xE0D2, 0xE0D4: return true
            default: break
            }
        }
        return false
    }

    /// Places a block cursor after its row backgrounds but before its glyphs,
    /// while outline cursors sit above all cell content.
    private func appendCursor(
        snapshot: ZshellSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        blockInsertionIndex: Int?
    ) {
        guard snapshot.cursor_line >= 0, snapshot.cursor_column >= 0 else { return }
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let left = Float(padding.x) + Float(snapshot.cursor_column) * cellWidth
        let top = Float(padding.y) + Float(snapshot.cursor_line) * cellHeight
        let color = Self.color(snapshot.cursor_color)

        if snapshot.cursor_shape == 3 {
            // Hollow cursor is four narrow quads.
            instances.append(contentsOf: [
                Instance(
                    origin: SIMD2(left, top), size: SIMD2(cellWidth, 1),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left, top + cellHeight - 1), size: SIMD2(cellWidth, 1),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left, top), size: SIMD2(1, cellHeight),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left + cellWidth - 1, top), size: SIMD2(1, cellHeight),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
            ])
            return
        }

        let (origin, size): (SIMD2<Float>, SIMD2<Float>) = switch snapshot.cursor_shape {
        case 1: (SIMD2(left, top + cellHeight - 2), SIMD2(cellWidth, 2))
        case 2: (SIMD2(left, top), SIMD2(2, cellHeight))
        default: (SIMD2(left, top), SIMD2(cellWidth, cellHeight))
        }
        let cursor = Instance(
            origin: origin, size: size, color: color,
            uvOrigin: .zero, uvSize: .zero, kind: 0
        )
        if snapshot.cursor_shape == 0, let blockInsertionIndex {
            instances.insert(cursor, at: blockInsertionIndex)
        } else {
            instances.append(cursor)
        }
    }

    /// Row instances are backgrounds followed by glyphs and decorations. Use
    /// the boundary captured with the cached row so partial damage cannot mix
    /// current snapshot backgrounds with stale instance counts.
    private func blockCursorInsertionIndex(snapshot: ZshellSnapshot) -> Int? {
        let row = snapshot.cursor_line
        let column = snapshot.cursor_column
        guard row >= 0, row < snapshot.rows,
              row < rowInstances.count,
              column >= 0, column < snapshot.columns
        else { return nil }

        let precedingInstances = rowInstances[..<row].reduce(0) {
            $0 + $1.instances.count
        }
        return precedingInstances + rowInstances[row].backgroundCount
    }

    private static func color(_ packed: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(
            Float((packed >> 16) & 0xff) / 255,
            Float((packed >> 8) & 0xff) / 255,
            Float(packed & 0xff) / 255,
            alpha
        )
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float2 origin;
        float2 size;
        float4 color;
        float2 uvOrigin;
        float2 uvSize;
        uint kind;
        uint atlasPage;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
        uint kind;
        uint atlasPage [[flat]];
    };

    // Quad corners come from vertex_id, so only the instance array is uploaded.
    constant float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };

    vertex VertexOut zshell_terminal_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device Instance *instances [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]]
    ) {
        Instance instance = instances[instanceID];
        float2 corner = corners[vertexID];
        float2 point = instance.origin + corner * instance.size;

        // Points, y-down from the top-left, into clip space.
        float2 normalized = point / viewport;
        float2 clip = float2(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0);

        VertexOut out;
        out.position = float4(clip, 0, 1);
        out.color = instance.color;
        out.uv = instance.uvOrigin + corner * instance.uvSize;
        out.kind = instance.kind;
        out.atlasPage = instance.atlasPage;
        return out;
    }

    fragment float4 zshell_terminal_fragment(
        VertexOut in [[stage_in]],
        array<texture2d<float>, 4> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        if (in.kind == 0) {
            return in.color;
        }
        float4 sample = atlas[in.atlasPage % 4].sample(atlasSampler, in.uv);
        if (in.kind == 3) {
            return sample;
        }
        if (in.kind == 2) {
            // CGContext stores premultiplied pixels. The pipeline uses
            // straight-alpha blending, so undo that multiplication here.
            return sample.a > 0.0
                ? float4(sample.rgb / sample.a, sample.a)
                : float4(0.0);
        }
        // Monochrome glyphs use the texture alpha as coverage; their RGB is
        // deliberately ignored so the terminal cell owns the foreground.
        float coverage = sample.a;
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """
}
