//
//  TerminalFont.swift
//  zshell
//

import AppKit
import CoreText

/// Terminal font handling, same approach as Otty: bundle JetBrains Mono
/// with the app so the default looks identical on every machine, and let
/// the OS cascade cover glyphs the primary font lacks (CJK, symbols).
enum TerminalFont {
    static let defaultSize: CGFloat = 13
    static let bundledFamily = "JetBrains Mono"
    private static let symbolsFontName = "SymbolsNFM"

    /// Registers the bundled JetBrains Mono faces (Regular/Bold/Italic/
    /// BoldItalic) and the Symbols Nerd Font for this process only, so
    /// nothing is installed system-wide. Must run before the first
    /// terminal view is created.
    static func registerBundledFonts() {
        // Xcode's synchronized groups flatten Fonts/ into Contents/Resources.
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// The terminal font for the current settings (family + size).
    @MainActor
    static func current() -> NSFont {
        let settings = AppSettings.shared
        return resolve(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    }

    /// Resolves a family name to a terminal-ready font. Empty family means
    /// the bundled default; an unknown family falls back to it too.
    ///
    /// The optional user fallback precedes the bundled Symbols Nerd Font in
    /// the CoreText cascade. The symbols face still supplies PUA icon glyphs;
    /// JetBrains Mono covers Powerline separators itself.
    static func resolve(
        family: String,
        fallbackFamily: String = "",
        size: CGFloat
    ) -> NSFont {
        let base: NSFont
        if !family.isEmpty, family != bundledFamily,
           let chosen = font(family: family, size: size) {
            base = chosen
        } else if let bundled = NSFont(name: "JetBrainsMono-Regular", size: size) {
            base = bundled
        } else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        var cascade: [NSFontDescriptor] = []
        if !fallbackFamily.isEmpty,
           fallbackFamily != family,
           let fallback = font(family: fallbackFamily, size: size) {
            cascade.append(fallback.fontDescriptor)
        }
        cascade.append(NSFontDescriptor(name: symbolsFontName, size: size))
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func font(family: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(
            withFamily: family, traits: [], weight: 5, size: size
        )
    }

    /// Families with representative Chinese, Japanese, or Korean glyphs.
    /// Unlike the primary picker, these may be proportional: CoreText uses
    /// their glyph advances only when the Latin face has no matching glyph.
    static func selectableCJKFallbackFamilies() -> [String] {
        let manager = NSFontManager.shared
        let sample: [UniChar] = [0x4E2D, 0x65E5, 0xD55C]
        return manager.availableFontFamilies
            .filter { family in
                guard family != bundledFamily,
                      !family.hasPrefix("Symbols Nerd Font"),
                      !family.hasPrefix("."),
                      let font = manager.font(
                          withFamily: family, traits: [], weight: 5, size: 13
                      )
                else { return false }
                return sample.contains { character in
                    var codeUnit = character
                    var glyph = CGGlyph()
                    return CTFontGetGlyphsForCharacters(
                        font as CTFont, &codeUnit, &glyph, 1
                    ) && glyph != 0
                }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Some CJK terminal fonts use double-width ideographs and therefore do
    /// not set CoreText's strict fixed-pitch flag, even though their ASCII
    /// glyphs occupy one consistent terminal cell. Accept those when a
    /// representative ASCII sample has identical advances.
    private static func isTerminalMonospaced(_ font: NSFont) -> Bool {
        if font.isFixedPitch { return true }

        let characters: [UniChar] = Array(" ilMW01@#".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        guard
            CTFontGetGlyphsForCharacters(
                font as CTFont, characters, &glyphs, characters.count
            ), !glyphs.contains(0)
        else { return false }

        var advances = Array(repeating: CGSize.zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(
            font as CTFont, .horizontal, glyphs, &advances, glyphs.count
        )
        guard let width = advances.first?.width, width > 0 else { return false }
        return advances.dropFirst().allSatisfy { abs($0.width - width) < 0.01 }
    }

    /// Fixed-pitch families available for the font picker, bundled default
    /// first. The symbols-only fallback font is not a usable primary font.
    static func selectableFamilies() -> [String] {
        let families = NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard !family.hasPrefix("Symbols Nerd Font"),
                      family != bundledFamily, !family.hasPrefix("."),
                      let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
                else { return false }
                return isTerminalMonospaced(font)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [bundledFamily] + families
    }
}
