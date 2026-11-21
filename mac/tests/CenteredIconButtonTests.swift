import AppKit

@main
struct CenteredIconButtonTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let native = CommandLine.arguments.contains("--native")
        let symbols = [
            "square.and.arrow.down", "magnifyingglass", "arrow.up.forward.app",
            "arrow.clockwise", "ellipsis", "plus", "xmark", "pin", "gearshape",
            "rectangle.split.2x1", "rectangle.split.1x2", "stop.fill", "circle.dashed",
        ]
        let cases = symbols.map { ($0, false) } + symbols.prefix(3).map { ($0, true) }
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(name)") }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scale: CGFloat in [1, 1.5, 2] {
                for (symbol, optical) in cases {
                    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 22 * scale, height: 22 * scale))
                    if !native { button.cell = CenteredIconButtonCell(textCell: "") }
                    button.appearance = NSAppearance(named: appearance)
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyDown
                    button.isBordered = false
                    button.contentTintColor = .systemBlue
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 11 * scale, weight: .regular))
                    if optical { (button.cell as? CenteredIconButtonCell)?.opticalSize = 11 * scale }
                    let cell = button.cell as! NSButtonCell
                    let rect = cell.imageRect(forBounds: button.bounds)
                    if optical {
                        check(
                            abs(max(rect.width, rect.height) - 11 * scale) < 0.01,
                            "\(symbol) uses a uniform visible size at scale \(scale)")
                    } else {
                        check(
                            abs(rect.midY - button.bounds.midY) < 0.01
                                && abs(rect.midX - button.bounds.midX) < 0.01,
                            "\(symbol) image bounds center at scale \(scale)")
                    }
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(button.bounds.width * 2), pixelsHigh: Int(button.bounds.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
                    if button.isFlipped {
                        NSGraphicsContext.current!.cgContext.translateBy(x: 0, y: button.bounds.height)
                        NSGraphicsContext.current!.cgContext.scaleBy(x: 1, y: -1)
                    }
                    button.appearance?.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
                    NSGraphicsContext.restoreGraphicsState()
                    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
                    var hasTint = false
                    var totalAlpha: CGFloat = 0, weightedX: CGFloat = 0, weightedY: CGFloat = 0
                    for y in 0 ..< bitmap.pixelsHigh {
                        for x in 0 ..< bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0 {
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            totalAlpha += color.alphaComponent
                            weightedX += (CGFloat(x) + 0.5) / 2 * color.alphaComponent
                            weightedY += (CGFloat(y) + 0.5) / 2 * color.alphaComponent
                            hasTint = hasTint || color.blueComponent > color.redComponent
                        }
                    }
                    check(maxX >= minX && maxY >= minY, "\(symbol) draws a visible icon")
                    let centerX = optical ? weightedX / totalAlpha : CGFloat(minX + maxX + 1) / 4
                    let centerY = optical ? weightedY / totalAlpha : CGFloat(minY + maxY + 1) / 4
                    check(
                        abs(centerX - button.bounds.midX) <= (optical ? 0.35 : 0.26)
                            && abs(centerY - button.bounds.midY) <= (optical ? 0.35 : 0.26),
                        "\(symbol) rendered pixels center at scale \(scale): \(centerX), \(centerY)")
                    if optical {
                        let visibleSize = CGFloat(max(maxX - minX + 1, maxY - minY + 1)) / 2
                        check(
                            abs(visibleSize - 11 * scale) <= 0.6,
                            "\(symbol) rendered size matches its neighbors at scale \(scale): \(visibleSize)")
                    }
                    check(hasTint, "\(symbol) keeps template tint")
                }
            }
        }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        button.cell = CenteredIconButtonCell(textCell: "")
        button.title = "Action"
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        let imageRect = button.cell!.imageRect(forBounds: button.bounds)
        let titleRect = button.cell!.titleRect(forBounds: button.bounds)
        check(
            imageRect.width > 0 && titleRect.width > 0 && imageRect.maxX <= titleRect.minX,
            "text buttons keep the icon beside the title")
        print("Icon alignment: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
