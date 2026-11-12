import Foundation

@main
struct TerminalScrollScaleProbe {
    static func main() {
        let pixelWidth = 14.0
        let pixelHeight = 30.0
        let scale = 2.0
        let pointWidth = pixelWidth / scale
        let pointHeight = pixelHeight / scale

        expect(
            TerminalScrollSettings.ghosttyPrecisePixels(pointWidth, backingScale: scale) == pixelWidth,
            "scale 2 turns one point-cell width into one pixel-cell"
        )
        expect(
            TerminalScrollSettings.ghosttyPrecisePixels(pointHeight, backingScale: scale) == pixelHeight,
            "scale 2 turns one point-cell height into one pixel-cell"
        )
        expect(
            TerminalScrollSettings.ghosttyPrecisePixels(-pointHeight, backingScale: scale) == -pixelHeight,
            "scale 2 preserves the direction of a point-cell"
        )

        for value in [0.0, 1.0, -3.0, 0.25, pointWidth, pointHeight, pixelWidth, pixelHeight] {
            expect(
                TerminalScrollSettings.ghosttyPrecisePixels(value, backingScale: 1) == value,
                "scale 1 is identity for \(value)"
            )
        }

        for bad in [0.0, -2.0, Double.nan, Double.infinity, -Double.infinity] {
            let converted = TerminalScrollSettings.ghosttyPrecisePixels(pointHeight, backingScale: bad)
            expect(converted == pointHeight, "non-finite or non-positive scale uses 1")
        }
        expect(TerminalScrollSettings.ghosttyPrecisePixels(Double.nan, backingScale: scale).isNaN, "non-finite points stay non-finite")
        expect(TerminalScrollSettings.ghosttyPrecisePixels(Double.infinity, backingScale: scale).isInfinite, "infinite points stay infinite")

        // scrollWheel applies the conversion only for precise deltas. A wheel
        // tick stays the original value, including when the display scale is 2.
        let tick = 1.0
        let forwarded = forwardedDelta(tick, precise: false, backingScale: scale)
        expect(forwarded == tick, "wheel tick is not multiplied")
        expect(
            forwardedDelta(tick, precise: true, backingScale: scale) == tick * scale,
            "a precise tick-sized point delta is scaled"
        )

        var wheel = TerminalScrollAccumulator()
        let wheelColumns = wheel.consume(
            tick.rounded(), multiplier: 1, limit: TerminalScrollSettings.maximumApplicationLines
        )
        expect(wheelColumns == 1, "horizontal wheel tick is not multiplied")

        let pixelsPerPoint = TerminalScrollSettings.ghosttyPrecisePixels(1, backingScale: scale)
        let pointCellWidth = pixelWidth / pixelsPerPoint
        var trackpad = TerminalScrollAccumulator()
        let columns = trackpad.consume(
            pointWidth / pointCellWidth, multiplier: 1, limit: TerminalScrollSettings.maximumApplicationLines
        )
        let sent = Double(columns) * pixelWidth
        expect(columns == 1 && sent == pixelWidth, "one horizontal point-cell sends one pixel-cell")

        let limit = Double(TerminalScrollSettings.maximumApplicationLines) * pixelHeight
        let clamped = TerminalScrollSettings.boundedDelta(
            TerminalScrollSettings.ghosttyPrecisePixels(pointHeight, backingScale: scale),
            limit: limit
        )
        expect(clamped == pixelHeight, "one vertical point-cell survives the pixel clamp")
        print("terminal scroll scale checks passed")
    }

    private static func forwardedDelta(_ delta: Double, precise: Bool, backingScale: Double) -> Double {
        precise ? TerminalScrollSettings.ghosttyPrecisePixels(delta, backingScale: backingScale) : delta
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL \(message)\n", stderr)
            Foundation.exit(1)
        }
        print("PASS \(message)")
    }
}
