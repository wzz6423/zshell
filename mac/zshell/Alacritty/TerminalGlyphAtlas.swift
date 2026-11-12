//
//  TerminalGlyphAtlas.swift
//  zshell
//

import AppKit
import CoreText
import Metal
import simd

/// Rasterized glyphs packed into Metal texture pages.
///
/// The GPU renderer draws a textured quad per cell, so every glyph has to
/// exist somewhere in a texture first. CoreText does the rasterizing — the
/// same path the CPU renderer used — which keeps font matching, hinting and
/// the system fallback chain identical to the rest of Zshell. Only the
/// compositing moves to the GPU.
///
/// Packing is a shelf allocator: glyphs are appended along a row until it is
/// full, then a new row starts below. A full cache is rebuilt from the visible
/// grid, with enough pages for that working set and one page of cache headroom.
/// Scrollback can therefore introduce new glyphs without retaining every
/// character the session has ever printed.
final class TerminalGlyphAtlas {
    enum Content: Hashable {
        case scalar(UInt32)
        case cluster(Data)

        var string: String? {
            switch self {
            case .scalar(let value):
                Unicode.Scalar(value).map(String.init)
            case .cluster(let data):
                String(data: data, encoding: .utf8)
            }
        }
    }

    struct Key: Hashable {
        let content: Content
        let bold: Bool
        let italic: Bool
    }

    private struct GlyphKey: Hashable {
        let font: CTFont
        let glyph: CGGlyph
    }

    /// Where a glyph lives in the atlas, and how to place it in its cell.
    struct Entry {
        let page: Int
        /// Normalized texture coordinates.
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        /// Size in points.
        let size: SIMD2<Float>
        /// Offset from the cell's text origin to the glyph's bottom-left.
        let bearing: SIMD2<Float>
        /// Color glyphs (emoji) carry their own RGB values instead of using
        /// the terminal cell's foreground color.
        let isColor: Bool
    }

    private static let initialDimension = 1024
    private static let maximumDimension = 2048

    private let device: MTLDevice
    var textures: [MTLTexture] { pages.map(\.texture) }
    var pageCount: Int { pages.count }
    private(set) var generation: UInt64 = 0
    private(set) var needsRebuild = false
    private var dimension: Int
    private var scale: CGFloat
    private var entries: [Key: Entry] = [:]
    private var glyphEntries: [GlyphKey: Entry] = [:]

    private struct Page {
        let texture: MTLTexture
        /// Shelf state, in device pixels.
        var shelfX = 0
        var shelfY = 0
        var shelfHeight = 0
    }

    private var pages: [Page]
    private var maximumPages = 2
    private var rebuildingVisibleGlyphs = false
    private var rebuiltVisibleGlyphArea: Float = 0

    private var metrics: AlacrittyMetrics

    init?(device: MTLDevice, metrics: AlacrittyMetrics, scale: CGFloat) {
        let dimension = Self.initialDimension
        guard let texture = Self.makeTexture(device: device, dimension: dimension) else {
            return nil
        }
        self.device = device
        pages = [Page(texture: texture)]
        self.dimension = dimension
        self.metrics = metrics
        self.scale = max(scale, 1)
    }

    private static func makeTexture(device: MTLDevice, dimension: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Drops every glyph. Called when the font or the backing scale changes,
    /// since both invalidate the rasterization.
    @discardableResult
    func reset(metrics: AlacrittyMetrics, scale: CGFloat) -> Bool {
        let scale = max(scale, 1)
        guard metrics.cellWidth != self.metrics.cellWidth
            || metrics.cellHeight != self.metrics.cellHeight
            || metrics.regular != self.metrics.regular
            || metrics.bold != self.metrics.bold
            || metrics.italic != self.metrics.italic
            || metrics.boldItalic != self.metrics.boldItalic
            || metrics.fontThicken != self.metrics.fontThicken
            || metrics.fontThickenStrength != self.metrics.fontThickenStrength
            || scale != self.scale
        else { return true }
        guard let texture = Self.makeTexture(device: device, dimension: Self.initialDimension)
        else { return false }
        self.metrics = metrics
        self.scale = scale
        replacePages(with: texture, dimension: Self.initialDimension)
        maximumPages = 2
        rebuiltVisibleGlyphArea = 0
        return true
    }

    /// Replacing textures preserves pages already sampled by in-flight
    /// command buffers. Reusing their storage would change an older frame.
    func beginRebuild() -> Bool {
        guard let texture = Self.makeTexture(device: device, dimension: Self.maximumDimension)
        else { return false }
        replacePages(with: texture, dimension: Self.maximumDimension)
        rebuildingVisibleGlyphs = true
        return true
    }

    func finishRebuild(visibleGlyphArea: Float) {
        rebuildingVisibleGlyphs = false
        maximumPages = pages.count + 1
        rebuiltVisibleGlyphArea = visibleGlyphArea
    }

    /// A much smaller visible working set releases surplus pages once. The
    /// new baseline prevents a steady small frame from compacting repeatedly.
    func shouldCompact(visibleGlyphArea: Float) -> Bool {
        pages.count > 2 && visibleGlyphArea < rebuiltVisibleGlyphArea / 2
    }

    private func replacePages(with texture: MTLTexture, dimension: Int) {
        pages = [Page(texture: texture)]
        self.dimension = dimension
        entries.removeAll()
        glyphEntries.removeAll()
        needsRebuild = false
        rebuildingVisibleGlyphs = false
        generation &+= 1
    }

    /// The atlas entry for a glyph, rasterizing it on first use. Nil for a
    /// glyph with no ink (a space), or while a full cache awaits rebuilding.
    func entry(for key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        guard !needsRebuild, let text = key.content.string else { return nil }
        guard let rasterized = rasterize(text: text, bold: key.bold, italic: key.italic)
        else { return nil }
        entries[key] = rasterized
        return rasterized
    }

    func entry(for glyph: CGGlyph, font: CTFont) -> Entry? {
        let key = GlyphKey(font: font, glyph: glyph)
        if let cached = glyphEntries[key] { return cached }
        guard !needsRebuild else { return nil }
        var glyph = glyph
        let isColor = CTFontGetSymbolicTraits(font).rawValue & (1 << 13) != 0
        var bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        let strokeWidth = metrics.fontThicken && !isColor
            ? CTFontGetSize(font) * (0.5 + CGFloat(min(max(metrics.fontThickenStrength, 0), 255)) / 255 * 1.5) / 100 : 0
        if strokeWidth > 0 { bounds = bounds.insetBy(dx: -strokeWidth, dy: -strokeWidth) }
        guard let entry = rasterize(bounds: bounds, isColor: isColor, draw: { context in
            context.setFillColor(NSColor.white.cgColor)
            if strokeWidth > 0 {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(strokeWidth)
                context.setTextDrawingMode(.fillStroke)
            }
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }) else { return nil }
        glyphEntries[key] = entry
        return entry
    }

    // MARK: - Rasterization

    private func rasterize(text: String, bold: Bool, italic: Bool) -> Entry? {
        let font = metrics.font(bold: bold, italic: italic)
        // CTLine rather than raw glyph drawing: it runs the system fallback
        // chain, so emoji and Nerd Font icons rasterize the same way they did
        // on the CPU path instead of coming out as missing-glyph boxes.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        var attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        let isColor = containsColorGlyphs(line)
        if metrics.fontThicken, !isColor {
            // CoreText uses negative percentages for inner stroke expansion.
            // Map Ghostty's 0...255 range to a subtle 0.5...2% pass while
            // keeping the existing full-strength Alacritty appearance.
            let strength = min(max(metrics.fontThickenStrength, 0), 255)
            let strokeWidth = -(0.5 + CGFloat(strength) / 255 * 1.5)
            attributes[.strokeColor] = NSColor.white
            attributes[.strokeWidth] = strokeWidth
            attributed = NSAttributedString(string: text, attributes: attributes)
            line = CTLineCreateWithAttributedString(attributed)
        }
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return rasterize(bounds: bounds, isColor: isColor) { context in
            CTLineDraw(line, context)
        }
    }

    private func rasterize(bounds: CGRect, isColor: Bool, draw: (CGContext) -> Void) -> Entry? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // A pixel of bleed on each side keeps linear sampling from picking up
        // a neighbour's ink along the shared edge.
        let padding: CGFloat = 1
        let pixelWidth = Int(((bounds.width + padding * 2) * scale).rounded(.up))
        let pixelHeight = Int(((bounds.height + padding * 2) * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= dimension, pixelHeight <= dimension
        else { return nil }

        guard let origin = allocate(width: pixelWidth, height: pixelHeight) else { return nil }

        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: space,
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        // The atlas stores grayscale coverage, not an opaque LCD surface.
        // Core Graphics font smoothing strengthens that coverage even when
        // `fontThicken` is off, making Alacritty's regular face look heavier
        // than the same font in Ghostty. Keep normal antialiasing, and let the
        // explicit stroke above be the only opt-in thickening pass.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        // Draw relative to the glyph's own bounds so the bearing below is the
        // only thing that positions it in the cell.
        context.textPosition = CGPoint(x: -bounds.minX + padding, y: -bounds.minY + padding)
        context.translateBy(x: context.textPosition.x, y: context.textPosition.y)
        context.textPosition = .zero
        draw(context)

        pages[origin.page].texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: pixelWidth * 4
        )

        let atlasDimension = Float(dimension)
        return Entry(
            page: origin.page,
            uvOrigin: SIMD2(
                Float(origin.x) / atlasDimension,
                Float(origin.y) / atlasDimension
            ),
            uvSize: SIMD2(
                Float(pixelWidth) / atlasDimension,
                Float(pixelHeight) / atlasDimension
            ),
            size: SIMD2(Float(pixelWidth) / Float(scale), Float(pixelHeight) / Float(scale)),
            bearing: SIMD2(Float(bounds.minX - padding), Float(bounds.minY - padding)),
            isColor: isColor
        )
    }

    /// CoreText's fallback run tells us whether the resolved face has an
    /// intrinsic color table (`sbix`, `COLR`, or SVG). Checking the actual run
    /// matters: the configured monospace face is not a color font, but its
    /// fallback for emoji is Apple Color Emoji.
    private func containsColorGlyphs(_ line: CTLine) -> Bool {
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).rawValue & (1 << 13) != 0 {
                return true
            }
        }
        return false
    }

    private func allocate(width: Int, height: Int) -> (page: Int, x: Int, y: Int)? {
        var page = pages.count - 1
        if pages[page].shelfX + width > dimension {
            // Start a new shelf below the tallest glyph on this one.
            pages[page].shelfX = 0
            pages[page].shelfY += pages[page].shelfHeight
            pages[page].shelfHeight = 0
        }
        if pages[page].shelfY + height > dimension, grow() {
            return allocate(width: width, height: height)
        }
        if pages[page].shelfY + height > dimension {
            // Only a complete visible-grid rebuild may exceed the cache
            // budget. Its page count is bounded by visible glyphs, not history.
            guard rebuildingVisibleGlyphs || pages.count < maximumPages,
                  let texture = Self.makeTexture(device: device, dimension: dimension)
            else {
                needsRebuild = true
                return nil
            }
            pages.append(Page(texture: texture))
            page += 1
        }
        let origin = (page: page, x: pages[page].shelfX, y: pages[page].shelfY)
        pages[page].shelfX += width
        pages[page].shelfHeight = max(pages[page].shelfHeight, height)
        return origin
    }

    /// Most terminal sessions use far fewer than a thousand distinct glyph
    /// variants, which fit comfortably in a 1024² atlas (4 MiB). Grow to the
    /// previous 2048² capacity only for a session that actually needs it.
    ///
    /// Growth invalidates every existing UV. The renderer observes
    /// `generation` and rebuilds all cached rows once against the new texture.
    private func grow() -> Bool {
        guard dimension < Self.maximumDimension else { return false }
        let nextDimension = min(dimension * 2, Self.maximumDimension)
        guard let nextTexture = Self.makeTexture(device: device, dimension: nextDimension) else {
            return false
        }
        replacePages(with: nextTexture, dimension: nextDimension)
        return true
    }
}
