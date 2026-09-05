//
//  FontThickenPreviewView.swift
//  zshell
//

import AppKit

/// Font preview that honors `font-thicken`. Ghostty thickens by enabling
/// CoreText font smoothing when rasterizing glyphs, which no ordinary text
/// control does — so the sample is drawn by hand with `shouldSmoothFonts`
/// matching the setting.
final class FontThickenPreviewView: NSView {
    var previewFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var thicken = false

    /// Regular, icon, and bold samples: the glyphs whose weight the setting
    /// visibly changes.
    private let lines: [(text: String, bold: Bool)] = [
        ("zshell ❯ echo \"the quick brown fox\" 0O 1lI", false),
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

    /// The sample's height follows the font, so both settings arrive together
    /// and the layout is invalidated with the drawing.
    func configure(font: NSFont, thicken: Bool) {
        guard previewFont != font || self.thicken != thicken else { return }
        previewFont = font
        self.thicken = thicken
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        let height = verticalPadding * 2
            + CGFloat(lines.count) * lineHeight
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
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        for (text, bold) in lines {
            let font = bold
                ? NSFontManager.shared.convert(previewFont, toHaveTrait: .boldFontMask)
                : previewFont
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            y += lineHeight + lineSpacing
        }
    }
}
