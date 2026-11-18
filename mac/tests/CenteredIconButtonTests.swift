import AppKit

@main
struct CenteredIconButtonTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let native = CommandLine.arguments.contains("--native")
        let symbols = ["square.and.arrow.down", "magnifyingglass", "arrow.up.forward.app",
                       "arrow.clockwise", "ellipsis", "plus", "xmark", "pin", "gearshape",
                       "rectangle.split.2x1", "rectangle.split.1x2", "stop.fill", "circle.dashed"]
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(name)") }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scale: CGFloat in [1, 1.5, 2] {
                for symbol in symbols {
                    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 22 * scale, height: 22 * scale))
                    if !native { button.cell = CenteredIconButtonCell(textCell: "") }
                    button.appearance = NSAppearance(named: appearance)
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyDown
                    button.isBordered = false
                    button.contentTintColor = .systemBlue
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 11 * scale, weight: .regular))
                    let cell = button.cell as! NSButtonCell
                    let rect = cell.imageRect(forBounds: button.bounds)
                    check(abs(rect.midY - button.bounds.midY) < 0.01
                        && abs(rect.midX - button.bounds.midX) < 0.01,
                        "\(symbol) image bounds center at scale \(scale)")
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: Int(button.bounds.width * 2), pixelsHigh: Int(button.bounds.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
                    button.appearance?.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
                    NSGraphicsContext.restoreGraphicsState()
                    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
                    var hasTint = false
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0 {
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            hasTint = hasTint || color.blueComponent > color.redComponent
                        }
                    }
                    check(maxX >= minX && maxY >= minY, "\(symbol) draws a visible icon")
                    let centerX = CGFloat(minX + maxX + 1) / 4
                    let centerY = CGFloat(minY + maxY + 1) / 4
                    check(abs(centerX - button.bounds.midX) <= 0.26
                        && abs(centerY - button.bounds.midY) <= 0.26,
                        "\(symbol) rendered pixels center at scale \(scale): \(centerX), \(centerY)")
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
        check(imageRect.width > 0 && titleRect.width > 0 && imageRect.maxX <= titleRect.minX,
              "text buttons keep the icon beside the title")
        print("Icon alignment: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
