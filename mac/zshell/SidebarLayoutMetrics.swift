//
//  SidebarLayoutMetrics.swift
//  zshell
//

import AppKit

/// AppKit font measurements shared by both sidebar compositions.
struct SidebarLayoutMetrics {
    let fontScale: CGFloat
    let growthScale: CGFloat

    init(fontSize: Double) {
        let range = AppSettings.sidebarFontSizeRange
        let clamped = min(max(fontSize, range.lowerBound), range.upperBound)
        fontScale = CGFloat(clamped / AppSettings.defaultSidebarFontSize)
        growthScale = max(1, fontScale)
    }

    init(fontScale: CGFloat) {
        let minimum = CGFloat(
            AppSettings.sidebarFontSizeRange.lowerBound
                / AppSettings.defaultSidebarFontSize
        )
        let maximum = CGFloat(
            AppSettings.sidebarFontSizeRange.upperBound
                / AppSettings.defaultSidebarFontSize
        )
        self.fontScale = min(max(fontScale, minimum), maximum)
        growthScale = max(1, self.fontScale)
    }

    func minimumWidth(_ designedWidth: CGFloat) -> CGFloat {
        ceil(designedWidth * growthScale)
    }

    func iconSize(_ designedSize: CGFloat) -> CGFloat {
        ceil(designedSize * growthScale)
    }

    func slotSize(_ designedSize: CGFloat) -> CGFloat {
        ceil(designedSize * growthScale)
    }

    func lineHeight(
        designedFontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        minimum: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: designedFontSize * fontScale,
            weight: weight
        )
        return max(minimum, ceil(font.ascender - font.descender + font.leading))
    }
}
