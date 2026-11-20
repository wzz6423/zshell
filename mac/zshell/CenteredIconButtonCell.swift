import AppKit

final class CenteredIconButtonCell: NSButtonCell {
    var opticalSize: CGFloat?
    override var image: NSImage? { didSet { renderedImage = nil } }
    private var sourceScale: CGFloat = 0
    private var renderedImage: CGImage?
    private var opticalCenter = NSPoint(x: 0.5, y: 0.5)

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
        if let opticalSize {
            let scale = opticalSize / max(size.width, size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        switch imageScaling {
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            let scale = imageScaling == .scaleProportionallyDown ? min(1, fit) : fit
            size = NSSize(width: size.width * scale, height: size.height * scale)
        case .scaleAxesIndependently:
            size = bounds.size
        default: break
        }
        let center = opticalSize == nil ? NSPoint(x: 0.5, y: 0.5) : opticalCenter
        let centerY = controlView?.isFlipped == true ? 1 - center.y : center.y
        return NSRect(x: bounds.midX - size.width * center.x, y: bounds.midY - size.height * centerY,
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
        var totalAlpha: CGFloat = 0, weightedX: CGFloat = 0, weightedY: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                let alpha = CGFloat(data[y * bitmap.bytesPerRow + x * 4 + 3])
                totalAlpha += alpha
                weightedX += (CGFloat(x) + 0.5) * alpha
                weightedY += (CGFloat(y) + 0.5) * alpha
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A protruding arrow changes a symbol's visual weight without moving its bounds center.
        opticalCenter = NSPoint(x: (weightedX / totalAlpha - CGFloat(minX)) / CGFloat(maxX - minX + 1),
                                y: (CGFloat(maxY + 1) - weightedY / totalAlpha) / CGFloat(maxY - minY + 1))
        renderedImage = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1))
        return renderedImage
    }
}
