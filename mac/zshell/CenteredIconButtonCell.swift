import AppKit

final class CenteredIconButtonCell: NSButtonCell {
    override var image: NSImage? { didSet { renderedImage = nil } }
    private var sourceScale: CGFloat = 0
    private var renderedImage: CGImage?

    override func imageRect(forBounds bounds: NSRect) -> NSRect {
        guard imagePosition == .imageOnly, let image,
              let icon = raster(for: image, scale: controlView?.window?.backingScaleFactor ?? 2)
        else { return super.imageRect(forBounds: bounds) }
        return centeredRect(for: icon, in: bounds)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in view: NSView) {
        guard imagePosition == .imageOnly,
              let icon = raster(for: image, scale: view.window?.backingScaleFactor ?? 2),
              let context = NSGraphicsContext.current?.cgContext
        else { super.drawImage(image, withFrame: frame, in: view); return }
        let scale = sourceScale
        var rect = centeredRect(for: icon, in: view.bounds)
        rect.origin.x = (rect.minX * scale).rounded() / scale
        rect.origin.y = (rect.minY * scale).rounded() / scale
        context.saveGState()
        context.setAlpha(!isEnabled && imageDimsWhenDisabled ? 0.35 : isHighlighted ? 0.65 : 1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if view.isFlipped {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            rect.origin = .zero
        }
        context.draw(icon, in: rect)
        if image.isTemplate {
            let color = (view as? NSButton)?.contentTintColor ?? .controlTextColor
            context.setBlendMode(.sourceIn)
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func centeredRect(for icon: CGImage, in bounds: NSRect) -> NSRect {
        var size = NSSize(width: CGFloat(icon.width) / sourceScale, height: CGFloat(icon.height) / sourceScale)
        switch imageScaling {
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            let scale = imageScaling == .scaleProportionallyDown ? min(1, fit) : fit
            size = NSSize(width: size.width * scale, height: size.height * scale)
        case .scaleAxesIndependently:
            size = bounds.size
        default: break
        }
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func raster(for image: NSImage, scale: CGFloat) -> CGImage? {
        if let renderedImage, sourceScale == scale { return renderedImage }
        sourceScale = scale
        renderedImage = nil
        let size = image.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData
        else { return nil }
        bitmap.size = size
        context.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // Symbol baseline padding is useful beside text, but offsets standalone icons.
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        renderedImage = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1))
        return renderedImage
    }
}
