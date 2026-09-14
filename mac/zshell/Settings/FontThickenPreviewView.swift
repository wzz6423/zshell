//
//  FontThickenPreviewView.swift
//  zshell
//

import AppKit

/// Terminal font preview shared by the family, line-height, and thickening
/// controls. It uses CoreText's smoothing flag plus the same normalized stroke
/// mapping as the Alacritty backend; Ghostty's native raster can differ slightly.
final class FontThickenPreviewView: NSView {
    var previewFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var thicken = false
    var thickenStrength = AppSettings.defaultFontThickenStrength
    var lineHeight: CGFloat = 1

    /// Regular, icon, and bold samples: the glyphs whose weight the setting
    /// visibly changes.
    private let lines: [(text: String, bold: Bool)] = [
        ("zshell ❯ printf \"中文 日本語 한국어\" 0O 1lI", false),
        ("\u{E0A0} main \u{E0B0} ~/dev/zshell \u{E711} \u{F024B} \u{F0A7D}", false),
        ("bold — permission denied (os error 13)", true),
    ]

    private let lineSpacing: CGFloat = 6
    private let verticalPadding: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Drawn text has no semantic children of its own; read the sample out
        // so VoiceOver still reaches it.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(lines.map(\.text).joined(separator: "\n"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The sample's height follows the font, so both settings arrive together
    /// and the layout is invalidated with the drawing.
    func configure(
        font: NSFont,
        thicken: Bool,
        thickenStrength: Int,
        lineHeight: CGFloat
    ) {
        guard previewFont != font
            || self.thicken != thicken
            || self.thickenStrength != thickenStrength
            || self.lineHeight != lineHeight
        else { return }
        previewFont = font
        self.thicken = thicken
        self.thickenStrength = thickenStrength
        self.lineHeight = lineHeight
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let rowHeight = ceil(previewFont.boundingRectForFont.height * lineHeight)
        let height = verticalPadding * 2
            + CGFloat(lines.count) * rowHeight
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Mirror Ghostty's CoreText glyph path (face/coretext.zig):
        // font-thicken == shouldSmoothFonts.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(thicken)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let color = NSColor.labelColor
        var y = verticalPadding
        let rowHeight = ceil(previewFont.boundingRectForFont.height * lineHeight)
        for (text, bold) in lines {
            let font = bold
                ? NSFontManager.shared.convert(previewFont, toHaveTrait: .boldFontMask)
                : previewFont
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if thicken {
                let strength = min(max(thickenStrength, 0), 255)
                attrs[.strokeColor] = color
                attrs[.strokeWidth] = -(0.5 + CGFloat(strength) / 255 * 1.5)
            }
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            y += rowHeight + lineSpacing
        }
    }
}
